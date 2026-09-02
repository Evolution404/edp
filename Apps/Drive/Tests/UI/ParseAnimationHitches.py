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
    parser.add_argument("--events", required=True)
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


def resolve_numeric(
    element: ET.Element | None,
    cache: dict[str, int],
    *,
    is_duration: bool,
) -> int | None:
    if element is None:
        return None
    ref = element.attrib.get("ref")
    if ref is not None:
        return cache.get(ref)

    raw = (element.text or "").strip()
    value: int | None = None
    if raw.isdigit():
        value = int(raw)
    else:
        formatted = element.attrib.get("fmt", raw).strip()
        if formatted:
            if is_duration:
                parts = formatted.split()
                if len(parts) >= 2:
                    try:
                        scalar = float(parts[0])
                    except ValueError:
                        scalar = -1
                    unit = parts[1].lower()
                    multipliers = {
                        "ns": 1,
                        "µs": 1_000,
                        "us": 1_000,
                        "ms": 1_000_000,
                        "s": 1_000_000_000,
                    }
                    if scalar >= 0 and unit in multipliers:
                        value = int(scalar * multipliers[unit])
            else:
                try:
                    value = int(float(formatted) * 1_000_000_000)
                except ValueError:
                    value = None

    if value is not None:
        identifier = element.attrib.get("id")
        if identifier is not None:
            cache[identifier] = value
    return value


def timing_element(children: list[ET.Element], keyword: str, fallback_index: int) -> ET.Element | None:
    for child in children:
        if keyword in child.tag.lower():
            return child
    if fallback_index < len(children):
        return children[fallback_index]
    return None


def parse_timing_table(path: Path, label: str) -> tuple[int, list[tuple[int, int]]]:
    root = ET.parse(path).getroot()
    start_cache: dict[str, int] = {}
    duration_cache: dict[str, int] = {}
    rows: list[tuple[int, int]] = []
    raw_row_count = 0
    raw_row_samples: list[str] = []

    for row in root.iter("row"):
        raw_row_count += 1
        children = list(row)
        if len(raw_row_samples) < 3:
            raw_row_samples.append(" | ".join(
                f"{child.tag}:text={(child.text or '').strip()!r}:fmt={child.attrib.get('fmt')!r}:ref={child.attrib.get('ref')!r}"
                for child in children[:8]
            ))
        start_element = timing_element(children, "start", 0)
        duration_element = timing_element(children, "duration", 1)
        start_ns = resolve_numeric(start_element, start_cache, is_duration=False)
        duration_ns = resolve_numeric(duration_element, duration_cache, is_duration=True)
        if start_ns is None or duration_ns is None:
            continue
        rows.append((start_ns, duration_ns))

    print(f"UI_HITCH_{label}_RAW_ROWS={raw_row_count}")
    print(f"UI_HITCH_{label}_PARSED_ROWS={len(rows)}")
    for index, sample in enumerate(raw_row_samples, start=1):
        print(f"UI_HITCH_{label}_ROW_{index}={sample}")
    return raw_row_count, rows


def durations_in_window(
    rows: list[tuple[int, int]],
    trace_start: float,
    begin: float,
    end: float,
) -> list[int]:
    result: list[int] = []
    for start_ns, duration_ns in rows:
        row_epoch = trace_start + start_ns / 1_000_000_000
        if begin - 0.010 <= row_epoch <= end + 0.010:
            result.append(duration_ns)
    return result


def main() -> None:
    args = parse_args()
    log_text = Path(args.log).read_text()
    begin, end = parse_epoch_markers(log_text)
    trace_start = parse_trace_start(Path(args.toc))

    frame_raw_count, frame_rows = parse_timing_table(
        Path(args.hitches), "FRAME_LIFETIME"
    )
    if frame_raw_count > 0:
        if not frame_rows:
            raise SystemExit("frame-lifetime table contained rows but no timing rows were parseable")
        samples = durations_in_window(frame_rows, trace_start, begin, end)
        if not samples:
            raise SystemExit("no frame-lifetime samples overlapped the sidebar toggle interval")
        source = "frame-lifetimes"
    else:
        # Xcode 26 GitHub-hosted macOS runners expose the frame-lifetime schema
        # but may leave that table empty. In that case use the sparse Animation
        # Hitches event table from the same trace. We still apply our explicit
        # 33,000,000 ns threshold; an empty sparse event window means Instruments
        # observed no hitch event during the sidebar automation interval.
        event_raw_count, event_rows = parse_timing_table(
            Path(args.events), "EVENT"
        )
        if event_raw_count > 0 and not event_rows:
            raise SystemExit("hitch event table contained rows but no timing rows were parseable")
        samples = durations_in_window(event_rows, trace_start, begin, end)
        source = "hitch-events"

    max_ns = max(samples) if samples else 0
    hitch_count = sum(value > THRESHOLD_NS for value in samples)

    print(f"UI_HITCH_TRACE_START_EPOCH={trace_start:.6f}")
    print(f"UI_HITCH_TOGGLE_BEGIN_EPOCH={begin:.6f}")
    print(f"UI_HITCH_TOGGLE_END_EPOCH={end:.6f}")
    print(f"UI_HITCH_SAMPLE_SOURCE={source}")
    print(f"UI_HITCH_FRAME_COUNT={len(samples)}")
    print(f"UI_HITCH_MAX_MS={max_ns / 1_000_000:.3f}")
    print(f"UI_HITCH_COUNT_GT33MS={hitch_count}")
    if hitch_count != 0:
        raise SystemExit("sidebar Animation Hitches gate failed")
    print("RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO")


if __name__ == "__main__":
    main()
