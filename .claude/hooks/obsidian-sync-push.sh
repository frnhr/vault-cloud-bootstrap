#!/usr/bin/env bash
set -euo pipefail

# Stop hook: blocking push of any vault changes back to Obsidian Sync.

VAULT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/vault"

# Route ob fetch calls through the sandbox proxy (same as pull hook).
GLOBAL_NODE_MODULES=$(npm root -g)
export GLOBAL_NODE_MODULES
BOOTSTRAP="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/hooks/node-proxy-bootstrap.js"
export NODE_OPTIONS="--require $BOOTSTRAP"

echo "[obsidian-sync-push] Pushing vault changes via Obsidian Sync..."
ob sync --path "$VAULT_DIR"
echo "[obsidian-sync-push] Vault synced."
