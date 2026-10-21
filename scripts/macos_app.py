"""Assemble a local macOS app bundle from the native host and owned game data."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from app_version import resolve as resolve_app_version, write_metadata


def copy_tree(source, destination):
    """Use APFS clones when available, falling back to an ordinary copy."""
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["cp", "-cR", str(source), str(destination)],
                                    capture_output=True, text=True)
            if result.returncode == 0:
                return
        except OSError:
            pass
        if destination.exists():
            shutil.rmtree(destination)
    shutil.copytree(source, destination)


def tree_size(path):
    path = Path(path)
    if path.is_file():
        return path.stat().st_size
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def apfs_clone_available(source, destination_parent):
    if sys.platform != "darwin" or not shutil.which("cp"):
        return False
    source = Path(source)
    sample = source if source.is_file() else next(
        (path for path in source.rglob("*") if path.is_file()), None)
    if sample is None:
        return False
    try:
        with tempfile.TemporaryDirectory(prefix=".lordran-clone-check-",
                                         dir=destination_parent) as probe:
            result = subprocess.run(["cp", "-c", str(sample), str(Path(probe) / "sample")],
                                    capture_output=True)
            return result.returncode == 0
    except OSError:
        return False


def compile_launcher(repo, destination):
    clang = shutil.which("clang")
    if not clang:
        raise RuntimeError("clang is unavailable; install Xcode Command Line Tools")
    source = Path(repo) / "scripts/macos_app_launcher.m"
    subprocess.run([clang, "-O2", "-fobjc-arc", "-framework", "Foundation",
                    str(source), "-o", str(destination)], check=True)
    destination.chmod(0o755)


def build_app(*, repo, profile, host, patched, romfs, shader_cache, fonts,
              output, app_name, bundle_id, version_info=None, replace=False):
    """Build an unsigned .app and refuse to overwrite it unless asked."""
    repo = Path(repo).resolve()
    host = Path(host).resolve()
    patched = Path(patched).resolve()
    romfs = Path(romfs).resolve()
    shader_cache = Path(shader_cache).resolve()
    fonts = Path(fonts).resolve()
    output = Path(output).expanduser()
    if not output.is_absolute():
        output = Path.cwd() / output
    output = output.parent.resolve() / output.name
    private_root = (repo / "game").resolve()
    if output == private_root or private_root not in output.parents:
        raise ValueError("Keep the macOS app and its included game data under this checkout's game/ directory")

    chain_line = next((line for line in profile.table("dmsh_chain.h").read_text(
        encoding="utf-8").splitlines() if line.startswith('#define DMSH_CHAIN ')), None)
    if not chain_line:
        raise ValueError("The game profile has no DMSH_CHAIN value")
    chain = chain_line.split('"')[1]
    shader_root = shader_cache / f"b-{chain}"
    required = (
        (host, "Mac host executable"),
        (romfs / profile.get("romfs_marker"), "game RomFS marker"),
        (shader_root, "Mac shader libraries"),
        (patched / "main.patched.bin", "rewritten main module"),
        (fonts / "standard.ttf", "standard font"),
        (fonts / "nintendo_ext.ttf", "Nintendo extension font"),
    )
    for path, description in required:
        if not path.exists():
            raise FileNotFoundError(f"Missing {description}: {path}")
    if output.suffix != ".app":
        raise ValueError("macOS app output must use the .app suffix")
    if output.exists() and not replace:
        raise FileExistsError(f"Output already exists; choose another path or pass --replace: {output}")

    output.parent.mkdir(parents=True, exist_ok=True)
    romfs_size = tree_size(romfs)
    patched_size = tree_size(patched)
    shader_root_size = tree_size(shader_root)
    payload_size = (romfs_size + patched_size + shader_root_size +
                    tree_size(fonts / "standard.ttf") + tree_size(fonts / "nintendo_ext.ttf") +
                    host.stat().st_size)
    free_bytes = shutil.disk_usage(output.parent).free
    clone_source = romfs if romfs_size else shader_root
    clone_supported = apfs_clone_available(clone_source, output.parent)
    required_bytes = 5 * 2**30 if clone_supported else payload_size + 1 * 2**30
    if free_bytes < required_bytes:
        raise OSError(
            f"Not enough free space for the macOS app: {free_bytes / 2**30:.1f} GiB free, "
            f"approximately {required_bytes / 2**30:.1f} GiB required"
        )

    if version_info is None:
        version_info = resolve_app_version(repo)

    with tempfile.TemporaryDirectory(prefix=f".{output.name}.build-", dir=output.parent) as temporary:
        bundle = Path(temporary) / output.name
        contents = bundle / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        game = resources / "game"
        dm = resources / "dm"
        game.mkdir(parents=True)
        dm.mkdir(parents=True)
        (resources / "fonts").mkdir()
        (resources / "shaders").mkdir()

        macos.mkdir(parents=True, exist_ok=True)
        shutil.copy2(host, macos / "dmhost")
        os.chmod(macos / "dmhost", 0o755)
        compile_launcher(repo, macos / "LordranNativeLauncher")
        copy_tree(romfs, game / "RomFS")
        copy_tree(patched, game / "patched")
        copy_tree(shader_root, resources / "shaders" / f"b-{chain}")

        for name in ("shader_map.tsv", "pso_manifest.tsv", "c1_full.tsv"):
            shutil.copy2(profile.table(name), dm / name)
        for name in ("standard.ttf", "nintendo_ext.ttf"):
            shutil.copy2(fonts / name, resources / "fonts" / name)

        identity = profile.bundle_id(bundle_id)
        info = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": app_name,
            "CFBundleExecutable": "LordranNativeLauncher",
            "CFBundleIdentifier": identity,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": app_name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version_info["marketing_version"],
            "CFBundleVersion": version_info["build_version"],
            "LSApplicationCategoryType": profile.get("app_category"),
            "LSMultipleInstancesProhibited": True,
            "NSHighResolutionCapable": True,
        }
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream, sort_keys=True)
        write_metadata(resources / "dm/app-version.json", version_info)

        previous = None
        if output.exists():
            previous = output.with_name(f".{output.name}.previous-{os.getpid()}")
            if previous.exists():
                raise FileExistsError(f"Refusing to replace an existing backup: {previous}")
            output.rename(previous)
        try:
            bundle.rename(output)
        except OSError:
            if previous is not None and previous.exists():
                previous.rename(output)
            raise
        if previous is not None:
            if previous.is_symlink() or previous.is_file():
                previous.unlink()
            else:
                shutil.rmtree(previous)
    return output
