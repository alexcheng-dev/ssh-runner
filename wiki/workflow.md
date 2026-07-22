# Workflow

## GitHub Actions SSH runner

This repo keeps the SSH runner workflow source at `/Users/igor/Documents/sshworker/.github/workflows/ssh-runner.yml`, but deploys workers from the public GitHub repo `alexcheng-dev/agent-workspace`.

Reliable pattern:

1. Start `sshd` on the GitHub runner on local port `2222`.
2. Start `scripts/lolgames_tunnel.py` in raw TCP mode with a unique public port.
3. Save the `ssh -i ... -p <port> runner@<name>.lolgames.net` command into `/tmp/ssh-link.txt`.
4. Upload `ssh-link.txt` as the `ssh-link` artifact before the 6-hour sleep step.
5. Generate the SSH keypair locally in `scripts/ssh-runner-link.sh`, pass only the public key into the workflow, and keep the private key under `./outputs/keys/<run_id>_id_ed25519`.

Why this shape:

- Tmate can return `Internal error` / web `503` while the GitHub Actions job still appears `in_progress`; lolgames gives us our own SSH TCP path.
- GitHub job logs were not a reliable way to retrieve the live SSH link while the job was still running.
- The artifact is available immediately after the upload step completes, so it remains a useful retrieval surface for the human-readable SSH link.
- SSH is raw TCP, so each runner SSH tunnel uses a unique public port; it cannot share one public port by hostname like HTTP traffic can.
- The host and port are deterministic from `GITHUB_RUN_ID`: `runner-<run_id>-1-ssh.lolgames.net:<30000 + (run_id % 20000)>`.

## Canonical workflow

Default workflow:

1. Prefer reusing an existing healthy worker and refresh it in place.
2. Fall back to a fresh worker launch only when no healthy reusable worker exists or the existing one is broken beyond quick repair.

Use these commands:

```bash
./scripts/list-running-workers.sh
./scripts/doctor-worker.sh "<ssh-destination-or-worker-url>"
./scripts/refresh-worker-agents-worker.sh "<ssh-destination>"
```

Fallback fresh launch:

```bash
./scripts/run-worker-agents-worker.sh
```

Treat interactive tmate as inspection/debug only. Automation should prefer direct SSH, persisted state files, public health endpoints, and one-shot CLI checks.

## Quick usage

Trigger and fetch a live SSH link:

```bash
/Users/igor/Documents/sshworker/scripts/ssh-runner-link.sh alexcheng-dev/agent-workspace ssh-runner.yml
```

The output prints:

- the live `ssh -i /path/to/key -p <port> runner@<name>.lolgames.net` command
- the matching GitHub Actions run URL

Do not rely on tmate for automation in this workflow. In practice tmate SSH returned `Internal error` and the tmate web URL returned `503` while the workflow still showed `in_progress`.

Ensure the public runner repo exists and has the current workflow/tunnel client:

```bash
./scripts/ensure-agent-workspace-repo.sh
```

`ensure-agent-workspace-repo.sh` creates `alexcheng-dev/agent-workspace` as a public repo when missing, then syncs `.github/workflows/ssh-runner.yml` and `scripts/lolgames_tunnel.py` there. The worker launchers default to this repo and run this sync preflight by default (`SYNC_AGENT_WORKSPACE=1`); override with `REPO=owner/name` only when intentionally testing another Actions workspace.

List all currently running worker instances and their live SSH links when the
`ssh-link` artifact is already available:

```bash
./scripts/list-running-workers.sh
```

The listing script prints SSH, the GitHub Actions run creation time, and live lolgames worker URLs if the runner SSH state is reachable.

Inspect one worker directly:

```bash
./scripts/inspect-worker.sh <ssh-destination>
```

Refresh the current existing worker in place instead of launching a new one:

```bash
./scripts/refresh-worker-agents-worker.sh <ssh-destination>
```

This script targets exactly one worker: the SSH destination you pass in. This is the preferred default path whenever you already have a live worker.

Run one health/status pass before or after a refresh:

```bash
./scripts/doctor-worker.sh <ssh-destination-or-worker-url>
```

`doctor-worker.sh` verifies:

- runner reachable when SSH is available
- Worker Agents reachable locally/publicly
- 9Router reachable locally/publicly
- Hermes presence/registration
- tunnel/public URL health
- persisted state consistency

