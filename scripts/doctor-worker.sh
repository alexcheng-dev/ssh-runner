#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/doctor-worker.sh <ssh-destination-or-command|worker-url>

Examples:
  ./scripts/doctor-worker.sh "ssh -i ./outputs/keys/123_id_ed25519 -p 30123 runner@runner-123-1-ssh.lolgames.net"
  ./scripts/doctor-worker.sh http://example-worker-agents.lolgames.net:1456
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require python3
require curl

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  usage
  exit 2
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PY_OUT="$TMP_DIR/doctor.py"
cat >"$PY_OUT" <<'PY'
import json, os, re, shlex, subprocess, sys, urllib.error, urllib.parse, urllib.request

target = sys.argv[1]
timeout = float(os.environ.get("DOCTOR_TIMEOUT", "12"))

def ok(name, value="", detail=""):
    rows.append((name, "OK", value, detail))

def fail(name, value="", detail=""):
    rows.append((name, "FAIL", value, detail))

def warn(name, value="", detail=""):
    rows.append((name, "WARN", value, detail))

def skip(name, value="", detail=""):
    rows.append((name, "SKIP", value, detail))

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "doctor-worker/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, body.decode("utf-8", "replace"), None
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        return e.code, body, None
    except Exception as e:
        return None, "", str(e)

def run_ssh(ssh_cmd, remote_cmd):
    argv = shlex.split(ssh_cmd)
    if argv and argv[0] != "ssh":
      argv = ["ssh", *argv]
    argv += ["bash", "-lc", remote_cmd]
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout + 8)

def derive_router_url(worker_url):
    parsed = urllib.parse.urlparse(worker_url)
    port = parsed.port or 1456
    host = parsed.hostname or ""
    return urllib.parse.urlunparse((parsed.scheme or "http", f"{host}:20127", "/v1/models", "", "", ""))

def looks_like_url(value):
    return value.startswith("http://") or value.startswith("https://")

def looks_like_ssh(value):
    return value.startswith("ssh ") or "@" in value or ".lolgames.net" in value

def parse_state(raw):
    try:
        return json.loads(raw)
    except Exception:
        return None

rows = []
worker_url = None
ssh_cmd = None
local_state = None

if looks_like_url(target):
    worker_url = target
elif looks_like_ssh(target):
    ssh_cmd = target if target.startswith("ssh ") else f"ssh {shlex.quote(target)}"
else:
    fail("input", target, "expected ssh destination/command or worker URL")
    ssh_cmd = None

if ssh_cmd:
    probe = run_ssh(ssh_cmd, "printf '__doctor_ok__\\n'")
    if probe.returncode == 0 and "__doctor_ok__" in probe.stdout:
        ok("runner_reachable", "ssh", "remote shell responded")
    else:
        fail("runner_reachable", "ssh", (probe.stderr or probe.stdout or "ssh failed").strip()[:220])
        ssh_cmd = None

if ssh_cmd:
    state_probe = run_ssh(
        ssh_cmd,
        r"""python3 - <<'PY'
import json, os
from pathlib import Path
state_path = Path.home()/'.worker-agents'/'state.json'
status_path = Path.home()/'.worker-agents'/'status.json'
payload = {
  "state_exists": state_path.exists(),
  "status_exists": status_path.exists(),
  "state": json.loads(state_path.read_text()) if state_path.exists() else None,
  "status": json.loads(status_path.read_text()) if status_path.exists() else None,
  "hermes_dir": str(Path.home()/'hermes-webui'),
  "hermes_exists": (Path.home()/'hermes-webui').exists(),
}
print(json.dumps(payload))
PY"""
    )
    if state_probe.returncode == 0:
        payload = parse_state(state_probe.stdout.strip())
        if payload:
            local_state = payload
            state = payload.get("state") or {}
            worker_url = worker_url or state.get("worker_agents_url") or state.get("url")
            if payload.get("state_exists"):
                ok("persisted_state_file", "~/.worker-agents/state.json", "present")
            else:
                fail("persisted_state_file", "~/.worker-agents/state.json", "missing")
            if payload.get("status_exists"):
                ok("persisted_status_file", "~/.worker-agents/status.json", "present")
            else:
                warn("persisted_status_file", "~/.worker-agents/status.json", "missing")
            if payload.get("hermes_exists"):
                ok("hermes_present", payload.get("hermes_dir", "~/hermes-webui"), "repo present")
            else:
                warn("hermes_present", payload.get("hermes_dir", "~/hermes-webui"), "repo missing")
        else:
            fail("persisted_state_read", "", "invalid JSON from remote state probe")
    else:
        fail("persisted_state_read", "", (state_probe.stderr or state_probe.stdout or "probe failed").strip()[:220])

