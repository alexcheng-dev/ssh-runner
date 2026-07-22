#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-alexcheng-dev/agent-workspace}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
APP_DIR="$ROOT_DIR/workerAgents"
ROUTER_GIT_URL="${ROUTER_GIT_URL:-https://github.com/alexcheng-dev/9router.git}"
ROUTER_PREBUILT_REPO="${ROUTER_PREBUILT_REPO:-alexcheng-dev/9router}"
ROUTER_PREBUILT_WORKFLOW="${ROUTER_PREBUILT_WORKFLOW:-build-standalone.yml}"
HERMES_WEBUI_GIT_URL="${HERMES_WEBUI_GIT_URL:-https://github.com/nesquena/hermes-webui.git}"
TUNNEL_CLIENT_PATH="$ROOT_DIR/scripts/lolgames_tunnel.py"
APP_PORT="${APP_PORT:-1456}"
SYNC_AGENT_WORKSPACE="${SYNC_AGENT_WORKSPACE:-1}"
REUSE_EXISTING_WORKER="${REUSE_EXISTING_WORKER:-1}"
CANCEL_OLDER_WORKERS="${CANCEL_OLDER_WORKERS:-1}"
START_CHILD_AGENTS="${START_CHILD_AGENTS:-0}"
INSTALL_CHILD_DEPS="${INSTALL_CHILD_DEPS:-$START_CHILD_AGENTS}"
PROVISION_TRACE="${PROVISION_TRACE:-1}"
SMOKE_TEST="${SMOKE_TEST:-1}"
SMOKE_REQUIRE_ROUTER="${SMOKE_REQUIRE_ROUTER:-0}"
TMP_DIR="$(mktemp -d)"
RUN_ID=""
WEB_URL=""
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

