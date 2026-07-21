#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/tests/common.sh"

SSH_DEST="$(require_ssh_dest "${1:-}")"

run_remote "$SSH_DEST" $'export PATH="$HOME/.local/bin:$PATH"\n[ -f "$HOME/.profile" ] && . "$HOME/.profile"\n[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"\ncd "$HOME"\nhermes -z "Reply with exactly hi."\n' | tee /tmp/test-hermes-cli.log

if ! grep -Eiq '(^|[^[:alpha:]])hi([^[:alpha:]]|$)' /tmp/test-hermes-cli.log; then
  echo "Hermes CLI test did not return hi" >&2
  exit 1
fi
