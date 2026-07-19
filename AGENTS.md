# Local repo instructions

Keep this file short. Put durable workflow details in `./wiki/*.md` and reusable helpers in `./scripts/*.sh`.

## Wiki index

- `/Users/igor/Documents/Codex/2026-07-19/alexcheng-dev/wiki/workflow.md` — local workflow notes for the GitHub Actions SSH runner and quick usage.

## Scripts

- `/Users/igor/Documents/Codex/2026-07-19/alexcheng-dev/scripts/ssh-runner-link.sh` — trigger the workflow, wait for the `ssh-link` artifact, and print the live SSH/Web links.
- `/Users/igor/Documents/Codex/2026-07-19/alexcheng-dev/scripts/run-codexapp-worker.sh` — end-to-end local launcher: start the GitHub Actions worker, fetch SSH details, connect, start `codexapp` in detached tmux, expose it with `cloudflared`, and print the public URL and password.
