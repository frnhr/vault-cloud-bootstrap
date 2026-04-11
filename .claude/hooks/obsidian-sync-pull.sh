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

# Node 22's built-in fetch (undici) ignores HTTPS_PROXY. Install the npm
# undici package (once) so its ProxyAgent can be wired in via NODE_OPTIONS.
GLOBAL_NODE_MODULES=$(npm root -g)
if [ ! -d "$GLOBAL_NODE_MODULES/undici" ]; then
  echo "[obsidian-sync-pull] Installing undici for proxy support..."
  npm install -g undici
fi

# Route all ob fetch calls through the sandbox proxy.
export GLOBAL_NODE_MODULES
BOOTSTRAP="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/hooks/node-proxy-bootstrap.js"
export NODE_OPTIONS="--require $BOOTSTRAP"

# Fail loudly and early if credentials were not injected
: "${OBSIDIAN_EMAIL:?OBSIDIAN_EMAIL env var is not set — configure it in the Claude Code cloud session}"
: "${OBSIDIAN_PASSWORD:?OBSIDIAN_PASSWORD env var is not set}"
: "${OBSIDIAN_VAULT_NAME:?OBSIDIAN_VAULT_NAME env var is not set}"
: "${OBSIDIAN_VAULT_PASSWORD:?OBSIDIAN_VAULT_PASSWORD env var is not set}"

# Idempotent first-run auth + remote vault pairing.
# Credentials come from env vars; never written into the repo or the vault.
if [ ! -f "$HOME/.obsidian-headless/config.json" ]; then
  echo "[obsidian-sync-pull] First run in this sandbox — authenticating..."
  ob login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" \
    ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"}

  echo "[obsidian-sync-pull] Pairing local ./vault with remote vault '$OBSIDIAN_VAULT_NAME'..."
  ob sync-setup --path "$VAULT_DIR" \
    --vault "$OBSIDIAN_VAULT_NAME" \
    --password "$OBSIDIAN_VAULT_PASSWORD"
fi

echo "[obsidian-sync-pull] Pulling vault from Obsidian Sync..."
ob sync --vault "$VAULT_DIR"
echo "[obsidian-sync-pull] Vault ready at $VAULT_DIR"
