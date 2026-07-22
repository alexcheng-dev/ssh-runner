#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <owner/repo> <workflow-file-or-name> [branch]" >&2
  echo "Example: $0 alexcheng-dev/agent-workspace ssh-runner.yml main" >&2
  exit 1
fi

REPO="$1"
WORKFLOW="$2"
BRANCH="${3:-}"
TMP_DIR="$(mktemp -d)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEY_TMP_PATH="$TMP_DIR/id_ed25519"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PREV_RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId // ""' 2>/dev/null || true)"

resolve_new_run_id() {
  gh run list \
    --repo "$REPO" \
    --workflow "$WORKFLOW" \
    --limit 10 \
    --json databaseId,createdAt,status \
    --jq ".[] | select(.databaseId != ($PREV_RUN_ID | tonumber?)) | select(.createdAt >= \"$STARTED_AT\") | .databaseId" \
    2>/dev/null | head -n 1
}

run_workflow() {
  ssh-keygen -t ed25519 -f "$KEY_TMP_PATH" -N "" -q >/dev/null
  SSH_PUBLIC_KEY="$(tr -d '\n' < "$KEY_TMP_PATH.pub")"
  if [[ -n "$BRANCH" ]]; then
    gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" -f ssh_public_key="$SSH_PUBLIC_KEY" >/dev/null
  else
    gh workflow run "$WORKFLOW" --repo "$REPO" -f ssh_public_key="$SSH_PUBLIC_KEY" >/dev/null
  fi
}

RUN_ID=""
for attempt in {1..3}; do
  if run_workflow; then
    sleep 2
    RUN_ID="$(resolve_new_run_id)"
    if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
      RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')"
    fi
    break
  fi
  RUN_ID="$(resolve_new_run_id)"
  if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
    echo "Workflow dispatch returned an error, but run $RUN_ID already exists; reusing it." >&2
    break
  fi
  if [[ "$attempt" == 3 ]]; then
    echo "Failed to dispatch workflow after $attempt attempts" >&2
    exit 1
  fi
  echo "Workflow dispatch failed; retrying in 3s..." >&2
  sleep 3
done

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "Failed to resolve latest run id" >&2
  exit 1
fi

KEY_DIR="$ROOT_DIR/outputs/keys"
mkdir -p "$KEY_DIR"
KEY_PATH="$KEY_DIR/${RUN_ID}_id_ed25519"
cp "$KEY_TMP_PATH" "$KEY_PATH"
chmod 600 "$KEY_PATH"

HOST="runner-${RUN_ID}-1-ssh.lolgames.net"
PORT="$((30000 + (RUN_ID % 20000)))"
WEB_URL="https://github.com/${REPO}/actions/runs/${RUN_ID}"
SSH_LINK_PATH="$TMP_DIR/ssh-link.txt"
{
  printf 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s -p %s runner@%s\n' "$KEY_PATH" "$PORT" "$HOST"
  printf '%s\n' "$WEB_URL"
  printf 'host=%s\n' "$HOST"
  printf 'port=%s\n' "$PORT"
} > "$SSH_LINK_PATH"

if [[ -n "${SSH_RUNNER_META_OUT:-}" ]]; then
  {
    printf 'RUN_ID=%s\n' "$RUN_ID"
    printf 'REPO=%s\n' "$REPO"
    printf 'WORKFLOW=%s\n' "$WORKFLOW"
    printf 'HOST=%s\n' "$HOST"
    printf 'PORT=%s\n' "$PORT"
    printf 'KEY_PATH=%s\n' "$KEY_PATH"
  } > "$SSH_RUNNER_META_OUT"
fi

cat "$SSH_LINK_PATH"
