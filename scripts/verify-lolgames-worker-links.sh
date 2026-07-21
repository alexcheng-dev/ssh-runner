#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-lolgames-worker-links.sh <worker-agents-url>

Examples:
  verify-lolgames-worker-links.sh http://runnervm3jd5f-123-worker-agents.lolgames.net:1456
EOF
}

WORKER_URL="${1:-}"
if [[ -z "$WORKER_URL" ]]; then
  usage
  exit 2
fi

python3 - "$WORKER_URL" <<'PY'
from urllib.parse import urlparse, urlunparse
import sys

worker = urlparse(sys.argv[1])
if not worker.scheme or not worker.hostname:
    raise SystemExit(f"invalid worker URL: {sys.argv[1]}")

def url_for(parsed, port, path="/"):
    netloc = parsed.hostname
    if parsed.username:
        netloc = f"{parsed.username}@{netloc}"
    netloc = f"{netloc}:{port}"
    return urlunparse((parsed.scheme or "http", netloc, path, "", "", ""))

urls = [
    ("worker", url_for(worker, worker.port or 1456, "/")),
    ("worker-status", url_for(worker, worker.port or 1456, "/api/status")),
    ("worker-host-router-port", url_for(worker, 20127, "/v1/models")),
]
for label, url in urls:
    print(f"{label}\t{url}")
PY

echo
while IFS=$'\t' read -r label url; do
  [[ -n "${label:-}" && -n "${url:-}" ]] || continue
  body="$(mktemp)"
  err="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' --max-time "${VERIFY_TIMEOUT:-12}" "$url" 2>"$err" || true)"
  printf '%-24s HTTP=%s %s\n' "$label" "$code" "$url"
  if [[ -s "$err" ]]; then sed 's/^/  curl: /' "$err"; fi
  if [[ -s "$body" ]]; then
    printf '  '
    head -c 220 "$body" | tr '\n' ' '
    printf '\n'
  fi
  rm -f "$body" "$err"
done < <(python3 - "$WORKER_URL" <<'PY'
from urllib.parse import urlparse, urlunparse
import sys

worker = urlparse(sys.argv[1])

def url_for(parsed, port, path="/"):
    return urlunparse((parsed.scheme or "http", f"{parsed.hostname}:{port}", path, "", "", ""))

rows = [
    ("worker", url_for(worker, worker.port or 1456, "/")),
    ("worker-status", url_for(worker, worker.port or 1456, "/api/status")),
    ("worker-host-router-port", url_for(worker, 20127, "/v1/models")),
]
for row in rows:
    print("\t".join(row))
PY
)
