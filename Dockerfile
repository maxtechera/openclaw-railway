# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.4.21
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build

# Patch: remove the hardcoded "complex interpreter invocation" exec preflight block
# so agents can use shell pipelines and ANSI-C quoting (e.g. || fallbacks, $'...' args).
# The check has no config bypass; this is the only way to allow it in a trusted deployment.
# NOTE: uses find+python inline to avoid Docker layer caching masking the patch.
RUN find /openclaw/dist/ -name '*.js' -exec grep -l 'complex interpreter invocation detected' {} \; \
  | xargs -I FILE python3 -c "
import re, sys
path = sys.argv[1]
content = open(path).read()
patched = re.sub(
  r'if \(hasInterpreterInvocation && hasComplexSyntax && \([^)]+\)\) throw new Error\(\"exec preflight: complex interpreter invocation detected[^\"]*\"\);',
  '/* exec preflight: complex interpreter invocation check removed for trusted deployment */',
  content
)
assert patched != content, 'pattern not found — check regex'
open(path, 'w').write(patched)
print('patched', path)
" FILE


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=7168"

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    python3 \
    python3-pip \
    python3-venv \
    pipx \
  && rm -rf /var/lib/apt/lists/*

# Cache-bust: 2026-04-08 session-prune bootstrap
# Optional: bake runtime-installed dependencies into the image so they survive redeploys.
# Example (Railway build args):
#   RUNTIME_APT_PACKAGES="ffmpeg jq"
#   RUNTIME_NPM_GLOBAL_PACKAGES="acpx"
ARG RUNTIME_APT_PACKAGES="git curl wget jq ffmpeg sqlite3 ripgrep tmux gh chromium imagemagick poppler-utils tesseract-ocr xz-utils libopus0 libopus-dev libsodium23 libsodium-dev build-essential cmake iptables iproute2"
RUN if [ -n "${RUNTIME_APT_PACKAGES}" ]; then \
      apt-get update \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${RUNTIME_APT_PACKAGES} \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

ARG RUNTIME_NPM_GLOBAL_PACKAGES="acpx clawhub"
RUN if [ -n "${RUNTIME_NPM_GLOBAL_PACKAGES}" ]; then \
      npm install -g --omit=dev ${RUNTIME_NPM_GLOBAL_PACKAGES} \
      && npm cache clean --force; \
    fi

# Bake Python-based CLI tools into the image
RUN pipx install yt-dlp && pipx ensurepath
ENV PATH="/root/.local/bin:${PATH}"

# Install gogcli (Google Workspace CLI — Gmail, Calendar, Drive, Sheets, etc.)
ARG GOGCLI_VERSION=0.12.0
RUN curl -fsSL "https://github.com/steipete/gogcli/releases/download/v${GOGCLI_VERSION}/gogcli_${GOGCLI_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin gog \
    && chmod +x /usr/local/bin/gog

# Install schpet/linear-cli (Linear issue tracker CLI — replaces python tools/linear.py)
ARG LINEAR_CLI_VERSION=1.11.1
RUN curl -fsSL "https://github.com/schpet/linear-cli/releases/download/v${LINEAR_CLI_VERSION}/linear-x86_64-unknown-linux-gnu.tar.xz" \
    | tar -xJ --strip-components=1 -C /usr/local/bin linear-x86_64-unknown-linux-gnu/linear \
    && chmod +x /usr/local/bin/linear

# Install Tailscale (userspace-networking mode — no TUN, no NET_ADMIN caps required).
# Used by discord voice transcription to reach the home-lab Wyoming/Whisper server
# over the tailnet. Auth key is provided via TS_AUTHKEY env var; the node registers
# itself as ephemeral so Railway redeploys don't accumulate ghost nodes.
ARG TAILSCALE_VERSION=1.80.3
RUN curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz" \
    | tar -xz -C /tmp \
    && mv /tmp/tailscale_${TAILSCALE_VERSION}_amd64/tailscale /usr/local/bin/tailscale \
    && mv /tmp/tailscale_${TAILSCALE_VERSION}_amd64/tailscaled /usr/local/bin/tailscaled \
    && chmod +x /usr/local/bin/tailscale /usr/local/bin/tailscaled \
    && rm -rf /tmp/tailscale_${TAILSCALE_VERSION}_amd64

# Build whisper.cpp as a fallback transcription server for Discord voice.
# Runs on 127.0.0.1:8723 when the Windows tailnet host is unreachable.
# Uses ggml-base.bin (~142MB, multilingual, CPU-friendly).
ARG WHISPER_CPP_REF=v1.7.1
ARG WHISPER_CPP_MODEL=base
RUN git clone --depth 1 --branch "${WHISPER_CPP_REF}" https://github.com/ggerganov/whisper.cpp.git /opt/whisper.cpp \
    && cd /opt/whisper.cpp \
    && make -j server \
    && bash ./models/download-ggml-model.sh "${WHISPER_CPP_MODEL}" \
    && ln -s /opt/whisper.cpp/server /usr/local/bin/whisper-server \
    && find /opt/whisper.cpp -type d \( -name '.git' -o -name 'samples' -o -name 'tests' \) -prune -exec rm -rf {} +

# Python deps for the Discord voice bot (py-cord with voice support + aiohttp).
# Wyoming protocol is implemented inline in tools/discord_voice.py so no extra
# package needed there. PyNaCl is required by py-cord for voice encryption.
RUN pip3 install --no-cache-dir --break-system-packages \
    "py-cord[voice]==2.6.1" \
    "PyNaCl>=1.5.0" \
    "aiohttp>=3.9.0"

# Persist user-installed tools by default by targeting the Railway volume.
# - npm global installs -> /data/npm
# - pnpm global installs -> /data/pnpm (binaries) + /data/pnpm-store (store)
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
# /usr/local/bin comes first so the built openclaw wrapper always shadows any
# npm-globally-installed version that may persist on the /data volume between deploys.
ENV PATH="/usr/local/bin:/data/npm/bin:/data/pnpm:${PATH}"

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src
COPY scripts ./scripts

# The wrapper listens on $PORT.
# IMPORTANT: Do not set a default PORT here.
# Railway injects PORT at runtime and routes traffic to that port.
# If we force a different port, deployments can come up but the domain will route elsewhere.
EXPOSE 8080

COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN chmod +x /app/scripts/entrypoint.sh

# Ensure PID 1 reaps zombies and forwards signals.
ENTRYPOINT ["tini", "--"]
# entrypoint.sh boots tailscaled (userspace-networking), starts whisper.cpp fallback,
# bootstraps CLI credentials, then execs the Node server.
CMD ["/app/scripts/entrypoint.sh"]
