#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-alexcheng-dev/ssh-runner}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
RUN_LIMIT="${RUN_LIMIT:-20}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
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
require python3
require unzip
require ssh

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

while IFS= read -r RUN_ID; do
  [[ -n "$RUN_ID" ]] || continue

  STATUS_LINE="$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '[.display_title, .status, (.html_url // "")] | @tsv')"
  TITLE="$(printf '%s\n' "$STATUS_LINE" | cut -f1)"
  STATUS="$(printf '%s\n' "$STATUS_LINE" | cut -f2)"
  RUN_URL="$(printf '%s\n' "$STATUS_LINE" | cut -f3)"

  ARTIFACT_ID="$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[]? | select(.name=="ssh-link" and .expired==false) | .id' | head -n 1 || true)"

  SSH_CMD=""
  WEB_URL=""
  CODEX_WEB_URL=""
  CODEX_PASSWORD=""
  if [[ -n "${ARTIFACT_ID:-}" ]]; then
    ZIP_PATH="$TMP_DIR/$RUN_ID.zip"
    OUT_DIR="$TMP_DIR/$RUN_ID"
    mkdir -p "$OUT_DIR"
    gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$ZIP_PATH"
    unzip -qo "$ZIP_PATH" -d "$OUT_DIR"
    SSH_CMD="$(sed -n '1p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"
    WEB_URL="$(sed -n '2p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"

    SSH_DEST="$(printf '%s\n' "$SSH_CMD" | awk '{print $2}' 2>/dev/null || true)"
    if [[ -n "${SSH_DEST:-}" ]]; then
      REMOTE_INFO="$(
        python3 - "$SSH_DEST" "$PROBE_TIMEOUT" <<'PY'
import re
import subprocess
import sys

ssh_dest = sys.argv[1]
cmd = (
    "q"
    "CODEX_URL=$(sed -n '1p' ~/.codex/codexui-public-url 2>/dev/null || true); "
    "if [ -z \"$CODEX_URL\" ]; then CODEX_URL=$(sed -n 's/.*\\(https://[-a-zA-Z0-9.]*trycloudflare\\.com\\).*/\\1/p' ~/codexapp-cloudflared.log 2>/dev/null | tail -n 1 || true); fi; "
    "CODEX_PASSWORD=$(sed -n '1p' ~/.codex/codexui-password 2>/dev/null || true); "
    "printf 'codex_url\\t%s\\ncodex_password\\t%s\\n' \"$CODEX_URL\" \"$CODEX_PASSWORD\"\n"
    "exit\n"
)
try:
    proc = subprocess.run(
        [
            "ssh",
            "-tt",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=8",
            ssh_dest,
        ],
        input=cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=int(sys.argv[2]),
        check=False,
    )
    output = proc.stdout
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode("utf-8", errors="ignore")

clean = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", output).replace("\r", "")
print(clean)
PY
      )"
      CODEX_WEB_URL="$(printf '%s\n' "$REMOTE_INFO" | awk -F '\t' '$1=="codex_url"{print $2}' | tail -n 1)"
      CODEX_PASSWORD="$(printf '%s\n' "$REMOTE_INFO" | awk -F '\t' '$1=="codex_password"{print $2}' | tail -n 1)"
    fi
  fi

  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'title\t%s\n' "$TITLE"
  printf 'status\t%s\n' "$STATUS"
  printf 'run_url\t%s\n' "$RUN_URL"
  printf 'ssh\t%s\n' "${SSH_CMD:-<artifact not ready>}"
  printf 'web\t%s\n' "${WEB_URL:-<artifact not ready>}"
  printf 'codex_web\t%s\n' "${CODEX_WEB_URL:-<not running>}"
  printf 'codex_password\t%s\n' "${CODEX_PASSWORD:-<not running>}"
  printf '\n'
done <<< "$RUN_IDS"
