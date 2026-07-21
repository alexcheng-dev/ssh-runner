#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH_DEST="${1:-}"

"$ROOT_DIR/tests/test-codex-cli.sh" "$SSH_DEST"
"$ROOT_DIR/tests/test-opencode-cli.sh" "$SSH_DEST"
"$ROOT_DIR/tests/test-hermes-cli.sh" "$SSH_DEST"
