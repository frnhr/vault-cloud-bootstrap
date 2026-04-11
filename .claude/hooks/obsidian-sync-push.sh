#!/usr/bin/env bash
set -euo pipefail

# Stop hook: blocking push of any vault changes back to Obsidian Sync.

VAULT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/vault"

echo "[obsidian-sync-push] Pushing vault changes via Obsidian Sync..."
ob sync --vault "$VAULT_DIR"
echo "[obsidian-sync-push] Vault synced."
