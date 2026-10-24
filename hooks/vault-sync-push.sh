#!/usr/bin/env bash
set -euo pipefail
LOG="$HOME/.claude/hooks/vault-sync-push.log"
VAULT_DIR="$HOME/vault"
[ -d "$VAULT_DIR" ] || exit 0
if [ -e "$VAULT_DIR/.seeded-from-git" ]; then
  echo "[vault-sync] git seed not reconciled yet; push skipped." >>"$LOG"
  exit 0
fi
command -v ob >/dev/null 2>&1 || { echo "[vault-sync] ob missing; edits NOT pushed" >>"$LOG"; exit 0; }
export NODE_OPTIONS="--use-env-proxy --disable-warning=UNDICI-EHPA"
echo "[vault-sync] $(date -Is) push start" >>"$LOG"
if ! ob sync --path "$VAULT_DIR" 2>&1 | { grep --line-buffered -vE '^(Checking|Downloading) ' || true; } >>"$LOG"; then
  echo "[vault-sync] PUSH FAILED; vault edits NOT synced. See $LOG." >>"$LOG"
fi
exit 0
