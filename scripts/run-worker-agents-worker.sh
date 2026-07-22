#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-alexcheng-dev/agent-workspace}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
APP_DIR="$ROOT_DIR/workerAgents"
ROUTER_GIT_URL="${ROUTER_GIT_URL:-https://github.com/decolua/9router.git}"
HERMES_WEBUI_GIT_URL="${HERMES_WEBUI_GIT_URL:-https://github.com/nesquena/hermes-webui.git}"
TUNNEL_CLIENT_PATH="$ROOT_DIR/scripts/lolgames_tunnel.py"
APP_PORT="${APP_PORT:-1456}"
SYNC_AGENT_WORKSPACE="${SYNC_AGENT_WORKSPACE:-1}"
CANCEL_OLDER_WORKERS="${CANCEL_OLDER_WORKERS:-1}"
SMOKE_TEST="${SMOKE_TEST:-1}"
SMOKE_REQUIRE_ROUTER="${SMOKE_REQUIRE_ROUTER:-0}"
TMP_DIR="$(mktemp -d)"
RUN_ID=""
LAUNCH_OK=0
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

on_exit() {
  status=$?
  if [[ $status -ne 0 && $LAUNCH_OK -ne 1 && -n "${RUN_ID:-}" && "${CANCEL_FAILED_RUN:-1}" == "1" ]]; then
    gh run cancel "$RUN_ID" --repo "$REPO" >/dev/null 2>&1 || true
    echo "Canceled failed worker run: $RUN_ID" >&2
  fi
  cleanup
  exit $status
}
trap on_exit EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require gh
require ssh
require unzip
require awk
require sed
require curl
require tar
require python3

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/outputs"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app directory: $APP_DIR" >&2
  exit 1
fi

if [[ ! -f "$TUNNEL_CLIENT_PATH" ]]; then
  echo "Missing lolgames tunnel client: $TUNNEL_CLIENT_PATH" >&2
  exit 1
fi

if [[ "$SYNC_AGENT_WORKSPACE" == "1" ]]; then
  ./scripts/ensure-agent-workspace-repo.sh
fi

if [[ "$CANCEL_OLDER_WORKERS" == "1" ]]; then
  while IFS= read -r old_run_id; do
    [[ -n "$old_run_id" ]] || continue
    echo "Canceling older in-progress worker run: $old_run_id" >&2
    gh run cancel "$old_run_id" --repo "$REPO" >/dev/null 2>&1 || true
  done < <(gh run list --repo "$REPO" --workflow "$WORKFLOW" --status in_progress --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)
fi

echo "Triggering worker..."
SSH_RUNNER_META_OUT="$TMP_DIR/ssh-runner-meta.env" ./scripts/ssh-runner-link.sh "$REPO" "$WORKFLOW" > "$TMP_DIR/ssh-link.txt"
source "$TMP_DIR/ssh-runner-meta.env"
SSH_CMD="$(sed -n '1p' "$TMP_DIR/ssh-link.txt")"
WEB_URL="$(sed -n '2p' "$TMP_DIR/ssh-link.txt")"

if [[ -z "$SSH_CMD" ]]; then
  echo "Failed to get SSH command" >&2
  exit 1
fi

ARCHIVE_PATH="$TMP_DIR/workerAgents.tgz"
tar \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='workers.json' \
  -czf "$ARCHIVE_PATH" \
  -C "$ROOT_DIR" \
  workerAgents

REMOTE_SCRIPT="$TMP_DIR/remote-worker-agents-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOF'
set -euo pipefail
APP_HOME="$HOME/workerAgents"
ROUTER_HOME="$HOME/9router"
HERMES_WEBUI_HOME="$HOME/hermes-webui"
STATE_DIR="$HOME/.worker-agents"
mkdir -p "$STATE_DIR" "$HOME/node-http2"

cat > "$STATE_DIR/9router-shell-env.sh" <<'SH'
export WORKER_AGENTS_9ROUTER_PORT=20127
export WORKER_AGENTS_9ROUTER_API_KEY=local-dev-key
export WORKER_AGENTS_9ROUTER_MODEL=openai/gpt-5.4-mini
export OPENAI_BASE_URL="http://127.0.0.1:20127/v1"
export OPENAI_API_KEY="local-dev-key"
SH

for profile in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$profile"
  if ! grep -Fq '.worker-agents/9router-shell-env.sh' "$profile"; then
    printf '\n[ -f "$HOME/.worker-agents/9router-shell-env.sh" ] && . "$HOME/.worker-agents/9router-shell-env.sh"\n' >> "$profile"
  fi
done

mkdir -p "$HOME/.codex"
python3 - <<'PY'
from pathlib import Path

