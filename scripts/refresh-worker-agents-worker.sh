#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/workerAgents"
APP_PORT="${APP_PORT:-1456}"
SSH_DEST="${1:-}"
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

if [[ -z "$SSH_DEST" ]]; then
  echo "Usage: $0 <ssh-destination>" >&2
  echo "Example: $0 TcmpQmxBBMTWhy5KNJ5b3gMbM@sfo2.tmate.io" >&2
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app directory: $APP_DIR" >&2
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

REMOTE_SCRIPT="$TMP_DIR/refresh-worker-agents-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOF'
set -euo pipefail
APP_HOME="$HOME/workerAgents"
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

if [[ ! -x ~/node-http2/cloudflared ]]; then
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o ~/node-http2/cloudflared
  chmod +x ~/node-http2/cloudflared
fi

rm -rf "$APP_HOME"
mkdir -p "$APP_HOME"
tar -xzf /tmp/workerAgents.tgz -C "$HOME"
cd "$APP_HOME"
npm install

TMUX='' tmux -L workeragents -f /dev/null kill-server 2>/dev/null || true
TMUX='' tmux -L workeragents -f /dev/null new-session -d -s workeragents "cd \"$APP_HOME\" && PORT=${APP_PORT:-1456} AGENT_CONSOLE_HOST=127.0.0.1 WORKER_AGENTS_9ROUTER_DIR=\"$HOME/9router\" WORKER_AGENTS_9ROUTER_PORT=20127 WORKER_AGENTS_9ROUTER_API_KEY=local-dev-key WORKER_AGENTS_9ROUTER_MODEL=openai/gpt-5.4-mini HERMES_WEBUI_DIR=\"$HOME/hermes-webui\" npm start > ~/worker-agents.log 2>&1"

for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${APP_PORT:-1456}/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

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

CODEX_URL=""
OPENCODE_URL=""
HERMES_URL=""
if [[ -n "${CODEX_PORT:-}" ]]; then CODEX_URL="$(start_tunnel codex-web-local "$CODEX_PORT" || true)"; fi
if [[ -n "${OPENCODE_PORT:-}" ]]; then OPENCODE_URL="$(start_tunnel opencode "$OPENCODE_PORT" || true)"; fi
if [[ -n "${HERMES_PORT:-}" ]]; then HERMES_URL="$(start_tunnel hermes-webui "$HERMES_PORT" || true)"; fi

python3 - "${WORKER_AGENTS_URL:-}" "${APP_PORT:-1456}" "${ROUTER_URL:-}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" <<'PY'
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
state = {
    "status": "running" if worker_agents_url else "starting",
    "url": worker_agents_url,
    "worker_agents_url": worker_agents_url,
    "port": port,
    "router_url": router_url,
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
echo "ROUTER_URL=${ROUTER_URL:-}"
echo "CODEX_URL=${CODEX_URL:-}"
echo "OPENCODE_URL=${OPENCODE_URL:-}"
echo "HERMES_URL=${HERMES_URL:-}"
EOF

REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
python3 - "$SSH_DEST" "$ARCHIVE_PATH" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" "$APP_PORT" <<'PY'
import base64
import re
import subprocess
import sys
import time

ssh_dest, archive_path, script_path, out_path, app_port = sys.argv[1:]
proc = subprocess.Popen(
    [
        "ssh", "-tt",
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
        (script_path, "/tmp/refresh-worker-agents-setup.sh.b64", "/tmp/refresh-worker-agents-setup.sh"),
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

    proc.stdin.write(f"APP_PORT={app_port} bash /tmp/refresh-worker-agents-setup.sh\n")
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
PUBLIC_URL="$(grep -aoE 'PUBLIC_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^PUBLIC_URL=//' | tail -n 1 || true)"
ROUTER_URL="$(grep -aoE 'ROUTER_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^ROUTER_URL=//' | tail -n 1 || true)"
CODEX_URL="$(grep -aoE 'CODEX_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^CODEX_URL=//' | tail -n 1 || true)"
OPENCODE_URL="$(grep -aoE 'OPENCODE_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^OPENCODE_URL=//' | tail -n 1 || true)"
HERMES_URL="$(grep -aoE 'HERMES_URL=https://[-a-zA-Z0-9.]+trycloudflare.com' "$SANITIZED_OUTPUT" | sed 's/^HERMES_URL=//' | tail -n 1 || true)"

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

python3 - "$ROOT_DIR/outputs/$TIMESTAMP-worker-refresh.json" "$SSH_DEST" "${PUBLIC_URL:-}" "${ROUTER_URL:-}" "${CODEX_URL:-}" "${OPENCODE_URL:-}" "${HERMES_URL:-}" <<'PY'
import json
import sys
from datetime import datetime, timezone

out_path, ssh_dest, public_url, router_url, codex_url, opencode_url, hermes_url = sys.argv[1:]
payload = {
    "created_at": datetime.now(timezone.utc).isoformat(),
    "ssh": ssh_dest,
    "worker_agents_url": public_url,
    "router_url": router_url,
    "codex_web_url": codex_url,
    "opencode_url": opencode_url,
    "hermes_webui_url": hermes_url,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

if [[ -z "${PUBLIC_URL:-}" ]]; then
  echo "Warning: workerAgents Cloudflare URL not found yet." >&2
  exit 1
fi
