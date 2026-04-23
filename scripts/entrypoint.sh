#!/bin/sh
# Railway container entrypoint.
# Order matters: bring up tailnet → start whisper.cpp fallback → bootstrap
# CLI credentials → exec the Node server (PID 2 under tini).

set -eu

log() {
  printf '[%s] [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# ─── 1. Tailscale (userspace networking) ──────────────────────────────────────
# Skipped silently if TS_AUTHKEY is not set; the Discord voice bot will just
# fall back to the local whisper.cpp server.
if [ -n "${TS_AUTHKEY:-}" ]; then
  log "starting tailscaled (userspace-networking)"
  mkdir -p /var/lib/tailscale /var/run/tailscale
  tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --tun=userspace-networking \
    > /var/log/tailscaled.log 2>&1 &

  # Give tailscaled a moment to create the socket.
  i=0
  while [ ! -S /var/run/tailscale/tailscaled.sock ] && [ $i -lt 20 ]; do
    i=$((i + 1))
    sleep 0.25
  done

  TS_HOSTNAME="${TS_HOSTNAME:-openclaw-railway}"
  log "tailscale up hostname=${TS_HOSTNAME} ephemeral=yes"
  if ! tailscale --socket=/var/run/tailscale/tailscaled.sock up \
      --authkey="${TS_AUTHKEY}" \
      --hostname="${TS_HOSTNAME}" \
      --accept-routes \
      --accept-dns=false \
      --ssh=false \
      >> /var/log/tailscaled.log 2>&1; then
    log "WARN: tailscale up failed — continuing without tailnet (see /var/log/tailscaled.log)"
  else
    log "tailscale up ok"
  fi

  # Export socket path so any tailscale CLI calls from child processes work.
  export TS_SOCKET=/var/run/tailscale/tailscaled.sock
else
  log "TS_AUTHKEY not set — skipping tailscale bootstrap"
fi

# ─── 2. Whisper.cpp fallback transcription server ─────────────────────────────
# Binds to 127.0.0.1 only. Used by tools/discord_voice.py when the primary
# Wyoming server on the tailnet is unreachable.
WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-/opt/whisper.cpp/models/ggml-base.bin}"
WHISPER_PORT="${WHISPER_CPP_PORT:-8723}"
if [ -x /usr/local/bin/whisper-server ] && [ -f "${WHISPER_MODEL_PATH}" ]; then
  log "starting whisper.cpp server on 127.0.0.1:${WHISPER_PORT}"
  /usr/local/bin/whisper-server \
    --host 127.0.0.1 \
    --port "${WHISPER_PORT}" \
    --model "${WHISPER_MODEL_PATH}" \
    --threads "${WHISPER_CPP_THREADS:-2}" \
    > /var/log/whisper-server.log 2>&1 &
else
  log "whisper.cpp server or model missing — fallback unavailable"
fi

# ─── 3. Bootstrap CLI credentials ─────────────────────────────────────────────
if [ -f /app/scripts/bootstrap-cli-credentials.sh ]; then
  sh /app/scripts/bootstrap-cli-credentials.sh || log "WARN: credential bootstrap exited non-zero"
fi

# ─── 4. Start the Node server as PID 2 ─────────────────────────────────────────
log "exec node src/server.js"
exec node src/server.js
