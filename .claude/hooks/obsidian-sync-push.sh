#!/usr/bin/env bash
set -euo pipefail

# Stop hook: blocking push of any vault changes back to Obsidian Sync.

VAULT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/vault"

# Node 22.19+ supports HTTPS_PROXY natively via --use-env-proxy.
export NODE_OPTIONS="--use-env-proxy"

echo "[obsidian-sync-push] Pushing vault changes via Obsidian Sync..."
ob sync --path "$VAULT_DIR"
echo "[obsidian-sync-push] Vault synced."