Launch `workerAgents` on a fresh worker only when refresh/reuse is not viable:

```bash
./scripts/run-worker-agents-worker.sh
```

That script:

1. syncs `agent-workspace`, optionally cancels older in-progress worker runs, then starts a fresh SSH runner from `alexcheng-dev/agent-workspace`
2. uploads `/Users/igor/Documents/sshworker/workerAgents`
3. clones 9Router and Hermes WebUI on the runner from public repos; it does not upload those projects from the Mac
4. runs `npm install` and installs `codexapp`, `opencode-ai`, and `openclaw`
5. starts Worker Agents in detached tmux on port `1456`
6. starts one `*.lolgames.net` same-port tunnel for Worker Agents; child UIs reuse that hostname with their own ports
7. smoke-tests the public console and `/api/status`
8. saves ignored local metadata under `./outputs/*-worker-agents.json` and `./outputs/latest-worker-agents.json`

Default dependency repos:

- 9Router: `https://github.com/decolua/9router.git`
- Hermes WebUI: `https://github.com/nesquena/hermes-webui.git`

Useful knobs:

- `SYNC_AGENT_WORKSPACE=0` skips the public repo sync preflight.
- `CANCEL_OLDER_WORKERS=0` keeps older in-progress `agent-workspace` workflow runs alive. The Worker Agents launcher defaults to canceling them; the Codex app launcher defaults to preserving them unless explicitly set.
- `SMOKE_TEST=0` skips post-deploy HTTP smoke checks.
- `SMOKE_REQUIRE_ROUTER=1` makes the derived 9Router public route mandatory instead of warning-only.

## Profiling

Preferred profiling target: refresh/reuse first, fresh launch second.

Refresh path:

```bash
PROVISION_TRACE=1 \
/usr/bin/time -lp ./scripts/refresh-worker-agents-worker.sh "<ssh-destination>" \
  2>&1 | tee /tmp/worker-refresh-profile.txt
```

Fresh-launch path:

```bash
REUSE_EXISTING_WORKER=0 START_CHILD_AGENTS=0 INSTALL_CHILD_DEPS=0 PROVISION_TRACE=1 \
/usr/bin/time -lp ./scripts/run-worker-agents-worker.sh \
  2>&1 | tee /tmp/worker-provision-profile.txt
```

What to inspect:

- local `[trace][HH:MM:SS] ...` spans for sync, SSH readiness, prebuilt fetch, upload, and smoke-test stages
- remote `[remote-trace][HH:MM:SS] ...` spans for extract/install/startup work on the runner
- total wall-clock time from `/usr/bin/time -lp`

Known good profiling habits:

- keep `START_CHILD_AGENTS=0` unless profiling child-agent startup specifically
- keep `INSTALL_CHILD_DEPS=0` unless profiling first-time dependency/bootstrap cost
- use the prebuilt 9Router artifact path first; only profile clone+build fallback intentionally
- run `./scripts/doctor-worker.sh ...` immediately after profiling to confirm the worker is still healthy

## Notes

