# vault-cloud-bootstrap

Minimal bootstrap repo for running **Claude Code cloud sessions** (Claude Code
on the Web) against an Obsidian vault. The vault lives in Obsidian Sync;
this repo contains only the wiring to pull/push it via
[`obsidian-headless`](https://github.com/obsidianmd/obsidian-headless) at
session start and stop.

## How it works

The sync machinery lives in **user-level** hooks (`~/.claude/`), installed by
an idempotent init script — it is not shipped as repo hooks. The full script
and setup details live in [`docs/vault-sync.md`](docs/vault-sync.md).

1. A Claude Code cloud session is launched against this repo from the web UI
   or the Claude mobile app.
2. The cloud sandbox clones this repo and runs the init script (as the
   environment setup script), which installs `obsidian-headless` and writes the
   pull/push hooks into `~/.claude/`.
3. **SessionStart** hook (`~/.claude/hooks/vault-sync-pull.sh`):
   - Installs `obsidian-headless` if missing.
   - `ob login` on first run of a fresh sandbox, using env-var credentials.
   - `ob sync-setup` to pair `$HOME/vault/` with the remote vault on first run.
   - Blocking `ob sync` to pull current vault contents into `$HOME/vault/`.
4. Claude does its work on files under `$HOME/vault/`.
5. **Stop** hook (`~/.claude/hooks/vault-sync-push.sh`): blocking `ob sync`
   to push changes back via Obsidian Sync.
6. Session ends; sandbox is discarded.

No git ever touches vault content. Obsidian Sync remains the single source
of truth.

## Setup (one-time)

1. Push this repo to a **private** GitHub repo.
2. Connect it in Claude Code on the Web (Repositories → Add).
3. Add the init script from [`docs/vault-sync.md`](docs/vault-sync.md) as the
   environment's setup script so the hooks are installed in each sandbox.
4. In the session config for this repo, set the following env vars (synced to
   mobile automatically):
   - `OBSIDIAN_EMAIL`
   - `OBSIDIAN_PASSWORD`
   - `OBSIDIAN_VAULT_NAME` — the remote vault name on Obsidian Sync
   - `OBSIDIAN_VAULT_PASSWORD` — the end-to-end encryption password
   - `OBSIDIAN_MFA` — only if the account has 2FA (a dedicated MFA-less sync
     account is cleaner for automation)
5. Launch a cloud session from web or mobile and walk the verification
   checklist below.

## Verification (first cloud session)

0. Hook sees env vars — the pull script skips sync with a clear message if any
   required var is missing.
1. `ob --version` works after SessionStart. If `better-sqlite3` fails to
   compile, add `apt install -y build-essential python3` to the pull hook
   before `npm install -g`.
2. `ob login` and `ob sync-setup` exit cleanly with no TTY prompts.
3. `ls -la $HOME/vault/` shows vault contents including `.obsidian/` and
   `_GUIDE.md`.
4. Create `$HOME/vault/scratch/cloud-sync-test-<timestamp>.md` during the
   session; after Stop hook fires, open Obsidian on the Mac and confirm the
   file appears within seconds.
5. Confirm the Stop hook actually fires in the cloud sandbox (hooks work
   locally — verify they're not stripped in cloud). If they're stripped, have
   Claude call `ob sync --path "$HOME/vault"` as its final action instead (add
   the instruction to `CLAUDE.md`).

## Why not put the vault itself in git?

The vault is already managed by Obsidian Sync as its single source of truth.
Adding git on top would mean two competing sync mechanisms and all the
conflict-resolution pain that comes with it. `obsidian-headless` lets this
repo carry **zero** vault content — the bootstrap only wires up the cloud
session to Obsidian Sync directly.

## Why not `ob sync --continuous`?

A continuous daemon can race Claude's edits mid-session and produce Obsidian
Sync conflict files. Blocking start+end suits short cloud sessions. Add
`ob sync --continuous &` to the pull hook later if start+end proves too
coarse.