path = Path.home() / ".codex" / "config.toml"
existing = path.read_text(encoding="utf-8") if path.exists() else ""
lines = existing.splitlines()
globals_ = []
rest = []
in_section = False
for line in lines:
    if line.lstrip().startswith("["):
        in_section = True
    if in_section:
        rest.append(line)
    else:
        globals_.append(line)

def set_global_line(key, value):
    line = f'{key} = {value}'
    for i, current in enumerate(globals_):
        if current.startswith(f"{key} = "):
            globals_[i] = line
            return
    globals_.append(line)

set_global_line("model", '"openai/gpt-5.4-mini"')
set_global_line("openai_base_url", '"http://127.0.0.1:20127/v1"')
set_global_line("chatgpt_base_url", '"http://127.0.0.1:20127/backend-api"')
path.write_text("\n".join([*globals_, *rest]).rstrip() + "\n", encoding="utf-8")
PY

TUNNEL_PREFIX="${LOLGAMES_TUNNEL_PREFIX:-$(hostname | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')-$(date +%s)}"

start_tunnel() {
  local name="$1"
  local port="$2"
  local public_name="${TUNNEL_PREFIX}-${name}"
  local log_path="$HOME/${name}-lolgames.log"
  pkill -f "lolgames_tunnel.py client 127.0.0.1:${port} --server 161.153.109.33 --name ${public_name} --same-port" 2>/dev/null || true
  nohup python3 /tmp/lolgames_tunnel.py client "127.0.0.1:${port}" --server 161.153.109.33 --name "$public_name" --same-port > "$log_path" 2>&1 &
  printf 'http://%s.lolgames.net:%s\n' "$public_name" "$port"
}

rm -rf "$APP_HOME"
mkdir -p "$APP_HOME"
tar -xzf /tmp/workerAgents.tgz -C "$HOME"
rm -rf "$ROUTER_HOME" "$HERMES_WEBUI_HOME"
git clone --depth 1 "$ROUTER_GIT_URL" "$ROUTER_HOME"
git clone --depth 1 "$HERMES_WEBUI_GIT_URL" "$HERMES_WEBUI_HOME"

cd "$APP_HOME"
npm install
npm install -g codexapp opencode-ai
cd "$ROUTER_HOME"
npm install
if [[ ! -d .next ]]; then
  npm run build
fi

if [[ ! -x "$HOME/.local/bin/hermes" ]]; then
  timeout 180 python3 "$HERMES_WEBUI_HOME/bootstrap.py" --no-browser --foreground --host 127.0.0.1 18935 >/tmp/hermes-bootstrap.log 2>&1 || true
fi

TMUX='' tmux -L workeragents -f /dev/null kill-server 2>/dev/null || true
TMUX='' tmux -L workeragents -f /dev/null new-session -d -s workeragents "cd \"$APP_HOME\" && PORT=${APP_PORT:-1456} AGENT_CONSOLE_HOST=127.0.0.1 WORKER_AGENTS_9ROUTER_DIR=\"$ROUTER_HOME\" WORKER_AGENTS_9ROUTER_PORT=20127 WORKER_AGENTS_9ROUTER_API_KEY=local-dev-key HERMES_WEBUI_DIR=\"$HERMES_WEBUI_HOME\" npm start > ~/worker-agents.log 2>&1"

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

for agent_id in codex-web-local opencode hermes-webui; do
  curl -fsS -X POST "http://127.0.0.1:${APP_PORT:-1456}/api/agents/${agent_id}/restart" >/dev/null || true
  sleep 8
done

STATUS_PATH="$STATE_DIR/status.json"
curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" > "$STATUS_PATH"

WORKER_AGENTS_URL="$(start_tunnel worker-agents "${APP_PORT:-1456}" || true)"

python3 - "${WORKER_AGENTS_URL:-}" "${APP_PORT:-1456}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