- If GitHub returns a transient `HTTP 500: Failed to run workflow dispatch`, retrying a few seconds later usually works; `scripts/ssh-runner-link.sh` retries dispatch up to 3 times.
- `scripts/ssh-runner-link.sh` now tries to dedupe dispatch retries: if GitHub returns an error but a fresh run was actually created, the script reuses that run instead of dispatching another one.
- The launchers auto-cancel the just-created GitHub Actions run on failure by default (`CANCEL_FAILED_RUN=1`) so partial setup errors do not leave a new orphan worker behind.
- Fresh Worker Agents launches cancel older in-progress runs by default (`CANCEL_OLDER_WORKERS=1`) to avoid duplicate stale workers.
- Worker Agents can supervise Codex Web Local, OpenCode, Hermes WebUI, OpenClaw Gateway, and 9Router on the worker. A fresh Hermes WebUI clone may need the Hermes Agent bootstrap once before `--skip-agent-install` can run non-interactively.
- The worker launcher now preconfigures the child UIs to use local 9Router by default: Codex Web Local gets a seeded custom-endpoint state, OpenCode starts with a stable listed router model (`openai/gpt-5.4-mini`) against `http://127.0.0.1:20127/v1`, OpenClaw gets a `9router` custom provider in `~/.openclaw/openclaw.json`, and Hermes uses the generated `~/.hermes/config.yaml`.
- Prefer reusing an already running worker for CLI smoke tests. The repo `tests/` helpers are meant to run fast over SSH against a live worker with short one-shot prompts, not by launching a fresh worker each time.
- Prefer refreshing the current worker in place over launching a fresh worker whenever possible. Use `scripts/refresh-worker-agents-worker.sh <ssh-destination>` for one-worker updates and only fall back to fresh provisioning when the existing worker is broken beyond quick repair.
- Child UI links use the Worker Agents public hostname and only swap the port. Example: `http://<prefix>-worker-agents.lolgames.net:1456` is the console, and `http://<prefix>-worker-agents.lolgames.net:20127` reaches local 9Router on the worker.
- The launchers upload `scripts/lolgames_tunnel.py` to the worker and persist only the Worker Agents URL in `~/.worker-agents/state.json`; child URLs are derived from that hostname plus the child port.
- After a worker is provisioned, verify the live same-host routes with `./scripts/verify-lolgames-worker-links.sh "$WORKER_AGENTS_URL"` before sharing them.
- The runner stays alive for about 6 hours after the artifact upload step.
- Node.js was already present on the tested runner image (`node v22.23.1`, `npm 10.9.8` on July 19, 2026).

## tmate caveats

Tmate is for manual inspection/debug only. It is not the default automation transport.

- Treat the worker SSH endpoint as an interactive `tmate` session, not normal SSH.
- `ssh host "command"` can fail with `Invalid command`; automation should drive an interactive shell instead.
- The first screen may require sending `q` to dismiss the tmate banner before the shell prompt appears.
- Avoid sending `exit` at the end of setup: that can tear down the shared tmate session and make the published SSH/Web links unusable.
- Avoid pasting large heredocs into the interactive session. Echoed input and continuation prompts can break marker-based automation; base64 upload plus decode/run is more reliable here.
- Tmate automation should reset the shell with `Ctrl-C` after attaching and before submitting commands. If local automation is interrupted, send `Ctrl-C` to the remote shell before killing the local SSH client; otherwise the shared shell can remain at a `>` continuation prompt for later sessions.
- For base64 uploads, prefer quote-free chunks such as `printf %s <base64> >> file` because base64 uses shell-safe characters. Avoid single-quoted chunk commands; an interruption mid-line can leave an unmatched quote and poison the shared tmate shell.
- If you need to inventory a worker later, prefer persisted state files such as `~/.codex/worker-state.json` over scraping transient terminal output or `lolgames` startup logs.
- Tmate can close with `[lost server]` or `Internal error` while a workflow run still appears `in_progress`. Automation must treat local SSH EOF as terminal, not keep waiting for markers; pick another live worker or start a fresh one.
- SSH CLI verification should source the worker shell profiles and use the agent CLIs directly (`codex exec`, `opencode run`, `hermes -z`) instead of driving the web UIs. The repo `tests/` helpers automate that against the interactive tmate shell.
- When testing through the interactive tmate shell, run only one SSH automation session at a time per worker. Parallel sessions can interleave stale terminal output and create false positives/negatives.
- I tested parallel SSH automation against the same tmate worker on July 21, 2026 using two concurrent commands that each launched a detached tmux job on its own tmux socket/session. Both remote jobs completed (`parallel-p1.txt` and `parallel-p2.txt` each contained the expected `*:done` marker), so detached tmux can preserve the actual remote work. However, the shared tmate shell still interleaved the submitted command text and status markers, so parallel automation remains unsafe for anything that depends on clean stdout/stderr parsing or reliable command/result pairing.
- I re-tested the same pattern on July 21, 2026 with two concurrent SSH automations launching detached tmux sessions `sidep1` and `sidep2`. The shell again interleaved both command streams, confirming the rule: one parsed SSH automation session at a time per tmate worker. Detached tmux jobs are still acceptable as the parallel execution mechanism, but verification should happen afterward via files, logs, ports, or tmux session state rather than from mixed live stdout.
- The SSH smoke tests in `tests/` now use agent-specific exact tokens instead of a generic `hi` so previous tmate scrollback does not accidentally satisfy later checks.
- For Codex CLI, `openai_base_url` and `chatgpt_base_url` must stay at the top level of `~/.codex/config.toml`. If they are written inside `[projects."/home/runner"]`, Codex ignores them and falls back to `api.openai.com`.
- On the reused worker tested on July 21, 2026, Hermes CLI was healthy and local 9router responded on `127.0.0.1:20127`, but provider/model availability still depended on active credentials inside that worker's 9router state. A model can appear syntactically valid yet fail with `404 No active credentials for provider ...`.
- Local 9router `/v1/responses` on that worker accepted plain HTTP fallback, but Codex first attempted a websocket handshake and logged `Handshake not finished` before falling back successfully. Treat that websocket error as a transport quirk, not automatically as a fatal failure.

