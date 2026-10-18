"""The source audit must catch unknown messages and supplementary Han characters."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("check_log_language.py")
ROOT = SCRIPT.resolve().parents[3]


class SourceLanguageAudit(unittest.TestCase):
    def audit(self, source, suffix=".c", allowlist=None):
        work = ROOT / "game/01004AB00A260000-work/run"
        work.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="language-audit-", dir=work) as directory:
            root = Path(directory)
            for folder in ("dm/host", "dm/gfx", "dm/ios"):
                (root / folder).mkdir(parents=True)
            filename = "dm/host/unfamiliar" + suffix
            (root / filename).write_text(source)
            allowed = root / "allowlist.json"
            allowed.write_text(json.dumps(allowlist or []))
            spec = importlib.util.spec_from_file_location("source_language_check", SCRIPT)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            module.ROOT, module.ALLOWLIST = root, allowed
            output = io.StringIO()
            with redirect_stdout(output):
                result = module.main()
            return result, output.getvalue()

    def test_unknown_helper_and_separate_message_variable(self):
        result, output = self.audit('const char *value = "\u9f98";\n'
            "void emit(void) { unfamiliar_writer(value); }\n")
        self.assertTrue(result)
        self.assertIn("unfamiliar.c:1", output)

    def test_supplementary_han_in_include_and_character_literal(self):
        for literal in ('"\U00020bb7"', "L'\U00020bb7'"):
            with self.subTest(literal=literal):
                result, _ = self.audit("const int value = " + literal + ";\n", ".inc")
                self.assertTrue(result)

    def test_comments_are_not_runtime_output(self):
        result, _ = self.audit("// \u4e2d\u6587\n/* \U00020bb7 */\nconst char *value = \"English\";\n")
        self.assertFalse(result)

    def test_allowlist_is_an_exact_source_line(self):
        localized = 'const char *label = "\u786e\u5b9a";'
        allowed = [{"file": "dm/host/unfamiliar.c", "source": localized}]
        self.assertFalse(self.audit(localized + "\n", allowlist=allowed)[0])
        self.assertTrue(self.audit(localized + '\nunfamiliar_writer("\u786e\u5b9a");\n',
            allowlist=allowed)[0])


if __name__ == "__main__":
    unittest.main()
