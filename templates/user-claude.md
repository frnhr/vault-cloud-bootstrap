# The Vault

An Obsidian vault syncs into `~/vault/` (`$HOME/vault`) in the background, starting when the session starts. Before relying on it, check `~/.claude/hooks/vault-sync-pull.log`: success is a `sync ok on attempt N` line. If it is not there yet, wait for it for up to 5 minutes, and tell the user if the vault has not synced by then.

Once synced, look for a folder under `~/vault/projects/` that matches this repository and read its overview. Keep the first read brief, and come back to it when the task needs more context. If there is no matching folder, leave the vault alone unless the user points you to it.

Edits under `~/vault/` are pushed back to Obsidian Sync at the end of every turn.

If the sync failed, or the vault or this project's `.env` files are missing, run `~/.claude/hooks/vault-doctor.sh` and include its output when telling the user. It prints no secrets. The environment build's own output is in `~/.claude/vault-cloud-bootstrap/build.log`, with a summary in `~/.claude/vault-cloud-bootstrap/build-status`.

<!-- Add your own session-wide instructions below: this file is installed as /home/user/CLAUDE.md, the parent directory of every cloned repository, so every session loads it. -->
