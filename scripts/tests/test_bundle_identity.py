"""App identities must stay consistent across native and shell packaging."""
import argparse
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "dm/games"))
import game
import build_ipa_from_nsp as native
import build_ipa_from_shell as shell
import guest_dylib
import player_support as support


class BundleIdentityTests(unittest.TestCase):
    def setUp(self):
        self.profile = game.load()
        (ROOT / "game").mkdir(exist_ok=True)

    def test_profile_default_and_explicit_overrides(self):
        self.assertEqual(self.profile.bundle_id(), "dev.nishikori.lordran-native")
        self.assertEqual(self.profile.bundle_id("org.example.custom-app"), "org.example.custom-app")
        for invalid in ("", "missing-dot", "a..b", "a.b c", "a/b", "a.b_underscore",
                        "a.b\n", "dev.\u6e38\u620f", "$(command).app"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.profile.bundle_id(invalid)

    def test_shell_inherits_identity_and_can_override_it(self):
        original = dict(CFBundleIdentifier="org.example.custom-shell", OtherSetting=True)
        for override, expected in (
            (None, "org.example.custom-shell"),
            (self.profile.bundle_id(), self.profile.bundle_id()),
            ("org.example.override", "org.example.override"),
        ):
            info = shell.application_info(original, self.profile, "Game", override)
            self.assertEqual(info["CFBundleIdentifier"], expected)
            self.assertEqual(info["CFBundleDisplayName"], "Game")
            self.assertTrue(info["OtherSetting"])
            with tempfile.TemporaryDirectory() as folder, patch.object(guest_dylib, "build", return_value=b"synthetic"):
                framework = guest_dylib.write(folder, folder, [], info["CFBundleIdentifier"] + ".guest")
                metadata = plistlib.loads((framework / "Info.plist").read_bytes())
                self.assertEqual(metadata["CFBundleIdentifier"], expected + ".guest")
        self.assertEqual(original["CFBundleIdentifier"], "org.example.custom-shell")

    def test_native_packer_passes_resolved_identity_to_ios_build(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "game") as folder:
            folder = Path(folder)
            keys = folder / "placeholder.keys"
            keys.touch()
            input_file = folder / "placeholder.nsp"
            input_file.touch()
            extraction = folder / "extracted"
            output = folder / "candidate.ipa"
            for override in (None, "org.example.native"):
                args = native.parse_args([str(folder), "--keys", str(keys), "--out", str(output)] +
                                         (["--bundle-id", override] if override else []))
                with patch.object(native, "scan_nsps", return_value=(self.profile.title_id, {})), \
                        patch.object(native, "check_prereqs"), \
                        patch.object(native, "pick_nsps", return_value={
                            version: (input_file, None) for version in self.profile.words("shader_versions")}), \
                        patch.object(native, "free_gb", return_value=1000), \
                        patch.object(native, "build_nx_extract"), \
                        patch.object(native, "extract", return_value=extraction), \
                        patch.object(native, "can_clone", return_value=False), \
                        patch.object(native, "rewrite"), patch.object(native, "split_shaders"), \
                        patch.object(native, "build_shaders", return_value=folder), \
                        patch.object(native, "say"), patch.object(native, "BUNDLE_ID", ""), \
                        patch.object(native, "run", side_effect=lambda *a, **k: output.touch()) as run:
                    args.app_name = "Synthetic Game"
                    native.main(args)
                self.assertEqual(run.call_args.kwargs["env"]["DM_BUNDLE_ID"], override or self.profile.bundle_id())

    def test_support_build_forwards_override_for_both_routes(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "game") as folder:
            folder = Path(folder)
            keys, shell_file = folder / "placeholder.keys", folder / "shell.zip"
            keys.touch()
            shell_file.touch()
            for use_shell in (False, True):
                args = argparse.Namespace(
                    nsp_dir=folder, keys=keys, shell=shell_file if use_shell else None,
                    package=None, out=None, replace=False, dry_run=True,
                    keep_extracted=False, spirv_cross_sha256=None, bundle_id="org.example.support")
                with patch.object(support.sys, "platform", "win32" if use_shell else "darwin"):
                    command = support.build(args)["command"]
                self.assertEqual(command[-2:], ["--bundle-id", "org.example.support"])


if __name__ == "__main__":
    unittest.main()
