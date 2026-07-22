#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/workerAgents"
ROUTER_DIR="${ROUTER_DIR:-/Users/igor/Git-projects/9router}"
ROUTER_GIT_URL="${ROUTER_GIT_URL:-https://github.com/phaneron23/9router.git}"
HERMES_WEBUI_DIR="${HERMES_WEBUI_DIR:-/Users/igor/Git-projects/hermes-webui}"
HERMES_WEBUI_GIT_URL="${HERMES_WEBUI_GIT_URL:-https://github.com/nesquena/hermes-webui.git}"
APP_PORT="${APP_PORT:-1456}"
TUNNEL_CLIENT_PATH="$ROOT_DIR/scripts/lolgames_tunnel.py"
SSH_TARGET="${1:-}"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require python3
require tar

if [[ -z "$SSH_TARGET" ]]; then
  echo "Usage: $0 <ssh-destination-or-command>" >&2
  echo "Example: $0 TcmpQmxBBMTWhy5KNJ5b3gMbM@sfo2.tmate.io" >&2
  echo "Example: $0 'ssh -i ./outputs/keys/123_id_ed25519 -p 43123 runner@runner-123-ssh.lolgames.net'" >&2
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
tar \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='workers.json' \
  -czf "$ARCHIVE_PATH" \
  -C "$ROOT_DIR" \
  workerAgents

ROUTER_ARCHIVE_PATH=""
if [[ "${ROUTER_UPLOAD:-0}" == "1" && -d "$ROUTER_DIR" ]]; then
  ROUTER_ARCHIVE_PATH="$TMP_DIR/9router.tgz"
  tar \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.next' \
    --exclude='.turbo' \
    --exclude='dist' \
    --exclude='build' \
    -czf "$ROUTER_ARCHIVE_PATH" \
    -C "$(dirname "$ROUTER_DIR")" \
    "$(basename "$ROUTER_DIR")"
fi

HERMES_ARCHIVE_PATH=""
if [[ "${HERMES_UPLOAD:-0}" == "1" && -d "$HERMES_WEBUI_DIR" ]]; then
  HERMES_ARCHIVE_PATH="$TMP_DIR/hermes-webui.tgz"
  tar \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='.venv' \
    --exclude='venv' \
    -czf "$HERMES_ARCHIVE_PATH" \
    -C "$(dirname "$HERMES_WEBUI_DIR")" \
    "$(basename "$HERMES_WEBUI_DIR")"
fi

REMOTE_SCRIPT="$TMP_DIR/refresh-worker-agents-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOF'
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

rm -rf "$APP_HOME"
mkdir -p "$APP_HOME"
tar -xzf /tmp/workerAgents.tgz -C "$HOME"
if [[ -f /tmp/9router.tgz ]]; then
  rm -rf "$ROUTER_HOME"
  tar -xzf /tmp/9router.tgz -C "$HOME"
elif [[ ! -f "$ROUTER_HOME/package.json" ]]; then
  rm -rf "$ROUTER_HOME"
  git clone --depth 1 "$ROUTER_GIT_URL" "$ROUTER_HOME"
fi
if [[ -f /tmp/hermes-webui.tgz ]]; then
  rm -rf "$HERMES_WEBUI_HOME"
  tar -xzf /tmp/hermes-webui.tgz -C "$HOME"
elif [[ ! -f "$HERMES_WEBUI_HOME/bootstrap.py" ]]; then
  rm -rf "$HERMES_WEBUI_HOME"
  git clone --depth 1 "$HERMES_WEBUI_GIT_URL" "$HERMES_WEBUI_HOME"
fi
cd "$APP_HOME"
npm install
npm install -g codexapp opencode-ai openclaw
if [[ -f "$ROUTER_HOME/package.json" ]]; then
  cd "$ROUTER_HOME"
  npm install
  if [[ ! -d .next ]]; then
    npm run build
  fi
fi
if [[ -f "$HERMES_WEBUI_HOME/bootstrap.py" && ! -x "$HOME/.local/bin/hermes" ]]; then
  timeout 180 python3 "$HERMES_WEBUI_HOME/bootstrap.py" --no-browser --foreground --host 127.0.0.1 18935 >/tmp/hermes-bootstrap.log 2>&1 || true
fi

TMUX='' tmux -L workeragents -f /dev/null kill-server 2>/dev/null || true
TMUX='' tmux -L workeragents -f /dev/null new-session -d -s workeragents "cd \"$APP_HOME\" && PORT=${APP_PORT:-1456} AGENT_CONSOLE_HOST=127.0.0.1 WORKER_AGENTS_9ROUTER_DIR=\"$HOME/9router\" WORKER_AGENTS_9ROUTER_PORT=20127 WORKER_AGENTS_9ROUTER_API_KEY=local-dev-key WORKER_AGENTS_9ROUTER_MODEL=openai/gpt-5.4-mini HERMES_WEBUI_DIR=\"$HOME/hermes-webui\" npm start > ~/worker-agents.log 2>&1"

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ "${REFRESH_START_AGENTS:-1}" == "1" ]]; then
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
curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" > "$STATUS_PATH"
WORKER_AGENTS_URL="$(start_tunnel worker-agents "${APP_PORT:-1456}" || true)"
ROUTER_URL="$(start_tunnel 9router 20127 || true)"
CODEX_PORT="$(python3 - "$STATUS_PATH" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for agent in data.get("agents", []):
    if agent.get("id") == "codex-web-local" and agent.get("state") == "running":
        print(agent.get("port", ""))
        break
PY
)"
OPENCODE_PORT="$(python3 - "$STATUS_PATH" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for agent in data.get("agents", []):
    if agent.get("id") == "opencode" and agent.get("state") == "running":
        print(agent.get("port", ""))
        break
