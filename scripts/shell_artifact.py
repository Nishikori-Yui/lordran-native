"""Name shell build inputs consistently for local builds and GitHub Actions."""
import argparse
import hashlib
import os
from pathlib import Path
import re

from app_version import source_identity

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
    identity = source_identity(repo, env)
    version = (safe_tag(identity["source_version"]) if identity["source_kind"] == "release"
               else identity["source_version"])
    return f"{PREFIX}-{version}.zip"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--work", required=True, type=Path, help="Output directory under game/")
    parser.add_argument("--github-output", required=True, type=Path, help="Actions output file")
    args = parser.parse_args()
    repo = args.repo.resolve()
    work = args.work.resolve()
    if not work.is_relative_to((repo / "game").resolve()):
        parser.error("Shell work directory must be under game/")
    filename = shell_filename(repo)
    with args.github_output.open("a", encoding="utf-8") as output:
        output.write(f"filename={filename}\nartifact_name={filename[:-4]}\npath={work / filename}\n")


if __name__ == "__main__":
    main()
