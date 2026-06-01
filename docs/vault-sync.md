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

# --- timing / context helpers ----------------------------------------------
T0=$(date +%s)
elapsed() { echo $(( $(date +%s) - T0 )); }       # seconds since hook start
uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null || echo "?"; }  # sandbox age
log()  { echo "[vault-sync] $*" >>"$LOG"; }
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

# --- diagnostics (instrument-only; NO retry / NO behaviour change) ----------
# Recurring symptom: at cold sandbox start `ob login` intermittently fails with
# {"error":"Server overloaded, please try again later."} returned by Obsidian's
# Cloudflare edge, then succeeds on a retry. `ob` hides the HTTP layer, so we
# probe POST /user/signin directly with curl and read the raw status line and
# headers (retry-after / cf-ray / cf-cache-status) that tell us whether this is
# upstream throttling vs a cold egress proxy. The probe sends an empty {} body
# — NO credentials, nothing to leak — so it is just an IP-level health/throttle
# sensor, sampled right next to the real login. We also stamp every phase with
# elapsed time and sandbox uptime to test the "only when cold" hypothesis.
OB_SIGNIN_URL="https://api.obsidian.md/user/signin"

probe_signin() {  # $1=label; logs a parsed summary and echoes it on stdout
  local label="$1" out
  out="$HOME/.claude/hooks/signin-$(date +%Y%m%dT%H%M%S)-${label}.http"
  {
    echo "# $(date -Is) — ${label} probe of ${OB_SIGNIN_URL} (empty {} body, no credentials)"
    echo
    curl -sS -m 20 -X POST "$OB_SIGNIN_URL" \
      -H 'Content-Type: application/json' \
      -H 'Origin: https://obsidian.md' \
      --data '{}' -D - 2>&1
  } >"$out" 2>&1 || true

  local http retry ray cc apierr
  http=$(grep  -m1 -iE '^HTTP/'            "$out" | tr -d '\r' || true)
  retry=$(grep -m1 -i  '^retry-after:'     "$out" | tr -d '\r' | cut -d: -f2- | xargs || true)
  ray=$(grep   -m1 -i  '^cf-ray:'          "$out" | tr -d '\r' | cut -d: -f2- | xargs || true)
  cc=$(grep    -m1 -i  '^cf-cache-status:' "$out" | tr -d '\r' | cut -d: -f2- | xargs || true)
  apierr=$(grep -m1 -o '"error":"[^"]*"'   "$out" | cut -d: -f2- | tr -d '"' || true)
  local summary="http='${http:-?}' retry_after='${retry:-}' cf_ray='${ray:-}' cc='${cc:-}' api_error='${apierr:-}'"
  log "probe[$label] (t+$(elapsed)s, up $(uptime_s)s) $summary -> $out"
  echo "$summary"
}
# ---------------------------------------------------------------------------

OB_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian-headless"
if [ ! -f "$OB_CONFIG_DIR/auth_token" ]; then
  log "cold auth: sandbox up $(uptime_s)s at first login attempt"
  probe_signin precold >/dev/null
  login_t0=$(date +%s)
  if ! ob login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" \
        ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"} >>"$LOG" 2>&1; then
    diag=$(probe_signin postfail)
    echo "[vault-sync] login FAILED (t+$(elapsed)s, sandbox up $(uptime_s)s, login took $(( $(date +%s) - login_t0 ))s): $diag"
    fail "login failed — inspect $HOME/.claude/hooks/signin-*.http and $LOG"
  fi
  log "login OK in $(( $(date +%s) - login_t0 ))s"
  ob sync-setup --path "$VAULT_DIR" \
    --vault "$OBSIDIAN_VAULT_NAME" --password "$OBSIDIAN_VAULT_PASSWORD" >>"$LOG" 2>&1 \
    || fail "pairing failed"
fi

sync_t0=$(date +%s)
ob sync --path "$VAULT_DIR" >>"$LOG" 2>&1 \
  || fail "pull failed — vault may be stale"

echo "[vault-sync] Vault ready at $VAULT_DIR (t+$(elapsed)s, sandbox up $(uptime_s)s, sync $(( $(date +%s) - sync_t0 ))s). Read $VAULT_DIR/_GUIDE.md before editing."
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

- `vault-sync-pull.log` / `vault-sync-push.log` — full `ob` output, plus the
  per-phase diagnostic lines (`probe[...]`, `login OK in Ns`, etc.).
- `signin-*.http` — raw `/user/signin` probe captures with full headers.

### The "fails at cold start, works on retry" login error

The recurring failure is `{"error":"Server overloaded, please try again
later."}` from `api.obsidian.md` during `ob login`. What we know:

- The response carries `server: cloudflare` + a `cf-ray` header, so it comes
  from **Obsidian's own Cloudflare edge**, not the Claude egress proxy — i.e.
  upstream throttling/overload, delivered cleanly (HTTP 200 with an error
  *body*, which is why `ob` can't gate on status code alone).
- It is transient and not predictable: the same probe can flip between a normal
  validation error and "Server overloaded" seconds apart, and login has
  succeeded moments after a probe still reported overloaded. The most likely
  cause is rate-limiting at Obsidian's edge, plausibly amplified because cloud
  sandboxes egress through a shared proxy IP pool.

The pull hook is **instrumented to confirm this** without changing behaviour
(still one login attempt, still fail-soft):

- On failure it prints a one-line summary to the session — elapsed time,
  **sandbox uptime**, login duration, and the probe's `http` / `retry_after` /
  `cf_ray` / `cf-cache-status` / `api_error`. Collect these across a few
  recurrences and check:
  - Do failures cluster at **low `sandbox up Ns`** (→ cold-start timing)?
  - Is there a `retry_after` header (→ explicit rate limit)?
  - Is `http` a clean `HTTP/2 200` with an error body, or an HTML/non-JSON page
    (→ that would instead point at a cold egress proxy)?

Once the data points one way, the fix is most likely a **retry with
exponential backoff + jitter** around `ob login` / `ob sync` (exit-code based,
so it covers both the "Server overloaded" JSON and any cold-proxy
`SyntaxError` mode). To recover in-session right now: re-run `ob login` then
`ob sync --path "$HOME/vault"`.

### Other notes

- **`$HOME/vault` empty after start** — the pull hook is fail-soft (always
  `exit 0`) so a sync hiccup never blocks the session. Read
  `vault-sync-pull.log` for the real cause.
- **The `signin-*.http` probe is a sensor, not the verdict.** A non-2xx-looking
  capture does not by itself prove login is broken (the empty `{}` body is also
  rejected with an error); read it together with the login exit status in the
  log.
- **`better-sqlite3` fails to compile** during `npm install -g
  obsidian-headless`: add `apt install -y build-essential python3` before the
  install.
