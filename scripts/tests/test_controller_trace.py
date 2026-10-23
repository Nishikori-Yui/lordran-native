import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOOL_PATH = ROOT / "dm" / "tools" / "analyze_controller_trace.py"
SPEC = importlib.util.spec_from_file_location("analyze_controller_trace", TOOL_PATH)
TRACE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRACE)


def controller(timestamp_ns, lx):
    return {
        "event": "controller_input",
        "kind": "nintendo",
        "source": "callback",
        "timestamp_ns": timestamp_ns,
        "buttons": 0,
        "lx": lx,
        "ly": 0,
        "rx": 0,
        "ry": 0,
    }


def receipt(publish_ns, read_start_ns, read_end_ns, lx):
    return {
        "event": "npad_receipt",
        "kind": "state_change",
        "publish_ns": publish_ns,
        "read_start_ns": read_start_ns,
        "read_end_ns": read_end_ns,
        "id": 0,
        "requested_style": 1,
        "active_style": 1,
        "sampling": 4,
        "buttons": 0,
        "lx": lx,
        "ly": 0,
        "rx": 0,
        "ry": 0,
        "attributes": 21,
    }


class ControllerTraceTests(unittest.TestCase):
    def test_matching_publication_and_receipt(self):
        summary = TRACE.summarize(
            [controller(1_000_000_000, 32767)],
            [receipt(1_000_000_000, 1_001_000_000, 1_004_000_000, 32767)],
        )
        self.assertEqual(summary["verdict"], "input_reached_game")
        self.assertEqual(summary["matched_receipt_records"], 1)
        self.assertEqual(summary["read_latency_ms"]["min"], 4.0)

    def test_publication_without_game_read(self):
        summary = TRACE.summarize(
            [controller(1_000_000_000, 32767)],
            [receipt(3_000_000_000, 3_001_000_000, 3_004_000_000, 32767)],
        )
        self.assertEqual(summary["verdict"], "game_read_missing")
        self.assertEqual(summary["controller_without_receipt"], 1)

    def test_receipt_without_publication(self):
        summary = TRACE.summarize(
            [],
            [receipt(1_000_000_000, 1_001_000_000, 1_004_000_000, 32767)],
        )
        self.assertEqual(summary["verdict"], "front_end_publication_missing")
        self.assertEqual(summary["receipt_without_controller"], 1)

    def test_cli_json_output(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            controller_path = directory / "controller.jsonl"
            receipt_path = directory / "receipt.jsonl"
            controller_path.write_text(
                json.dumps(controller(1_000_000_000, 32767)) + "\n",
                encoding="utf-8",
            )
            receipt_path.write_text(
                json.dumps(receipt(1_000_000_000, 1_001_000_000, 1_004_000_000, 32767))
                + "\n",
                encoding="utf-8",
            )
            summary = TRACE.summarize(
                TRACE.load_jsonl(controller_path),
                TRACE.load_jsonl(receipt_path),
            )
            self.assertEqual(summary["verdict"], "input_reached_game")


if __name__ == "__main__":
    unittest.main()
