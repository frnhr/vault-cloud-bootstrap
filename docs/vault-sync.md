# Vault sync setup

This repo wires up **Claude Code cloud sessions** (Claude Code on the Web) so
they can edit one Obsidian vault. The vault lives in Obsidian Sync and is never
committed to git; it is pulled into the sandbox at session start and pushed back
at session stop via [`obsidian-headless`](https://github.com/obsidianmd/obsidian-headless).

## Architecture

The sync machinery is **not** shipped as repo-level hooks. Instead, a single
init script installs `obsidian-headless` and writes two **user-level** hooks
into `~/.claude/`:

- `~/.claude/hooks/vault-sync-pull.sh` — registered as a **SessionStart** hook.
- `~/.claude/hooks/vault-sync-push.sh` — registered as a **Stop** hook.
- Both are registered in `~/.claude/settings.json` (merged, not clobbered, so
  existing hooks are preserved).

The vault materializes at **`$HOME/vault/`**. Read `$HOME/vault/_GUIDE.md`
before editing anything.

Why user-level instead of repo-level hooks? It keeps the repo free of
executable wiring, lets the same setup serve any repo in the account, and the
init script is idempotent so resumed sandboxes are a no-op.

## How to install

Run the init script below as the environment's **setup script** in the Claude
Code on the Web session config (or paste it into a fresh sandbox once). It is
safe to re-run.

```bash
#!/usr/bin/env bash
set -euo pipefail

# vault-sync init: install obsidian-headless once, drop user-level
# SessionStart/Stop hooks, register them in ~/.claude/settings.json.
# Idempotent — safe to re-run on resumed sandboxes.

# 1. Install obsidian-headless eagerly so first SessionStart hook is fast
if ! command -v ob >/dev/null 2>&1; then
  npm install -g obsidian-headless
fi

# 2. Write SessionStart pull hook
mkdir -p ~/.claude/hooks
cat > ~/.claude/hooks/vault-sync-pull.sh <<'PULL'
#!/usr/bin/env bash
set -euo pipefail

LOG="$HOME/.claude/hooks/vault-sync-pull.log"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

fail() { echo "[vault-sync] $1 — see $LOG"; exit 0; }

for v in OBSIDIAN_EMAIL OBSIDIAN_PASSWORD OBSIDIAN_VAULT_NAME OBSIDIAN_VAULT_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo "[vault-sync] $v not set — vault sync skipped."
    exit 0
  fi
done

VAULT_DIR="$HOME/vault"
mkdir -p "$VAULT_DIR"

if ! command -v ob >/dev/null 2>&1; then
  npm install -g obsidian-headless >>"$LOG" 2>&1 \
    || fail "obsidian-headless install failed"
fi

export NODE_OPTIONS="--use-env-proxy"

# Diagnostic: capture the raw /user/signin response.
# obsidian-headless logs in via `POST https://api.obsidian.md/user/signin` and
# JSON.parse()s the body *internally*, so an HTML error page (seen at cold
# container start — the egress proxy returns a gateway page before it is warm,
# recovers on retry) only surfaces as "SyntaxError: Unexpected token '<'" with
# no body. We re-issue the request with curl and save the raw response so the
# HTML can be inspected. A dummy body is sent — no real credentials are used.
OB_SIGNIN_URL="https://api.obsidian.md/user/signin"
capture_signin_response() {
  local label="$1" out
  out="$HOME/.claude/hooks/signin-$(date +%Y%m%dT%H%M%S)-${label}.http"
  {
    echo "# $(date -Is) — ${label} probe of ${OB_SIGNIN_URL} (dummy body, no credentials)"
    echo
    curl -sS -m 20 -X POST "$OB_SIGNIN_URL" \
      -H 'Content-Type: application/json' \
      -H 'Origin: https://obsidian.md' \
      --data '{}' -D - 2>&1
  } >"$out" 2>&1 || true
  echo "[vault-sync] signin response captured -> $out" >>"$LOG"
}

OB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless"
if [ ! -f "$OB_CONFIG_DIR/auth_token" ]; then
  capture_signin_response precold
  ob login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" \
    ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"} >>"$LOG" 2>&1 \
    || { capture_signin_response postfail; fail "login failed — inspect $HOME/.claude/hooks/signin-*.http"; }
  ob sync-setup --path "$VAULT_DIR" \
    --vault "$OBSIDIAN_VAULT_NAME" --password "$OBSIDIAN_VAULT_PASSWORD" >>"$LOG" 2>&1 \
    || fail "pairing failed"
fi

ob sync --path "$VAULT_DIR" >>"$LOG" 2>&1 \
  || fail "pull failed — vault may be stale"

