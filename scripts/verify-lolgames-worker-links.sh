#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-lolgames-worker-links.sh <worker-agents-url> [router-url]

Examples:
  verify-lolgames-worker-links.sh http://runnervm3jd5f-123-worker-agents.lolgames.net:1456
  verify-lolgames-worker-links.sh \
    http://runnervm3jd5f-123-worker-agents.lolgames.net:1456 \
    http://runnervm3jd5f-123-9router.lolgames.net:20127
EOF
}

WORKER_URL="${1:-}"
ROUTER_URL="${2:-}"
if [[ -z "$WORKER_URL" ]]; then
  usage
  exit 2
fi

python3 - "$WORKER_URL" "$ROUTER_URL" <<'PY'
from urllib.parse import urlparse, urlunparse
import sys

worker = urlparse(sys.argv[1])
router = urlparse(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
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
if router:
    urls.append(("router", url_for(router, router.port or 20127, "/v1/models")))
    urls.append(("router-host-worker-port", url_for(router, worker.port or 1456, "/")))

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
done < <(python3 - "$WORKER_URL" "$ROUTER_URL" <<'PY'
from urllib.parse import urlparse, urlunparse
import sys

worker = urlparse(sys.argv[1])
router = urlparse(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None

def url_for(parsed, port, path="/"):
    return urlunparse((parsed.scheme or "http", f"{parsed.hostname}:{port}", path, "", "", ""))

rows = [
    ("worker", url_for(worker, worker.port or 1456, "/")),
    ("worker-status", url_for(worker, worker.port or 1456, "/api/status")),
    ("worker-host-router-port", url_for(worker, 20127, "/v1/models")),
]
if router:
    rows.extend([
        ("router", url_for(router, router.port or 20127, "/v1/models")),
        ("router-host-worker-port", url_for(router, worker.port or 1456, "/")),
    ])
for row in rows:
    print("\t".join(row))
PY
)
