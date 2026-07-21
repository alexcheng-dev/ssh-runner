# Local repo instructions

Keep this file short. Put durable workflow details in `./wiki/*.md` and reusable helpers in `./scripts/*.sh`.

## Wiki index

- `/Users/igor/Documents/Codex/2026-07-19/alexcheng-dev/wiki/workflow.md` — local workflow notes for the GitHub Actions SSH runner and quick usage.
- `/Users/igor/Documents/sshworker/wiki/workflow.md` — local workflow notes, including the Worker Agents submodule.

## Scripts

- `/Users/igor/Documents/sshworker/scripts/ssh-runner-link.sh` — trigger the workflow, wait for the `ssh-link` artifact, and print the live SSH/Web links.
- `/Users/igor/Documents/sshworker/scripts/run-codexapp-worker.sh` — end-to-end local launcher: start the GitHub Actions worker, fetch SSH details, connect, start `codexapp` in detached tmux, expose it with `cloudflared`, and print the public URL and password.
- `/Users/igor/Documents/sshworker/scripts/run-worker-agents-worker.sh` — upload `workerAgents` to a fresh worker, install/run it in tmux, expose it with `cloudflared`, and print the public URL.
- `/Users/igor/Documents/sshworker/scripts/list-running-workers.sh` — list in-progress workflow runs and print their live SSH/Web links when the artifact is ready.
- `/Users/igor/Documents/sshworker/scripts/inspect-worker.sh` — inspect one worker over interactive tmate SSH and print its persisted Codex worker state JSON.
