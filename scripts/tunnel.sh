#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:?usage: tunnel.sh localhost:3000 [name]}"
NAME="${2:-}"
SERVER="${LOLGAMES_TUNNEL_SERVER:-161.153.109.33}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=(client "$TARGET" --server "$SERVER" --same-port)
if [[ -n "$NAME" ]]; then args+=(--name "$NAME"); fi
exec python3 "$SCRIPT_DIR/lolgames_tunnel.py" "${args[@]}"
