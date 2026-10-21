"""Resolve Apple-safe app versions and preserve the full source build identity."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


PRERELEASE_ID = r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER = re.compile(
    r"^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    rf"(?:-({PRERELEASE_ID}(?:\.{PRERELEASE_ID})*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def apple_versions(source_version):
    """Map SemVer tags to Apple's numeric plist version fields."""
    match = SEMVER.fullmatch(source_version)
    if not match:
        return "0.0.0", "1.0.0"
    major, minor, patch = map(int, match.group(1, 2, 3))
    if major > 9998 or minor > 99 or patch > 99:
        raise ValueError("Apple app version components must be major 0-9998 and minor/patch 0-99")
    numeric = f"{major}.{minor}.{patch}"
    # Apple's build version requires a positive first component.
    return numeric, f"{major + 1}.{minor}.{patch}"


def archive_identity(repo):
    from shell_common import GENERATED_FILE_PATHS, generated_directory
    digest = hashlib.sha256()
    count = 0
    for folder in ("dm", "scripts"):
        for parent, dirs, files in os.walk(repo / folder):
            dirs[:] = sorted(d for d in dirs if not generated_directory(d) and d != "tests")
            for name in sorted(files):
                path = Path(parent) / name
                relative = path.relative_to(repo).as_posix()
                if relative in GENERATED_FILE_PATHS or (path.suffix not in {
                    ".c", ".m", ".h", ".inc", ".S", ".py", ".cs", ".csproj", ".sh",
                    ".yml", ".plist", ".mk", ".xcconfig", ".tsv", ".json", ".lock"
                } and name != "Makefile"):
                    continue
                digest.update(relative.encode() + b"\0" + path.read_bytes().replace(b"\r\n", b"\n") + b"\0")
                count += 1
    if not count:
        raise ValueError("No source files available to identify this source archive")
    fingerprint = digest.hexdigest()
    return {"source_version": f"dev-source-{fingerprint[:12]}", "source_kind": "source-archive",
            "commit": "", "source_fingerprint": fingerprint}


def source_identity(repo, environ=None):
    """Resolve the exact source tag or a dev-short-commit fallback."""
    env = os.environ if environ is None else environ
    repo = Path(repo).resolve()
    if not (repo / ".git").exists():
        # Do not discover an unrelated ancestor checkout around an extracted source tree.
        return archive_identity(repo)

    def git(*args):
        try:
            return subprocess.check_output(
                ["git", "-C", str(repo), *args], encoding="utf-8", stderr=subprocess.DEVNULL
            ).strip()
        except (OSError, subprocess.CalledProcessError) as error:
            raise ValueError(f"Cannot resolve the app source version from Git in {repo}") from error

    commit = git("rev-parse", "HEAD")
    if not COMMIT.fullmatch(commit):
        raise ValueError("Git returned an invalid full commit ID")
    ref = env.get("GITHUB_REF", "")
    if ref.startswith("refs/tags/"):
        source_version = ref[len("refs/tags/"):]
        if git("rev-parse", "--verify", ref + "^{commit}") != commit:
            raise ValueError("Release tag does not point at the checked-out commit")
        kind = "release"
    elif ref:
        source_version = f"dev-{commit[:12]}"
        kind = "development"
    else:
        tags = git("tag", "--points-at", "HEAD").splitlines()
        if len(tags) > 1:
            raise ValueError("Multiple tags at HEAD; set GITHUB_REF to the exact tag to select a release")
        source_version = tags[0] if tags else f"dev-{commit[:12]}"
        kind = "release" if tags else "development"
    identity = {"source_version": source_version, "source_kind": kind, "commit": commit}
    if git("status", "--porcelain", "--untracked-files=all", "--", "dm", "scripts"):
        fingerprint = archive_identity(repo)["source_fingerprint"]
        identity.update(source_version=f"dev-{commit[:12]}-dirty-{fingerprint[:12]}",
                        source_kind="development", dirty=True, source_fingerprint=fingerprint)
        if kind == "release":
            identity["base_tag"] = source_version
    return identity


def resolve(repo, environ=None):
    """Resolve source identity and its Apple-compatible version fields."""
    identity = source_identity(repo, environ)
    marketing, build = (apple_versions(identity["source_version"])
                        if identity["source_kind"] == "release" else ("0.0.0", "1.0.0"))
    return dict(identity, **{
        "schema": 1,
        "marketing_version": marketing,
        "build_version": build,
    })


def validate_embedded(value):
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise ValueError("Invalid embedded app version metadata")
    source = value.get("source_version")
    kind = value.get("source_kind")
    commit = value.get("commit")
    if not isinstance(source, str) or not source or not isinstance(commit, str):
        raise ValueError("Invalid embedded app source identity")
    if kind in {"release", "development"} and not COMMIT.fullmatch(commit):
        raise ValueError("Invalid embedded app source commit")
    if kind == "release":
        expected = apple_versions(source)
        if value.get("marketing_version") != expected[0] or value.get("build_version") != expected[1]:
            raise ValueError("Embedded Apple app versions do not match the release tag")
    elif kind == "development":
        expected_source = f"dev-{commit[:12]}"
        if value.get("dirty"):
            fingerprint = value.get("source_fingerprint", "")
            if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
                raise ValueError("Invalid embedded dirty-source fingerprint")
            expected_source += f"-dirty-{fingerprint[:12]}"
        if source != expected_source or (value.get("marketing_version"), value.get("build_version")) != ("0.0.0", "1.0.0"):
            raise ValueError("Embedded development app version does not match its commit")
    elif kind == "source-archive":
        fingerprint = value.get("source_fingerprint", "")
        if (not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint) or
                source != f"dev-source-{fingerprint[:12]}" or commit or
                (value.get("marketing_version"), value.get("build_version")) != ("0.0.0", "1.0.0")):
            raise ValueError("Invalid embedded source archive identity")
    else:
        raise ValueError("Invalid embedded app source kind")
    return value


def legacy_identity(manifest, info):
    """Preserve old shell metadata without guessing from the current checkout."""
    source = manifest.get("source")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{64}", source):
        raise ValueError("Legacy shell has no valid source fingerprint")
    return {
        "schema": 1,
        "source_version": f"legacy-shell-source-sha256:{source}",
        "source_kind": "legacy-shell",
        "commit": "",
        "marketing_version": str(info.get("CFBundleShortVersionString", "1.0")),
        "build_version": str(info.get("CFBundleVersion", "1")),
    }


def write_metadata(path, metadata):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(metadata, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, help="Write resolved metadata JSON to this path")
    args = parser.parse_args()
    try:
        metadata = resolve(args.repo)
        if args.output:
            write_metadata(args.output, metadata)
        print(json.dumps(metadata, sort_keys=True))
    except ValueError as error:
        parser.exit(1, f"App version resolution failed: {error}\n")


if __name__ == "__main__":
    main()
