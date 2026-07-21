#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-alexcheng-dev/ssh-runner}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
APP_DIR="$ROOT_DIR/workerAgents"
ROUTER_DIR="${ROUTER_DIR:-/Users/igor/Git-projects/9router}"
HERMES_WEBUI_DIR="${HERMES_WEBUI_DIR:-/Users/igor/Git-projects/hermes-webui}"
APP_PORT="${APP_PORT:-1456}"
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

if [[ ! -d "$ROUTER_DIR" ]]; then
  echo "Missing 9router directory: $ROUTER_DIR" >&2
  exit 1
fi

if [[ ! -d "$HERMES_WEBUI_DIR" ]]; then
  echo "Missing Hermes WebUI directory: $HERMES_WEBUI_DIR" >&2
  exit 1
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

SSH_DEST="$(printf '%s\n' "$SSH_CMD" | awk '{print $2}')"
if [[ -z "$SSH_DEST" ]]; then
  echo "Failed to parse SSH destination from: $SSH_CMD" >&2
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

ROUTER_ARCHIVE_PATH="$TMP_DIR/9router.tgz"
tar \
  --exclude='.git' \
  --exclude='node_modules' \
  -czf "$ROUTER_ARCHIVE_PATH" \
  -C "$(dirname "$ROUTER_DIR")" \
  "$(basename "$ROUTER_DIR")"

HERMES_ARCHIVE_PATH="$TMP_DIR/hermes-webui.tgz"
tar \
  --exclude='.git' \
  --exclude='node_modules' \
  --exclude='.venv' \
  --exclude='venv' \
  -czf "$HERMES_ARCHIVE_PATH" \
  -C "$(dirname "$HERMES_WEBUI_DIR")" \
  "$(basename "$HERMES_WEBUI_DIR")"

REMOTE_SCRIPT="$TMP_DIR/remote-worker-agents-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOF'
set -euo pipefail
APP_HOME="$HOME/workerAgents"
ROUTER_HOME="$HOME/9router"
HERMES_WEBUI_HOME="$HOME/hermes-webui"
STATE_DIR="$HOME/.worker-agents"
mkdir -p "$STATE_DIR" "$HOME/node-http2"

start_tunnel() {
  local name="$1"
  local port="$2"
  local log_path="$HOME/${name}-cloudflared.log"
  pkill -f "cloudflared tunnel --url http://127.0.0.1:${port}" 2>/dev/null || true
  nohup ~/node-http2/cloudflared tunnel --url "http://127.0.0.1:${port}" > "$log_path" 2>&1 &
  for _ in $(seq 1 90); do
    local url
    url="$(sed -n 's/.*\(https:\/\/[-a-zA-Z0-9.]*trycloudflare\.com\).*/\1/p' "$log_path" | tail -n 1 || true)"
    if [[ -n "${url:-}" ]]; then
      printf '%s\n' "$url"
      return 0
    fi
    sleep 2
  done
  return 1
}

rm -rf "$APP_HOME"
mkdir -p "$APP_HOME"
tar -xzf /tmp/workerAgents.tgz -C "$HOME"
rm -rf "$ROUTER_HOME"
mkdir -p "$ROUTER_HOME"
tar -xzf /tmp/9router.tgz -C "$HOME"
rm -rf "$HERMES_WEBUI_HOME"
mkdir -p "$HERMES_WEBUI_HOME"
tar -xzf /tmp/hermes-webui.tgz -C "$HOME"

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

if [[ ! -x ~/node-http2/cloudflared ]]; then
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o ~/node-http2/cloudflared
  chmod +x ~/node-http2/cloudflared
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

CODEX_URL=""
OPENCODE_URL=""
HERMES_URL=""
if [[ -n "${CODEX_PORT:-}" ]]; then CODEX_URL="$(start_tunnel codex-web-local "$CODEX_PORT" || true)"; fi
if [[ -n "${OPENCODE_PORT:-}" ]]; then OPENCODE_URL="$(start_tunnel opencode "$OPENCODE_PORT" || true)"; fi
if [[ -n "${HERMES_PORT:-}" ]]; then HERMES_URL="$(start_tunnel hermes-webui "$HERMES_PORT" || true)"; fi

python3 - "${WORKER_AGENTS_URL:-}" "${APP_PORT:-1456}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

