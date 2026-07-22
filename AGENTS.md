# Local repo instructions

Keep this file short. Put durable workflow details in `./wiki/*.md` and reusable helpers in `./scripts/*.sh`.

- Always git commit completed repo changes unless the user explicitly says not to.
- Worker launchers use public `alexcheng-dev/agent-workspace` for GitHub Actions. Keep `/Users/igor/Documents/sshworker/.github/workflows/ssh-runner.yml` as source and sync with `scripts/ensure-agent-workspace-repo.sh`.
- Do not upload local Mac checkouts of 9Router or Hermes WebUI. Worker scripts should use public repos on the runner; the default 9Router source/prebuilt is `https://github.com/alexcheng-dev/9router.git`, and Hermes WebUI is `https://github.com/nesquena/hermes-webui.git`.

## Wiki index

- `/Users/igor/Documents/sshworker/wiki/workflow.md` — local workflow notes for the GitHub Actions SSH runner, quick usage, and the Worker Agents submodule.

## Scripts

- `/Users/igor/Documents/sshworker/scripts/ssh-runner-link.sh` — trigger the workflow, wait for the `ssh-link` artifact, and print the live SSH/Web links.
- `/Users/igor/Documents/sshworker/scripts/ensure-agent-workspace-repo.sh` — create/sync the public `alexcheng-dev/agent-workspace` Actions repo used by the worker launchers.
- `/Users/igor/Documents/sshworker/scripts/run-codexapp-worker.sh` — end-to-end local launcher: start the GitHub Actions worker, fetch SSH details, connect, start `codexapp` in detached tmux, expose it with the `*.lolgames.net` tunnel, and print the public URL and password.
- `/Users/igor/Documents/sshworker/scripts/run-worker-agents-worker.sh` — sync `agent-workspace`, launch a fresh worker, upload `workerAgents`, clone 9Router/Hermes WebUI from public repos, smoke-test, expose via `*.lolgames.net`, and write ignored local metadata.
- `/Users/igor/Documents/sshworker/scripts/refresh-worker-agents-worker.sh` — refresh the current existing worker in place over SSH: upload current `workerAgents`, clone 9Router/Hermes WebUI from public repos, restart Worker Agents, refresh tunnels/state, and print updated URLs.
- `/Users/igor/Documents/sshworker/scripts/doctor-worker.sh` — canonical worker health/status check for SSH or public URL inputs; verify runner reachability, Worker Agents, 9Router, Hermes presence, tunnel health, and persisted state consistency.
- `/Users/igor/Documents/sshworker/scripts/list-running-workers.sh` — list in-progress workflow runs and print their live SSH/Web links when the artifact is ready.
- `/Users/igor/Documents/sshworker/scripts/inspect-worker.sh` — inspect one worker over interactive tmate SSH and print its persisted Codex worker state JSON.
- `/Users/igor/Documents/sshworker/scripts/tunnel.sh` — publish a local port through `*.lolgames.net` via the Katie `lolgames-micro` broker.
- `/Users/igor/Documents/sshworker/scripts/verify-lolgames-worker-links.sh` — verify the Worker Agents `*.lolgames.net` URL and same-host cross-port routes.

## Tunnel testing

- `/Users/igor/Documents/sshworker/tests/test-tunnel-websocket.sh` — smoke-test a public WebSocket tunnel through `*.lolgames.net`.
- `/Users/igor/Documents/sshworker/tests/test-tunnel-sse.sh` — smoke-test a public SSE tunnel through `*.lolgames.net`.

## Worker testing

- Reuse an already running worker over SSH for investigation and verification before starting a fresh GitHub Actions worker, if a suitable one is still alive.
- Keep worker tests fast: prefer existing workers, direct SSH CLI checks, and short one-shot prompts over any web UI flow.
- Do not run multiple concurrent SSH automation sessions against the same tmate worker when output parsing matters. If parallelism is needed, start detached tmux jobs from one SSH session and collect results afterward from files, logs, ports, or tmux state.