worker_agents_url = sys.argv[1]
port = int(sys.argv[2])
state = {
    "status": "running" if worker_agents_url else "starting",
    "url": worker_agents_url,
    "worker_agents_url": worker_agents_url,
    "port": port,
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
state_dir = os.path.expanduser("~/.worker-agents")
os.makedirs(state_dir, exist_ok=True)
with open(os.path.join(state_dir, "state.json"), "w", encoding="utf-8") as f:
    json.dump(state, f)
    f.write("\n")
PY

echo "__WORKER_AGENTS_DONE__${RUN_TOKEN:-}"
echo "PUBLIC_URL=${WORKER_AGENTS_URL:-}"
EOF

RUN_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
python3 - "$SSH_CMD" "$ARCHIVE_PATH" "$TUNNEL_CLIENT_PATH" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" "$APP_PORT" "$RUN_TOKEN" <<'PY'
import base64
import os
import re
import shlex
import select
import signal
import subprocess
import sys
import time

ssh_cmd, archive_path, tunnel_client_path, script_path, out_path, app_port, run_token = sys.argv[1:]
ssh_argv = shlex.split(ssh_cmd)
if not ssh_argv or ssh_argv[0] != "ssh":
    raise SystemExit(f"Unsupported SSH command: {ssh_cmd}")
ssh_argv = [ssh_argv[0], "-tt", *ssh_argv[1:]]
proc = subprocess.Popen(
    ssh_argv,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)

def close_proc(interrupt_remote=False):
    if interrupt_remote:
        try:
            proc.stdin.write("\x03\n")
            proc.stdin.flush()
            time.sleep(0.2)
        except Exception:
            pass
    proc.kill()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass

def on_interrupt(_signum, _frame):
    close_proc(interrupt_remote=True)
    raise SystemExit(130)

signal.signal(signal.SIGINT, on_interrupt)
signal.signal(signal.SIGTERM, on_interrupt)

def read_chunk(timeout=0.2):
    fd = proc.stdout.fileno()
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return ""
    data = os.read(fd, 4096)
    return data.decode("utf-8", errors="ignore") if data else ""

prompt_re = re.compile(r"runner@[^:]+:.*\$ ")
continuation_re = re.compile(r"(?:^|\n|\r)> ?(?:\x1b\[[0-9;?]*[ -/]*[@-~])*")
last_ctrl_c = 0.0
buffer = ""
started = False
with open(out_path, "w", encoding="utf-8") as outf:
    deadline = time.time() + 60
    while time.time() < deadline:
        ch = read_chunk()
        if not ch:
            if proc.poll() is not None:
                break
            continue
        buffer += ch
        outf.write(ch)
        outf.flush()
        if not started and "Press <q> or <ctrl-c> to continue" in buffer:
            proc.stdin.write("q")
            proc.stdin.flush()
        if continuation_re.search(buffer) and not prompt_re.search(buffer):
            now = time.time()
            if now - last_ctrl_c > 1.0:
                proc.stdin.write("\x03\n")
                proc.stdin.flush()
                last_ctrl_c = now
        if prompt_re.search(buffer):
            started = True
            break
    if not started:
        try:
            proc.stdin.write("\x03\n")
            proc.stdin.flush()
        except Exception:
            pass
        raise SystemExit("Failed to reach remote shell prompt")

    # Clear any quote/heredoc continuation prompt left by a previous interrupted
    # tmate automation before sending upload/run commands.
    proc.stdin.write("\x03\n")
    proc.stdin.flush()
    time.sleep(0.2)

    for local_path, remote_b64, remote_out in [
        (archive_path, "/tmp/workerAgents.tgz.b64", "/tmp/workerAgents.tgz"),
        (tunnel_client_path, "/tmp/lolgames_tunnel.py.b64", "/tmp/lolgames_tunnel.py"),
        (script_path, "/tmp/worker-agents-setup.sh.b64", "/tmp/worker-agents-setup.sh"),
    ]:
        encoded = base64.b64encode(open(local_path, "rb").read()).decode("ascii")
        lines = [f": > {remote_b64}"]
        for i in range(0, len(encoded), 900):
            lines.append(f"printf %s {shlex.quote(encoded[i:i+900])} >> {remote_b64}")
        lines.append(f"base64 -d {remote_b64} > {remote_out}")
        if remote_out.endswith(".sh"):
            lines.append(f"chmod +x {remote_out}")
        proc.stdin.write("\n".join(lines) + "\n")
        proc.stdin.flush()

    proc.stdin.write(
        f"RUN_TOKEN={run_token} APP_PORT={app_port} "
        f"ROUTER_GIT_URL={shlex.quote(os.environ.get('ROUTER_GIT_URL', 'https://github.com/decolua/9router.git'))} "
        f"HERMES_WEBUI_GIT_URL={shlex.quote(os.environ.get('HERMES_WEBUI_GIT_URL', 'https://github.com/nesquena/hermes-webui.git'))} "
        "bash /tmp/worker-agents-setup.sh\n"
    )
    proc.stdin.flush()

    deadline = time.time() + 420
    while time.time() < deadline:
        ch = read_chunk()
        if not ch:
            if proc.poll() is not None:
                break
            continue
        buffer += ch
        outf.write(ch)
        outf.flush()
        if f"__WORKER_AGENTS_DONE__{run_token}" in buffer and ".lolgames.net" in buffer:
            break

    close_proc(interrupt_remote=True)
PY

SANITIZED_OUTPUT="$TMP_DIR/remote-output-clean.txt"
python3 - "$REMOTE_OUTPUT" "$SANITIZED_OUTPUT" <<'PY'
import re
import sys
src, dst = sys.argv[1:]
data = open(src, "r", encoding="utf-8", errors="ignore").read()
data = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', data)
data = data.replace('\r', '')
open(dst, "w", encoding="utf-8").write(data)
PY

PUBLIC_URL="$(grep -aoE 'PUBLIC_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^PUBLIC_URL=//' | tail -n 1 || true)"

if [[ -z "${PUBLIC_URL:-}" ]]; then
  STATE_FALLBACK="$TMP_DIR/remote-state-fallback.txt"
  python3 - "$ROOT_DIR" "$SSH_CMD" "$STATE_FALLBACK" <<'PY' || true
import pathlib
import shlex
import subprocess
import sys

root_dir = pathlib.Path(sys.argv[1])
ssh_cmd = sys.argv[2]
out_path = pathlib.Path(sys.argv[3])
remote_cmd = "cat ~/.worker-agents/state.json 2>/dev/null || true"
if "tmate.io" in ssh_cmd:
    dest = ssh_cmd.removeprefix("ssh ").strip()
    argv = [str(root_dir / "tests" / "lib" / "ssh_tmate_exec.py"), dest, remote_cmd, "--timeout", "30"]
    timeout = 45
else:
    argv = shlex.split(ssh_cmd) + [remote_cmd]
    timeout = 20
proc = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout, check=False)
out_path.write_text(proc.stdout or "", encoding="utf-8")
PY
  python3 - "$STATE_FALLBACK" "$TMP_DIR/state.env" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text).replace('\r', '')
