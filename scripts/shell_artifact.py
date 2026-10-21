"""Name shell build inputs consistently for local builds and GitHub Actions."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess

PREFIX = "LordranNative-shell-build-input"


def safe_tag(tag):
    if not tag:
        raise ValueError("Shell release tag must not be empty")
    # Keep ordinary tags verbatim; hash lossy/truncated names to avoid aliases.
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", tag)
    if slug != tag or len(slug) > 80:
        slug = slug[:64] + "-" + hashlib.sha256(tag.encode("utf-8")).hexdigest()[:12]
    return slug


def shell_filename(repo, environ=None):
    env = os.environ if environ is None else environ

    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

    ref = env.get("GITHUB_REF", "")
    if ref.startswith("refs/tags/"):
        version = safe_tag(ref[len("refs/tags/"):])
    elif ref:
        version = "dev-" + git("rev-parse", "--short=12", "HEAD")
    else:
        tags = git("tag", "--points-at", "HEAD").splitlines()
        if len(tags) > 1:
            raise ValueError("Multiple tags at HEAD; choose --out or set GITHUB_REF=refs/tags/<tag>")
        version = safe_tag(tags[0]) if tags else "dev-" + git("rev-parse", "--short=12", "HEAD")
    return f"{PREFIX}-{version}.zip"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", required=True, type=Path, help="Output directory under game/")
    parser.add_argument("--github-output", required=True, type=Path, help="Actions output file")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    work = args.work.resolve()
    if not work.is_relative_to((repo / "game").resolve()):
        parser.error("Shell work directory must be under game/")
    filename = shell_filename(repo)
    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"filename={filename}\nartifact_name={filename[:-4]}\npath={work / filename}\n")


if __name__ == "__main__":
    main()