## Running codexapp safely on the runner

Do not keep `npx codexapp` in the foreground of the interactive tmate shell. If that shell gets `Ctrl-C`, the app stops and any public tunnel to port `5900` starts returning `502`.

Use the local end-to-end launcher instead:

```bash
./scripts/run-codexapp-worker.sh
```

What it does:

1. Starts a fresh GitHub Actions SSH runner.
2. Fetches the live SSH/Web tmate links from the workflow artifact.
3. Connects to the worker via SSH.
4. Starts `codexapp` in a detached tmux session on a separate tmux socket:

```bash
TMUX='' tmux -L codexapp -f /dev/null new-session -d -s codexapp 'npx codexapp > ~/codexapp-tmux.log 2>&1'
```

5. Uploads the lolgames tunnel client to the worker.
6. Exposes `http://127.0.0.1:5900` publicly as `http://<worker-prefix>-codexapp.lolgames.net:5900` and prints the URL plus the generated password.

If plain `tmux new-session ...` fails with `server version is too old for client`, that is the nested-tmux/socket conflict from running inside tmate; use the separate `-L codexapp -f /dev/null` server above.

If the local launcher connects through tmate for setup, do not send `exit` to the remote shell after provisioning. The shell owns the shared tmate session; exiting it can make the fresh `ssh ...@tmate.io` endpoint return `Internal error`. Kill only the local SSH client after `codexapp` and the lolgames tunnel client are detached.

When automating the interactive tmate SSH session, do not paste the remote setup as a heredoc. The terminal can echo the script text, causing marker-based wait loops to match strings like `PUBLIC_URL=` before execution, or leave the remote shell stuck at a `>` continuation prompt. Upload the script as base64 chunks, decode it on the worker, then run it.

When waiting for remote setup completion, require the full lolgames hostname marker such as `.lolgames.net`, not just `PUBLIC_URL=`; output is read character-by-character and can otherwise stop before the URL body is captured.

The worker launcher persists runner state in `~/.codex/worker-state.json` and still writes `~/.codex/codexui-public-url`. Inventory scripts should prefer the JSON state file over scraping transient `lolgames` startup log lines.

## Worker Agents repo copy

`workerAgents/` now lives directly inside this repository as a normal tracked directory.

The fork removes the Android project and Android build/release docs, then keeps the reusable Node.js console as a generic worker supervisor. Verify it with:

```bash
cd workerAgents
npm run check
```

## Lolgames wildcard tunnel

- `scripts/tunnel.sh localhost:3000 [name]` publishes a local host through the Katie `lolgames-tunnel-micro` broker and prints `http://<name>.lolgames.net`. In same-port mode, requests to `http://<name>.lolgames.net:3000` connect to local port `3000`, requests to `http://<name>.lolgames.net:5173` connect to local port `5173`, and so on.
- The broker is on `lolgames-micro` (`161.153.109.33`) and receives wildcard DNS for `*.lolgames.net`; do not change the apex `lolgames.net` record for this workflow.
- The micro redirects inbound TCP `1024-65535` to the broker with iptables while leaving control port `20222` exempt; `lolgames-network.service` reapplies those rules after reboot.
- HTTP/WebSocket/SSE can share public ports across names via the Host header. Raw TCP still cannot use hostname routing unless the client protocol exposes a hostname, so keep raw TCP in unique-port mode, e.g. `python3 scripts/lolgames_tunnel.py client localhost:9001 --server 161.153.109.33 --name rawone --public-port 43123`.
- Worker Agents "open" links must preserve the currently viewed public hostname and only change the port. For example, when viewing `http://runnervm3jd5f-...-9router.lolgames.net:20127`, an app running on `127.0.0.1:18923` should open as `http://runnervm3jd5f-...-9router.lolgames.net:18923`, not `http://127.0.0.1:18923/`.