match = re.search(r'\{[^{}]*"worker_agents_url"[^{}]*\}', text, re.S)
data = json.loads(match.group(0)) if match else {}
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    val = str(data.get('worker_agents_url') or data.get('url') or '')
    f.write(f'PUBLIC_URL={val}\n')
PY
  # shellcheck disable=SC1090
  source "$TMP_DIR/state.env" 2>/dev/null || true
fi

echo
echo "Worker SSH:"
echo "$SSH_CMD"
echo
echo "workerAgents public URL:"
echo "${PUBLIC_URL:-<missing>}"

if [[ -z "${PUBLIC_URL:-}" ]]; then
  echo
  echo "Warning: workerAgents lolgames URL not found yet. Re-check on the worker:" >&2
  echo "  tail -60 ~/worker-agents-lolgames.log" >&2
  exit 1
fi

if [[ "$SMOKE_TEST" == "1" ]]; then
  echo
  echo "Smoke testing workerAgents..."
  curl -fsS --max-time 20 "$PUBLIC_URL/" >/dev/null
  curl -fsS --max-time 20 "$PUBLIC_URL/api/status" >/dev/null
  ROUTER_URL="$(python3 - "$PUBLIC_URL" <<'PY'
from urllib.parse import urlsplit, urlunsplit
import sys
u = urlsplit(sys.argv[1])
print(urlunsplit((u.scheme, f"{u.hostname}:20127", "/api/health", "", "")))
PY
)"
  if curl -fsS --max-time 20 "$ROUTER_URL" >/dev/null; then
    echo "9Router route OK: $ROUTER_URL"
  elif [[ "$SMOKE_REQUIRE_ROUTER" == "1" ]]; then
    echo "9Router smoke test failed: $ROUTER_URL" >&2
    exit 1
  else
    echo "Warning: 9Router route did not pass smoke test yet: $ROUTER_URL" >&2
  fi
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
METADATA_PATH="$ROOT_DIR/outputs/$TIMESTAMP-worker-agents.json"
LATEST_METADATA_PATH="$ROOT_DIR/outputs/latest-worker-agents.json"
python3 - "$METADATA_PATH" "$LATEST_METADATA_PATH" "$SSH_CMD" "${PUBLIC_URL:-}" "$REPO" "$WORKFLOW" "$RUN_ID" "$WEB_URL" "$ROUTER_GIT_URL" "$HERMES_WEBUI_GIT_URL" <<'PY'
import json
import sys
from datetime import datetime, timezone

out_path, latest_path, ssh_cmd, public_url, repo, workflow, run_id, run_url, router_git_url, hermes_webui_git_url = sys.argv[1:]
payload = {
    "created_at": datetime.now(timezone.utc).isoformat(),
    "repo": repo,
    "workflow": workflow,
    "run_id": run_id,
    "run_url": run_url,
    "ssh": ssh_cmd,
    "worker_agents_url": public_url,
    "router_git_url": router_git_url,
    "hermes_webui_git_url": hermes_webui_git_url,
}
for path in (out_path, latest_path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
PY
echo "Wrote metadata:"
echo "$METADATA_PATH"
echo "$LATEST_METADATA_PATH"

LAUNCH_OK=1
