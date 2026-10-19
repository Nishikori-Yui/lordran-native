"""Compatibility checks must depend on source, not local build products."""
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

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


if __name__ == "__main__":
    unittest.main()
