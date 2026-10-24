#!/usr/bin/env bash
set -uo pipefail
ROOT="${1:?usage: .decrypt.sh <project-dir>}"
VAULT_DIR="$HOME/vault"
AGE_KEY='__AGE_KEY__'
DOT="__dot__"

REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
REPO="$(basename -s .git "$REMOTE" 2>/dev/null || true)"
[ -n "$REPO" ] || REPO="$(basename "$ROOT")"
SRCDIR="$VAULT_DIR/_env/$REPO"

[ -d "$SRCDIR" ] || { echo "no _env/$REPO in vault"; exit 0; }
command -v age >/dev/null 2>&1 || { echo "age missing"; exit 0; }

umask 077
shopt -s nullglob
for enc in "$SRCDIR"/*.age; do
  name="$(basename "$enc" .age)"; name="${name//$DOT/.}"   # decode __dot__ -> .
  dest="$ROOT/$name"
  [ -e "$dest" ] && { echo "skip existing $name"; continue; }
  if age -d -i <(printf '%s\n' "$AGE_KEY") "$enc" > "$dest"; then
    echo "wrote $name"
  else
    rm -f "$dest"; echo "decrypt failed for $name"
  fi
done
