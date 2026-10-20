"""macOS app bundling keeps the executable and game resources self-contained."""
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
import macos_app


class MacOSAppTests(unittest.TestCase):
    def setUp(self):
        self.profile = game.load()
        (ROOT / "game").mkdir(exist_ok=True)

    def prepare_inputs(self, root):
        host = root / "dmhost"
        host.write_bytes(b"host executable")
        patched = root / "patched"
        patched.mkdir()
        (patched / "main.patched.bin").write_bytes(b"patched game module")
        romfs = root / "RomFS"
        romfs.mkdir()
        (romfs / self.profile.get("romfs_marker")).write_bytes(b"marker")
        shader_cache = root / "cache"
        chain = self.profile.table("dmsh_chain.h").read_text().split('"')[1]
        shader_root = shader_cache / f"b-{chain}"
        shader_root.mkdir(parents=True)
        (shader_root / "shader_b.metallib").write_bytes(b"shader library")
        fonts = root / "fonts"
        fonts.mkdir()
        (fonts / "standard.ttf").write_bytes(b"standard font")
        (fonts / "nintendo_ext.ttf").write_bytes(b"extension font")
        return host, patched, romfs, shader_cache, fonts

    def test_builds_bundle_with_private_data_outside_application_support(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "game") as temporary:
            root = Path(temporary)
            host, patched, romfs, cache, fonts = self.prepare_inputs(root)
            output = root / "LordranNative.app"

            def fake_compile(_repo, launcher):
                launcher.write_bytes(b"launcher")
                launcher.chmod(0o755)

            with patch.object(macos_app, "compile_launcher", side_effect=fake_compile):
                result = macos_app.build_app(
                    repo=ROOT, profile=self.profile, host=host, patched=patched,
                    romfs=romfs, shader_cache=cache, fonts=fonts, output=output,
                    app_name="Synthetic Game", bundle_id=None)

            self.assertEqual(result, output)
            info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleExecutable"], "LordranNativeLauncher")
            self.assertEqual(info["CFBundleDisplayName"], "Synthetic Game")
            self.assertTrue((output / "Contents/MacOS/dmhost").is_file())
            self.assertTrue((output / "Contents/MacOS/LordranNativeLauncher").stat().st_mode & 0o111)
            self.assertTrue((output / "Contents/Resources/game/RomFS" /
                             self.profile.get("romfs_marker")).is_file())
            self.assertTrue((output / "Contents/Resources/dm/pso_manifest.tsv").is_file())
            self.assertTrue((output / "Contents/Resources/shaders" /
                             f"b-{self.profile.table('dmsh_chain.h').read_text().split(chr(34))[1]}" /
                             "shader_b.metallib").is_file())

    def test_existing_bundle_requires_explicit_replace(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "game") as temporary:
            root = Path(temporary)
            host, patched, romfs, cache, fonts = self.prepare_inputs(root)
            output = root / "LordranNative.app"
            output.mkdir()
            (output / "keep.txt").write_text("previous bundle")
            kwargs = dict(repo=ROOT, profile=self.profile, host=host, patched=patched,
                          romfs=romfs, shader_cache=cache, fonts=fonts, output=output,
                          app_name="Synthetic Game", bundle_id=None)
            with self.assertRaises(FileExistsError):
                macos_app.build_app(**kwargs)
            self.assertEqual((output / "keep.txt").read_text(), "previous bundle")

            def fake_compile(_repo, launcher):
                launcher.write_bytes(b"launcher")

            with patch.object(macos_app, "compile_launcher", side_effect=fake_compile):
                macos_app.build_app(**kwargs, replace=True)
            self.assertTrue((output / "Contents/Info.plist").is_file())

    def test_output_must_remain_in_private_game_folder(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            host, patched, romfs, cache, fonts = self.prepare_inputs(root)
            with self.assertRaisesRegex(ValueError, "game/"):
                macos_app.build_app(
                    repo=ROOT, profile=self.profile, host=host, patched=patched,
                    romfs=romfs, shader_cache=cache, fonts=fonts,
                    output=root / "LordranNative.app", app_name="Synthetic Game",
                    bundle_id=None)


if __name__ == "__main__":
    unittest.main()
