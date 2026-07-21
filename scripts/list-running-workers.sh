#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-alexcheng-dev/ssh-runner}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
RUN_LIMIT="${RUN_LIMIT:-5}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUTS_DIR="$ROOT_DIR/outputs"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require gh
require python3
require unzip
find_local_output() {
  local ssh_cmd="$1"
  local web_url="$2"
  [[ -d "$OUTPUTS_DIR" ]] || return 0
  python3 - "$OUTPUTS_DIR" "$ssh_cmd" "$web_url" <<'PY'
import json
import pathlib
import sys

outputs_dir = pathlib.Path(sys.argv[1])
ssh_cmd = sys.argv[2]
web_url = sys.argv[3]

matches = []
for path in sorted(outputs_dir.glob("*-worker.json"), reverse=True):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    if data.get("ssh") == ssh_cmd or data.get("web") == web_url:
        matches.append(data)
        break

if matches:
    data = matches[0]
    print((data.get("codex_url") or "").strip())
    print((data.get("codex_password") or "").strip())
PY
}
find_local_lolgames() {
  local ssh_cmd="$1"
  local web_url="$2"
  [[ -d "$OUTPUTS_DIR" ]] || return 0
  python3 - "$OUTPUTS_DIR" "$ssh_cmd" "$web_url" <<'PY'
import json
import pathlib
import sys

outputs_dir = pathlib.Path(sys.argv[1])
ssh_cmd = sys.argv[2]
web_url = sys.argv[3]
ssh_raw = ssh_cmd.removeprefix("ssh ").strip()

for path in sorted(outputs_dir.glob("*-worker-refresh.json"), reverse=True):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    if data.get("ssh") in (ssh_cmd, ssh_raw) or data.get("worker_agents_url", "").startswith("http://") and web_url and web_url in data.get("worker_agents_url", ""):
        print((data.get("worker_agents_url") or "").strip())
        print((data.get("router_url") or "").strip())
        print((data.get("codex_web_url") or "").strip())
        print((data.get("opencode_url") or "").strip())
        print((data.get("hermes_webui_url") or "").strip())
        break
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

  STATUS_LINE="$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '[.display_title, .status, (.html_url // "")] | @tsv')"
  TITLE="$(printf '%s\n' "$STATUS_LINE" | cut -f1)"
  STATUS="$(printf '%s\n' "$STATUS_LINE" | cut -f2)"
  RUN_URL="$(printf '%s\n' "$STATUS_LINE" | cut -f3)"

  ARTIFACT_ID="$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[]? | select(.name=="ssh-link" and .expired==false) | .id' | head -n 1 || true)"

  SSH_CMD=""
  WEB_URL=""
  CODEX_WEB_URL=""
  CODEX_PASSWORD=""
  LOLGAMES_INFO=""
  if [[ -n "${ARTIFACT_ID:-}" ]]; then
    ZIP_PATH="$TMP_DIR/$RUN_ID.zip"
    OUT_DIR="$TMP_DIR/$RUN_ID"
    mkdir -p "$OUT_DIR"
    gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$ZIP_PATH"
    unzip -qo "$ZIP_PATH" -d "$OUT_DIR"
    SSH_CMD="$(sed -n '1p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"
    WEB_URL="$(sed -n '2p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"

    LOCAL_INFO="$(find_local_output "$SSH_CMD" "$WEB_URL")"
    CODEX_WEB_URL="$(printf '%s\n' "$LOCAL_INFO" | sed -n '1p')"
    CODEX_PASSWORD="$(printf '%s\n' "$LOCAL_INFO" | sed -n '2p')"
    LOLGAMES_INFO="$(find_local_lolgames "$SSH_CMD" "$WEB_URL")"
  fi

  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'title\t%s\n' "$TITLE"
  printf 'status\t%s\n' "$STATUS"
  printf 'run_url\t%s\n' "$RUN_URL"
  printf 'ssh\t%s\n' "${SSH_CMD:-<artifact not ready>}"
  printf 'codex_web\t%s\n' "${CODEX_WEB_URL:-<not running>}"
  printf 'codex_password\t%s\n' "${CODEX_PASSWORD:-<not running>}"
  if [[ -n "${LOLGAMES_INFO:-}" ]]; then
    i=0
    for field in $LOLGAMES_FIELDS; do
      i=$((i + 1))
      val="$(printf '%s\n' "$LOLGAMES_INFO" | sed -n "${i}p")"
      printf 'lolgames_%s\t%s\n' "$field" "${val:-<no tunnel>}"
    done
  fi
  printf '\n'
done <<< "$RUN_IDS"
