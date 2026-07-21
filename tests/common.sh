#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

latest_worker_ssh() {
  python3 - "$ROOT_DIR/outputs" <<'PY'
import json
import pathlib
import sys

outputs = pathlib.Path(sys.argv[1])
for path in sorted(outputs.glob("*-worker-agents.json"), reverse=True):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    ssh_cmd = str(data.get("ssh") or "").strip()
    if ssh_cmd.startswith("ssh "):
        print(ssh_cmd.split(None, 1)[1])
        break
PY
}

require_ssh_dest() {
  local value="${1:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  value="$(latest_worker_ssh)"
  if [[ -z "$value" ]]; then
    echo "Could not resolve worker SSH destination. Pass one explicitly." >&2
    return 1
  fi
  printf '%s\n' "$value"
}

run_remote() {
  local ssh_dest="$1"
  local command="$2"
  python3 "$ROOT_DIR/tests/lib/ssh_tmate_exec.py" "$ssh_dest" "$command"
}
