#!/usr/bin/env bash
# Bootstrap CLI credentials from Railway env vars on container start.
# Runs before server.js. Idempotent — skips if credentials already configured.
set -u

linear_creds="${HOME}/.config/linear/credentials.toml"

if command -v linear >/dev/null 2>&1 && [ ! -f "$linear_creds" ]; then
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    echo "[bootstrap] linear auth login from LINEAR_API_KEY"
    linear auth login -k "$LINEAR_API_KEY" 2>&1 | sed 's/^/[linear] /' || echo "[bootstrap] linear auth login failed (non-fatal)"
  else
    echo "[bootstrap] LINEAR_API_KEY not set — skipping linear CLI auth"
  fi
fi