echo "[vault-sync] Vault ready at $VAULT_DIR (read $VAULT_DIR/_GUIDE.md before editing)."
PULL
chmod +x ~/.claude/hooks/vault-sync-pull.sh

# 3. Write Stop push hook
cat > ~/.claude/hooks/vault-sync-push.sh <<'PUSH'
#!/usr/bin/env bash
set -euo pipefail

LOG="$HOME/.claude/hooks/vault-sync-push.log"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

VAULT_DIR="$HOME/vault"
[ -d "$VAULT_DIR" ] || exit 0

if ! command -v ob >/dev/null 2>&1; then
  echo "[vault-sync] ob CLI missing — vault edits NOT pushed!"
  exit 0
fi

export NODE_OPTIONS="--use-env-proxy"

if ! ob sync --path "$VAULT_DIR" >>"$LOG" 2>&1; then
  echo "[vault-sync] PUSH FAILED — vault edits NOT synced. See $LOG. Investigate before sandbox is discarded."
  exit 0
fi

echo "[vault-sync] Vault pushed."
PUSH
chmod +x ~/.claude/hooks/vault-sync-push.sh

# 4. Merge hook registrations into ~/.claude/settings.json
#    (skip-if-already-present so re-runs don't add duplicates;
#     preserves existing hooks like stop-hook-git-check.sh)
python3 - <<'PY'
import json, os

path = os.path.expanduser("~/.claude/settings.json")
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)

hooks = cfg.setdefault("hooks", {})

def ensure(event, command, timeout):
    entries = hooks.setdefault(event, [])
    for entry in entries:
        for h in entry.get("hooks", []):
            if h.get("command") == command:
                return
    entries.append({
        "matcher": "*",
        "hooks": [{"type": "command", "command": command, "timeout": timeout}],
    })

ensure("SessionStart", "~/.claude/hooks/vault-sync-pull.sh", 300)
ensure("Stop",         "~/.claude/hooks/vault-sync-push.sh", 120)

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(path, 0o600)
PY

echo "[vault-sync init] Done. Hooks at ~/.claude/hooks/, registered in ~/.claude/settings.json."
```

## Credentials

Set these env vars in the Claude Code on the Web session config for this repo
(they sync to mobile automatically). Never commit them.

| Var | Meaning |
| --- | --- |
| `OBSIDIAN_EMAIL` | Obsidian account email |
| `OBSIDIAN_PASSWORD` | Obsidian account password |
| `OBSIDIAN_VAULT_NAME` | Remote vault name on Obsidian Sync |
| `OBSIDIAN_VAULT_PASSWORD` | End-to-end encryption password for the vault |
| `OBSIDIAN_MFA` | Only if the account has 2FA (a dedicated MFA-less sync account is cleaner for automation) |

If any required var is missing, the pull hook exits cleanly with a
`[vault-sync] ... not set — vault sync skipped.` message rather than failing the
session.

## Lifecycle

1. Sandbox starts; cloud setup script runs the init script above (install +
   write hooks). On a resumed sandbox this is a no-op.
2. **SessionStart** → `vault-sync-pull.sh`: on first run it `ob login`s and
   `ob sync-setup`s (pairing `$HOME/vault` with the remote vault), then always
   does a blocking `ob sync` to pull.
3. Claude works on files under `$HOME/vault/`.
4. **Stop** → `vault-sync-push.sh`: blocking `ob sync` to push edits back.
5. Session ends; sandbox is discarded. Obsidian Sync stays the single source of
   truth — git never touches vault content.

## Troubleshooting

Logs live in `~/.claude/hooks/`:

- `vault-sync-pull.log` / `vault-sync-push.log` — full `ob` output.
- `signin-*.http` — raw `/user/signin` probe captures (see note below).

Common situations:

- **Vault dir (`$HOME/vault`) is empty after start.** The pull hook is
  fail-soft (always `exit 0`) so a sync hiccup never blocks the session — check
  `vault-sync-pull.log` for the real cause.
- **`{"error":"Server overloaded, please try again later."}`** from
  `api.obsidian.md` is a *transient* server-side error. The login is not cached
  on failure (no `auth_token` written), so the next SessionStart simply retries.
  To recover in-session, re-run `ob login` then `ob sync --path "$HOME/vault"`.
- **The `signin-*.http` captures are a red herring for health checks.** They
  POST an empty `{}` body, which the API rejects with a generic error (often the
  same "Server overloaded" string) even when real authenticated login works
  fine. They exist only to surface a raw HTML gateway page from a cold egress
  proxy. Do not treat a non-200-looking capture as proof login is broken — check
  the log and try a real `ob login`.
- **`better-sqlite3` fails to compile** during `npm install -g
  obsidian-headless`: add `apt install -y build-essential python3` before the
  install.