trace() {
  [[ "$PROVISION_TRACE" == "1" ]] || return 0
  printf '[trace][%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

find_reusable_worker() {
  local list_output ssh_cmd worker_url
  list_output="$(RUN_LIMIT=10 REPO="$REPO" WORKFLOW="$WORKFLOW" "$ROOT_DIR/scripts/list-running-workers.sh" 2>/dev/null || true)"
  ssh_cmd="$(printf '%s\n' "$list_output" | awk -F'\t' '$1=="ssh"{print $2; exit}')"
  worker_url="$(printf '%s\n' "$list_output" | awk -F'\t' '$1=="lolgames_worker_agents"{print $2; exit}')"
  if [[ -n "$ssh_cmd" ]]; then
    printf '%s\n%s\n' "$ssh_cmd" "$worker_url"
  fi
}

wait_for_ssh_ready() {
  local ssh_cmd="$1"
  local attempts="${2:-30}"
  local delay="${3:-2}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if bash -lc "$ssh_cmd -o ConnectTimeout=5 'true'" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

require gh
require ssh
require scp
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
  trace "sync agent-workspace"
  ./scripts/ensure-agent-workspace-repo.sh
fi

if [[ "$REUSE_EXISTING_WORKER" == "1" ]]; then
  trace "search reusable worker"
  if REUSE_INFO="$(find_reusable_worker)" && [[ -n "$REUSE_INFO" ]]; then
    REUSE_SSH_CMD="$(printf '%s\n' "$REUSE_INFO" | sed -n '1p')"
    REUSE_URL="$(printf '%s\n' "$REUSE_INFO" | sed -n '2p')"
    if [[ -n "$REUSE_SSH_CMD" && -n "$REUSE_URL" ]]; then
      trace "reuse existing worker $REUSE_URL"
      echo "Reusing existing worker: $REUSE_URL"
      REFRESH_START_AGENTS="$START_CHILD_AGENTS" \
      ROUTER_GIT_URL="$ROUTER_GIT_URL" \
      ROUTER_PREBUILT_REPO="$ROUTER_PREBUILT_REPO" \
      ROUTER_PREBUILT_WORKFLOW="$ROUTER_PREBUILT_WORKFLOW" \
      HERMES_WEBUI_GIT_URL="$HERMES_WEBUI_GIT_URL" \
      SMOKE_TEST="$SMOKE_TEST" \
      SMOKE_REQUIRE_ROUTER="$SMOKE_REQUIRE_ROUTER" \
      ./scripts/refresh-worker-agents-worker.sh "$REUSE_SSH_CMD"
      LAUNCH_OK=1
      exit 0
    fi
  fi
fi

if [[ "$CANCEL_OLDER_WORKERS" == "1" ]]; then
  trace "cancel older in-progress runs"
  while IFS= read -r old_run_id; do
    [[ -n "$old_run_id" ]] || continue
    echo "Canceling older in-progress worker run: $old_run_id" >&2
    gh run cancel "$old_run_id" --repo "$REPO" >/dev/null 2>&1 || true
  done < <(gh run list --repo "$REPO" --workflow "$WORKFLOW" --status in_progress --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)
fi

trace "trigger worker"
echo "Triggering worker..."
SSH_RUNNER_META_OUT="$TMP_DIR/ssh-runner-meta.env" ./scripts/ssh-runner-link.sh "$REPO" "$WORKFLOW" > "$TMP_DIR/ssh-link.txt"
source "$TMP_DIR/ssh-runner-meta.env"
SSH_CMD="$(sed -n '1p' "$TMP_DIR/ssh-link.txt")"
WEB_URL="$(sed -n '2p' "$TMP_DIR/ssh-link.txt")"

if [[ -z "$SSH_CMD" ]]; then
  echo "Failed to get SSH command" >&2
  exit 1
fi

trace "wait for ssh readiness"
if ! wait_for_ssh_ready "$SSH_CMD" 30 2; then
  echo "SSH runner did not become reachable in time" >&2
  exit 1
fi

ARCHIVE_PATH="$TMP_DIR/workerAgents.tgz"
trace "pack workerAgents archive"
tar --exclude='.git' --exclude='node_modules' --exclude='workers.json' -czf "$ARCHIVE_PATH" -C "$ROOT_DIR" workerAgents

ROUTER_PREBUILT_PATH="$TMP_DIR/9router-standalone.tgz"
trace "fetch 9router prebuilt"
if ! REPO="$ROUTER_PREBUILT_REPO" WORKFLOW="$ROUTER_PREBUILT_WORKFLOW" ./scripts/fetch-9router-prebuilt.sh "$ROUTER_PREBUILT_PATH" >/dev/null 2>&1; then
  echo "Warning: failed to fetch 9router prebuilt; falling back to clone+build." >&2
  ROUTER_PREBUILT_PATH=""
fi

REMOTE_SCRIPT="$TMP_DIR/remote-worker-agents-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOS'
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
path = Path.home() / '.codex' / 'config.toml'
existing = path.read_text(encoding='utf-8') if path.exists() else ''
lines = existing.splitlines()
globals_, rest, in_section = [], [], False
for line in lines:
    if line.lstrip().startswith('['):
        in_section = True
    (rest if in_section else globals_).append(line)
def set_global_line(key, value):
    line = f'{key} = {value}'
    for i, current in enumerate(globals_):
        if current.startswith(f'{key} = '):
            globals_[i] = line
            return
    globals_.append(line)
set_global_line('model', '"openai/gpt-5.4-mini"')
set_global_line('openai_base_url', '"http://127.0.0.1:20127/v1"')
set_global_line('chatgpt_base_url', '"http://127.0.0.1:20127/backend-api"')
path.write_text('\n'.join([*globals_, *rest]).rstrip() + '\n', encoding='utf-8')
PY

TUNNEL_PREFIX="${LOLGAMES_TUNNEL_PREFIX:-$(hostname | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')-$(date +%s)}"
trace() {
  [[ "${PROVISION_TRACE:-1}" == "1" ]] || return 0
  printf '[remote-trace][%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}
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
trace "extract workerAgents"
tar -xzf /tmp/workerAgents.tgz -C "$HOME"

if [[ -f /tmp/9router-standalone.tgz ]]; then
  trace "extract 9router prebuilt"
  rm -rf "$ROUTER_HOME"
  mkdir -p "$ROUTER_HOME"
  tar -xzf /tmp/9router-standalone.tgz -C "$ROUTER_HOME"
else
  trace "clone+build 9router fallback"
  rm -rf "$ROUTER_HOME"
  git clone --depth 1 "$ROUTER_GIT_URL" "$ROUTER_HOME"
  cd "$ROUTER_HOME"
  npm install
  npm run build
  mkdir -p .next/standalone/.next
  rm -rf .next/standalone/.next/static .next/standalone/public
  cp -R .next/static .next/standalone/.next/static
  cp -R public .next/standalone/public
fi

cd "$APP_HOME"
trace "npm install workerAgents"
npm install
if [[ "${INSTALL_CHILD_DEPS:-0}" == "1" ]]; then
  trace "clone Hermes WebUI"
  rm -rf "$HERMES_WEBUI_HOME"
  git clone --depth 1 "$HERMES_WEBUI_GIT_URL" "$HERMES_WEBUI_HOME"
  trace "install child CLIs"
  npm install -g codexapp opencode-ai openclaw
fi

if [[ "${INSTALL_CHILD_DEPS:-0}" == "1" && "${START_CHILD_AGENTS:-0}" == "1" && ! -x "$HOME/.local/bin/hermes" ]]; then
  trace "bootstrap Hermes"
  timeout 180 python3 "$HERMES_WEBUI_HOME/bootstrap.py" --no-browser --foreground --host 127.0.0.1 18935 >/tmp/hermes-bootstrap.log 2>&1 || true
fi

trace "start Worker Agents tmux"
TMUX='' tmux -L workeragents -f /dev/null kill-server 2>/dev/null || true
TMUX='' tmux -L workeragents -f /dev/null new-session -d -s workeragents "cd \"$APP_HOME\" && PORT=${APP_PORT:-1456} AGENT_CONSOLE_HOST=127.0.0.1 WORKER_AGENTS_9ROUTER_DIR=\"$ROUTER_HOME\" WORKER_AGENTS_9ROUTER_PORT=20127 WORKER_AGENTS_9ROUTER_API_KEY=local-dev-key HERMES_WEBUI_DIR=\"$HERMES_WEBUI_HOME\" npm start > ~/worker-agents.log 2>&1"

trace "wait for Worker Agents API"
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ "${START_CHILD_AGENTS:-0}" == "1" ]]; then
  trace "start child agents"
  for agent_id in codex-web-local opencode hermes-webui openclaw; do
    curl -fsS -X POST "http://127.0.0.1:${APP_PORT:-1456}/api/agents/${agent_id}/restart" >/dev/null || true
    sleep 8
  done
fi

STATUS_PATH="$STATE_DIR/status.json"
trace "capture status + start tunnel"
curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" > "$STATUS_PATH"
WORKER_AGENTS_URL="$(start_tunnel worker-agents "${APP_PORT:-1456}" || true)"

python3 - "${WORKER_AGENTS_URL:-}" "${APP_PORT:-1456}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
worker_agents_url = sys.argv[1]
port = int(sys.argv[2])
state = {
    'status': 'running' if worker_agents_url else 'starting',
    'url': worker_agents_url,
    'worker_agents_url': worker_agents_url,
    'port': port,
    'updated_at': datetime.now(timezone.utc).isoformat(),
}
state_dir = os.path.expanduser('~/.worker-agents')
os.makedirs(state_dir, exist_ok=True)
with open(os.path.join(state_dir, 'state.json'), 'w', encoding='utf-8') as f:
    json.dump(state, f)
    f.write('\n')
PY

echo "__WORKER_AGENTS_DONE__${RUN_TOKEN:-}"
echo "PUBLIC_URL=${WORKER_AGENTS_URL:-}"
EOS

RUN_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
trace "upload assets + run remote setup"
python3 - "$SSH_CMD" "$ARCHIVE_PATH" "${ROUTER_PREBUILT_PATH:-}" "$TUNNEL_CLIENT_PATH" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" "$APP_PORT" "$RUN_TOKEN" "$ROUTER_GIT_URL" "$HERMES_WEBUI_GIT_URL" "$START_CHILD_AGENTS" "$INSTALL_CHILD_DEPS" "$PROVISION_TRACE" <<'PY'
import os, shlex, subprocess, sys

ssh_cmd, archive_path, router_prebuilt_path, tunnel_client_path, script_path, out_path, app_port, run_token, router_git_url, hermes_webui_git_url, start_child_agents, install_child_deps, provision_trace = sys.argv[1:]
ssh_argv = shlex.split(ssh_cmd)
if not ssh_argv or ssh_argv[0] != 'ssh':
    raise SystemExit(f'Unsupported SSH command: {ssh_cmd}')

opts = []
dest = None
i = 1
while i < len(ssh_argv):
    token = ssh_argv[i]
    if token in ('-i', '-p', '-o'):
        opts.extend([token, ssh_argv[i + 1]])
        i += 2
        continue
    if token.startswith('-'):
        opts.append(token)
        i += 1
        continue
    dest = token
    i += 1
    break
if not dest:
    raise SystemExit(f'Could not parse SSH destination from: {ssh_cmd}')

scp_opts = []
i = 0
while i < len(opts):
    token = opts[i]
    if token == '-p':
        scp_opts.extend(['-P', opts[i + 1]])
        i += 2
    elif token in ('-i', '-o'):
        scp_opts.extend([token, opts[i + 1]])
        i += 2
    else:
        scp_opts.append(token)
        i += 1

files = [archive_path, tunnel_client_path, script_path]
if router_prebuilt_path:
    files.append(router_prebuilt_path)

subprocess.run(['scp', *scp_opts, *files, f'{dest}:/tmp/'], check=True)
remote_env = ' '.join([
    f'RUN_TOKEN={shlex.quote(run_token)}',
    f'APP_PORT={shlex.quote(app_port)}',
    f'ROUTER_GIT_URL={shlex.quote(router_git_url)}',
    f'HERMES_WEBUI_GIT_URL={shlex.quote(hermes_webui_git_url)}',
    f'START_CHILD_AGENTS={shlex.quote(start_child_agents)}',
    f'INSTALL_CHILD_DEPS={shlex.quote(install_child_deps)}',
    f'PROVISION_TRACE={shlex.quote(provision_trace)}',
])
with open(out_path, 'w', encoding='utf-8') as out:
    proc = subprocess.run([
        'ssh', *opts, dest, f'{remote_env} bash /tmp/{os.path.basename(script_path)}'
    ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    out.write(proc.stdout or '')
PY

python3 -c 'import re,sys; src,dst=sys.argv[1:3]; data=open(src,"r",encoding="utf-8",errors="ignore").read(); data=re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]","",data).replace("\r",""); open(dst,"w",encoding="utf-8").write(data)' "$REMOTE_OUTPUT" "$TMP_DIR/remote-output-clean.txt"

PUBLIC_URL="$(grep -aoE 'PUBLIC_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$TMP_DIR/remote-output-clean.txt" | sed 's/^PUBLIC_URL=//' | tail -n 1 || true)"

if [[ -z "${PUBLIC_URL:-}" ]]; then
  STATE_FALLBACK="$TMP_DIR/remote-state-fallback.txt"
  python3 - "$ROOT_DIR" "$SSH_CMD" "$STATE_FALLBACK" <<'PY' || true
import pathlib, shlex, subprocess, sys
root_dir = pathlib.Path(sys.argv[1])
ssh_cmd = sys.argv[2]
out_path = pathlib.Path(sys.argv[3])
proc = subprocess.run(shlex.split(ssh_cmd) + ['cat ~/.worker-agents/state.json 2>/dev/null || true'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20, check=False)
out_path.write_text(proc.stdout or '', encoding='utf-8')
PY
  python3 - "$STATE_FALLBACK" "$TMP_DIR/state.env" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text).replace('\r', '')
match = re.search(r'\{[^{}]*"worker_agents_url"[^{}]*\}', text, re.S)
data = json.loads(match.group(0)) if match else {}
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    f.write(f"PUBLIC_URL={str(data.get('worker_agents_url') or data.get('url') or '')}\n")
PY
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
  trace "smoke test public endpoints"
  echo
  echo "Smoke testing workerAgents..."
  curl -fsS --max-time 20 "$PUBLIC_URL/" >/dev/null
  curl -fsS --max-time 20 "$PUBLIC_URL/api/status" >/dev/null
  ROUTER_URL="$(python3 - "$PUBLIC_URL" <<'PY'
from urllib.parse import urlsplit, urlunsplit
import sys
u = urlsplit(sys.argv[1])
print(urlunsplit((u.scheme, f"{u.hostname}:20127", '/api/health', '', '')))
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
python3 - "$METADATA_PATH" "$LATEST_METADATA_PATH" "$SSH_CMD" "$PUBLIC_URL" "$REPO" "$WORKFLOW" "$RUN_ID" "$WEB_URL" "$ROUTER_GIT_URL" "$HERMES_WEBUI_GIT_URL" "$START_CHILD_AGENTS" <<'PY'
import json, sys
from datetime import datetime, timezone
out_path, latest_path, ssh_cmd, public_url, repo, workflow, run_id, run_url, router_git_url, hermes_webui_git_url, start_child_agents = sys.argv[1:]
payload = {
    'created_at': datetime.now(timezone.utc).isoformat(),
    'repo': repo,
    'workflow': workflow,
    'run_id': run_id,
    'run_url': run_url,
    'ssh': ssh_cmd,
    'worker_agents_url': public_url,
    'router_git_url': router_git_url,
    'hermes_webui_git_url': hermes_webui_git_url,
    'start_child_agents': start_child_agents == '1',
}
for path in (out_path, latest_path):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(payload, f, indent=2)
        f.write('\n')
PY
echo "Wrote metadata:"
echo "$METADATA_PATH"
echo "$LATEST_METADATA_PATH"

LAUNCH_OK=1
