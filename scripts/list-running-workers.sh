#!/usr/bin/env bash
set -euo pipefail

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
require python3
require unzip

RUN_IDS="$(gh run list \
  --repo "$REPO" \
  --workflow "$WORKFLOW" \
  --status in_progress \
  --limit 20 \
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
  if [[ -n "${ARTIFACT_ID:-}" ]]; then
    ZIP_PATH="$TMP_DIR/$RUN_ID.zip"
    OUT_DIR="$TMP_DIR/$RUN_ID"
    mkdir -p "$OUT_DIR"
    gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$ZIP_PATH"
    unzip -qo "$ZIP_PATH" -d "$OUT_DIR"
    SSH_CMD="$(sed -n '1p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"
    WEB_URL="$(sed -n '2p' "$OUT_DIR/ssh-link.txt" 2>/dev/null || true)"
  fi

  printf 'run_id\t%s\n' "$RUN_ID"
  printf 'title\t%s\n' "$TITLE"
  printf 'status\t%s\n' "$STATUS"
  printf 'run_url\t%s\n' "$RUN_URL"
  printf 'ssh\t%s\n' "${SSH_CMD:-<artifact not ready>}"
  printf 'web\t%s\n' "${WEB_URL:-<artifact not ready>}"
  printf '\n'
done <<< "$RUN_IDS"
