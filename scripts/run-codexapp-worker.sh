#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-alexcheng-dev/ssh-runner}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
TUNNEL_CLIENT_PATH="$ROOT_DIR/scripts/lolgames_tunnel.py"
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
require python3

cd "$ROOT_DIR"
if [[ ! -f "$TUNNEL_CLIENT_PATH" ]]; then
  echo "Missing lolgames tunnel client: $TUNNEL_CLIENT_PATH" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/outputs"

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

REMOTE_SCRIPT="$TMP_DIR/remote-setup.sh"
cat > "$REMOTE_SCRIPT" <<'EOF'
set -euo pipefail
mkdir -p ~/codexapp-run ~/node-http2
mkdir -p ~/.codex
if ! command -v tmux >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -yqq tmux
fi
TMUX='' tmux -L codexapp -f /dev/null kill-server 2>/dev/null || true
TMUX='' tmux -L codexapp -f /dev/null new-session -d -s codexapp 'npx codexapp > ~/codexapp-tmux.log 2>&1'

for _ in $(seq 1 60); do
  if [ -f ~/.codex/codexui-password ]; then
    break
  fi
  sleep 2
done

TUNNEL_PREFIX="${LOLGAMES_TUNNEL_PREFIX:-$(hostname | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')-$(date +%s)}"
PUBLIC_NAME="${TUNNEL_PREFIX}-codexapp"
pkill -f "lolgames_tunnel.py client 127.0.0.1:5900 --server 161.153.109.33 --name ${PUBLIC_NAME} --same-port" 2>/dev/null || true
nohup python3 /tmp/lolgames_tunnel.py client 127.0.0.1:5900 --server 161.153.109.33 --name "$PUBLIC_NAME" --same-port > ~/codexapp-lolgames.log 2>&1 &

URL="http://${PUBLIC_NAME}.lolgames.net:5900"

printf '%s\n' "${URL:-}" > ~/.codex/codexui-public-url
python3 - "${URL:-}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

url = sys.argv[1]
password_path = os.path.expanduser("~/.codex/codexui-password")
password = open(password_path, "r", encoding="utf-8").readline().strip() if os.path.exists(password_path) else ""
state = {
    "status": "running" if password and url else "starting",
    "codex_url": url,
    "password": password,
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
with open(os.path.expanduser("~/.codex/worker-state.json"), "w", encoding="utf-8") as f:
    json.dump(state, f)
    f.write("\n")
PY

echo "__CODEX_DONE__${RUN_TOKEN:-}"
echo "PASSWORD=$(sed -n '1p' ~/.codex/codexui-password 2>/dev/null || true)"
echo "PUBLIC_URL=${URL:-}"
EOF

echo "Connecting to worker and provisioning codexapp..."
RUN_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
python3 - "$SSH_DEST" "$REMOTE_SCRIPT" "$TUNNEL_CLIENT_PATH" "$REMOTE_OUTPUT" "$RUN_TOKEN" <<'PY'
import os
import re
import shlex
import select
import signal
import subprocess
import sys
import time

ssh_dest, script_path, tunnel_client_path, out_path, run_token = sys.argv[1:]
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

    import base64
    lines = []
    for local_path, remote_b64, remote_out in [
        (tunnel_client_path, "/tmp/lolgames_tunnel.py.b64", "/tmp/lolgames_tunnel.py"),
        (script_path, "/tmp/codexapp-remote-setup.b64", "/tmp/codexapp-remote-setup.sh"),
    ]:
        encoded = base64.b64encode(open(local_path, "rb").read()).decode("ascii")
        lines.append(f": > {remote_b64}")
        for i in range(0, len(encoded), 900):
            lines.append(f"printf %s {shlex.quote(encoded[i:i+900])} >> {remote_b64}")
        lines.append(f"base64 -d {remote_b64} > {remote_out}")
    lines.append(f"RUN_TOKEN={run_token} bash /tmp/codexapp-remote-setup.sh")
    cmd = "\n".join(lines) + "\n"
    proc.stdin.write(cmd)
    proc.stdin.flush()

    done_deadline = time.time() + 360
    while time.time() < done_deadline:
        ch = read_chunk()
        if not ch:
            if proc.poll() is not None:
                break
            continue
        buffer += ch
        outf.write(ch)
        outf.flush()
        if f"__CODEX_DONE__{run_token}" in buffer and ".lolgames.net" in buffer:
            break

    # Do not send `exit`: in a tmate-backed runner, exiting the shell can tear down
    # the share session and make the freshly printed SSH/Web links unusable. Close
    # only this local SSH client after the detached tmux/lolgames tunnel processes start.
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

PASSWORD="$(grep -aoE 'PASSWORD=[a-z0-9]+-[a-z0-9]+-[a-z0-9]+' "$SANITIZED_OUTPUT" | sed 's/^PASSWORD=//' | tail -n 1 || true)"
PUBLIC_URL="$(grep -aoE 'PUBLIC_URL=http://[-a-zA-Z0-9.]+\.lolgames\.net(:[0-9]+)?' "$SANITIZED_OUTPUT" | sed 's/^PUBLIC_URL=//' | tail -n 1 || true)"

if [[ -z "${PUBLIC_URL:-}" || -z "${PASSWORD:-}" ]]; then
  STATE_FALLBACK="$TMP_DIR/remote-state-fallback.txt"
  python3 "$ROOT_DIR/tests/lib/ssh_tmate_exec.py" "$SSH_DEST" 'cat ~/.codex/worker-state.json 2>/dev/null || true' --timeout 30 > "$STATE_FALLBACK" 2>/dev/null || true
  python3 - "$STATE_FALLBACK" "$TMP_DIR/state.env" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding='utf-8', errors='ignore').read()
text = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text).replace('\r', '')
match = re.search(r'\{[^{}]*"codex_url"[^{}]*\}', text, re.S)
data = json.loads(match.group(0)) if match else {}
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    f.write(f'PUBLIC_URL={str(data.get("codex_url") or "")}\n')
    f.write(f'PASSWORD={str(data.get("password") or "")}\n')
PY
  # shellcheck disable=SC1090
  source "$TMP_DIR/state.env" 2>/dev/null || true
fi

echo
echo "Worker SSH:"
echo "$SSH_CMD"
echo "Worker web shell:"
echo "$WEB_URL"
echo
echo "codexapp password:"
echo "${PASSWORD:-<missing>}"
echo
echo "codexapp public URL:"
echo "${PUBLIC_URL:-<missing>}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
python3 - "$ROOT_DIR/outputs/$TIMESTAMP-worker.json" "$SSH_CMD" "$WEB_URL" "${PASSWORD:-}" "${PUBLIC_URL:-}" <<'PY'
import json
import sys
from datetime import datetime, timezone

out_path, ssh_cmd, web_url, password, public_url = sys.argv[1:]
payload = {
    "created_at": datetime.now(timezone.utc).isoformat(),
    "ssh": ssh_cmd,
    "web": web_url,
    "codex_password": password,
    "codex_url": public_url,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

if [[ -z "${PUBLIC_URL:-}" ]]; then
  echo
  echo "Warning: lolgames URL not found yet. Re-check on the worker:" >&2
  echo "  tail -60 ~/codexapp-lolgames.log" >&2
  exit 1
fi

LAUNCH_OK=1
