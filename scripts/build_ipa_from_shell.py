#!/usr/bin/env python3
"""Build an unsigned iOS IPA from a Lordran Native shell and owned NSPs."""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_common import check_manifest, chain_id, shader_keys
from portable_shaders import verify_spirv_cross


def run(command, log, env=None, cwd=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        tail = log.read_text(encoding="utf-8", errors="replace").splitlines()[-12:]
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n" + "\n".join(tail))


def safe_shell(shell):
    with zipfile.ZipFile(shell) as archive:
        names = set(archive.namelist())
        root = "Payload/DmIOS.app/"
        allowed = {root + name for name in (
            "Info.plist", "PkgInfo", "DmIOS", "Assets.car", "dm/shader_map.tsv",
            "dm/pso_manifest.tsv", "dm/c1_full.tsv", "dm/shell.json",
            "dm/font/standard.ttf", "dm/font/nintendo_ext.ttf")}
        required = {root + name for name in (
            "Info.plist", "DmIOS", "dm/shader_map.tsv", "dm/pso_manifest.tsv",
            "dm/c1_full.tsv", "dm/shell.json", "dm/font/standard.ttf",
            "dm/font/nintendo_ext.ttf")}
        unexpected, missing = names - allowed, required - names
        if unexpected or missing:
            raise ValueError("Shell has missing or unexpected files: " + repr(sorted(unexpected | missing)))
        payload = {name[len(root):]: archive.read(name) for name in names}
    info = plistlib.loads(payload["Info.plist"])
    manifest = json.loads(payload["dm/shell.json"])
    return info, manifest, payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("nsp_dir", type=Path, help="Folder containing the base and update NSP")
    parser.add_argument("-k", "--keys", required=True, type=Path, help="Path to your prod.keys")
    parser.add_argument("--shell", required=True, type=Path, help="Shell ZIP from a matching release")
    parser.add_argument("--spirv-cross-sha256", default=os.environ.get("DM_SPIRV_CROSS_SHA256"),
                        help="Windows SPIRV-Cross SHA-256 recorded after the pinned source build "
                             "(default: DM_SPIRV_CROSS_SHA256)")
    parser.add_argument("-p", "--package", help="Profile package version (default: v196608)")
    parser.add_argument("-o", "--out", type=Path, help="Output IPA path")
    parser.add_argument("--keep-extracted", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo / "dm/games"))
    sys.path.insert(0, str(repo / "dm/tools"))
    sys.path.insert(0, str(repo / "scripts"))
    import game
    import build_ipa_from_nsp as source
    import nacp
    profile = game.load()
    nsp_dir, keys, shell = args.nsp_dir.resolve(), args.keys.resolve(), args.shell.resolve()
    private = (repo / "game").resolve()
    output = args.out.resolve() if args.out else nsp_dir / profile.get("ipa")
    if not nsp_dir.is_dir() or not keys.is_file() or not shell.is_file():
        parser.error("NSP folder, prod.keys, or shell file does not exist")
    if any(not path.is_relative_to(private) for path in (nsp_dir, keys, shell, output)):
        parser.error("NSP folder, keys, shell, and output IPA must remain under this repository's game/ directory")
    info, shell_manifest, shell_files = safe_shell(shell)
    check_manifest(shell_manifest, repo, profile)
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("The input shell is not an iPhoneOS build")
    # Reject an incomplete toolchain before scanning or extracting private inputs.
    dotnet = shutil.which("dotnet")
    if not dotnet:
        parser.error("Install the .NET 10 SDK and add dotnet to PATH")
    if not shutil.which("zstd"):
        parser.error("Install zstd and add it to PATH")
    verify_spirv_cross(args.spirv_cross_sha256)
    app, family = source.scan_nsps(nsp_dir)
    if app != profile.title_id:
        raise ValueError(f"Unsupported title ID: {app:016X}")
    package = args.package or profile.get("package")
    if package not in profile.builds():
        parser.error("--package must be a build registered in the Dark Souls profile")
    versions = profile.words("shader_versions")
    versions = versions + ([package] if package not in versions else [])
    picks = source.pick_nsps(family, versions)
    work = nsp_dir / f"{profile.id}_shell_build"
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    logs, extracted = work / "logs" / run_id, work / "extract"
    logs.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DM_GAME=profile.id, DM_ROOT=str(work), WORK=str(work / "tmp"),
               PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    if args.spirv_cross_sha256 is not None:
        env["DM_SPIRV_CROSS_SHA256"] = args.spirv_cross_sha256
    (work / "tmp").mkdir(exist_ok=True)
    tools = work / "tools"
    run([dotnet, "build", str(repo / "dm/tools/nx_extract/nx_extract.csproj"),
         "-c", "Release", "-o", str(tools / "nx_extract"), "-v", "quiet", "-nologo"],
        logs / "nx_extract_build.log", env)
    nx = tools / "nx_extract" / ("nx_extract.exe" if os.name == "nt" else "nx_extract")
    if not nx.is_file():
        raise RuntimeError("nx_extract did not produce its executable")
    translator = tools / "dmsh_xlate" / "dmsh_xlate.dll"
    run([dotnet, "build", str(repo / "dm/gfx/tools/dmsh_xlate/dmsh_xlate.csproj"),
         "-c", "Release", "-o", str(translator.parent), "-v", "quiet", "-nologo"],
        logs / "dmsh_xlate_build.log", env)
    dirs, clone = {}, None
    for version in versions:
        base, update = picks[version]
        dirs[version] = source.extract(nx, keys, extracted, version, base, update,
                                       clone, logs, profile)
        if update is None and clone is None and sys.platform == "darwin":
            try:
                if source.can_clone(extracted):
                    clone = dirs[version] / "RomFS"
            except OSError:
                clone = None
    game_dir = dirs[package]
    base_dir = next((dirs[v] for v in versions if picks[v][1] is None), dirs[versions[0]])
    name = nacp.name(base_dir / "control.nacp")
    if not name:
        raise ValueError("Could not read the game name from base control.nacp")
    patched = work / f"patched_{package}"
    source.rewrite(sys.executable, repo, game_dir / "ExeFS", patched, env, logs, profile)
    shaders = work / "shader"
    source.split_shaders(sys.executable, repo,
                         [dirs[v] / "RomFS" for v in profile.words("shader_versions")],
                         [dirs[v] / "ExeFS/main" for v in profile.words("shader_versions")],
                         shaders / "pkg", env, logs, profile)
    cache = work / "build/cache/metal_shader_cache"
    portable_env = dict(env, XLATE=str(translator),
                        MAIN=str(game_dir / "ExeFS/main"),
                        # keep all translator scratch files inside the private work folder
                        WORK=str(work / "tmp"))
    run([sys.executable, str(repo / "scripts/portable_shaders.py"),
         str(shaders / "pkg"), str(cache)], logs / "portable_shaders.log", portable_env)
    chain = chain_id(profile)
    shader_root = cache / f"b-{chain}"
    missing_shaders = [f"{key}_b.metal" for key in shader_keys(profile)
                       if not (shader_root / f"{key}_b.metal").is_file() or
                       not (shader_root / f"{key}_b.json").is_file()]
    if missing_shaders:
        raise ValueError("Shader translation incomplete; missing: " + ", ".join(missing_shaders[:12]))
    guest_dir = work / "Guest"
    run([sys.executable, "-c",
         "import sys; sys.path.insert(0, sys.argv[1]); from guest_dylib import write; "
         "write(sys.argv[2], sys.argv[3], sys.argv[4].split(), sys.argv[5])",
         str(repo / "scripts"), str(patched), str(guest_dir),
         " ".join(profile.words("modules")), f"org.nxnative.{profile.id.lower()}.guest"],
        logs / "guest_dylib.log", env)
    app_files = dict(shell_files)
    app_files["Info.plist"] = plistlib.dumps(dict(
        plistlib.loads(shell_files["Info.plist"]), CFBundleDisplayName=name))
    app_files.update({f"Frameworks/Guest.framework/{path.name}": path.read_bytes()
                      for path in (guest_dir / "Guest.framework").iterdir()})
    root = game_dir / "RomFS"
    for path in root.rglob("*"):
        if path.is_file():
            app_files[f"romfs/{path.relative_to(root).as_posix()}"] = path
    for path in shader_root.iterdir():
        if path.is_file() and path.suffix in (".metallib", ".json"):
            if path.name.endswith("_bf.metallib") and path.read_bytes()[:4] == b"MTLB":
                raise ValueError(f"Portable shader pass unexpectedly compiled {path.name}")
            app_files[f"msl/b-{chain}/{path.name}"] = path
    app_files["dm/font/nintendo_ext.ttf"] = shell_files["dm/font/nintendo_ext.ttf"]
    app_files["dm/font/standard.ttf"] = shell_files["dm/font/standard.ttf"]
    for name in profile.words("modules"):
        for suffix in ("fixups.tsv", "gates.tsv", "params.tsv", "cuts.tsv", "obs.tsv"):
            path = patched / f"{name}.{suffix}"
            if path.is_file():
                app_files[f"dm/{path.name}"] = path
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(".partial.ipa")
    try:
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            for name, value in sorted(app_files.items()):
                if value is None:
                    continue
                compression = zipfile.ZIP_STORED if any(
                    name.lower().endswith(ext) for ext in profile.get("zip_store").split(":")) else zipfile.ZIP_DEFLATED
                arcname = "Payload/DmIOS.app/" + name
                if isinstance(value, Path):
                    archive.write(value, arcname, compress_type=compression)
                else:
                    entry = zipfile.ZipInfo(arcname)
                    entry.compress_type = compression
                    mode = 0o755 if name in ("DmIOS", "Frameworks/Guest.framework/Guest") else 0o644
                    entry.external_attr = (0o100000 | mode) << 16
                    archive.writestr(entry, value)
        partial.replace(output)
    finally:
        partial.unlink(missing_ok=True)
    if not args.keep_extracted:
        shutil.rmtree(extracted, ignore_errors=True)
    print(f"Unsigned IPA: {output} ({output.stat().st_size / 2**30:.2f} GiB)")
    print("Shaders compile on first launch on the iPhone; the shell itself contains no game files.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Build failed: {error}", file=sys.stderr)
        sys.exit(1)