PY
)"
HERMES_PORT="$(python3 - "$STATUS_PATH" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for agent in data.get("agents", []):
    if agent.get("id") == "hermes-webui" and agent.get("state") == "running":
        print(agent.get("port", ""))
        break
PY
)"
OPENCLAW_PORT="$(python3 - "$STATUS_PATH" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for agent in data.get("agents", []):
    if agent.get("id") == "openclaw" and agent.get("state") == "running":
        print(agent.get("port", ""))
        break
PY
)"

CODEX_URL=""
OPENCODE_URL=""
HERMES_URL=""
OPENCLAW_URL=""
if [[ -n "${CODEX_PORT:-}" ]]; then CODEX_URL="$(start_tunnel codex-web-local "$CODEX_PORT" || true)"; fi
if [[ -n "${OPENCODE_PORT:-}" ]]; then OPENCODE_URL="$(start_tunnel opencode "$OPENCODE_PORT" || true)"; fi
if [[ -n "${HERMES_PORT:-}" ]]; then HERMES_URL="$(start_tunnel hermes-webui "$HERMES_PORT" || true)"; fi
if [[ -n "${OPENCLAW_PORT:-}" ]]; then OPENCLAW_URL="$(start_tunnel openclaw "$OPENCLAW_PORT" || true)"; fi

python3 - "${WORKER_AGENTS_URL:-}" "${APP_PORT:-1456}" "${ROUTER_URL:-}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" "${OPENCLAW_URL:-}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

worker_agents_url = sys.argv[1]
port = int(sys.argv[2])
router_url = sys.argv[3]
codex_url = sys.argv[4]
opencode_url = sys.argv[5]
hermes_url = sys.argv[6]
openclaw_url = sys.argv[7]
state = {
    "status": "running" if worker_agents_url else "starting",
    "url": worker_agents_url,
    "worker_agents_url": worker_agents_url,
    "port": port,
    "router_url": router_url,
    "codex_web_url": codex_url,
    "opencode_url": opencode_url,
    "hermes_webui_url": hermes_url,
    "openclaw_url": openclaw_url,
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
echo "ROUTER_URL=${ROUTER_URL:-}"
echo "CODEX_URL=${CODEX_URL:-}"
echo "OPENCODE_URL=${OPENCODE_URL:-}"
echo "HERMES_URL=${HERMES_URL:-}"
echo "OPENCLAW_URL=${OPENCLAW_URL:-}"
EOF

RUN_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
python3 - "$SSH_TARGET" "$ARCHIVE_PATH" "$TUNNEL_CLIENT_PATH" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" "$APP_PORT" "$RUN_TOKEN" "$ROUTER_ARCHIVE_PATH" "$HERMES_ARCHIVE_PATH" <<'PY'
import base64
import os
import re
import shlex
import select
import signal
import subprocess
import sys
import time

ssh_target, archive_path, tunnel_client_path, script_path, out_path, app_port, run_token, router_archive_path, hermes_archive_path = sys.argv[1:]
ssh_cmd = ssh_target if ssh_target.strip().startswith("ssh ") else f"ssh {shlex.quote(ssh_target)}"
ssh_argv = shlex.split(ssh_cmd)
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
        (hermes_archive_path, "/tmp/hermes-webui.tgz.b64", "/tmp/hermes-webui.tgz"),
        (tunnel_client_path, "/tmp/lolgames_tunnel.py.b64", "/tmp/lolgames_tunnel.py"),
        (script_path, "/tmp/refresh-worker-agents-setup.sh.b64", "/tmp/refresh-worker-agents-setup.sh"),
    ]:
        if not local_path:
            continue
        encoded = base64.b64encode(open(local_path, "rb").read()).decode("ascii")
        lines = [f": > {remote_b64}"]
        for i in range(0, len(encoded), 900):
            lines.append(f"printf %s {shlex.quote(encoded[i:i+900])} >> {remote_b64}")
        lines.append(f"base64 -d {remote_b64} > {remote_out}")
        if remote_out.endswith(".sh"):
            lines.append(f"chmod +x {remote_out}")
        proc.stdin.write("\n".join(lines) + "\n")
        proc.stdin.flush()

    if router_archive_path:
        encoded = base64.b64encode(open(router_archive_path, "rb").read()).decode("ascii")
        lines = [": > /tmp/9router.tgz.b64"]
        for i in range(0, len(encoded), 900):
            lines.append(f"printf %s {shlex.quote(encoded[i:i+900])} >> /tmp/9router.tgz.b64")
        lines.append("base64 -d /tmp/9router.tgz.b64 > /tmp/9router.tgz")
        proc.stdin.write("\n".join(lines) + "\n")
        proc.stdin.flush()

    proc.stdin.write(f"RUN_TOKEN={run_token} APP_PORT={app_port} ROUTER_GIT_URL={shlex.quote(os.environ.get('ROUTER_GIT_URL', 'https://github.com/phaneron23/9router.git'))} HERMES_WEBUI_GIT_URL={shlex.quote(os.environ.get('HERMES_WEBUI_GIT_URL', 'https://github.com/nesquena/hermes-webui.git'))} bash /tmp/refresh-worker-agents-setup.sh\n")
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

SANITIZED_OUTPUT="$TMP_DIR/remote-output.clean.txt"
python3 - "$REMOTE_OUTPUT" "$SANITIZED_OUTPUT" <<'PY'
import re
import sys

src, dst = sys.argv[1:]
text = open(src, "r", encoding="utf-8", errors="ignore").read()
text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
text = text.replace("\r", "")
open(dst, "w", encoding="utf-8").write(text)
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
