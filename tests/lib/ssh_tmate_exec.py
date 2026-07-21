#!/usr/bin/env python3
import argparse
import os
import re
import select
import signal
import subprocess
import sys
import time

PROMPT_RE = re.compile(r"runner@[^:]+:.*\$ ")
CONTINUATION_RE = re.compile(r"(?:^|\n|\r)> ?(?:\x1b\[[0-9;?]*[ -/]*[@-~])*")


def close_proc(proc, interrupt_remote=False):
    if interrupt_remote and proc.stdin:
        try:
            proc.stdin.write(b"\x03\n")
            proc.stdin.flush()
            time.sleep(0.2)
        except Exception:
            pass
    proc.kill()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def read_available(proc, timeout=0.2):
    if proc.stdout is None:
        return ""
    fd = proc.stdout.fileno()
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return ""
    try:
        data = os.read(fd, 4096)
    except BlockingIOError:
        return ""
    if not data:
        return ""
    return data.decode("utf-8", errors="ignore")


def wait_for_prompt(proc, timeout, echo=True, recover_continuation=True):
    buffer = ""
    deadline = time.time() + timeout
    sent_q = False
    last_ctrl_c = 0.0
    while time.time() < deadline:
        chunk = read_available(proc, timeout=0.2)
        if not chunk:
            if proc.poll() is not None:
                break
            continue
        buffer += chunk
        if echo:
            sys.stdout.write(chunk)
            sys.stdout.flush()
        if not sent_q and "Press <q> or <ctrl-c> to continue" in buffer:
            proc.stdin.write(b"q")
            proc.stdin.flush()
            sent_q = True
        if recover_continuation and CONTINUATION_RE.search(buffer) and not PROMPT_RE.search(buffer):
            now = time.time()
            if now - last_ctrl_c > 1.0:
                proc.stdin.write(b"\x03\n")
                proc.stdin.flush()
                last_ctrl_c = now
        if PROMPT_RE.search(buffer):
            return True, buffer
    return False, buffer


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a command through an interactive tmate SSH shell.")
    parser.add_argument("ssh_dest", help="tmate ssh destination, e.g. abcdef@sfo2.tmate.io")
    parser.add_argument("command", help="shell command to run remotely")
    parser.add_argument("--timeout", type=int, default=240, help="command timeout in seconds")
    args = parser.parse_args()

    proc = subprocess.Popen(
        [
            "ssh", "-tt",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            args.ssh_dest,
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )

    def on_interrupt(_signum, _frame):
        close_proc(proc, interrupt_remote=True)
        raise SystemExit(130)

    signal.signal(signal.SIGINT, on_interrupt)
    signal.signal(signal.SIGTERM, on_interrupt)

    started, _ = wait_for_prompt(proc, 60)
    if not started:
        close_proc(proc, interrupt_remote=True)
        raise SystemExit("Failed to reach remote shell prompt")

    # Always normalize after attach; this recovers a leftover quote/heredoc prompt.
    proc.stdin.write(b"\x03\n")
    proc.stdin.flush()
    wait_for_prompt(proc, 10)

    marker = "__CODEX_REMOTE_DONE__"
    reset_marker = "__CODEX_REMOTE_BUFFER_RESET__"
    proc.stdin.write(f"printf '{reset_marker}\\n'\n".encode())
    proc.stdin.flush()
    buffer = ""
    deadline = time.time() + 10
    reset_ok = False
    while time.time() < deadline:
        chunk = read_available(proc, timeout=0.2)
        if not chunk:
            if proc.poll() is not None:
                break
            continue
        buffer += chunk
        sys.stdout.write(chunk)
        sys.stdout.flush()
        if reset_marker in buffer:
            buffer = ""
            reset_ok = True
            break
    if not reset_ok:
        close_proc(proc, interrupt_remote=True)
        raise SystemExit("Failed to reset remote shell prompt")

    wrapped = f"{args.command}\nstatus=$?\nprintf '{marker}:%s\\n' \"$status\"\n"
    proc.stdin.write(wrapped.encode())
    proc.stdin.flush()

    run_deadline = time.time() + args.timeout
    status_code = None
    status_re = re.compile(rf"{re.escape(marker)}:(-?\d+)")
    while time.time() < run_deadline:
        chunk = read_available(proc, timeout=0.2)
        if not chunk:
            if proc.poll() is not None:
                break
            continue
        buffer += chunk
        sys.stdout.write(chunk)
        sys.stdout.flush()
        match = status_re.search(buffer)
        if match:
            status_code = int(match.group(1))
            break

    close_proc(proc)
    if status_code is None:
        close_proc(proc, interrupt_remote=True)
        raise SystemExit("Timed out waiting for remote command completion")
    return status_code


if __name__ == "__main__":
    raise SystemExit(main())
