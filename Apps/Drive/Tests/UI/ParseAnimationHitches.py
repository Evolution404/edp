#!/usr/bin/env python3
import argparse
import datetime as dt
import re
import xml.etree.ElementTree as ET
from pathlib import Path

THRESHOLD_NS = 33_000_000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toc", required=True)
    parser.add_argument("--hitches", required=True)
    parser.add_argument("--log", required=True)
    return parser.parse_args()


def parse_epoch_markers(log_text: str) -> tuple[float, float]:
    begin = re.search(r"UI_HITCH_TOGGLES_BEGIN_EPOCH=([0-9.]+)", log_text)
    end = re.search(r"UI_HITCH_TOGGLES_END_EPOCH=([0-9.]+)", log_text)
    if not begin or not end:
        raise SystemExit("missing UI hitch toggle epoch markers")
    begin_epoch = float(begin.group(1))
    end_epoch = float(end.group(1))
    if not begin_epoch < end_epoch:
        raise SystemExit("invalid UI hitch toggle interval")
    return begin_epoch, end_epoch


def parse_trace_start(toc_path: Path) -> float:
    root = ET.parse(toc_path).getroot()
    node = root.find("./run/info/summary/start-date")
    if node is None or not node.text:
        raise SystemExit("trace start-date missing")
    return dt.datetime.fromisoformat(node.text).timestamp()


def resolve_numeric(element: ET.Element | None, cache: dict[str, int]) -> int | None:
    if element is None:
        return None
    ref = element.attrib.get("ref")
    if ref is not None:
        return cache.get(ref)
    if element.text is None:
        return None
    value = int(element.text)
    identifier = element.attrib.get("id")
    if identifier is not None:
        cache[identifier] = value
    return value


def parse_hitches(hitches_path: Path, trace_start: float, begin: float, end: float) -> tuple[int, int, int]:
    root = ET.parse(hitches_path).getroot()
    start_cache: dict[str, int] = {}
    duration_cache: dict[str, int] = {}
    in_window: list[int] = []
    observed_starts: list[int] = []

    for row in root.iter("row"):
        start_ns = resolve_numeric(row.find("start-time"), start_cache)
        duration_ns = resolve_numeric(row.find("duration"), duration_cache)
        if start_ns is None or duration_ns is None:
            continue
        observed_starts.append(start_ns)
        row_epoch = trace_start + start_ns / 1_000_000_000
        # A small guard absorbs the millisecond precision of xctrace's start-date.
        if begin - 0.010 <= row_epoch <= end + 0.010:
            in_window.append(duration_ns)

    print(f"UI_HITCH_TRACE_START_EPOCH={trace_start:.6f}")
    print(f"UI_HITCH_TOGGLE_BEGIN_EPOCH={begin:.6f}")
    print(f"UI_HITCH_TOGGLE_END_EPOCH={end:.6f}")
    if observed_starts:
        first_start = min(observed_starts)
        last_start = max(observed_starts)
        print(f"UI_HITCH_FIRST_START_NS={first_start}")
        print(f"UI_HITCH_LAST_START_NS={last_start}")
        print(f"UI_HITCH_FIRST_ROW_EPOCH={trace_start + first_start / 1_000_000_000:.6f}")
        print(f"UI_HITCH_LAST_ROW_EPOCH={trace_start + last_start / 1_000_000_000:.6f}")

    if not in_window:
        raise SystemExit("no frame-lifetime samples overlapped the sidebar toggle interval")
    max_ns = max(in_window)
    hitch_count = sum(value > THRESHOLD_NS for value in in_window)
    return len(in_window), max_ns, hitch_count


def main() -> None:
    args = parse_args()
    log_text = Path(args.log).read_text()
    begin, end = parse_epoch_markers(log_text)
    trace_start = parse_trace_start(Path(args.toc))
    frame_count, max_ns, hitch_count = parse_hitches(
        Path(args.hitches), trace_start, begin, end
    )
    print(f"UI_HITCH_FRAME_COUNT={frame_count}")
    print(f"UI_HITCH_MAX_MS={max_ns / 1_000_000:.3f}")
    print(f"UI_HITCH_COUNT_GT33MS={hitch_count}")
    if hitch_count != 0:
        raise SystemExit("sidebar Animation Hitches gate failed")
    print("RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO")


if __name__ == "__main__":
    main()
