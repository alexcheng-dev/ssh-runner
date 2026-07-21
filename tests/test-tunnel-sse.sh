#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TUNNEL_NAME="${1:-ssedemo}"
PORT="${TEST_SSE_PORT:-3020}"

cleanup() {
  kill "${SSE_SERVER_PID:-}" "${SSE_TUNNEL_PID:-}" 2>/dev/null || true
  rm -f /tmp/sse_server.py
}
trap cleanup EXIT

cat > /tmp/sse_server.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import time

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        if self.path != '/events':
            body = b'not found\n'
            self.send_response(404)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'keep-alive')
        self.end_headers()
        for i in range(3):
            self.wfile.write(f'id: {i}\nevent: tick\ndata: msg-{i}\n\n'.encode())
            self.wfile.flush()
            time.sleep(0.5)

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', 3020), H).serve_forever()
PY

python3 /tmp/sse_server.py >/tmp/test-tunnel-sse-server.log 2>&1 &
SSE_SERVER_PID=$!
sleep 1

"$ROOT_DIR/scripts/tunnel.sh" "localhost:${PORT}" "$TUNNEL_NAME" >/tmp/test-tunnel-sse-client.log 2>&1 &
SSE_TUNNEL_PID=$!
sleep 2

python3 - <<PY
import requests

seen = []
with requests.get('http://${TUNNEL_NAME}.lolgames.net:${PORT}/events', stream=True, timeout=(5, 8)) as r:
    if r.status_code != 200:
        raise SystemExit(f'unexpected status: {r.status_code}')
    if r.headers.get('content-type') != 'text/event-stream':
        raise SystemExit(f'unexpected content-type: {r.headers.get("content-type")!r}')
    for line in r.iter_lines(chunk_size=1, decode_unicode=True):
        seen.append(line)
        if line == 'data: msg-2':
            break

expected = [
    'id: 0', 'event: tick', 'data: msg-0', '',
    'id: 1', 'event: tick', 'data: msg-1', '',
    'id: 2', 'event: tick', 'data: msg-2',
]
if seen != expected:
    raise SystemExit(f'unexpected SSE lines: {seen!r}')
for line in seen:
    print(line)
PY

