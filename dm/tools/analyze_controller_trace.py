#!/usr/bin/env python3
"""Compare macOS controller publication and Npad receipt JSONL traces."""

import argparse
import json
import sys
from pathlib import Path


def load_jsonl(path):
    records = []
    with Path(path).open("r", encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: record is not an object")
            records.append(value)
    return records


def nonzero(record):
    return bool(
        record.get("buttons", 0)
        or record.get("lx", 0)
        or record.get("ly", 0)
        or record.get("rx", 0)
        or record.get("ry", 0)
    )


def _number(record, key):
    value = record.get(key)
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def summarize(controller_records, receipt_records, window_ms=1000):
    window_ns = window_ms * 1_000_000
    controller_active = [
        record for record in controller_records
        if record.get("event") == "controller_input" and nonzero(record)
    ]
    receipt_active = [
        record for record in receipt_records
        if record.get("event") == "npad_receipt" and nonzero(record)
    ]
    controller_active.sort(key=lambda record: _number(record, "timestamp_ns") or 0)
    receipt_active.sort(key=lambda record: _number(record, "read_start_ns") or 0)

    matched_receipts = set()
    matched_controller = set()
    latencies_ms = []
    for controller_index, controller in enumerate(controller_active):
        published_ns = _number(controller, "timestamp_ns")
        if published_ns is None:
            continue
        for receipt_index, receipt in enumerate(receipt_active):
            if receipt_index in matched_receipts:
                continue
            receipt_publish_ns = _number(receipt, "publish_ns")
            read_start_ns = _number(receipt, "read_start_ns")
            read_end_ns = _number(receipt, "read_end_ns")
            if receipt_publish_ns is None or read_start_ns is None or read_end_ns is None:
                continue
            if receipt_publish_ns < published_ns:
                continue
            if receipt_publish_ns - published_ns > window_ns:
                break
            if read_end_ns < published_ns:
                continue
            matched_receipts.add(receipt_index)
            matched_controller.add(controller_index)
            latencies_ms.append((read_end_ns - published_ns) / 1_000_000)
            break

    if matched_controller and matched_receipts:
        verdict = "input_reached_game"
    elif controller_active:
        verdict = "game_read_missing"
    elif receipt_active:
        verdict = "front_end_publication_missing"
    else:
        verdict = "no_nonzero_input"

    return {
        "controller_records": len(controller_records),
        "receipt_records": len(receipt_records),
        "controller_nonzero_records": len(controller_active),
        "receipt_nonzero_records": len(receipt_active),
        "matched_controller_records": len(matched_controller),
        "matched_receipt_records": len(matched_receipts),
        "controller_without_receipt": len(controller_active) - len(matched_controller),
        "receipt_without_controller": len(receipt_active) - len(matched_receipts),
        "first_controller_timestamp_ns": (
            _number(controller_active[0], "timestamp_ns") if controller_active else None
        ),
        "first_receipt_read_start_ns": (
            _number(receipt_active[0], "read_start_ns") if receipt_active else None
        ),
        "read_latency_ms": {
            "min": min(latencies_ms) if latencies_ms else None,
            "max": max(latencies_ms) if latencies_ms else None,
            "count": len(latencies_ms),
        },
        "verdict": verdict,
        "window_ms": window_ms,
    }


def text_summary(summary):
    latency = summary["read_latency_ms"]
    lines = [
        f"verdict: {summary['verdict']}",
        f"controller records: {summary['controller_records']} "
        f"(nonzero={summary['controller_nonzero_records']})",
        f"Npad receipt records: {summary['receipt_records']} "
        f"(nonzero={summary['receipt_nonzero_records']})",
        f"matched nonzero records: controller={summary['matched_controller_records']} "
        f"receipt={summary['matched_receipt_records']}",
        f"unmatched: controller={summary['controller_without_receipt']} "
        f"receipt={summary['receipt_without_controller']}",
        f"read latency ms: count={latency['count']} "
        f"min={latency['min']} max={latency['max']}",
    ]
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller", required=True, type=Path,
                        help="DM_CONTROLLER_INPUT_LOG JSONL path")
    parser.add_argument("--receipt", required=True, type=Path,
                        help="DM_HID_RECEIPT_LOG JSONL path")
    parser.add_argument("--window-ms", type=int, default=1000,
                        help="maximum publication-to-receipt matching window")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args(argv)
    if args.window_ms <= 0:
        parser.error("--window-ms must be positive")
    try:
        summary = summarize(
            load_jsonl(args.controller),
            load_jsonl(args.receipt),
            args.window_ms,
        )
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.format == "json":
        print(json.dumps(summary, indent=2, sort_keys=True))
    else:
        print(text_summary(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