### Standard-port TLS/status

- `status.lolgames.net` is served by Caddy on `lolgames-micro`; both `http://status.lolgames.net/` and `https://status.lolgames.net/` return the static status page.
- Caddy handles automatic Let's Encrypt certificates for standard ports `80/443`. Use Caddy/Nginx only for named standard-port sites; keep arbitrary `:PORT` tunnel traffic on the broker path.
- To add another standard HTTPS hostname, add a normal Caddy site block on `lolgames-micro`, make sure DNS resolves to `161.153.109.33`, and reload Caddy.

### Tunnel smoke tests

- `./tests/test-tunnel-websocket.sh` starts a local echo server on port `3010`, publishes it through `scripts/tunnel.sh`, and verifies a public `ws://<name>.lolgames.net:3010/` round-trip.
- `./tests/test-tunnel-sse.sh` starts a local SSE server on port `3020`, publishes it through `scripts/tunnel.sh`, and verifies streamed `text/event-stream` lines over the public tunnel.
- `./scripts/verify-lolgames-worker-links.sh <worker-agents-url>` verifies live Worker Agents and same-host 9Router cross-port routes like `<worker-host>:20127`.

### All-ports hostname mode

- The lolgames tunnel client now uses `--same-port` by default in `scripts/tunnel.sh` and the worker launchers. One registered hostname forwards any public port on that hostname to the same port on the worker/local target host.
- Example: if Worker Agents is published as `http://<prefix>-worker-agents.lolgames.net:1456`, then `http://<prefix>-worker-agents.lolgames.net:20127/` reaches the worker's local 9Router port too, as long as 9Router is listening locally.
- Worker Agents rebases “open” links to the current `*.lolgames.net` hostname when accessed through lolgames, so clicking child UI links should stay on the same public hostname and only change the port/path.
- A closed local port must not kill an all-ports hostname tunnel. The client should close only that failed connection and keep the control session alive for other ports.
- The tunnel client reconnects its broker control session after resets. If a public URL starts timing out, inspect `~/worker-agents-lolgames.log`; restarting the detached client for the same name restores the same public hostname.
- If the broker appears to "lose" registrations while worker client processes are still alive, check `lolgames-micro` for leaked public sockets: `ss -tan state close-wait '( sport = :10080 or sport ge :1024 )'`. The broker/client protocol has ping/pong keepalives and the public forwarding path must cancel the paired copy task as soon as either side closes; otherwise stale control sessions or `CLOSE-WAIT` public sockets can leave a hostname unregistered until the client is restarted.
- The worker launchers clone `https://github.com/decolua/9router.git` and `https://github.com/nesquena/hermes-webui.git` on the GitHub runner. Do not upload local Mac checkouts for these dependencies.
- On July 21, 2026, the preferred live pattern is one hostname: `http://<prefix>-worker-agents.lolgames.net:1456/` returns Worker Agents (`200`), and `http://<prefix>-worker-agents.lolgames.net:20127/v1/models` reaches 9Router (`401` without API key).
- 9Router is a Next standalone build. After `npm run build`, copy `.next/static` to `.next/standalone/.next/static` and `public` to `.next/standalone/public`, then launch from inside `.next/standalone` with `node server.js`. If `/login` returns HTML but every `/_next/static/...` asset returns `404`, the page will look stuck on loading until this static-copy/working-directory fix is applied.
- `refresh-worker-agents-worker.sh` provisions missing child-agent CLIs on the runner: `codexapp`, `opencode`, `openclaw`, and Hermes WebUI. Hermes WebUI is cloned from `https://github.com/nesquena/hermes-webui.git` by default; use `HERMES_UPLOAD=1` only when a local Hermes checkout must be shipped.
- `run-worker-agents-worker.sh` should follow the same Hermes rule as refresh: clone Hermes WebUI on the runner by default and only upload a local Hermes checkout when `HERMES_UPLOAD=1`. Uploading the whole local Hermes tree through tmate makes fresh-worker provisioning much less reliable.