worker_agents_url = sys.argv[1]
port = int(sys.argv[2])
codex_url = sys.argv[3]
opencode_url = sys.argv[4]
hermes_url = sys.argv[5]
state = {
    "status": "running" if worker_agents_url else "starting",
    "url": worker_agents_url,
    "port": port,
    "codex_web_url": codex_url,
    "opencode_url": opencode_url,
    "hermes_webui_url": hermes_url,
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
state_dir = os.path.expanduser("~/.worker-agents")
os.makedirs(state_dir, exist_ok=True)
with open(os.path.join(state_dir, "state.json"), "w", encoding="utf-8") as f:
    json.dump(state, f)
    f.write("\n")
PY

echo "__WORKER_AGENTS_DONE__"
echo "PUBLIC_URL=${WORKER_AGENTS_URL:-}"
echo "CODEX_URL=${CODEX_URL:-}"
echo "OPENCODE_URL=${OPENCODE_URL:-}"
echo "HERMES_URL=${HERMES_URL:-}"
EOF

REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
python3 - "$SSH_DEST" "$ARCHIVE_PATH" "$ROUTER_ARCHIVE_PATH" "$HERMES_ARCHIVE_PATH" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" "$APP_PORT" <<'PY'
import base64
import re
import subprocess
import sys
import time

ssh_dest, archive_path, router_archive_path, hermes_archive_path, script_path, out_path, app_port = sys.argv[1:]
proc = subprocess.Popen(
    [
        "ssh",
        "-tt",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        ssh_dest,
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    bufsize=1,
)

prompt_re = re.compile(r"runner@[^:]+:.*\$ ")
buffer = ""
started = False
with open(out_path, "w", encoding="utf-8") as outf:
    deadline = time.time() + 60
    while time.time() < deadline:
        ch = proc.stdout.read(1)
        if not ch:
            break
        buffer += ch
        outf.write(ch)
        outf.flush()
        if not started and "Press <q> or <ctrl-c> to continue" in buffer:
            proc.stdin.write("q")
            proc.stdin.flush()
        if prompt_re.search(buffer):
            started = True
            break
    if not started:
        raise SystemExit("Failed to reach remote shell prompt")

    for local_path, remote_b64, remote_out in [
        (archive_path, "/tmp/workerAgents.tgz.b64", "/tmp/workerAgents.tgz"),
        (router_archive_path, "/tmp/9router.tgz.b64", "/tmp/9router.tgz"),
        (hermes_archive_path, "/tmp/hermes-webui.tgz.b64", "/tmp/hermes-webui.tgz"),
        (script_path, "/tmp/worker-agents-setup.sh.b64", "/tmp/worker-agents-setup.sh"),
    ]:
        encoded = base64.b64encode(open(local_path, "rb").read()).decode("ascii")
        lines = [f": > {remote_b64}"]
        for i in range(0, len(encoded), 900):
            lines.append(f"printf '%s' '{encoded[i:i+900]}' >> {remote_b64}")
        lines.append(f"base64 -d {remote_b64} > {remote_out}")
        if remote_out.endswith(".sh"):
            lines.append(f"chmod +x {remote_out}")
        proc.stdin.write("\n".join(lines) + "\n")
        proc.stdin.flush()

    proc.stdin.write(f"APP_PORT={app_port} bash /tmp/worker-agents-setup.sh\n")
    proc.stdin.flush()

    deadline = time.time() + 420
    while time.time() < deadline:
        ch = proc.stdout.read(1)
        if not ch:
            break
        buffer += ch
        outf.write(ch)
        outf.flush()
        if "__WORKER_AGENTS_DONE__" in buffer and "trycloudflare.com" in buffer:
            break

    proc.kill()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass
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

PUBLIC_URL="$(grep -aoE 'PUBLIC_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^PUBLIC_URL=//' | tail -n 1 || true)"
CODEX_URL="$(grep -aoE 'CODEX_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^CODEX_URL=//' | tail -n 1 || true)"
OPENCODE_URL="$(grep -aoE 'OPENCODE_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^OPENCODE_URL=//' | tail -n 1 || true)"
HERMES_URL="$(grep -aoE 'HERMES_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^HERMES_URL=//' | tail -n 1 || true)"

echo
echo "Worker SSH:"
echo "$SSH_CMD"
echo
echo "workerAgents public URL:"
echo "${PUBLIC_URL:-<missing>}"
echo "codex_web public URL:"
echo "${CODEX_URL:-<missing>}"
echo "opencode public URL:"
echo "${OPENCODE_URL:-<missing>}"
echo "hermes_webui public URL:"
echo "${HERMES_URL:-<missing>}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
python3 - "$ROOT_DIR/outputs/$TIMESTAMP-worker-agents.json" "$SSH_CMD" "${PUBLIC_URL:-}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" <<'PY'
import json
import sys
from datetime import datetime, timezone

out_path, ssh_cmd, public_url, codex_url, opencode_url, hermes_url = sys.argv[1:]
payload = {
    "created_at": datetime.now(timezone.utc).isoformat(),
    "ssh": ssh_cmd,
    "worker_agents_url": public_url,
    "codex_web_url": codex_url,
    "opencode_url": opencode_url,
    "hermes_webui_url": hermes_url,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

if [[ -z "${PUBLIC_URL:-}" ]]; then
  echo
  echo "Warning: workerAgents Cloudflare URL not found yet. Re-check on the worker:" >&2
  echo "  tail -60 ~/worker-agents-cloudflared.log" >&2
  exit 1
fi

LAUNCH_OK=1
