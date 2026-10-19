"""Shared shell compatibility and shader-output checks."""
import hashlib
import json
import os
import re
from pathlib import Path

SCHEMA = 1
SOURCE_PATHS = (
    "scripts/build_ipa_from_nsp.py", "scripts/build_ipa_from_shell.py",
    "scripts/build_shell.py", "scripts/guest_dylib.py", "scripts/portable_shaders.py",
    "scripts/shell_common.py",
    "dm/tools/patch_nso.py", "dm/tools/nso.py", "dm/tools/nacp.py",
    "dm/tools/nx_extract/Program.cs", "dm/tools/nx_extract/nx_extract.csproj",
    "dm/tools/make_ext_font.py", "dm/games/game.py",
    "dm/gfx/tools/dmsh_chain.lock", "dm/ios/tools/ios_metal.py", "dm/ios/project.yml",
)


def generated_directory(name):
    return (name in {"Gen", "DmIOS.xcodeproj", "gen", "__pycache__", "bin", "obj",
                     "build", "DerivedData", "node_modules"}
            or name.startswith(".iosdd")
            or name.lower().endswith((".dsym", ".app", ".xcarchive")))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_id(repo, game):
    paths = list(SOURCE_PATHS)
    for folder in ("dm",):
        base = repo / folder
        for parent, dirs, files in os.walk(base):
            dirs[:] = sorted(d for d in dirs if not generated_directory(d))
            paths += [Path(parent, name).relative_to(repo).as_posix() for name in files
                      if Path(name).suffix in (".c", ".m", ".h", ".inc", ".S", ".py",
                                               ".cs", ".csproj", ".sh", ".yml", ".plist", ".json",
                                               ".mk", ".xcconfig") or name == "Makefile"]
    paths += [p.relative_to(repo).as_posix() for p in (repo / "dm/gfx/tools").glob("dmsh_*.py")]
    paths += [p.relative_to(repo).as_posix() for p in (repo / "dm/gfx/tools/dmsh_xlate").glob("*")
              if p.suffix in (".cs", ".csproj")]
    paths += [p.relative_to(repo).as_posix() for p in game.dir.iterdir()
              if p.suffix in (".tsv", ".h") or p.name.endswith(".conflicts.tsv")]
    h = hashlib.sha256()
    for name in sorted(set(paths)):
        # Git may check text out with CRLF on Windows.
        h.update(name.encode() + b"\0" + (repo / name).read_bytes().replace(b"\r\n", b"\n") + b"\0")
    return h.hexdigest()


def chain_id(game):
    return re.search(r'#define DMSH_CHAIN "([^"]+)"',
                     game.table("dmsh_chain.h").read_text(encoding="utf-8"))[1]


def shader_keys(game):
    return sorted({line.split("\t")[3] for line in
                   game.table("shader_map.tsv").read_text(encoding="utf-8").splitlines()
                   if line and not line.startswith(("#", "package\t"))})


def make_manifest(repo, game):
    return dict(schema=SCHEMA, game=game.id, source=source_id(repo, game),
                chain=chain_id(game), shader_keys=shader_keys(game))


def check_manifest(manifest, repo, game):
    expected = dict(schema=SCHEMA, game=game.id, source=source_id(repo, game), chain=chain_id(game))
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"Shell {key} mismatch; use the shell and source from the same release")
    if manifest.get("shader_keys") != shader_keys(game):
        raise ValueError("Shell shader inventory does not match the game profile")
