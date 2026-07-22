#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/workerAgents"
ROUTER_GIT_URL="${ROUTER_GIT_URL:-https://github.com/alexcheng-dev/9router.git}"
ROUTER_PREBUILT_REPO="${ROUTER_PREBUILT_REPO:-alexcheng-dev/9router}"
ROUTER_PREBUILT_WORKFLOW="${ROUTER_PREBUILT_WORKFLOW:-build-standalone.yml}"
HERMES_WEBUI_GIT_URL="${HERMES_WEBUI_GIT_URL:-https://github.com/nesquena/hermes-webui.git}"
APP_PORT="${APP_PORT:-1456}"
TUNNEL_CLIENT_PATH="$ROOT_DIR/scripts/lolgames_tunnel.py"
SSH_TARGET="${1:-}"
REFRESH_START_AGENTS="${REFRESH_START_AGENTS:-0}"
INSTALL_CHILD_DEPS="${INSTALL_CHILD_DEPS:-$REFRESH_START_AGENTS}"
PROVISION_TRACE="${PROVISION_TRACE:-1}"
SMOKE_TEST="${SMOKE_TEST:-1}"
SMOKE_REQUIRE_ROUTER="${SMOKE_REQUIRE_ROUTER:-0}"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

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

require python3
require tar
require scp
require ssh

if [[ -z "$SSH_TARGET" ]]; then
  echo "Usage: $0 <ssh-destination-or-command>" >&2
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app directory: $APP_DIR" >&2
  exit 1
fi

if [[ ! -f "$TUNNEL_CLIENT_PATH" ]]; then
  echo "Missing lolgames tunnel client: $TUNNEL_CLIENT_PATH" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/outputs"

ARCHIVE_PATH="$TMP_DIR/workerAgents.tgz"
trace "pack workerAgents archive"
tar --exclude='.git' --exclude='node_modules' --exclude='workers.json' -czf "$ARCHIVE_PATH" -C "$ROOT_DIR" workerAgents

ROUTER_PREBUILT_PATH="$TMP_DIR/9router-standalone.tgz"
trace "fetch 9router prebuilt"
if ! REPO="$ROUTER_PREBUILT_REPO" WORKFLOW="$ROUTER_PREBUILT_WORKFLOW" ./scripts/fetch-9router-prebuilt.sh "$ROUTER_PREBUILT_PATH" >/dev/null 2>&1; then
  echo "Warning: failed to fetch 9router prebuilt; falling back to clone+build." >&2
  ROUTER_PREBUILT_PATH=""
fi

REMOTE_SCRIPT="$TMP_DIR/refresh-worker-agents-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOS'
set -euo pipefail
APP_HOME="$HOME/workerAgents"
ROUTER_HOME="$HOME/9router"
HERMES_WEBUI_HOME="$HOME/hermes-webui"
STATE_DIR="$HOME/.worker-agents"
mkdir -p "$STATE_DIR" "$HOME/node-http2" "$HOME/.codex"

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

trace() {
  [[ "${PROVISION_TRACE:-1}" == "1" ]] || return 0
  printf '[remote-trace][%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
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
if [[ "${INSTALL_CHILD_DEPS:-0}" == "1" && "${REFRESH_START_AGENTS:-0}" == "1" && ! -x "$HOME/.local/bin/hermes" ]]; then
  trace "bootstrap Hermes"
  timeout 180 python3 "$HERMES_WEBUI_HOME/bootstrap.py" --no-browser --foreground --host 127.0.0.1 18935 >/tmp/hermes-bootstrap.log 2>&1 || true
fi

trace "start Worker Agents tmux"
TMUX='' tmux -L workeragents -f /dev/null kill-server 2>/dev/null || true
TMUX='' tmux -L workeragents -f /dev/null new-session -d -s workeragents "cd \"$APP_HOME\" && PORT=${APP_PORT:-1456} AGENT_CONSOLE_HOST=127.0.0.1 WORKER_AGENTS_9ROUTER_DIR=\"$ROUTER_HOME\" WORKER_AGENTS_9ROUTER_PORT=20127 WORKER_AGENTS_9ROUTER_API_KEY=local-dev-key WORKER_AGENTS_9ROUTER_MODEL=openai/gpt-5.4-mini HERMES_WEBUI_DIR=\"$HERMES_WEBUI_HOME\" npm start > ~/worker-agents.log 2>&1"

trace "wait for Worker Agents API"
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ "${REFRESH_START_AGENTS:-0}" == "1" ]]; then
  trace "start child agents"
  for agent_id in codex-web-local opencode hermes-webui openclaw; do
    curl -fsS -X POST "http://127.0.0.1:${APP_PORT:-1456}/api/agents/${agent_id}/restart" >/dev/null || true
    sleep 8
  done
fi

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

STATUS_PATH="$STATE_DIR/status.json"
trace "capture status + start tunnels"
curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" > "$STATUS_PATH"
WORKER_AGENTS_URL="$(start_tunnel worker-agents "${APP_PORT:-1456}" || true)"
ROUTER_URL="$(start_tunnel 9router 20127 || true)"

