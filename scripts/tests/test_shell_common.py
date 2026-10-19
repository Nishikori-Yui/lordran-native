"""Compatibility checks must depend on source, not local build products."""
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import shell_common


class SourceFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.game = SimpleNamespace(dir=self.repo / "dm/games/01004AB00A260000")
        self.game.dir.mkdir(parents=True)
        for name in shell_common.SOURCE_PATHS:
            self.write(name, b"source\n")
        self.write("dm/host/runtime.c", b"int value = 1;\n")

    def write(self, name, content):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def fingerprint(self):
        return shell_common.source_id(self.repo, self.game)

    def test_generated_outputs_do_not_change_source(self):
        expected = self.fingerprint()
        self.write("dm/ios/Sources/Info.plist", b"generated plist\n")
        self.assertEqual(self.fingerprint(), expected)
        for directory in ("t_shader_map.dSYM", "Release.app", "Build.xcarchive",
                          ".iosdd-simulator", "build", "__pycache__"):
            with self.subTest(directory=directory):
                self.write(f"dm/gfx/tests/{directory}/Contents/Info.plist", b"generated\n")
                self.write(f"dm/gfx/tests/{directory}/source.c", b"generated\n")
                self.assertEqual(self.fingerprint(), expected)

    def test_runtime_source_edit_changes_source(self):
        expected = self.fingerprint()
        self.write("dm/host/runtime.c", b"int value = 2;\n")
        self.assertNotEqual(self.fingerprint(), expected)

    def test_new_runtime_source_changes_source(self):
        expected = self.fingerprint()
        self.write("dm/host/another.c", b"int another;\n")
        self.assertNotEqual(self.fingerprint(), expected)

    def test_windows_line_endings_are_stable(self):
        expected = self.fingerprint()
        for path in self.repo.rglob("*"):
            if path.is_file():
                path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(self.fingerprint(), expected)


class C1GuardTests(unittest.TestCase):
    CHAIN = "123456789abc"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.game = SimpleNamespace(id="01004AB00A260000",
                                    table=lambda name: self.root / name)
        (self.root / "dmsh_chain.h").write_text(f'#define DMSH_CHAIN "{self.CHAIN}"\n')
        self.table = self.root / "c1_full.tsv"
        self.table.write_text(f"# chain b-{self.CHAIN} 2026-10-20T00:00:00+00:00\n")

    def test_matching_table_and_shell_payload(self):
        shell_common.check_c1_table(self.game)
        shell_common.check_c1_table(self.game, self.table.read_bytes())

    def test_empty_missing_and_stale_metadata_fail(self):
        for contents in (b"", b"# no chain\n", b"# chain b-000000000000 date\n",
                         f"# chain b-{self.CHAIN}extra date\n".encode()):
            with self.subTest(contents=contents):
                self.table.write_bytes(contents)
                with self.assertRaisesRegex(ValueError, "regenerate"):
                    shell_common.check_c1_table(self.game)
        self.table.unlink()
        with self.assertRaisesRegex(ValueError, "Missing c1_full.tsv"):
            shell_common.check_c1_table(self.game)

    def test_shell_payload_is_checked_independently(self):
        with self.assertRaisesRegex(ValueError, "regenerate"):
            shell_common.check_c1_table(self.game, b"# chain b-000000000000 date\n")

    def test_producer_and_consumer_reject_stale_profile(self):
        self.table.write_text("# chain b-000000000000 date\n")
        for function, args in ((shell_common.make_manifest, (self.root, self.game)),
                               (shell_common.check_manifest, ({}, self.root, self.game))):
            with self.subTest(function=function.__name__), \
                    patch.object(shell_common, "source_id") as fingerprint:
                with self.assertRaisesRegex(ValueError, "regenerate"):
                    function(*args)
                fingerprint.assert_not_called()


if __name__ == "__main__":
    unittest.main()
