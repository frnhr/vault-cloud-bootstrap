# vault-cloud-bootstrap

Bootstrap repo for editing one Obsidian vault from Claude Code cloud
sessions (Claude Code on the Web). The vault itself lives in Obsidian Sync
and is NOT in git.

## Lifecycle

- **SessionStart** hook runs `.claude/hooks/obsidian-sync-pull.sh`: installs
  `obsidian-headless` (once per fresh sandbox), authenticates with env-var
  credentials, and does a blocking `ob sync` into `./vault/`.
- **Stop** hook runs `.claude/hooks/obsidian-sync-push.sh`: another blocking
  `ob sync` to push changes back via Obsidian Sync.

## Where to work

- **Operate on files under `./vault/`.** That is where the real vault content
  is materialized at session start.
- **Read `./vault/_GUIDE.md` first** — it is the agent-facing guide to vault
  structure, note conventions, frontmatter, wikilinks, and index maintenance.
- Do not create files outside `./vault/` unless they are throwaway scratch for
  your own work — nothing outside `./vault/` syncs back to Obsidian.

## Do not touch

- `.claude/` in this repo — the hooks that make the whole thing work. Safe to
  read; do not modify unless the sync workflow itself is being iterated on.
- `.obsidian/` inside the vault — Obsidian's own config. Obsidian Sync handles
  it; do not hand-edit unless the user asks.

## Credentials

The following env vars must be set in the Claude Code on the Web session
config for this repo:

- `OBSIDIAN_EMAIL`
- `OBSIDIAN_PASSWORD`
- `OBSIDIAN_VAULT_NAME`
- `OBSIDIAN_VAULT_PASSWORD`
- `OBSIDIAN_MFA` (only if the account has 2FA)

Never commit credentials to this repo.