python3 - "$STATUS_PATH" <<'PY' > "$STATE_DIR/ports.env"
import json, sys
agents = {a.get('id'): a for a in json.load(open(sys.argv[1])).get('agents', [])}
for key, env in [('codex-web-local', 'CODEX_PORT'), ('opencode', 'OPENCODE_PORT'), ('hermes-webui', 'HERMES_PORT'), ('openclaw', 'OPENCLAW_PORT')]:
    agent = agents.get(key) or {}
    print(f"{env}={agent.get('port') if agent.get('state') == 'running' else ''}")
PY
source "$STATE_DIR/ports.env"

CODEX_URL=""
OPENCODE_URL=""
HERMES_URL=""
OPENCLAW_URL=""
if [[ -n "${CODEX_PORT:-}" ]]; then CODEX_URL="$(start_tunnel codex-web-local "$CODEX_PORT" || true)"; fi
if [[ -n "${OPENCODE_PORT:-}" ]]; then OPENCODE_URL="$(start_tunnel opencode "$OPENCODE_PORT" || true)"; fi
if [[ -n "${HERMES_PORT:-}" ]]; then HERMES_URL="$(start_tunnel hermes-webui "$HERMES_PORT" || true)"; fi
if [[ -n "${OPENCLAW_PORT:-}" ]]; then OPENCLAW_URL="$(start_tunnel openclaw "$OPENCLAW_PORT" || true)"; fi

