#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <ssh-destination>" >&2
  echo "Example: $0 qGgPa7rgUTj3nP3b3TkLwJuxR@sfo2.tmate.io" >&2
  exit 1
fi

SSH_DEST="$1"

python3 - "$SSH_DEST" <<'PY'
import re
import subprocess
import sys

ssh_dest = sys.argv[1]
cmd = (
    "q\n"
    "python3 - <<'__PY__'\n"
    "import json, os\n"
    "state_path = os.path.expanduser('~/.codex/worker-state.json')\n"
    "if os.path.exists(state_path):\n"
    "    print(open(state_path, 'r', encoding='utf-8').read())\n"
    "else:\n"
    "    print('{\"status\":\"unknown\",\"codex_url\":\"\",\"password\":\"\"}')\n"
    "__PY__\n"
    "exit\n"
)

try:
    proc = subprocess.run(
        [
            "ssh", "-tt",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=8",
            ssh_dest,
        ],
        input=cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=12,
        check=False,
    )
    output = proc.stdout
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode("utf-8", errors="ignore")

clean = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", output).replace("\r", "")
match = re.search(r'(\{\s*"status".*\})', clean, re.S)
if match:
    print(match.group(1))
PY
