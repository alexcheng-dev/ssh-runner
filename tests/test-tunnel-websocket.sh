#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TUNNEL_NAME="${1:-wsdemo}"
PORT="${TEST_WS_PORT:-3010}"

cleanup() {
  kill "${WS_SERVER_PID:-}" "${WS_TUNNEL_PID:-}" 2>/dev/null || true
  rm -f /tmp/ws_echo_server.py
}
trap cleanup EXIT

cat > /tmp/ws_echo_server.py <<'PY'
import asyncio
import websockets

async def handler(ws):
    await ws.send('hello-from-server')
    async for msg in ws:
        await ws.send('echo:' + msg)

async def main():
    async with websockets.serve(handler, '127.0.0.1', 3010):
        await asyncio.Future()

asyncio.run(main())
PY

python3 /tmp/ws_echo_server.py >/tmp/test-tunnel-websocket-server.log 2>&1 &
WS_SERVER_PID=$!
sleep 1

"$ROOT_DIR/scripts/tunnel.sh" "localhost:${PORT}" "$TUNNEL_NAME" >/tmp/test-tunnel-websocket-client.log 2>&1 &
WS_TUNNEL_PID=$!
sleep 2

python3 - <<PY
import asyncio
import websockets

async def main():
    url = 'ws://${TUNNEL_NAME}.lolgames.net:${PORT}/'
    async with websockets.connect(url, open_timeout=10, close_timeout=5) as ws:
        first = await asyncio.wait_for(ws.recv(), timeout=10)
        second_expected = 'echo:ping'
        if first != 'hello-from-server':
            raise SystemExit(f'unexpected first frame: {first!r}')
        await ws.send('ping')
        second = await asyncio.wait_for(ws.recv(), timeout=10)
        if second != second_expected:
            raise SystemExit(f'unexpected second frame: {second!r}')
        print(first)
        print(second)

asyncio.run(main())
PY

