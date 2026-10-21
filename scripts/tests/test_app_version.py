"""Apple app versions track tags while diagnostics retain exact source identity."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import app_version
import shell_artifact

ROOT = Path(__file__).resolve().parents[2]


class AppVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.git("init", "--quiet")
        self.git("-c", "user.name=App Version Test", "-c", "user.email=app@example.invalid",
                 "commit", "--quiet", "--allow-empty", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def test_release_stable_prerelease_and_build_metadata(self):
        for tag, apple in (("v0.2.0", "0.2.0"), ("1.12.3", "1.12.3"),
                           ("v0.2.0-rc.1", "0.2.0"), ("v0.2.0+build.7", "0.2.0"),
                           ("v0.2.0-rc.1+build.7", "0.2.0")):
            with self.subTest(tag=tag):
                self.git("tag", tag)
                identity = app_version.resolve(self.repo, {"GITHUB_REF": "refs/tags/" + tag})
                self.assertEqual(identity["source_version"], tag)
                self.assertEqual(identity["source_kind"], "release")
                self.assertEqual(identity["commit"], self.commit)
                self.assertEqual(identity["marketing_version"], apple)
                major, rest = apple.split(".", 1)
                self.assertEqual(identity["build_version"], str(int(major) + 1) + "." + rest)
                self.assertEqual(shell_artifact.shell_filename(
                    self.repo, {"GITHUB_REF": "refs/tags/" + tag}),
                    f"{shell_artifact.PREFIX}-{shell_artifact.safe_tag(tag)}.zip")
                self.assertEqual(app_version.validate_embedded(identity), identity)

    def test_development_ignores_stale_tags_and_preserves_commit_identity(self):
        self.git("tag", "v9.9.9")
        development = app_version.resolve(self.repo, {"GITHUB_REF": "refs/heads/topic"})
        self.assertEqual(development["source_version"], f"dev-{self.commit[:12]}")
        self.assertEqual((development["marketing_version"], development["build_version"]),
                         ("0.0.0", "1.0.0"))
        self.assertEqual(app_version.validate_embedded(development), development)
        self.assertEqual(shell_artifact.shell_filename(
            self.repo, {"GITHUB_REF": "refs/heads/topic"}),
            f"{shell_artifact.PREFIX}-dev-{self.commit[:12]}.zip")
        self.git("tag", "v9.9.9-alias")
        with self.assertRaisesRegex(ValueError, "Multiple tags"):
            app_version.resolve(self.repo, {})

    def test_no_git_source_fallback_ignores_ancestor_and_stale_build_metadata(self):
        source = self.repo / "source-only"
        (source / "scripts").mkdir(parents=True)
        (source / "scripts/source.py").write_text("value = 1\n")
        stale = source / "dm/ios/Gen/dm/app-version.json"
        stale.parent.mkdir(parents=True)
        stale.write_text('{"source_version":"v99.0.0"}')
        identity = app_version.resolve(source, {})
        self.assertEqual(identity["source_kind"], "source-archive")
        self.assertEqual(identity["commit"], "")
        self.assertTrue(identity["source_version"].startswith("dev-source-"))
        self.assertEqual(app_version.validate_embedded(identity), identity)
        stale.write_text('{"source_version":"v98.0.0"}')
        (source / "dm/ios/Sources").mkdir()
        (source / "dm/ios/Sources/Info.plist").write_text("generated plist")
        self.assertEqual(app_version.resolve(source, {}), identity)
        self.assertIn(identity["source_version"], shell_artifact.shell_filename(source, {}))
        (source / "scripts/source.py").write_bytes(b"value = 1\r\n")
        self.assertEqual(app_version.resolve(source, {}), identity)
        (source / "scripts/source.py").write_text("value = 2\n")
        self.assertNotEqual(app_version.resolve(source, {}), identity)

    def test_non_semver_tag_uses_numeric_fallback_and_preserves_full_tag(self):
        for tag in ("release/test", "v1", "v1.2", "v01.2.3", "v1.2.3-", "v1.2.3+", "v1.2.3-01"):
            with self.subTest(tag=tag):
                self.git("tag", tag)
                value = app_version.resolve(self.repo, {"GITHUB_REF": "refs/tags/" + tag})
                self.assertEqual(value["source_version"], tag)
                self.assertEqual((value["marketing_version"], value["build_version"]), ("0.0.0", "1.0.0"))
                self.assertEqual(app_version.validate_embedded(value), value)
        for malformed in ("v1.2.3-rc..1", "v1.2.3+build..7"):
            self.assertEqual(app_version.apple_versions(malformed), ("0.0.0", "1.0.0"))
        for tag in ("v10000.0.0", "v1.100.0", "v1.2.100"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "components"):
                app_version.apple_versions(tag)
        self.assertEqual(app_version.apple_versions("v9998.99.99"), ("9998.99.99", "9999.99.99"))

    def test_prebuilt_shell_keeps_embedded_identity_without_git(self):
        self.git("tag", "v0.2.0-rc.1")
        identity = app_version.resolve(self.repo, {"GITHUB_REF": "refs/tags/v0.2.0-rc.1"})
        app_version.write_metadata(self.repo / "prebuilt/app-version.json", identity)
        metadata = json.loads((self.repo / "prebuilt/app-version.json").read_text())
        self.assertEqual(app_version.validate_embedded(metadata)["source_version"], "v0.2.0-rc.1")
        legacy = app_version.legacy_identity(
            {"source": "a" * 64}, {"CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"})
        self.assertEqual(legacy["source_kind"], "legacy-shell")
        self.assertEqual(legacy["source_version"], "legacy-shell-source-sha256:" + "a" * 64)
        with self.assertRaisesRegex(ValueError, "valid source fingerprint"):
            app_version.legacy_identity({}, {})

    def test_tag_ref_must_match_the_checked_out_commit(self):
        self.git("tag", "v0.2.0")
        self.git("-c", "user.name=App Version Test", "-c", "user.email=app@example.invalid",
                 "commit", "--quiet", "--allow-empty", "-m", "next development")
        with self.assertRaisesRegex(ValueError, "does not point"):
            app_version.resolve(self.repo, {"GITHUB_REF": "refs/tags/v0.2.0"})
        identity = app_version.resolve(self.repo, {})
        self.assertEqual(identity["source_kind"], "development")
        with self.assertRaisesRegex(ValueError, "Cannot resolve"):
            app_version.resolve(self.repo, {"GITHUB_REF": "refs/tags/v-does-not-exist"})

    def test_modified_tagged_checkout_is_a_dirty_development_build(self):
        self.git("tag", "v0.2.0")
        source = self.repo / "scripts/source.py"
        source.parent.mkdir()
        source.write_text("value = 1\n")
        identity = app_version.resolve(self.repo, {"GITHUB_REF": "refs/tags/v0.2.0"})
        self.assertEqual(identity["source_kind"], "development")
        self.assertEqual(identity["base_tag"], "v0.2.0")
        self.assertTrue(identity["source_version"].startswith(f"dev-{self.commit[:12]}-dirty-"))
        self.assertEqual((identity["marketing_version"], identity["build_version"]), ("0.0.0", "1.0.0"))
        self.assertEqual(app_version.validate_embedded(identity), identity)
        self.assertIn(identity["source_version"], shell_artifact.shell_filename(self.repo, {"GITHUB_REF": "refs/tags/v0.2.0"}))
        source.write_text("value = 2\n")
        self.assertNotEqual(app_version.resolve(self.repo, {}), identity)

    @unittest.skipIf(os.name == "nt", "Native iOS packaging entry points run in Bash on macOS")
    def test_native_ios_and_simulator_refresh_metadata_before_packaging(self):
        profile = "dm/games/01004AB00A260000/"
        for relative in ("scripts/app_version.py", "scripts/shell_common.py", "dm/games/game.py",
                         "dm/ios/tools/build_ipa.sh", profile + "game.tsv",
                         profile + "dmsh_chain.h", profile + "c1_full.tsv"):
            destination = self.repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        (self.repo / ".gitignore").write_text("/game/\n__pycache__/\n")
        self.git("add", ".")
        self.git("-c", "user.name=App Version Test", "-c", "user.email=app@example.invalid",
                 "commit", "--quiet", "-m", "native build fixture")
        for tag in ("v0.2.0", "v0.2.0-rc.1+build.7"):
            self.git("tag", tag)
        work = self.repo / "game/native"
        variants = [("refs/tags/v0.2.0", "release"),
                    ("refs/tags/v0.2.0-rc.1+build.7", "release"),
                    ("refs/heads/development", "development"), (None, "source-archive")]
        for ref, kind in variants:
            if ref is None:
                shutil.rmtree(self.repo / ".git")
            env = dict(os.environ, GITHUB_REF=ref or "", GAME="01004AB00A260000",
                       W=str(work), DM_DISPLAY_NAME="Synthetic App")
            expected = app_version.resolve(self.repo, env)
            for target, folder in (("device", "ios"), ("simulator", "ios-simulator")):
                with self.subTest(ref=ref, target=target):
                    metadata = work / f"build/{folder}/pkg/app-version.json"
                    app_version.write_metadata(metadata, {"source_version": "stale-release"})
                    result = subprocess.run(["bash", str(self.repo / "dm/ios/tools/build_ipa.sh")],
                                            env=dict(env, DM_IOS_TARGET=target), capture_output=True, text=True)
                    # Stop before Xcode or private inputs, after the real version handoff.
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("no rewritten module", result.stdout)
                    actual = json.loads(metadata.read_text())
                    self.assertEqual(actual, expected)
                    self.assertEqual(actual["source_kind"], kind)

if __name__ == "__main__":
    unittest.main()