python3 - "${WORKER_AGENTS_URL:-}" "${APP_PORT:-1456}" "${ROUTER_URL:-}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" "${OPENCLAW_URL:-}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
worker_agents_url, port, router_url, codex_url, opencode_url, hermes_url, openclaw_url = sys.argv[1:]
state = {
    'status': 'running' if worker_agents_url else 'starting',
    'url': worker_agents_url,
    'worker_agents_url': worker_agents_url,
    'port': int(port),
    'router_url': router_url,
    'codex_web_url': codex_url,
    'opencode_url': opencode_url,
    'hermes_webui_url': hermes_url,
    'openclaw_url': openclaw_url,
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
echo "ROUTER_URL=${ROUTER_URL:-}"
echo "CODEX_URL=${CODEX_URL:-}"
echo "OPENCODE_URL=${OPENCODE_URL:-}"
echo "HERMES_URL=${HERMES_URL:-}"
echo "OPENCLAW_URL=${OPENCLAW_URL:-}"
EOS

REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
trace "upload assets + run remote refresh"
python3 - "$SSH_TARGET" "$ARCHIVE_PATH" "${ROUTER_PREBUILT_PATH:-}" "$TUNNEL_CLIENT_PATH" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" "$APP_PORT" "$ROUTER_GIT_URL" "$HERMES_WEBUI_GIT_URL" "$REFRESH_START_AGENTS" "$INSTALL_CHILD_DEPS" "$PROVISION_TRACE" <<'PY'
import os, shlex, subprocess, sys
ssh_target, archive_path, router_prebuilt_path, tunnel_client_path, script_path, out_path, app_port, router_git_url, hermes_webui_git_url, refresh_start_agents, install_child_deps, provision_trace = sys.argv[1:]
ssh_cmd = ssh_target if ssh_target.strip().startswith('ssh ') else f'ssh {shlex.quote(ssh_target)}'
ssh_argv = shlex.split(ssh_cmd)
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
    f'RUN_TOKEN=refresh',
    f'APP_PORT={shlex.quote(app_port)}',
    f'ROUTER_GIT_URL={shlex.quote(router_git_url)}',
    f'HERMES_WEBUI_GIT_URL={shlex.quote(hermes_webui_git_url)}',
    f'REFRESH_START_AGENTS={shlex.quote(refresh_start_agents)}',
    f'INSTALL_CHILD_DEPS={shlex.quote(install_child_deps)}',
    f'PROVISION_TRACE={shlex.quote(provision_trace)}',
]) 
proc = subprocess.run(['ssh', *opts, dest, f'{remote_env} bash /tmp/{os.path.basename(script_path)}'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
open(out_path, 'w', encoding='utf-8').write(proc.stdout or '')
PY

SANITIZED_OUTPUT="$TMP_DIR/remote-output.clean.txt"
python3 - "$REMOTE_OUTPUT" "$SANITIZED_OUTPUT" <<'PY'
import re, sys
src, dst = sys.argv[1:]
text = open(src, 'r', encoding='utf-8', errors='ignore').read()
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text).replace('\r', '')
open(dst, 'w', encoding='utf-8').write(text)
PY

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PUBLIC_URL="$(grep -aoE 'PUBLIC_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^PUBLIC_URL=//' | tail -n 1 || true)"
ROUTER_URL="$(grep -aoE 'ROUTER_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^ROUTER_URL=//' | tail -n 1 || true)"
CODEX_URL="$(grep -aoE 'CODEX_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^CODEX_URL=//' | tail -n 1 || true)"
OPENCODE_URL="$(grep -aoE 'OPENCODE_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^OPENCODE_URL=//' | tail -n 1 || true)"
HERMES_URL="$(grep -aoE 'HERMES_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^HERMES_URL=//' | tail -n 1 || true)"
OPENCLAW_URL="$(grep -aoE 'OPENCLAW_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^OPENCLAW_URL=//' | tail -n 1 || true)"

if [[ -z "${PUBLIC_URL:-}" ]]; then
  STATE_FALLBACK="$TMP_DIR/remote-state-fallback.txt"
  python3 - "$ROOT_DIR" "$SSH_TARGET" "$STATE_FALLBACK" <<'PY' || true
import pathlib
import shlex
import subprocess
import sys

root_dir = pathlib.Path(sys.argv[1])
ssh_target = sys.argv[2]
out_path = pathlib.Path(sys.argv[3])
remote_cmd = "cat ~/.worker-agents/state.json 2>/dev/null || true"
if "tmate.io" in ssh_target:
    dest = ssh_target.removeprefix("ssh ").strip()
    argv = [str(root_dir / "tests" / "lib" / "ssh_tmate_exec.py"), dest, remote_cmd, "--timeout", "30"]
    timeout = 45
else:
    ssh_cmd = ssh_target if ssh_target.strip().startswith("ssh ") else f"ssh {shlex.quote(ssh_target)}"
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
    for key, name in [
        ('worker_agents_url','PUBLIC_URL'), ('router_url','ROUTER_URL'),
        ('codex_web_url','CODEX_URL'), ('opencode_url','OPENCODE_URL'),
        ('hermes_webui_url','HERMES_URL'),
        ('openclaw_url','OPENCLAW_URL')]:
        val = str(data.get(key) or '')
        f.write(f'{name}={val}\n')
PY
  # shellcheck disable=SC1090
  source "$TMP_DIR/state.env" 2>/dev/null || true
fi

echo "workerAgents public URL:"
echo "${PUBLIC_URL:-<missing>}"
echo "9router public URL:"
echo "${ROUTER_URL:-<missing>}"
echo "codex_web public URL:"
echo "${CODEX_URL:-<missing>}"
echo "opencode public URL:"
echo "${OPENCODE_URL:-<missing>}"
echo "hermes_webui public URL:"
echo "${HERMES_URL:-<missing>}"
echo "openclaw public URL:"
echo "${OPENCLAW_URL:-<missing>}"

python3 - "$ROOT_DIR/outputs/$TIMESTAMP-worker-refresh.json" "$SSH_TARGET" "${PUBLIC_URL:-}" "${ROUTER_URL:-}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" "${OPENCLAW_URL:-}" <<'PY'
import json
import sys
from datetime import datetime, timezone

out_path, ssh_dest, public_url, router_url, codex_url, opencode_url, hermes_url, openclaw_url = sys.argv[1:]
payload = {
    "created_at": datetime.now(timezone.utc).isoformat(),
    "ssh": ssh_dest,
    "worker_agents_url": public_url,
    "router_url": router_url,
    "codex_web_url": codex_url,
    "opencode_url": opencode_url,
    "hermes_webui_url": hermes_url,
    "openclaw_url": openclaw_url,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

if [[ -z "${PUBLIC_URL:-}" ]]; then
  echo "Warning: workerAgents lolgames URL not found yet." >&2
  exit 1
fi

if [[ "$SMOKE_TEST" == "1" ]]; then
  trace "smoke test public endpoints"
  curl -fsS --max-time 20 "$PUBLIC_URL/" >/dev/null
  curl -fsS --max-time 20 "$PUBLIC_URL/api/status" >/dev/null
  if [[ -n "$ROUTER_URL" ]]; then
    if curl -fsS --max-time 20 "$ROUTER_URL/api/health" >/dev/null; then
      :
    elif [[ "$SMOKE_REQUIRE_ROUTER" == "1" ]]; then
      echo "9Router smoke test failed: $ROUTER_URL/api/health" >&2
      exit 1
    fi
  fi
fi

echo
echo "workerAgents public URL:"
echo "${PUBLIC_URL:-<missing>}"
[[ -n "$ROUTER_URL" ]] && { echo; echo "9router public URL:"; echo "$ROUTER_URL"; }
[[ -n "$CODEX_URL" ]] && { echo; echo "Codex Web public URL:"; echo "$CODEX_URL"; }
[[ -n "$OPENCODE_URL" ]] && { echo; echo "OpenCode public URL:"; echo "$OPENCODE_URL"; }
[[ -n "$HERMES_URL" ]] && { echo; echo "Hermes WebUI public URL:"; echo "$HERMES_URL"; }

python3 - "$ROOT_DIR/outputs/$TIMESTAMP-worker-refresh.json" "$PUBLIC_URL" "$ROUTER_URL" "$CODEX_URL" "$OPENCODE_URL" "$HERMES_URL" <<'PY'
import json, sys
from datetime import datetime, timezone
out_path, worker_agents_url, router_url, codex_url, opencode_url, hermes_url = sys.argv[1:]
payload = {
    'created_at': datetime.now(timezone.utc).isoformat(),
    'worker_agents_url': worker_agents_url,
    'router_url': router_url,
    'codex_web_url': codex_url,
    'opencode_url': opencode_url,
    'hermes_webui_url': hermes_url,
}
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2)
    f.write('\n')
PY
