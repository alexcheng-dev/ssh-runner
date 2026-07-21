#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a command through an interactive tmate SSH shell.")
    parser.add_argument("ssh_dest", help="tmate ssh destination, e.g. abcdef@sfo2.tmate.io")
    parser.add_argument("command", help="shell command to run remotely")
    parser.add_argument("--timeout", type=int, default=240, help="command timeout in seconds")
    args = parser.parse_args()

    proc = subprocess.Popen(
        [
            "ssh",
            "-tt",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            args.ssh_dest,
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    prompt_re = re.compile(r"runner@[^:]+:.*\$ ")
    buffer = ""
    started = False
    start_deadline = time.time() + 60
    while time.time() < start_deadline:
        ch = proc.stdout.read(1)
        if not ch:
            break
        buffer += ch
        sys.stdout.write(ch)
        sys.stdout.flush()
        if "Press <q> or <ctrl-c> to continue" in buffer:
            proc.stdin.write("q")
            proc.stdin.flush()
        if prompt_re.search(buffer):
            started = True
            break
    if not started:
      proc.kill()
      raise SystemExit("Failed to reach remote shell prompt")

    marker = "__CODEX_REMOTE_DONE__"
    buffer = ""
    proc.stdin.write("printf '__CODEX_REMOTE_BUFFER_RESET__\\n'\n")
    proc.stdin.flush()
    reset_deadline = time.time() + 10
    while time.time() < reset_deadline:
        ch = proc.stdout.read(1)
        if not ch:
            break
        sys.stdout.write(ch)
        sys.stdout.flush()
        buffer += ch
        if "__CODEX_REMOTE_BUFFER_RESET__" in buffer:
            buffer = ""
            break

    wrapped = f"{args.command}\nstatus=$?\nprintf '{marker}:%s\\n' \"$status\"\n"
    proc.stdin.write(wrapped)
    proc.stdin.flush()

    run_deadline = time.time() + args.timeout
    status_code = None
    status_re = re.compile(rf"{re.escape(marker)}:(-?\d+)")
    while time.time() < run_deadline:
        ch = proc.stdout.read(1)
        if not ch:
            break
        buffer += ch
        sys.stdout.write(ch)
        sys.stdout.flush()
        match = status_re.search(buffer)
        if match:
            status_code = int(match.group(1))
            break

    proc.kill()
    try:
      proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
      pass

    if status_code is None:
      raise SystemExit("Timed out waiting for remote command completion")
    return status_code


if __name__ == "__main__":
    raise SystemExit(main())
