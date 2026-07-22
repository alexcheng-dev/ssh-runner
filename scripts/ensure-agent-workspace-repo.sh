#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-alexcheng-dev/agent-workspace}"
DESCRIPTION="${DESCRIPTION:-Public GitHub Actions worker workspace}"
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
require git

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public --description "$DESCRIPTION" --confirm >/dev/null
fi

VISIBILITY="$(gh repo view "$REPO" --json visibility --jq .visibility)"
if [[ "$VISIBILITY" != "PUBLIC" ]]; then
  echo "Repository exists but is not public: $REPO ($VISIBILITY)" >&2
  exit 1
fi

git clone "https://github.com/${REPO}.git" "$TMP_DIR/repo" >/dev/null 2>&1
cd "$TMP_DIR/repo"
mkdir -p .github/workflows scripts
cp "$ROOT_DIR/.github/workflows/ssh-runner.yml" .github/workflows/ssh-runner.yml
cp "$ROOT_DIR/scripts/lolgames_tunnel.py" scripts/lolgames_tunnel.py
if [[ ! -f README.md ]]; then
  cat > README.md <<README
# agent-workspace

Public GitHub Actions workspace for short-lived SSH worker runners used by sshworker.
README
fi

if git diff --quiet -- .github/workflows/ssh-runner.yml scripts/lolgames_tunnel.py README.md 2>/dev/null && git diff --cached --quiet; then
  echo "agent-workspace is already up to date: $REPO"
  exit 0
fi

git add .github/workflows/ssh-runner.yml scripts/lolgames_tunnel.py README.md
git commit -m "Sync SSH worker workflow" >/dev/null
git push origin HEAD:main >/dev/null
echo "Synced agent-workspace: $REPO"
