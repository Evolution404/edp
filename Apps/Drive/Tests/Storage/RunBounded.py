#!/usr/bin/env python3
import argparse
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error("a command is required")
    try:
        result = subprocess.run(args.command, timeout=args.timeout, check=False)
    except subprocess.TimeoutExpired:
        print(
            f"BOUNDED_COMMAND_TIMEOUT={args.timeout:g} command={args.command[0]}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