if worker_url:
    code, body, err = fetch(worker_url.rstrip("/") + "/api/status")
    if err:
        fail("workeragents_public", worker_url, err[:220])
    elif code == 200:
        ok("workeragents_public", worker_url, "api/status returned 200")
        public_status = parse_state(body)
    else:
        fail("workeragents_public", worker_url, f"HTTP {code}")
        public_status = None
else:
    skip("workeragents_public", "", "no public worker URL available")
    public_status = None

if ssh_cmd:
    local_http = run_ssh(ssh_cmd, "curl -fsS http://127.0.0.1:1456/api/status >/tmp/doctor-worker-status.json && cat /tmp/doctor-worker-status.json")
    if local_http.returncode == 0:
        ok("workeragents_local", "127.0.0.1:1456", "api/status returned")
        local_status = parse_state(local_http.stdout.strip())
    else:
        fail("workeragents_local", "127.0.0.1:1456", (local_http.stderr or local_http.stdout or "curl failed").strip()[:220])
        local_status = None
else:
    skip("workeragents_local", "", "ssh not provided")
    local_status = None

router_url = derive_router_url(worker_url) if worker_url else None
if router_url:
    code, body, err = fetch(router_url)
    if err:
        fail("9router_public", router_url, err[:220])
    elif code in (200, 401):
        ok("9router_public", router_url, f"HTTP {code}")
    else:
        fail("9router_public", router_url, f"HTTP {code}")
else:
    skip("9router_public", "", "no public worker URL available")

if ssh_cmd:
    router_local = run_ssh(ssh_cmd, "curl -sS -o /tmp/doctor-router-body -w '%{http_code}' http://127.0.0.1:20127/v1/models; printf '\\n'; cat /tmp/doctor-router-body")
    if router_local.returncode == 0:
        lines = router_local.stdout.splitlines()
        code = lines[0].strip() if lines else ""
        if code in ("200", "401"):
            ok("9router_local", "127.0.0.1:20127", f"HTTP {code}")
        else:
            fail("9router_local", "127.0.0.1:20127", f"HTTP {code or 'unknown'}")
    else:
        fail("9router_local", "127.0.0.1:20127", (router_local.stderr or router_local.stdout or "curl failed").strip()[:220])
else:
    skip("9router_local", "", "ssh not provided")

agents = None
for candidate in (public_status, local_status, (local_state or {}).get("status")):
    if isinstance(candidate, dict) and isinstance(candidate.get("agents"), list):
        agents = candidate["agents"]
        break

if agents is None:
    warn("agent_inventory", "", "no agent list found in status payload")
else:
    running = {a.get("id"): a for a in agents if a.get("state") == "running"}
    ok("agent_inventory", str(len(agents)), f"running={','.join(sorted(running)) or 'none'}")
    if any(a.get("id") == "hermes-webui" for a in agents):
        ok("hermes_registered", "hermes-webui", "present in Worker Agents status")
    elif local_state and local_state.get("hermes_exists"):
        warn("hermes_registered", "hermes-webui", "repo exists but agent not listed")
    else:
        warn("hermes_registered", "hermes-webui", "not listed")

if worker_url and public_status and local_state and isinstance(local_state.get("state"), dict):
    persisted_url = local_state["state"].get("worker_agents_url") or local_state["state"].get("url")
    if persisted_url == worker_url:
        ok("state_consistency", worker_url, "public URL matches persisted state")
    else:
        fail("state_consistency", worker_url, f"persisted={persisted_url!r}")
elif worker_url and not ssh_cmd:
    skip("state_consistency", worker_url, "need ssh to read persisted state")
else:
    warn("state_consistency", "", "insufficient data")

if ssh_cmd:
    proc_probe = run_ssh(ssh_cmd, "ps -ef | egrep 'workerAgents|server.js|hermes|lolgames_tunnel.py' | grep -v grep || true")
    if proc_probe.returncode == 0 and proc_probe.stdout.strip():
        ok("processes", "remote", proc_probe.stdout.strip().splitlines()[0][:220])
    else:
        warn("processes", "remote", "expected processes not found in ps output")
else:
    skip("processes", "", "ssh not provided")

width = max(len(name) for name, *_ in rows) if rows else 10
for name, status, value, detail in rows:
    print(f"{name.ljust(width)}  {status:<4}  {value}")
    if detail:
        print(f"  {detail}")

bad = any(status == "FAIL" for _, status, _, _ in rows)
sys.exit(1 if bad else 0)
PY

python3 "$PY_OUT" "$TARGET"
