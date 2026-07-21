#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <owner/repo> <workflow-file-or-name> [branch]" >&2
  echo "Example: $0 alexcheng-dev/ssh-runner ssh-runner.yml main" >&2
  exit 1
fi

REPO="$1"
WORKFLOW="$2"
BRANCH="${3:-}"
TMP_DIR="$(mktemp -d)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
  if [[ -n "$BRANCH" ]]; then
    gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$BRANCH" >/dev/null
  else
    gh workflow run "$WORKFLOW" --repo "$REPO" >/dev/null
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

for _ in {1..60}; do
  CONCLUSION="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs" --jq '.jobs[0].steps[] | select(.name=="Upload SSH link as artifact") | .conclusion' 2>/dev/null || true)"
  if [[ "$CONCLUSION" == "success" ]]; then
    break
  fi

  RUN_STATE="$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '.status + "/" + (.conclusion // "")' 2>/dev/null || true)"
  if [[ "$RUN_STATE" == completed/* ]]; then
    echo "Run completed before ssh-link artifact became available: $RUN_STATE" >&2
    exit 1
  fi

  sleep 2
done

ARTIFACT_ID="$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" --jq '.artifacts[] | select(.name=="ssh-link") | .id')"
if [[ -z "$ARTIFACT_ID" || "$ARTIFACT_ID" == "null" ]]; then
  echo "ssh-link artifact not found" >&2
  exit 1
fi

gh api "repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" > "$TMP_DIR/artifact.zip"
unzip -qo "$TMP_DIR/artifact.zip" -d "$TMP_DIR"

if [[ -n "${SSH_RUNNER_META_OUT:-}" ]]; then
  {
    printf 'RUN_ID=%s\n' "$RUN_ID"
    printf 'REPO=%s\n' "$REPO"
    printf 'WORKFLOW=%s\n' "$WORKFLOW"
  } > "$SSH_RUNNER_META_OUT"
fi

cat "$TMP_DIR/ssh-link.txt"
