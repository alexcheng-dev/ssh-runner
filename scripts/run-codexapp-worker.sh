#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-alexcheng-dev/ssh-runner}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

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

echo "Triggering worker..."
./scripts/ssh-runner-link.sh "$REPO" "$WORKFLOW" > "$TMP_DIR/ssh-link.txt"
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

if [[ ! -x ~/node-http2/cloudflared ]]; then
  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o ~/node-http2/cloudflared
  chmod +x ~/node-http2/cloudflared
fi

pkill -f 'cloudflared tunnel --url http://127.0.0.1:5900' 2>/dev/null || true
nohup ~/node-http2/cloudflared tunnel --url http://127.0.0.1:5900 > ~/codexapp-cloudflared.log 2>&1 &

for _ in $(seq 1 60); do
  URL="$(sed -n 's/.*\(https:\/\/[-a-zA-Z0-9.]*trycloudflare\.com\).*/\1/p' ~/codexapp-cloudflared.log | tail -n 1 || true)"
  if [[ -n "${URL:-}" ]]; then
    break
  fi
  sleep 2
done

echo "__CODEX_DONE__"
echo "PASSWORD=$(sed -n '1p' ~/.codex/codexui-password 2>/dev/null || true)"
echo "PUBLIC_URL=${URL:-}"
EOF

echo "Connecting to worker and provisioning codexapp..."
REMOTE_OUTPUT="$TMP_DIR/remote-output.txt"
python3 - "$SSH_DEST" "$REMOTE_SCRIPT" "$REMOTE_OUTPUT" <<'PY'
import re
import subprocess
import sys
import time

ssh_dest, script_path, out_path = sys.argv[1:]
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

    with open(script_path, "r", encoding="utf-8") as f:
        payload = f.read()
    cmd = "bash <<'__CODEX_REMOTE__'\n" + payload + "\n__CODEX_REMOTE__\n"
    proc.stdin.write(cmd)
    proc.stdin.flush()

    done_deadline = time.time() + 360
    while time.time() < done_deadline:
        ch = proc.stdout.read(1)
        if not ch:
            break
        buffer += ch
        outf.write(ch)
        outf.flush()
        if "__CODEX_DONE__" in buffer and "PUBLIC_URL=" in buffer:
            break

    proc.stdin.write("exit\n")
    proc.stdin.flush()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
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

PASSWORD="$(awk '/^PASSWORD=/{sub(/^PASSWORD=/,""); print}' "$SANITIZED_OUTPUT" | tail -n 1)"
PUBLIC_URL="$(awk '/^PUBLIC_URL=/{sub(/^PUBLIC_URL=/,""); print}' "$SANITIZED_OUTPUT" | tail -n 1)"

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

if [[ -z "${PUBLIC_URL:-}" ]]; then
  echo
  echo "Warning: cloudflared URL not found yet. Re-check on the worker:" >&2
  echo "  tail -60 ~/codexapp-cloudflared.log" >&2
  exit 1
fi
