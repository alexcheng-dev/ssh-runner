# sshworker

Launch and refresh GitHub Actions workers that expose services through `*.lolgames.net`.

This repo keeps the workflow source locally, syncs it to the public Actions repo [`alexcheng-dev/agent-workspace`](https://github.com/alexcheng-dev/agent-workspace), then uses that repo to start runners with a deterministic raw-SSH endpoint plus public HTTP tunnels for Worker Agents and child services.

## What this repo is for

- start a fresh GitHub Actions worker with raw SSH over lolgames
- reuse an existing worker and refresh it in place
- deploy `workerAgents` from this repo
- use public repos for dependencies instead of uploading local Mac checkouts
- expose Worker Agents, 9Router, and child apps on `*.lolgames.net`

Default dependency sources:

- 9Router: [`alexcheng-dev/9router`](https://github.com/alexcheng-dev/9router) prebuilt artifact, with clone/build fallback
- Hermes WebUI: [`nesquena/hermes-webui`](https://github.com/nesquena/hermes-webui)
- workflow/deploy repo: [`alexcheng-dev/agent-workspace`](https://github.com/alexcheng-dev/agent-workspace)

## Canonical workflow

Preferred default:

1. reuse an existing healthy worker
2. run a doctor check
3. refresh that worker in place

Fallback:

1. launch a fresh worker
2. run a doctor check on the new worker

Commands:

```bash
./scripts/list-running-workers.sh
./scripts/doctor-worker.sh "<ssh-destination-or-worker-url>"
./scripts/refresh-worker-agents-worker.sh "<ssh-destination>"
./scripts/run-worker-agents-worker.sh
```

## Fresh worker flow

`./scripts/run-worker-agents-worker.sh` does this:

1. sync `alexcheng-dev/agent-workspace`
2. trigger `.github/workflows/ssh-runner.yml` there
3. generate the SSH keypair locally and pass only the public key to the workflow
4. compute the public SSH endpoint from `GITHUB_RUN_ID`
5. wait for SSH readiness on `runner-<run_id>-1-ssh.lolgames.net:<30000 + (run_id % 20000)>`
6. upload `workerAgents`
7. fetch the latest successful `9router-standalone` artifact from `alexcheng-dev/9router`, with clone/build fallback
8. clone Hermes WebUI from GitHub on the runner
9. start Worker Agents in detached tmux
10. expose Worker Agents and same-host cross-port child services through `*.lolgames.net`
11. write local metadata to `./outputs/*-worker-agents.json`

## Health/status

Use:

```bash
./scripts/doctor-worker.sh "<ssh-destination-or-worker-url>"
```

Checks:

- runner reachable
- Worker Agents local/public
- 9Router local/public
- Hermes presence/registration
- tunnel health
- persisted state consistency

## Important scripts

- `/Users/igor/Documents/sshworker/scripts/ensure-agent-workspace-repo.sh` — create/sync the public Actions repo
- `/Users/igor/Documents/sshworker/scripts/ssh-runner-link.sh` — trigger the workflow and print the SSH link
- `/Users/igor/Documents/sshworker/scripts/run-worker-agents-worker.sh` — fresh worker launch
- `/Users/igor/Documents/sshworker/scripts/refresh-worker-agents-worker.sh` — refresh an existing worker
- `/Users/igor/Documents/sshworker/scripts/doctor-worker.sh` — one health/status entrypoint
- `/Users/igor/Documents/sshworker/scripts/list-running-workers.sh` — enumerate running workers and known links
- `/Users/igor/Documents/sshworker/scripts/verify-lolgames-worker-links.sh` — verify same-host public routes

## Notes

- Prefer direct SSH and persisted state over interactive tmate automation.
- Treat tmate as inspection/debug only.
- Worker Agents is the main public hostname; child services reuse the same hostname and switch only the port.
- The workflow source of truth is `/Users/igor/Documents/sshworker/.github/workflows/ssh-runner.yml`.
- Durable workflow details live in `/Users/igor/Documents/sshworker/wiki/workflow.md`.
