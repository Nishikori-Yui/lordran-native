"""Player feedback must preserve uncertainty and redact before excerpting."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import player_support_common as common
import prepare_issue as report


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        context = patch.object(common, "REPO", self.root)
        context.start()
        self.addCleanup(context.stop)
        self.output = self.root / "game" / "反馈 with spaces"

    def write(self, text):
        path = self.root / "input report.txt"
        path.write_text(text, encoding="utf-8")
        return path

    def draft(self, path, **kwargs):
        result = report.prepare(path, out_dir=self.output, **kwargs)
        return Path(result["files"]["issue-draft"]).read_text(encoding="utf-8")

    def test_redacts_credentials_and_identifiers_but_keeps_diagnostics(self):
        original = (
            '[2026-10-20T04:57:00.123Z] [ERROR] [metal] pc=main+0x123 error=0xe800801c\n'
            'password="a long password" token=abc123 header_key = ' + "a" * 32 + '\n'
            'ssh tester@192.0.2.17 -i /Users/player/.ssh/private\n'
            '"C:\\Users\\Player\\Downloads\\private report.txt"\n'
            'name@example.com FE80::1234:5678:abcd:ef01\n'
            '12345678-1234-5678-9abc-123456789abc\n'
            '-----BEGIN ' + 'PRIVATE KEY-----\nprivate-base64-value\n-----END ' + 'PRIVATE KEY-----\n')
        cleaned = report.sanitize(original)
        for secret in ("a long password", "abc123", "a" * 32, "tester@", "192.0.2",
                       "/Users/player", "Player", "name@example", "FE80",
                       "12345678-1234", "private-base64-value"):
            self.assertNotIn(secret, cleaned)
        for diagnostic in ("2026-10-20T04:57:00.123Z", "[ERROR]", "main+0x123", "0xe800801c"):
            self.assertIn(diagnostic, cleaned)
        inline = report.sanitize('[INFO] api_key="hidden value" error=17')
        self.assertNotIn("hidden value", inline)
        self.assertIn("error=17", inline)

    def test_metadata_is_not_fabricated_and_both_log_generations_are_retained(self):
        metadata = dict(app_version="1.0", app_build="1", exported_at="2026-10-20T04:57:51.920Z",
                        device_model="/Users/player/private@example.com/device",
                        performance=dict(game_fps=50.7, gpu_ms=0.85, width=1280, height=720))
        text = ("Dark Souls diagnostics\n" + json.dumps(metadata) +
                "\n===== log.txt =====\n[INFO] Session started recovery=yes\n[INFO] Current session\n"
                "===== log.prev.txt =====\n[ERROR] previous failure error=0x123\n")
        path = self.write(text)
        draft = self.draft(path, kind="performance", symptom="战斗帧率不稳", steps=["进入战斗"])
        self.assertIn("log.prev.txt", draft)
        self.assertIn("previous failure error=0x123", draft)
        self.assertIn("源码 commit 未由本报告确认", draft)
        self.assertIn("不是整个运行阶段的平均值", draft)
        self.assertIn("game_fps=50.7", draft)
        self.assertNotIn("/Users/player", draft)
        self.assertNotIn("private@example.com", draft)
        self.assertIn("1. 进入战斗", draft)
        self.assertNotIn("player-support:", draft)
        self.assertNotIn("labels:", draft)
        self.assertEqual(path.read_text(), text)

    def test_plain_truncated_log_and_markdown_fences(self):
        path = self.write('[ERROR] failed\n```\n@someone do not run this\n{"truncated":')
        draft = self.draft(path, symptom="启动失败")
        self.assertIn("````text", draft)
        self.assertIn("尚未确认根因", draft)
        self.assertIn("待补充", draft)
        self.assertIn("启动失败", draft)
        self.assertNotIn("已修复", draft)

    def test_user_fields_cannot_inject_extra_markdown_sections(self):
        path = self.write("[ERROR] failed")
        draft = self.draft(path, symptom="launch failed\n## Injected section [link](https://example.invalid)",
                           steps=["open app\n- injected"])
        self.assertIn("launch failed ## Injected section", draft)
        self.assertIn(r"\[link\]\(https://example.invalid\)", draft)
        self.assertIn("1. open app - injected", draft)
        self.assertNotIn("\n## Injected section", draft)

    def test_current_template_is_the_source_of_structure(self):
        template = """---\nname: test\n---\n## Newly added heading\n<!-- player-support:summary -->\n<!-- player-support:logs -->\nold placeholder\n<!-- /player-support:logs -->\n"""
        rendered = report.render(template, {"summary": "user symptom", "logs": "selected logs"})
        self.assertIn("## Newly added heading", rendered)
        self.assertIn("user symptom", rendered)
        self.assertIn("selected logs", rendered)
        self.assertNotIn("old placeholder", rendered)

    def test_related_issue_snapshot_cannot_supply_an_external_link(self):
        snapshot = self.root / "issues.json"
        snapshot.write_text(json.dumps([
            dict(number=12, title="shader pipeline stutter", url="https://untrusted.example/"),
            dict(number=13, title="unrelated keyboard input"),
        ]))
        related = report.related_issues(snapshot, "shader pipeline stall")
        self.assertIn("#12", related)
        self.assertNotIn("#13", related)
        self.assertNotIn("untrusted", related)

    def test_output_must_remain_private_and_runs_do_not_overwrite(self):
        path = self.write("[ERROR] failure")
        with self.assertRaisesRegex(ValueError, "game/"):
            report.prepare(path, out_dir=self.root / "public")
        first = report.prepare(path, out_dir=self.output)
        second = report.prepare(path, out_dir=self.output)
        self.assertNotEqual(first["files"], second["files"])
        self.assertEqual(path.read_text(), "[ERROR] failure")

    def test_large_report_is_rejected_without_reading(self):
        path = self.write("log")
        with patch.object(report, "MAX_BYTES", 2):
            with self.assertRaisesRegex(ValueError, "exceeds"):
                report.read_report(path)

    def test_explicitly_verified_full_git_sha_is_not_redacted_as_a_device_id(self):
        revision = "a1b2c3d4" * 5
        draft = self.draft(self.write("[INFO] log"), build=revision)
        self.assertIn(revision, draft)
        self.assertNotIn("源码 commit 未由本报告确认", draft)


if __name__ == "__main__":
    unittest.main()
