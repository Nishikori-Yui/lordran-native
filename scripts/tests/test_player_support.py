"""Check player support without SDK installation, game files, or a GPU."""
import argparse
import json
import plistlib
import struct
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import player_support as support
import player_support_common as common
import shell_common
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "dm/games"))
from game import Game


def executable(target=2, cpu=0x0100000C):
    command = struct.pack("<6I", 0x32, 24, target, 26 << 16, 26 << 16, 0)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, len(command), 0, 0) + command


class SupportTests(unittest.TestCase):
    CHAIN = "123456789abc"
    KEY = "12345678" + "abcdef01"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "checkout with spaces"
        self.folder = self.repo / "game" / "玩家 inputs"
        self.folder.mkdir(parents=True)
        self.game_dir = self.repo / "dm/games/01004AB00A260000"
        self.game_dir.mkdir(parents=True)
        values = dict(romfs_marker="marker.bhd5", ipa="Game.ipa", package="v0")
        self.game = SimpleNamespace(
            id=self.game_dir.name, dir=self.game_dir,
            get=values.__getitem__, table=lambda n: self.game_dir / n,
            builds=lambda: {"v0": {"main": "registered"}})
        self.game.bundle_id = lambda override=None: Game.bundle_id(self.game, override)
        for name in shell_common.SOURCE_PATHS:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("source\n")
        (self.repo / "dm/tools/nx_extract/nx_extract.csproj").write_text(
            "<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>")
        (self.game_dir / "dmsh_chain.h").write_text(f'#define DMSH_CHAIN "{self.CHAIN}"\n')
        (self.game_dir / "c1_full.tsv").write_text(f"# chain b-{self.CHAIN} date\n")
        (self.game_dir / "shader_map.tsv").write_text(f"v0\tvs\t0\t{self.KEY}\n")
        for context in (patch.object(support, "REPO", self.repo),
                        patch.object(common, "REPO", self.repo),
                        patch.object(support, "profile", return_value=self.game)):
            context.start()
            self.addCleanup(context.stop)

    def artifact(self, *, target=2, source=False, manifest=False, edits=None, duplicate=None):
        root = "Payload/DmIOS.app/" if target == 2 else "DmIOS.app/"
        metadata = dict(chain=self.CHAIN, chain_metal="xcrun -sdk iphoneos metal")
        if target == 7:
            metadata["metal_platform"] = "iphonesimulator"
        files = {
            "Info.plist": plistlib.dumps(dict(
                CFBundleExecutable="DmIOS",
                CFBundleIdentifier="dev.example.game",
                CFBundleSupportedPlatforms=["iPhoneOS" if target == 2 else "iPhoneSimulator"])),
            "DmIOS": executable(target),
            "romfs/marker.bhd5": b"FAKE_GAME_MARKER",
            "dm/c1_full.tsv": (self.game_dir / "c1_full.tsv").read_bytes(),
            "dm/shader_map.tsv": (self.game_dir / "shader_map.tsv").read_bytes(),
            f"msl/b-{self.CHAIN}/{self.KEY}_b.json": json.dumps(metadata).encode(),
            f"msl/b-{self.CHAIN}/{self.KEY}_b.metallib": (
                b"#include <metal_stdlib>\nusing namespace metal;\n" + b"source" * 12
                if source else b"MTLB" + b"\0" * 20),
        }
        if manifest:
            files["dm/shell.json"] = json.dumps(shell_common.make_manifest(self.repo, self.game)).encode()
            files["Frameworks/Guest.framework/Guest"] = executable(target)
            files["Frameworks/Guest.framework/Info.plist"] = plistlib.dumps(
                dict(CFBundleIdentifier="dev.example.game.guest"))
        files.update(edits or {})
        path = self.folder / "candidate.ipa"
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, data in files.items():
                if data is not None:
                    archive.writestr(root + name, data)
            if duplicate:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr(root + duplicate, files[duplicate])
        return path

    def test_native_and_source_shader_artifacts_are_structural_checks(self):
        for source in (False, True):
            result = support.verify(self.artifact(source=source), full_crc=True)
            self.assertEqual(result["status"], "artifact-structure-verified")
            self.assertEqual(result["runtime_compiled_sources"], int(source))
            self.assertEqual(result["archive_crc"], "passed")
            self.assertIn("Not tested", result["runtime"])
            self.assertFalse(result["executable"]["signature_load_command"])

    def test_simulator_is_distinct_from_device(self):
        path = self.artifact(target=7)
        with self.assertRaisesRegex(ValueError, "not the requested device"):
            support.verify(path)
        self.assertEqual(support.verify(path, target="simulator")["target"], "simulator")

    def test_malformed_and_wrong_architecture_executables(self):
        for data in (b"not a Mach-O", executable(cpu=0x01000007),
                     executable()[:40], executable(target=1)):
            with self.subTest(header=data[:4]):
                with self.assertRaises(ValueError):
                    support.verify(self.artifact(edits={"DmIOS": data}))

    def test_universal_executable_selects_arm64(self):
        thin = executable()
        fat = struct.pack(">II", 0xCAFEBABE, 1) + struct.pack(
            ">IIIII", 0x0100000C, 0, 32, len(thin), 2)
        fat = fat.ljust(32, b"\0") + thin
        result = support.verify(self.artifact(edits={"DmIOS": fat}))
        self.assertEqual(result["executable"]["architecture"], "arm64")

    def test_stale_chain_platform_and_incomplete_shader_payload_fail(self):
        prefix = f"msl/b-{self.CHAIN}/{self.KEY}_b"
        variants = [
            {"dm/c1_full.tsv": b"# chain b-000000000000 date\n"},
            {prefix + ".json": json.dumps(dict(chain="000000000000")).encode()},
            {prefix + ".json": json.dumps(dict(chain=self.CHAIN,
                                               metal_platform="iphonesimulator")).encode()},
            {prefix + ".metallib": None},
            {prefix + ".metallib": b"not a valid shader source payload"},
            {"romfs/marker.bhd5": None},
        ]
        for edits in variants:
            with self.subTest(edits=list(edits)):
                with self.assertRaises((ValueError, KeyError)):
                    support.verify(self.artifact(edits=edits))

    def test_shell_manifest_checks_and_guest_platform(self):
        path = self.artifact(manifest=True)
        support.verify(path, match_source=True)
        (self.repo / shell_common.SOURCE_PATHS[0]).write_text("changed source\n")
        support.verify(path)
        with self.assertRaisesRegex(ValueError, "source mismatch"):
            support.verify(path, match_source=True)
        with self.assertRaisesRegex(ValueError, "platforms disagree"):
            support.verify(self.artifact(manifest=True, edits={
                "Frameworks/Guest.framework/Guest": executable(7)}))

    def test_embedded_manifest_schema_is_checked_without_source_matching(self):
        manifest = shell_common.make_manifest(self.repo, self.game)
        for change in ({"schema": 999}, {"source": "not-a-fingerprint"}):
            with self.subTest(change=change):
                invalid = dict(manifest, **change)
                with self.assertRaisesRegex(ValueError, "manifest schema or source"):
                    support.verify(self.artifact(manifest=True, edits={
                        "dm/shell.json": json.dumps(invalid).encode()}))

    def test_guest_identity_must_follow_the_actual_app_identity(self):
        with self.assertRaisesRegex(ValueError, "Bundle ID must derive"):
            support.verify(self.artifact(manifest=True, edits={
                "Frameworks/Guest.framework/Info.plist": plistlib.dumps(
                    dict(CFBundleIdentifier="dev.example.other.guest"))}))

    def test_duplicate_paths_private_keys_and_oversized_metadata_fail(self):
        for kwargs in (
            {"duplicate": "DmIOS"},
            {"edits": {"../outside": b"x"}},
            {"edits": {"prod.keys": b"never read"}},
            {"edits": {"Info.plist": b"x" * (support.MAX_METADATA + 1)}},
            {"edits": {"Info.plist": plistlib.dumps(["invalid root"])}},
            {"edits": {f"msl/b-{self.CHAIN}/{self.KEY}_b.json": b"[]"}},
        ):
            with self.subTest(kwargs=list(kwargs)):
                with self.assertRaises(ValueError):
                    support.verify(self.artifact(**kwargs))

    def test_full_crc_detects_damage_outside_metadata(self):
        path = self.artifact()
        path.write_bytes(path.read_bytes().replace(b"FAKE_GAME_MARKER", b"BROKEN__MARKER__"))
        with self.assertRaisesRegex(ValueError, "CRC"):
            support.verify(path, full_crc=True)

    def doctor_contexts(self, sdk="10.0.100 [tools]", platform_name="darwin"):
        def probe(command, env=None):
            return sdk if command[:2] == ["dotnet", "--list-sdks"] else "26.0"
        return (
            patch.object(support.sys, "platform", platform_name),
            patch.object(support.platform, "machine", return_value="arm64"),
            patch.object(support.source, "check_prereqs"),
            patch.object(support.source, "missing_python_modules", return_value=[]),
            patch.object(support, "verify_spirv_cross", return_value="spirv-cross"),
            patch.object(support, "probe", side_effect=probe),
            patch.object(support.shell_builder, "check_tools", return_value="dotnet"),
        )

    def run_doctor(self, **kwargs):
        contexts = self.doctor_contexts(**kwargs.pop("context", {}))
        for context in contexts:
            context.start()
            self.addCleanup(context.stop)
        return support.doctor(work_dir=self.folder, **kwargs)

    def test_doctor_collects_actual_sdk_and_dependency_failures(self):
        result = self.run_doctor()
        self.assertEqual(result["status"], "environment-ready")
        with patch.object(support.source, "missing_python_modules", return_value=["capstone"]), \
                patch.object(support, "probe", return_value="8.0.400 [tools]"):
            result = support.doctor(work_dir=self.folder)
        failures = [c["name"] for c in result["checks"] if c["status"] == "fail"]
        self.assertIn("python-modules", failures)
        self.assertIn("dotnet-sdk", failures)

    def test_shell_doctor_uses_consumer_validation_without_extracting(self):
        with patch.object(support.shell_builder, "validate_shell", side_effect=ValueError("Shell source mismatch")) as validate:
            result = self.run_doctor(route="shell", shell=self.folder / "shell.zip",
                                     context={"platform_name": "win32"})
        validate.assert_called_once()
        self.assertEqual(result["status"], "environment-incomplete")
        self.assertFalse((self.folder / "extract").exists())

    def test_shell_doctor_reports_invalid_archive_as_a_check_failure(self):
        with patch.object(support.shell_builder, "validate_shell", side_effect=zipfile.BadZipFile("invalid ZIP")):
            result = self.run_doctor(route="shell", shell=self.folder / "shell.zip",
                                     context={"platform_name": "win32"})
        self.assertEqual(result["status"], "environment-incomplete")
        shell_check = next(c for c in result["checks"] if c["name"] == "shell-compatibility")
        self.assertEqual(shell_check["status"], "fail")

    def build_args(self, **values):
        keys, shell = self.folder / "prod.keys", self.folder / "shell.zip"
        keys.touch()
        shell.touch()
        defaults = dict(nsp_dir=self.folder, keys=keys, shell=None, package=None, out=None,
                        replace=False, dry_run=True, keep_extracted=False, spirv_cross_sha256=None)
        defaults.update(values)
        return argparse.Namespace(**defaults)

    def test_build_plan_preserves_unicode_paths_and_never_uses_a_shell(self):
        with patch.object(support.sys, "platform", "darwin"), \
                patch.object(support.subprocess, "run") as run:
            result = support.build(self.build_args())
        run.assert_not_called()
        self.assertIn(str(self.folder.resolve()), result["command"])
        self.assertTrue(result["command"][1].endswith("build_ipa_from_nsp.py"))
        self.assertTrue(result["output"].endswith(".ipa"))

    def test_windows_build_delegates_to_existing_shell_packer(self):
        args = self.build_args(shell=self.folder / "shell.zip", dry_run=False)
        with patch.object(support.sys, "platform", "win32"), \
                patch.object(support, "doctor", return_value={"status": "environment-ready"}), \
                patch.object(support, "verify", return_value={"status": "artifact-structure-verified"}) as verify, \
                patch.object(support.subprocess, "run") as run:
            result = support.build(args)
        command = run.call_args.args[0]
        self.assertTrue(command[1].endswith("build_ipa_from_shell.py"))
        self.assertIn("--shell", command)
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertEqual(result["status"], "build-complete")
        verify.assert_called_once()

    def test_failed_preflight_and_existing_output_do_not_launch_a_build(self):
        with patch.object(support.sys, "platform", "darwin"), \
                patch.object(support, "doctor", return_value={"status": "environment-incomplete"}), \
                patch.object(support.subprocess, "run") as run:
            support.build(self.build_args(dry_run=False))
            run.assert_not_called()
        output = self.folder / "old.ipa"
        output.write_bytes(b"keep previous candidate")
        with patch.object(support.sys, "platform", "darwin"):
            with self.assertRaisesRegex(ValueError, "already exists"):
                support.build(self.build_args(out=output))
        self.assertEqual(output.read_bytes(), b"keep previous candidate")


if __name__ == "__main__":
    unittest.main()
