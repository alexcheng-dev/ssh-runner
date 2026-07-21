# Workflow

## GitHub Actions SSH runner

This repo uses `/Users/igor/Documents/Codex/2026-07-19/alexcheng-dev/.github/workflows/ssh-runner.yml` for short-lived SSH access to a GitHub Actions runner.

Reliable pattern:

1. Download the static `tmate` binary directly from GitHub releases.
2. Start `tmate` manually and collect the SSH/Web URLs.
3. Save those URLs into `/tmp/ssh-link.txt`.
4. Upload `ssh-link.txt` as the `ssh-link` artifact before the 6-hour sleep step.

Why this shape:

- `apt-get`-based setup was unreliable here and could hang.
- GitHub job logs were not a reliable way to retrieve the live SSH link while the job was still running.
- The artifact is available immediately after the upload step completes, so it is the best retrieval surface.

## Quick usage

Trigger and fetch a live SSH link:

```bash
/Users/igor/Documents/Codex/2026-07-19/alexcheng-dev/scripts/ssh-runner-link.sh alexcheng-dev/ssh-runner ssh-runner.yml
```

The output prints:

- the live `ssh ...@...tmate.io` command
- the matching `https://tmate.io/t/...` web session URL

Do not rely on the tmate web session URL for this workflow. In practice it was returning `503` here and was not usable; prefer the SSH session and the Codex Web URL.

List all currently running worker instances and their live SSH links when the
`ssh-link` artifact is already available:

```bash
./scripts/list-running-workers.sh
```

The listing script prints SSH plus the live Codex Web Cloudflare URL and the current Codex Web password. It intentionally does not print the tmate web URL because that surface was consistently unusable here.

Inspect one worker directly:

```bash
./scripts/inspect-worker.sh <ssh-destination>
```

## Notes

- If GitHub returns a transient `HTTP 500: Failed to run workflow dispatch`, retrying a few seconds later usually works; `scripts/ssh-runner-link.sh` retries dispatch up to 3 times.
- The runner stays alive for about 6 hours after the artifact upload step.
- Node.js was already present on the tested runner image (`node v22.23.1`, `npm 10.9.8` on July 19, 2026).

## tmate caveats

- Treat the worker SSH endpoint as an interactive `tmate` session, not normal SSH.
- `ssh host "command"` can fail with `Invalid command`; automation should drive an interactive shell instead.
- The first screen may require sending `q` to dismiss the tmate banner before the shell prompt appears.
- Avoid sending `exit` at the end of setup: that can tear down the shared tmate session and make the published SSH/Web links unusable.
- Avoid pasting large heredocs into the interactive session. Echoed input and continuation prompts can break marker-based automation; base64 upload plus decode/run is more reliable here.
- If you need to inventory a worker later, prefer persisted state files such as `~/.codex/worker-state.json` over scraping transient terminal output or `cloudflared` startup logs.

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

5. Downloads `cloudflared` on the worker if needed.
6. Exposes `http://127.0.0.1:5900` publicly and prints the URL plus the generated password.

If plain `tmux new-session ...` fails with `server version is too old for client`, that is the nested-tmux/socket conflict from running inside tmate; use the separate `-L codexapp -f /dev/null` server above.

If the local launcher connects through tmate for setup, do not send `exit` to the remote shell after provisioning. The shell owns the shared tmate session; exiting it can make the fresh `ssh ...@tmate.io` endpoint return `Internal error`. Kill only the local SSH client after `codexapp` and `cloudflared` are detached.

When automating the interactive tmate SSH session, do not paste the remote setup as a heredoc. The terminal can echo the script text, causing marker-based wait loops to match strings like `PUBLIC_URL=` before execution, or leave the remote shell stuck at a `>` continuation prompt. Upload the script as base64 chunks, decode it on the worker, then run it.

When waiting for remote setup completion, require the full Cloudflare hostname marker such as `trycloudflare.com`, not just `PUBLIC_URL=`; output is read character-by-character and can otherwise stop before the URL body is captured.

The worker launcher persists runner state in `~/.codex/worker-state.json` and still writes `~/.codex/codexui-public-url`. Inventory scripts should prefer the JSON state file over scraping transient `cloudflared` startup log lines.

## Worker Agents submodule

`workerAgents/` is a git submodule pinned to a local worktree fork of `/Users/igor/Git-projects/codex-web-local-android/hermes3`.

The fork removes the Android project and Android build/release docs, then keeps the reusable Node.js console as a generic worker supervisor. Verify it with:

```bash
cd workerAgents
npm run check
```
