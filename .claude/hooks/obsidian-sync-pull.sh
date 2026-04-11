#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook: installs obsidian-headless on first run in a fresh
# sandbox, authenticates with env-var credentials, and does a blocking pull
# of the remote vault into ./vault/.

VAULT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/vault"

# Idempotent install — only first cloud session in a fresh sandbox
if ! command -v ob >/dev/null 2>&1; then
  echo "[obsidian-sync-pull] Installing obsidian-headless..."
  npm install -g obsidian-headless
fi

# Node 22's built-in fetch/WebSocket (internal undici) ignore HTTPS_PROXY.
# Install proxy-support packages once and wire them in via NODE_OPTIONS.
GLOBAL_NODE_MODULES=$(npm root -g)
for pkg in undici ws; do
  if [ ! -d "$GLOBAL_NODE_MODULES/$pkg" ]; then
    echo "[obsidian-sync-pull] Installing $pkg for proxy support..."
    npm install -g "$pkg"
  fi
done
# https-proxy-agent v5 is required (v6+ are ESM-only, incompatible with require())
if ! node -e "require('$GLOBAL_NODE_MODULES/https-proxy-agent')" 2>/dev/null; then
  echo "[obsidian-sync-pull] Installing https-proxy-agent@5 for proxy support..."
  npm install -g https-proxy-agent@5
fi

# Route all ob fetch + WebSocket calls through the sandbox proxy.
export GLOBAL_NODE_MODULES
export NODE_PATH="$GLOBAL_NODE_MODULES"
BOOTSTRAP="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/hooks/node-proxy-bootstrap.js"
export NODE_OPTIONS="--require $BOOTSTRAP"

# Fail loudly and early if credentials were not injected
: "${OBSIDIAN_EMAIL:?OBSIDIAN_EMAIL env var is not set — configure it in the Claude Code cloud session}"
: "${OBSIDIAN_PASSWORD:?OBSIDIAN_PASSWORD env var is not set}"
: "${OBSIDIAN_VAULT_NAME:?OBSIDIAN_VAULT_NAME env var is not set}"
: "${OBSIDIAN_VAULT_PASSWORD:?OBSIDIAN_VAULT_PASSWORD env var is not set}"

# Idempotent first-run auth + remote vault pairing.
# Credentials come from env vars; never written into the repo or the vault.
OB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless"
if [ ! -f "$OB_CONFIG_DIR/auth_token" ]; then
  echo "[obsidian-sync-pull] First run in this sandbox — authenticating..."
  ob login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" \
    ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"}

  echo "[obsidian-sync-pull] Pairing local ./vault with remote vault '$OBSIDIAN_VAULT_NAME'..."
  ob sync-setup --path "$VAULT_DIR" \
    --vault "$OBSIDIAN_VAULT_NAME" \
    --password "$OBSIDIAN_VAULT_PASSWORD"
fi

echo "[obsidian-sync-pull] Pulling vault from Obsidian Sync..."
ob sync --path "$VAULT_DIR"
echo "[obsidian-sync-pull] Vault ready at $VAULT_DIR"
