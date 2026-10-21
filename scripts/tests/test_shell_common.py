"""Compatibility checks must depend on source, not local build products."""
import json
import os
import plistlib
import sys
import tempfile
import unittest
import zipfile
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import shell_common
import build_ipa_from_shell
import app_version
from PIL import Image
from ios_icons import PHONE_ICONS, IPAD_ICONS


class SourceFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve()
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

    def test_legacy_and_versioned_names_keep_real_manifest_checks(self):
        self.game.id = "01004AB00A260000"
        self.game.table = lambda name: self.game.dir / name
        self.write("dm/games/01004AB00A260000/dmsh_chain.h", b'#define DMSH_CHAIN "123456789abc"\n')
        self.write("dm/games/01004AB00A260000/c1_full.tsv", b"# chain b-123456789abc date\n")
        self.write("dm/games/01004AB00A260000/shader_map.tsv", b"v0\tvs\t0\t12345678abcdef01\n")
        manifest = shell_common.make_manifest(self.repo, self.game)
        files = dict.fromkeys(("DmIOS", "dm/shader_map.tsv", "dm/pso_manifest.tsv",
                              "dm/font/standard.ttf", "dm/font/nintendo_ext.ttf"), b"synthetic")
        files.update({"Info.plist": plistlib.dumps({"CFBundleSupportedPlatforms": ["iPhoneOS"]}),
                      "dm/shell.json": json.dumps(manifest).encode(),
                      "dm/c1_full.tsv": self.game.table("c1_full.tsv").read_bytes()})
        for filename in ("LordranNative-shell-build-input.zip",
                         "LordranNative-shell-build-input-v0.2.0.zip",
                         "LordranNative-shell-build-input-dev-123456789abc.zip"):
            with self.subTest(filename=filename):
                shell = self.repo / filename
                with zipfile.ZipFile(shell, "w") as archive:
                    for name, content in files.items():
                        archive.writestr("Payload/DmIOS.app/" + name, content)
                _, _, _, version = build_ipa_from_shell.validate_shell(shell, self.repo, self.game)
                self.assertEqual(version["source_kind"], "legacy-shell")
                self.assertTrue(version["source_version"].startswith("legacy-shell-source-sha256:"))
                self.write("dm/host/runtime.c", b"int value = 2;\n")
                with self.assertRaisesRegex(ValueError, "Shell source mismatch"):
                    build_ipa_from_shell.validate_shell(shell, self.repo, self.game)
                self.write("dm/host/runtime.c", b"int value = 1;\n")

    def test_no_git_prebuilt_shell_keeps_tag_dev_and_archive_versions(self):
        self.game.id = "01004AB00A260000"
        self.game.table = lambda name: self.game.dir / name
        self.game.bundle_id = lambda value: value
        self.write("dm/games/01004AB00A260000/dmsh_chain.h", b'#define DMSH_CHAIN "123456789abc"\n')
        self.write("dm/games/01004AB00A260000/c1_full.tsv", b"# chain b-123456789abc date\n")
        self.write("dm/games/01004AB00A260000/shader_map.tsv", b"v0\tvs\t0\t12345678abcdef01\n")
        manifest = shell_common.make_manifest(self.repo, self.game)
        versions = [
            dict(schema=1, source_version=tag, source_kind="release", commit="b" * 40,
                 marketing_version="0.2.0", build_version="1.2.0")
            for tag in ("v0.2.0", "v0.2.0-rc.1+build.7")]
        versions += [dict(schema=1, source_version="dev-" + "b" * 12, source_kind="development",
                          commit="b" * 40, marketing_version="0.0.0", build_version="1.0.0"),
                     app_version.resolve(self.repo, {})]
        self.assertFalse((self.repo / ".git").exists())
        for version in versions:
            with self.subTest(source_version=version["source_version"]):
                shell = self.repo / "shell.zip"
                info = dict(CFBundleIdentifier="dev.example.shell", CFBundleSupportedPlatforms=["iPhoneOS"],
                            CFBundleShortVersionString=version["marketing_version"],
                            CFBundleVersion=version["build_version"])
                payload = dict.fromkeys(("DmIOS", "dm/shader_map.tsv", "dm/pso_manifest.tsv",
                                         "dm/font/standard.ttf", "dm/font/nintendo_ext.ttf"), b"synthetic")
                payload.update({"Info.plist": plistlib.dumps(info),
                                "dm/shell.json": json.dumps(manifest).encode(),
                                "dm/c1_full.tsv": self.game.table("c1_full.tsv").read_bytes(),
                                "dm/app-version.json": json.dumps(version).encode()})
                with zipfile.ZipFile(shell, "w") as archive:
                    for name, contents in payload.items():
                        archive.writestr("Payload/DmIOS.app/" + name, contents)
                with patch.object(app_version, "resolve", side_effect=AssertionError("Do not resolve Git for a prebuilt shell")):
                    actual_info, _, _, actual_version = build_ipa_from_shell.validate_shell(shell, self.repo, self.game)
                    packaged = build_ipa_from_shell.application_info(actual_info, self.game, "Game", version=actual_version)
                self.assertEqual(actual_version, version)
                self.assertEqual(packaged["CFBundleShortVersionString"], version["marketing_version"])
                self.assertEqual(packaged["CFBundleVersion"], version["build_version"])

                payload["Info.plist"] = plistlib.dumps(dict(info, CFBundleShortVersionString="9.9.9"))
                with zipfile.ZipFile(shell, "w") as archive:
                    for name, contents in payload.items():
                        archive.writestr("Payload/DmIOS.app/" + name, contents)
                with self.assertRaisesRegex(ValueError, "Info.plist.*disagree"):
                    build_ipa_from_shell.validate_shell(shell, self.repo, self.game)

    def test_final_ipa_preserves_source_identity_after_package_extraction(self):
        self.game.id = "01004AB00A260000"
        self.game.title_id = int(self.game.id, 16)
        self.game.table = lambda name: self.game.dir / name
        self.game.bundle_id = lambda value: value
        self.game.get = {"package": "v196608", "ipa": "out.ipa", "zip_store": ".bin"}.__getitem__
        self.game.words = {"shader_versions": ["v0", "v196608"], "modules": ["main"]}.__getitem__
        self.game.builds = lambda: ["v0", "v196608"]
        chain, shader = "123456789abc", "12345678abcdef01"
        self.write("dm/games/01004AB00A260000/dmsh_chain.h", f'#define DMSH_CHAIN "{chain}"\n'.encode())
        self.write("dm/games/01004AB00A260000/c1_full.tsv", f"# chain b-{chain} date\n".encode())
        self.write("dm/games/01004AB00A260000/shader_map.tsv", f"v0\tvs\t0\t{shader}\n".encode())
        manifest = shell_common.make_manifest(self.repo, self.game)
        private = self.repo / "game"
        private.mkdir()
        keys, shell = private / "synthetic.keys", private / "shell.zip"
        keys.touch()

        def extract(_nx, _keys, root, package, *_args):
            romfs = root / package / "RomFS"
            romfs.mkdir(parents=True, exist_ok=True)
            (romfs / "synthetic.bin").write_bytes(b"synthetic game data")
            Image.new("RGB", (256, 256), "red" if package == "v196608" else "blue").save(
                romfs.parent / "icon.jpg")
            return romfs.parent

        def run(command, _log, env=None, cwd=None):
            if command[0] == "synthetic-dotnet":
                target = Path(command[command.index("-o") + 1])
                target.mkdir(parents=True, exist_ok=True)
                name = ("nx_extract.exe" if os.name == "nt" else "nx_extract") if target.name == "nx_extract" else "dmsh_xlate.dll"
                (target / name).touch()
            elif str(command[1]).endswith("portable_shaders.py"):
                target = Path(command[-1]) / f"b-{chain}"
                target.mkdir(parents=True, exist_ok=True)
                for suffix in ("metal", "metallib", "json"):
                    (target / f"{shader}_b.{suffix}").write_bytes(b"synthetic shader")
            elif command[1] == "-c":
                framework = Path(command[5]) / "Guest.framework"
                framework.mkdir(parents=True, exist_ok=True)
                (framework / "Guest").write_bytes(b"synthetic guest")
            else:
                raise AssertionError(f"Unexpected external command: {command}")

        source = SimpleNamespace(
            scan_nsps=lambda _: (self.game.title_id, {}),
            pick_nsps=lambda _family, versions: {v: ("synthetic-base", None if v == "v0" else "synthetic-update") for v in versions},
            extract=extract, can_clone=lambda _: False,
            rewrite=lambda *_: None, split_shaders=lambda *_: None)
        modules = {"game": SimpleNamespace(load=lambda: self.game), "build_ipa_from_nsp": source,
                   "nacp": SimpleNamespace(name=lambda _: "Synthetic app")}
        versions = [dict(schema=1, source_version=tag, source_kind="release", commit="b" * 40,
                         marketing_version="0.2.0", build_version="1.2.0")
                    for tag in ("v0.2.0", "v0.2.0-rc.1+build.7")]
        versions += [dict(schema=1, source_version="dev-" + "b" * 12, source_kind="development",
                          commit="b" * 40, marketing_version="0.0.0", build_version="1.0.0"),
                     app_version.resolve(self.repo, {}), None]
        for index, version in enumerate(versions):
            with self.subTest(source_version=version["source_version"] if version else "legacy-shell"):
                info = dict(CFBundleIdentifier="dev.example.shell", CFBundleSupportedPlatforms=["iPhoneOS"],
                            CFBundleShortVersionString=version["marketing_version"] if version else "1.0",
                            CFBundleVersion=version["build_version"] if version else "1")
                payload = dict.fromkeys(("DmIOS", "dm/shader_map.tsv", "dm/pso_manifest.tsv",
                                         "dm/font/standard.ttf", "dm/font/nintendo_ext.ttf"), b"synthetic")
                payload.update({"Info.plist": plistlib.dumps(info),
                                "dm/shell.json": json.dumps(manifest).encode(),
                                "dm/c1_full.tsv": self.game.table("c1_full.tsv").read_bytes()})
                if version:
                    payload["dm/app-version.json"] = json.dumps(version).encode()
                expected = version or app_version.legacy_identity(manifest, info)
                with zipfile.ZipFile(shell, "w") as archive:
                    for name, contents in payload.items():
                        archive.writestr("Payload/DmIOS.app/" + name, contents)
                output = private / f"synthetic-{index}.ipa"
                with patch.dict(sys.modules, modules), \
                        patch.object(build_ipa_from_shell, "__file__", str(self.repo / "scripts/build_ipa_from_shell.py")), \
                        patch.object(sys, "path", sys.path.copy()), \
                        patch.object(sys, "argv", ["build_ipa_from_shell.py", str(private), "-k", str(keys),
                                                  "--shell", str(shell), "-o", str(output)]), \
                        patch.object(build_ipa_from_shell, "check_tools", return_value="synthetic-dotnet"), \
                        patch.object(build_ipa_from_shell, "run", side_effect=run), \
                        patch.object(app_version, "resolve", side_effect=AssertionError("Do not resolve local Git")):
                    build_ipa_from_shell.main()
                with zipfile.ZipFile(output) as archive:
                    self.assertIsNone(archive.testzip())
                    actual = json.loads(archive.read("Payload/DmIOS.app/dm/app-version.json"))
                    self.assertEqual(actual, expected)
                    packaged = plistlib.loads(archive.read("Payload/DmIOS.app/Info.plist"))
                    self.assertEqual(packaged["CFBundleShortVersionString"], expected["marketing_version"])
                    self.assertEqual(packaged["CFBundleVersion"], expected["build_version"])
                    for key, icons in (("CFBundleIcons", PHONE_ICONS), ("CFBundleIcons~ipad", IPAD_ICONS)):
                        declared = packaged[key]["CFBundlePrimaryIcon"]["CFBundleIconFiles"]
                        self.assertEqual(declared, [name for name, _ in icons])
                        for name, size in icons:
                            with Image.open(BytesIO(archive.read("Payload/DmIOS.app/" + name + ".png"))) as icon:
                                self.assertEqual(icon.size, (size, size))
                                self.assertGreater(icon.getpixel((0, 0))[0], 240)


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
