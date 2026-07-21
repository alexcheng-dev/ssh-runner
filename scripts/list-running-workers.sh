#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-alexcheng-dev/ssh-runner}"
WORKFLOW="${WORKFLOW:-ssh-runner.yml}"
RUN_LIMIT="${RUN_LIMIT:-5}"
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
INSPECT_SCRIPT="$(cd "$(dirname "$0")" && pwd)/inspect-worker.sh"

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
      REMOTE_INFO="$(PROBE_TIMEOUT="$PROBE_TIMEOUT" "$INSPECT_SCRIPT" "$SSH_DEST" 2>/dev/null || true)"
      CODEX_WEB_URL="$(python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.loads(s).get("codex_url","")) if s else None' <<<"$REMOTE_INFO" 2>/dev/null || true)"
      CODEX_PASSWORD="$(python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.loads(s).get("password","")) if s else None' <<<"$REMOTE_INFO" 2>/dev/null || true)"
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
