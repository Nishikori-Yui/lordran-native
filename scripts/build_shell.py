#!/usr/bin/env python3
"""Build an unsigned, game-free iOS shell on a Mac with Xcode."""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

from shell_common import make_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", required=True, type=Path, help="Private work directory under game/")
    parser.add_argument("-o", "--out", type=Path, help="Output shell .zip under game/")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    sys.path.insert(0, str(repo / "dm/games"))
    import game
    profile = game.load()
    work = args.work.resolve()
    output = args.out.resolve() if args.out else work / "LordranNative-shell-build-input.zip"
    private = (repo / "game").resolve()
    if not work.is_relative_to(private) or not output.is_relative_to(private):
        parser.error("Shell work and output paths must be under game/")
    if output.suffix != ".zip":
        parser.error("Shell build input must use .zip")
    manifest = make_manifest(repo, profile)
    work.mkdir(parents=True, exist_ok=True)
    tree = work / f"tree-{manifest['source'][:12]}"
    if tree.exists():
        raise ValueError(f"Isolated build tree already exists; choose another --work directory: {tree}")
    # Only copy the source subtree. User files and the existing generated iOS
    # project never enter the isolated shell build.
    shutil.copytree(repo / "dm", tree / "dm", ignore=shutil.ignore_patterns(
        "Gen", "DmIOS.xcodeproj", "gen", "__pycache__", "bin", "obj", "*.o", "*.a", "dmhost"))
    ios = tree / "dm/ios"
    gen = ios / "Gen"
    (gen / "dm").mkdir(parents=True)
    (gen / "msl").mkdir()
    (gen / "Assets.xcassets").mkdir()
    (gen / "Assets.xcassets/Contents.json").write_text(
        '{"info":{"author":"xcode","version":1}}\n', encoding="utf-8")
    (gen / "embed.S").write_text("// Game modules are supplied by Guest.framework.\n", encoding="utf-8")
    for name in ("shader_map.tsv", "pso_manifest.tsv", "c1_full.tsv"):
        shutil.copyfile(profile.table(name), gen / "dm" / name)
    font_dir = gen / "dm/font"
    font_dir.mkdir()
    shutil.copyfile("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", font_dir / "standard.ttf")
    subprocess.run([sys.executable, str(repo / "dm/tools/make_ext_font.py"),
                    str(font_dir / "nintendo_ext.ttf")], check=True)
    (gen / "dm/shell.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    env = dict(os.environ, GAME=profile.id, DM_GAME=profile.id,
               DM_BUNDLE_ID=f"org.nxnative.{profile.id.lower()}",
               DM_DISPLAY_NAME="Lordran Native", DM_APP_CATEGORY=profile.get("app_category"),
               DM_TEAM_ID="0000000000", DM_ROOT=str(work), WORK=str(work / "tmp"))
    (work / "tmp").mkdir(exist_ok=True)
    with (work / "generate.log").open("w", encoding="utf-8") as log:
        config = subprocess.run([sys.executable, "tools/gen_build.py", "../host", "Gen"],
                                cwd=ios, env=env, stdout=subprocess.PIPE, stderr=log,
                                text=True, check=True).stdout
    config = config.replace("OTHER_CFLAGS = $(inherited) ",
                            "OTHER_CFLAGS = $(inherited) -DDM_SHELL=1 ")
    config += "\nOTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS)\n"
    (gen / "dm.xcconfig").write_text(config, encoding="utf-8")
    subprocess.run(["xcodegen", "generate", "-q"], cwd=ios, env=env, check=True)
    with (work / "build.log").open("w", encoding="utf-8") as log:
        subprocess.run(["xcodebuild", "-project", "DmIOS.xcodeproj", "-scheme", "DmIOS",
                        "-configuration", "Release", "-sdk", "iphoneos",
                        "-destination", "generic/platform=iOS", "-derivedDataPath", str(work / "dd"),
                        # Override custom Xcode product locations as well.
                        f"CONFIGURATION_BUILD_DIR={work / 'products'}",
                        "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO",
                        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build"],
                       cwd=ios, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    app = work / "products/DmIOS.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("Shell executable was not built for iPhoneOS")
    # A strict resource allowlist prevents generated or private content from
    # leaking into a redistributable shell.
    allowed = {"Info.plist", "PkgInfo", "DmIOS", "Assets.car",
               "dm/shader_map.tsv", "dm/pso_manifest.tsv", "dm/c1_full.tsv", "dm/shell.json"}
    allowed |= {"dm/font/standard.ttf", "dm/font/nintendo_ext.ttf"}
    files = sorted(p for p in app.rglob("*") if p.is_file())
    for path in files:
        relative = path.relative_to(app).as_posix()
        if relative not in allowed or path.is_symlink():
            raise ValueError(f"Unexpected shell resource: {relative}")
    headers = subprocess.run(["xcrun", "otool", "-l", str(app / "DmIOS")],
                             check=True, capture_output=True, text=True).stdout
    if any(f"__DM{name}W" in headers or f"__dm{name}x0" in headers
           for name in profile.words("modules")):
        raise ValueError("Shell executable contains embedded game modules")
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(".partial.zip")
    try:
        with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            for path in files:
                archive.write(path, "Payload/DmIOS.app/" + path.relative_to(app).as_posix())
        partial.replace(output)
    finally:
        partial.unlink(missing_ok=True)
    print(f"Unsigned shell build input: {output}")
    print(f"Game: {profile.id}; chain: {manifest['chain']}; shader keys: {len(manifest['shader_keys'])}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Shell build failed: {error}", file=sys.stderr)
        sys.exit(1)
