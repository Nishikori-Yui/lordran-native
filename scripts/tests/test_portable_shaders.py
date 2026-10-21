"""Tool verification must be usable publicly and must fail before extraction."""
import hashlib
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import portable_shaders
import build_ipa_from_shell


class SpirvCrossTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.executable = Path(self.temp.name) / "spirv-cross.exe"
        self.executable.write_bytes(b"test executable")
        self.sha = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        for context in (
            patch.object(portable_shaders.sys, "platform", "win32"),
            patch.object(portable_shaders.shutil, "which", return_value=str(self.executable)),
            patch.dict(os.environ, {}, clear=True),
        ):
            context.start()
            self.addCleanup(context.stop)

    def test_missing_and_malformed_fingerprints_fail(self):
        for expected in (None, "", "abcd", "g" * 64, "a" * 63):
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(ValueError, "--spirv-cross-sha256"):
                    portable_shaders.verify_spirv_cross(expected)

    def test_matching_fingerprint_passes(self):
        self.assertEqual(portable_shaders.verify_spirv_cross(self.sha.upper()),
                         str(self.executable))

    def test_environment_fallback(self):
        with patch.dict(os.environ, DM_SPIRV_CROSS_SHA256=self.sha):
            portable_shaders.verify_spirv_cross()

    def test_explicit_value_takes_precedence(self):
        with patch.dict(os.environ, DM_SPIRV_CROSS_SHA256="0" * 64):
            portable_shaders.verify_spirv_cross(self.sha)

    def test_mismatch_and_modified_binary_fail(self):
        with self.assertRaisesRegex(ValueError, "mismatch"):
            portable_shaders.verify_spirv_cross("0" * 64)
        self.executable.write_bytes(b"replaced executable")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            portable_shaders.verify_spirv_cross(self.sha)

    def test_missing_executable_fails(self):
        with patch.object(portable_shaders.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "PATH"):
                portable_shaders.verify_spirv_cross(self.sha)

    def test_windows_fingerprint_cannot_bypass_mac_lock(self):
        with patch.object(portable_shaders.sys, "platform", "darwin"):
            with self.assertRaisesRegex(ValueError, "release toolchain lock"):
                portable_shaders.verify_spirv_cross(self.sha)

    def test_invalid_windows_toolchain_fails_before_nsp_scan(self):
        repo = Path(self.temp.name) / "checkout"
        private = repo / "game"
        private.mkdir(parents=True)
        keys, shell = private / "prod.keys", private / "shell.zip"
        keys.touch()
        shell.touch()
        scanner = Mock(side_effect=AssertionError("NSPs must not be read"))
        modules = {
            "game": SimpleNamespace(load=lambda: SimpleNamespace(id="01004AB00A260000")),
            "build_ipa_from_nsp": SimpleNamespace(scan_nsps=scanner),
            "nacp": SimpleNamespace(),
        }
        with patch.dict(sys.modules, modules), \
                patch.object(build_ipa_from_shell, "__file__",
                             str(repo / "scripts/build_ipa_from_shell.py")), \
                patch.object(sys, "path", sys.path.copy()), \
                patch.object(sys, "argv", ["build_ipa_from_shell.py", str(private),
                                          "-k", str(keys), "--shell", str(shell),
                                          "-o", str(private / "out.ipa")]), \
                patch.object(build_ipa_from_shell, "safe_shell", return_value=(
                    {"CFBundleSupportedPlatforms": ["iPhoneOS"]}, {},
                    {"dm/c1_full.tsv": b"test table"}, {})), \
                patch.object(build_ipa_from_shell, "check_manifest"), \
                patch.object(build_ipa_from_shell, "check_c1_table"):
            with self.assertRaisesRegex(ValueError, "Windows builds require"):
                build_ipa_from_shell.main()
        scanner.assert_not_called()
        self.assertFalse((private / "01004AB00A260000_shell_build").exists())


if __name__ == "__main__":
    unittest.main()
