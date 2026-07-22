#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-alexcheng-dev/agent-workspace}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
RUN_LIMIT="${RUN_LIMIT:-5}"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require gh
require python3
require unzip
require ./tests/lib/ssh_tmate_exec.py
find_remote_lolgames() {
  local ssh_cmd="$1"
  python3 - "$ROOT_DIR" "$ssh_cmd" <<'PY'
import json
import pathlib
import re
import shlex
import subprocess
import sys

root_dir = pathlib.Path(sys.argv[1])
ssh_cmd = sys.argv[2].strip()
helper = root_dir / "tests" / "lib" / "ssh_tmate_exec.py"
if not ssh_cmd:
    raise SystemExit(0)

remote_cmd = "cat ~/.worker-agents/state.json 2>/dev/null || cat ~/.codex/worker-state.json 2>/dev/null || true"
try:
    if "tmate.io" in ssh_cmd:
        ssh_dest = ssh_cmd.removeprefix("ssh ").strip()
        argv = [str(helper), ssh_dest, remote_cmd, "--timeout", "25"]
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=40,
            check=False,
        )
    else:
        argv = shlex.split(ssh_cmd) + [remote_cmd]
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=20,
            check=False,
        )
except Exception:
    print("__ERROR__ssh_helper_failed")
    raise SystemExit(0)

text = proc.stdout or ""
if "Failed to reach remote shell prompt" in text or "Internal error" in text:
    print("__ERROR__tmate_unavailable")
    raise SystemExit(0)
match = re.search(r'\{[^{}]*"worker_agents_url"[^{}]*\}', text, re.S)
if not match:
    match = re.search(r'\{.*?"worker_agents_url".*?\}', text, re.S)
if not match:
    print("__ERROR__remote_state_missing")
    raise SystemExit(0)

try:
    data = json.loads(match.group(0))
except Exception:
    raise SystemExit(0)

print((data.get("worker_agents_url") or data.get("url") or "").strip())
print((data.get("router_url") or "").strip())
print((data.get("codex_web_url") or "").strip())
print((data.get("opencode_url") or "").strip())
print((data.get("hermes_webui_url") or "").strip())
PY
}


RUN_IDS="$(gh run list \
  --repo "$REPO" \
  --workflow "$WORKFLOW" \
  --status in_progress \
  --limit "$RUN_LIMIT" \
  --json databaseId \
  --jq '.[].databaseId')"

if [[ -z "${RUN_IDS:-}" ]]; then
  echo "No in-progress $WORKFLOW runs found for $REPO."
  exit 0
fi
LOLGAMES_FIELDS="worker_agents router codex_web opencode hermes_webui"

while IFS= read -r RUN_ID; do
  [[ -n "$RUN_ID" ]] || continue

  STATUS_LINE="$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '[.display_title, .status, (.html_url // ""), (.created_at // "")] | @tsv')"
  TITLE="$(printf '%s\n' "$STATUS_LINE" | cut -f1)"
  STATUS="$(printf '%s\n' "$STATUS_LINE" | cut -f2)"
  RUN_URL="$(printf '%s\n' "$STATUS_LINE" | cut -f3)"
  CREATED_AT="$(printf '%s\n' "$STATUS_LINE" | cut -f4)"

  ARTIFACT_ID="$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[]? | select(.name=="ssh-link" and .expired==false) | .id' | head -n 1 || true)"

  SSH_CMD=""
  LOLGAMES_INFO=""
  if [[ -n "${ARTIFACT_ID:-}" ]]; then
    ZIP_PATH="$TMP_DIR/$RUN_ID.zip"
    OUT_DIR="$TMP_DIR/$RUN_ID"
    mkdir -p "$OUT_DIR"
    gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$ZIP_PATH"
    unzip -qo "$ZIP_PATH" -d "$OUT_DIR"
    SSH_CMD="$(sed -n '1p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"
    if [[ "$SSH_CMD" == *"-i ./id_ed25519"* ]]; then
      KEY_DIR="$ROOT_DIR/outputs/keys"
      mkdir -p "$KEY_DIR"
      KEY_PATH="$KEY_DIR/${RUN_ID}_id_ed25519"
      if [[ -f "$OUT_DIR/id_ed25519" ]]; then
        cp "$OUT_DIR/id_ed25519" "$KEY_PATH"
        chmod 600 "$KEY_PATH"
      fi
      if [[ -f "$KEY_PATH" ]]; then
        SSH_CMD="$(python3 - "$SSH_CMD" "$KEY_PATH" <<'PY'
import sys
print(sys.argv[1].replace("-i ./id_ed25519", f"-i {sys.argv[2]}"))
PY
)"
      fi
    fi
    LOLGAMES_INFO="$(find_remote_lolgames "$SSH_CMD")"
  fi

  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'created_at\t%s\n' "${CREATED_AT:-<unknown>}"
  printf 'title\t%s\n' "$TITLE"
  printf 'status\t%s\n' "$STATUS"
  printf 'run_url\t%s\n' "$RUN_URL"
  printf 'ssh\t%s\n' "${SSH_CMD:-<artifact not ready>}"
  if [[ -n "${LOLGAMES_INFO:-}" ]]; then
    first_line="$(printf '%s\n' "$LOLGAMES_INFO" | sed -n '1p')"
    if [[ "$first_line" == __ERROR__* ]]; then
      printf 'lolgames_state\t%s\n' "${first_line#__ERROR__}"
    else
      i=0
      for field in $LOLGAMES_FIELDS; do
        i=$((i + 1))
        val="$(printf '%s\n' "$LOLGAMES_INFO" | sed -n "${i}p")"
        printf 'lolgames_%s\t%s\n' "$field" "${val:-<no tunnel>}"
      done
    fi
  fi
  printf '\n'
done <<< "$RUN_IDS"
