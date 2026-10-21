"""Shell names identify revisions without becoming paths or Actions syntax."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import build_shell
import build_ipa_from_shell
import shell_artifact


class ShellNameTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "--quiet")
        self.git("-c", "user.name=Shell Test", "-c", "user.email=shell@example.invalid",
                 "commit", "--quiet", "--allow-empty", "-m", "fixture")
        self.short = self.git("rev-parse", "--short=12", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def test_development_branch_and_detached_head(self):
        expected = f"{shell_artifact.PREFIX}-dev-{self.short}.zip"
        self.assertEqual(shell_artifact.shell_filename(self.repo, {}), expected)
        self.git("checkout", "--quiet", "--detach")
        self.assertEqual(shell_artifact.shell_filename(self.repo, {}), expected)
        self.assertEqual(shell_artifact.shell_filename(
            self.repo, {"GITHUB_REF": "refs/heads/topic/feature"}), expected)

    def test_exact_local_tags_and_ci_tag_take_precedence(self):
        self.git("tag", "v0.2.0")
        expected = f"{shell_artifact.PREFIX}-v0.2.0.zip"
        self.assertEqual(shell_artifact.shell_filename(self.repo, {}), expected)
        self.git("tag", "v0.2.0-alias")
        with self.assertRaisesRegex(ValueError, "Multiple tags"):
            shell_artifact.shell_filename(self.repo, {})
        self.assertEqual(shell_artifact.shell_filename(
            self.repo, {"GITHUB_REF": "refs/tags/v0.2.0"}), expected)
        self.assertEqual(shell_artifact.shell_filename(
            self.repo, {"GITHUB_REF": "refs/heads/main"}),
            f"{shell_artifact.PREFIX}-dev-{self.short}.zip")

    def test_only_exact_tags_are_used_including_annotated_tags(self):
        self.git("-c", "user.name=Shell Test", "-c", "user.email=shell@example.invalid",
                 "tag", "-a", "v0.2.0", "-m", "release")
        self.assertEqual(shell_artifact.shell_filename(self.repo, {}),
                         f"{shell_artifact.PREFIX}-v0.2.0.zip")
        self.git("-c", "user.name=Shell Test", "-c", "user.email=shell@example.invalid",
                 "commit", "--quiet", "--allow-empty", "-m", "development")
        self.assertEqual(shell_artifact.shell_filename(self.repo, {}),
                         f"{shell_artifact.PREFIX}-dev-{self.git('rev-parse', '--short=12', 'HEAD')}.zip")

    def test_sanitization_is_bounded_safe_and_distinguishes_lossy_names(self):
        tags = ("release/test", "release-test", "release\\test", "v1.0 +?%:#*<>|\"", "v0.2.0.partial",
                "../..", "\nfilename=evil", "${{ github.token }}", "\u7248\u672c/\U0001f600",
                "a" * 300, "a" * 299 + "b", "CON", "-start", ".")
        names = []
        for tag in tags:
            with self.subTest(tag=tag):
                name = f"{shell_artifact.PREFIX}-{shell_artifact.safe_tag(tag)}.zip"
                self.assertRegex(name, r"^[A-Za-z0-9._-]+\.zip$")
                self.assertLess(len(name.encode("ascii")), 150)
                self.assertEqual(Path(name).name, name)
                self.assertEqual(name, f"{shell_artifact.PREFIX}-{shell_artifact.safe_tag(tag)}.zip")
                names.append(name)
        self.assertEqual(len(names), len(set(names)))
        with self.assertRaises(ValueError):
            shell_artifact.safe_tag("")

    def test_ci_metadata_matches_default_generator_name(self):
        output = self.repo / "github-output"
        work = self.repo / "game/naming"
        self.git("tag", "v0.2.0")
        self.git("tag", "releases/test+%")
        for ref in ("refs/tags/v0.2.0", "refs/tags/releases/test+%", "refs/heads/main"):
            with self.subTest(ref=ref), patch.dict(os.environ, GITHUB_REF=ref):
                output.unlink(missing_ok=True)
                subprocess.run([sys.executable, str(ROOT / "scripts/shell_artifact.py"),
                                "--repo", str(self.repo), "--work", str(work),
                                "--github-output", str(output)], check=True)
                fields = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(fields["filename"], shell_artifact.shell_filename(self.repo))
                self.assertEqual(fields["artifact_name"] + ".zip", fields["filename"])
                self.assertEqual(Path(fields["path"]), work / fields["filename"])


class ShellProducerTests(unittest.TestCase):
    def test_default_and_explicit_names_preserve_manifest_validation(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            (repo / "dm/ios").mkdir(parents=True)
            profile_dir = repo / "dm/games/01004AB00A260000"
            profile_dir.mkdir(parents=True)
            for name in ("shader_map.tsv", "pso_manifest.tsv", "c1_full.tsv"):
                (profile_dir / name).write_text("fixture\n")
            profile = SimpleNamespace(id=profile_dir.name, table=lambda n: profile_dir / n,
                                      bundle_id=lambda _: "org.example.shell",
                                      get=lambda _: "public.app-category.games", words=lambda _: [])
            manifest = dict(schema=1, source="a" * 64, chain="123456789abc", shader_keys=[])
            version = dict(schema=1, source_version="v0.2.0", source_kind="release", commit="b" * 40,
                           marketing_version="0.2.0", build_version="1.2.0")
            original_copy = shutil.copyfile

            def copy_file(source, target, **kwargs):
                if str(source).startswith("/System/Library/Fonts/"):
                    Path(target).write_bytes(b"synthetic font")
                else:
                    return original_copy(source, target, **kwargs)

            def run(command, **kwargs):
                if command[0] == "xcodebuild":
                    work = Path(kwargs["env"]["DM_ROOT"])
                    app = work / "products/DmIOS.app"
                    shutil.copytree(Path(kwargs["cwd"]) / "Gen/dm", app / "dm")
                    (app / "DmIOS").write_bytes(b"synthetic executable")
                    (app / "Info.plist").write_bytes(plistlib.dumps(dict(
                        CFBundleIdentifier="org.example.shell", CFBundleSupportedPlatforms=["iPhoneOS"],
                        CFBundleShortVersionString=kwargs["env"]["DM_MARKETING_VERSION"],
                        CFBundleVersion=kwargs["env"]["DM_BUILD_VERSION"])))
                elif any(str(arg).endswith("make_ext_font.py") for arg in command):
                    Path(command[-1]).write_bytes(b"synthetic font")
                return SimpleNamespace(stdout="", returncode=0)

            for explicit in (False, True):
                with self.subTest(explicit=explicit):
                    work = repo / "game" / str(explicit)
                    output = work / ("chosen.zip" if explicit else
                                     "LordranNative-shell-build-input-v0.2.0.zip")
                    argv = ["build_shell.py", "--work", str(work)]
                    if explicit:
                        argv += ["--out", str(output)]
                    partial_names = []
                    archive_class = zipfile.ZipFile

                    def open_archive(path, *args, **kwargs):
                        partial_names.append(Path(path).name)
                        return archive_class(path, *args, **kwargs)

                    with patch.dict(sys.modules, game=SimpleNamespace(load=lambda: profile)), \
                            patch.object(build_shell, "__file__", str(repo / "scripts/build_shell.py")), \
                            patch.object(sys, "argv", argv), \
                            patch.object(build_shell, "shell_filename", return_value=output.name) as naming, \
                            patch.object(build_shell, "make_manifest", return_value=manifest), \
                            patch.object(build_shell, "resolve_app_version", return_value=version), \
                            patch.object(build_shell, "check_c1_table"), \
                            patch.object(build_shell.shutil, "copyfile", side_effect=copy_file), \
                            patch.object(build_shell.zipfile, "ZipFile", side_effect=open_archive), \
                            patch.object(build_shell.subprocess, "run", side_effect=run):
                        build_shell.main()
                    self.assertEqual(naming.call_count, 0 if explicit else 1)
                    self.assertTrue(output.is_file())
                    self.assertEqual(partial_names, [output.name + ".partial"])
                    self.assertFalse(output.with_suffix(".zip.partial").exists())
                    with zipfile.ZipFile(output) as archive:
                        self.assertEqual(json.loads(archive.read("Payload/DmIOS.app/dm/shell.json")), manifest)
                        version = json.loads(archive.read("Payload/DmIOS.app/dm/app-version.json"))
                        self.assertEqual(version["source_version"], "v0.2.0")
                        self.assertEqual(version["marketing_version"], "0.2.0")
                        self.assertEqual(version["build_version"], "1.2.0")
                    with patch.object(build_ipa_from_shell, "check_manifest",
                                      side_effect=ValueError("Shell source mismatch")) as check:
                        with self.assertRaisesRegex(ValueError, "source mismatch"):
                            build_ipa_from_shell.validate_shell(output, repo, profile)
                    check.assert_called_once_with(manifest, repo, profile)
                    legacy = output.with_name(shell_artifact.PREFIX + ".zip")
                    output.rename(legacy)
                    with patch.object(build_ipa_from_shell, "check_manifest") as check, \
                            patch.object(build_ipa_from_shell, "check_c1_table"):
                        build_ipa_from_shell.validate_shell(legacy, repo, profile)
                    check.assert_called_once_with(manifest, repo, profile)


if __name__ == "__main__":
    unittest.main()
