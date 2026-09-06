#!/usr/bin/env python3
import argparse
import os
import signal
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--kill-process-group", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("a command is required")
    process = subprocess.Popen(
        args.command,
        start_new_session=args.kill_process_group,
    )
    try:
        returncode = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        if args.kill_process_group:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        else:
            process.kill()
        try:
            process.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            # A macOS filesystem/disk process can remain in an uninterruptible
            # kernel wait even after SIGKILL. Never turn a bounded helper into
            # an unbounded CI hang while waiting for that process to reap.
            print(
                f"BOUNDED_COMMAND_STUCK_AFTER_KILL=1 pid={process.pid} "
                f"command={args.command[0]}",
                file=sys.stderr,
            )
        print(
            f"BOUNDED_COMMAND_TIMEOUT={args.timeout:g} command={args.command[0]}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    raise SystemExit(returncode)


if __name__ == "__main__":
    main()
