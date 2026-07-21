#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/common.sh"

SSH_DEST="$(require_ssh_dest "${1:-}")"

run_remote "$SSH_DEST" $'export PATH="$HOME/.local/bin:$PATH"\n[ -f "$HOME/.profile" ] && . "$HOME/.profile"\n[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"\ncd "$HOME"\nrm -f /tmp/codex-hi.txt\ncodex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox --color never --output-last-message /tmp/codex-hi.txt "Reply with exactly hi."\ncat /tmp/codex-hi.txt\n' | tee /tmp/test-codex-cli.log

if ! grep -Eiq '(^|[^[:alpha:]])hi([^[:alpha:]]|$)' /tmp/test-codex-cli.log; then
  echo "Codex CLI test did not return hi" >&2
  exit 1
fi
