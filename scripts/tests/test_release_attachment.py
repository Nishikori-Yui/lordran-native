"""Exercise the workflow's release step without uploading an artifact."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from urllib.parse import quote

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shell_artifact import PREFIX, shell_filename


@unittest.skipIf(os.name == "nt", "The release job runs in Bash on Ubuntu")
class ReleaseAttachmentTests(unittest.TestCase):
    def setUp(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/build-shell.yml"
        step = workflow.read_text().split("      - name: Attach shell to GitHub release\n", 1)[1]
        self.environment, script = step.split("        run: |\n", 1)
        lines = []
        for line in script.splitlines():
            if line and not line.startswith("          "):
                break
            lines.append(line)
        self.script = textwrap.dedent("\n".join(lines))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = self.root / "calls.jsonl"
        tools = self.root / "bin"
        tools.mkdir()
        gh = tools / "gh"
        gh.write_text("#!/usr/bin/env python3\n" + textwrap.dedent('''\
            import json
            import os
            import sys
            from pathlib import Path
            args = sys.argv[1:]
            with open(os.environ["GH_TEST_CALLS"], "a") as output:
                output.write(json.dumps({"args": args, "repo": os.environ.get("GH_REPO")}) + "\\n")
            if args[0] == "api":
                status = os.environ["GH_TEST_STATUS"]
                if status == "transport":
                    print("Test transport failure", file=sys.stderr)
                    sys.exit(1)
                print("HTTP/2.0 " + status + " Test response")
                sys.exit(0 if status == "200" else 1)
            if args[:2] == ["release", "upload"]:
                if not Path(args[-1]).is_file():
                    sys.exit(98)
                sys.exit(int(os.environ.get("GH_TEST_UPLOAD_EXIT", "0")))
            sys.exit(99)
            '''))
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        GH_REPO="test-owner/test-repo", GITHUB_REF_NAME="v1.2.3",
                        SHELL_FILENAME=PREFIX + "-v1.2.3.zip",
                        GH_TOKEN="test-token", GH_TEST_CALLS=str(self.calls))

    def run_step(self, status, **settings):
        env = dict(self.env, GH_TEST_STATUS=status, **settings)
        env["SHELL_FILENAME"] = shell_filename(self.root, {
            "GITHUB_REF": "refs/tags/" + env["GITHUB_REF_NAME"]})
        artifact = self.root / "game/ci-shell" / env["SHELL_FILENAME"]
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.touch()
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", self.script],
                                cwd=self.root, env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.calls.unlink()
        return result, calls

    def test_existing_release_uploads_without_checkout(self):
        self.assertIn("GH_REPO: ${{ github.repository }}", self.environment)
        result, calls = self.run_step("200")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["repo"] for call in calls], ["test-owner/test-repo"] * 2)
        self.assertEqual(calls[0]["args"], [
            "api", "--include", "--silent", "repos/test-owner/test-repo/releases/tags/v1.2.3"])
        self.assertEqual(calls[1]["args"], [
            "release", "upload", "--clobber", "--", "v1.2.3",
            "game/ci-shell/LordranNative-shell-build-input-v1.2.3.zip"])

    def test_missing_release_skips_upload(self):
        result, calls = self.run_step("404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("No release exists", result.stdout)

    def test_query_failures_are_not_treated_as_missing_releases(self):
        for status in ("401", "403", "500", "503", "transport"):
            with self.subTest(status=status):
                result, calls = self.run_step(status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                self.assertNotIn("No release exists", result.stdout)
                self.assertIn("::error::", result.stderr)

    def test_upload_failure_fails_the_job(self):
        result, calls = self.run_step("200", GH_TEST_UPLOAD_EXIT="7")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(len(calls), 2)

    def test_tag_is_encoded_for_lookup_and_preserved_for_upload(self):
        tag = "-releases/test +?%"
        result, calls = self.run_step("200", GITHUB_REF_NAME=tag)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0]["args"][-1],
                         "repos/test-owner/test-repo/releases/tags/" + quote(tag, safe=""))
        self.assertEqual(calls[1]["args"][4], tag)
        self.assertEqual(Path(calls[1]["args"][5]).name, shell_filename(self.root, {
            "GITHUB_REF": "refs/tags/" + tag}))

    def test_workflow_passes_the_same_metadata_through_all_stages(self):
        workflow = (Path(__file__).resolve().parents[2] /
                    ".github/workflows/build-shell.yml").read_text()
        for expected in (
                "filename: ${{ steps.shell.outputs.filename }}",
                "artifact_name: ${{ steps.shell.outputs.artifact_name }}",
                "SHELL_PATH: ${{ steps.shell.outputs.path }}", '--out "$SHELL_PATH"',
                "name: ${{ steps.shell.outputs.artifact_name }}",
                "path: ${{ steps.shell.outputs.path }}",
                "name: ${{ needs.build-shell.outputs.artifact_name }}",
                "SHELL_FILENAME: ${{ needs.build-shell.outputs.filename }}"):
            self.assertIn(expected, workflow)


if __name__ == "__main__":
    unittest.main()
