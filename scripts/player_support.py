#!/usr/bin/env python3
"""Check a player build environment, run the existing packer, or inspect an IPA."""
import argparse
import json
import os
import platform
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from xml.etree import ElementTree

import build_ipa_from_nsp as source
import build_ipa_from_shell as shell_builder
from player_support_common import REPO, private_path, profile, print_json
from portable_shaders import verify_spirv_cross
from shell_common import SCHEMA, check_c1_table, check_manifest, chain_id, shader_keys

MAX_METADATA = 4 * 1024 * 1024


def probe(command, env=None):
    result = subprocess.run(command, env=env, capture_output=True, text=True,
                            errors="replace", timeout=30)
    if result.returncode:
        raise ValueError((result.stderr or result.stdout).strip()[:1200] or
                         f"{command[0]} exited with {result.returncode}")
    return result.stdout.strip()


def doctor(*, route="auto", shell=None, work_dir=None, expected_hash=None):
    route = ("shell" if sys.platform == "win32" else "mac") if route == "auto" else route
    checks = []
    def check(name, function):
        try:
            detail = function()
            checks.append(dict(name=name, status="pass", detail=detail or "Available"))
        except (ValueError, OSError, subprocess.SubprocessError, source.BuildError,
                zipfile.BadZipFile, KeyError, TypeError, ElementTree.ParseError) as error:
            checks.append(dict(name=name, status="fail", detail=str(error)))
    supported = sys.platform in ("darwin", "win32")
    checks.append(dict(name="host", status="pass" if supported and
                       (route != "mac" or sys.platform == "darwin") else "fail",
                       detail=f"{platform.system()} / {platform.machine()} / {route} route"))
    minimum = (3, 12) if route == "shell" else (3, 9)
    checks.append(dict(name="python", status="pass" if sys.version_info[:2] >= minimum else "fail",
                       detail=f"{platform.python_version()} at {sys.executable}; required >= {minimum[0]}.{minimum[1]}"))
    env = source.build_environment() if route == "mac" else dict(os.environ)
    env.update(DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1", DOTNET_CLI_TELEMETRY_OPTOUT="1")
    def python_modules():
        missing = source.missing_python_modules()
        if missing:
            raise ValueError(f"Missing modules in this Python: {', '.join(missing)}")
        return ", ".join(source.PYTHON_MODULES)
    check("python-modules", python_modules)
    if supported:
        if route == "shell":
            check("packaging-tools", lambda: shell_builder.check_tools(expected_hash))
        else:
            check("packaging-tools", lambda: source.check_prereqs(
                env, REPO / "dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate"))
            check("spirv-cross-fingerprint", lambda: verify_spirv_cross(path=env["PATH"]))
            checks.append(dict(name="native-host", status="pass" if platform.machine().lower()
                               in ("arm64", "aarch64") else "fail",
                               detail="The native Mac route requires Apple silicon"))
            check("iphoneos-sdk", lambda: probe(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], env))
            check("metal-compiler", lambda: probe(["xcrun", "--sdk", "iphoneos", "metal", "--version"], env))
        def dotnet_sdk():
            target = ElementTree.parse(REPO / "dm/tools/nx_extract/nx_extract.csproj").findtext(".//TargetFramework")
            major = int(re.fullmatch(r"net(\d+)\.\d+", target)[1])
            output = probe(["dotnet", "--list-sdks"], env)
            versions = re.findall(r"(?m)^(\d+\.\d+\.[^\s]+)", output)
            if not any(int(v.split(".")[0]) == major for v in versions):
                raise ValueError(f"Install the SDK for {target}; detected: {', '.join(versions) or 'none'}")
            return f"{target}; SDKs: {', '.join(versions)}"
        check("dotnet-sdk", dotnet_sdk)
    g = profile()
    check("profile-chain", lambda: check_c1_table(g))
    if shell is not None:
        check("shell-compatibility", lambda: shell_builder.validate_shell(Path(shell), REPO, g)[1]["chain"])
    elif route == "shell":
        checks.append(dict(name="shell-compatibility", status="not-checked",
                           detail="Supply --shell before packaging; no shell was opened"))
    directory = private_path(work_dir or REPO / "game" / g.id)
    ancestor = directory
    while not ancestor.exists():
        ancestor = ancestor.parent
    try:
        free = shutil.disk_usage(ancestor).free / 2**30
        checks.append(dict(name="disk-space", status="info", detail=f"{free:.1f} GiB free",
                           note="Compare with the size estimate in README; the packer checks its own working space"))
    except OSError as error:
        checks.append(dict(name="disk-space", status="fail", detail=str(error)))
    ready = not any(c["status"] == "fail" for c in checks)
    return dict(status="environment-ready" if ready else "environment-incomplete",
                route=route, checked_at=datetime.now(timezone.utc).isoformat(),
                checks=checks, scope="Tools and optional shell compatibility; no game extraction or installation",
                guide="docs/windows-packaging.md" if route == "shell" else "README.md")


def read_member(archive, name, limit=MAX_METADATA):
    info = archive.getinfo(name)
    if info.file_size > limit:
        raise ValueError(f"Metadata exceeds size limit: {name}")
    return archive.read(info)


def macho_slice(stream, size):
    header = stream.read(32)
    if len(header) < 32 or struct.unpack_from("<I", header)[0] != 0xFEEDFACF:
        raise ValueError("Expected a 64-bit little-endian Mach-O executable")
    _, cpu, _, _, count, length, _, _ = struct.unpack("<8I", header)
    if cpu != 0x0100000C or count > 8192 or length > 1024 * 1024 or length + 32 > size:
        raise ValueError("Invalid or non-arm64 Mach-O header")
    commands = stream.read(length)
    if len(commands) != length:
        raise ValueError("Truncated Mach-O load commands")
    offset, platforms, signed = 0, [], False
    for _ in range(count):
        if offset + 8 > length:
            raise ValueError("Truncated Mach-O load command")
        cmd, size_cmd = struct.unpack_from("<II", commands, offset)
        if size_cmd < 8 or offset + size_cmd > length:
            raise ValueError("Invalid Mach-O load command size")
        if cmd == 0x32:
            if size_cmd < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            target, minimum = struct.unpack_from("<II", commands, offset + 8)
            platforms.append((target, minimum))
        signed |= cmd == 0x1D
        offset += size_cmd
    if offset != length or len(platforms) != 1:
        raise ValueError("Executable must declare one LC_BUILD_VERSION platform")
    target, minimum = platforms[0]
    if target not in (2, 7):
        raise ValueError("Executable is not built for iOS or iOS Simulator")
    return dict(architecture="arm64", target="device" if target == 2 else "simulator",
                minimum_os=f"{minimum >> 16}.{(minimum >> 8) & 255}.{minimum & 255}",
                signature_load_command=bool(signed))


def executable_info(archive, name):
    member = archive.getinfo(name)
    with archive.open(member) as stream:
        magic = stream.read(8)
        stream.seek(0)
        if magic[:4] not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            return macho_slice(stream, member.file_size)
        wide = magic[:4] == b"\xca\xfe\xba\xbf"
        count = struct.unpack(">I", magic[4:])[0]
        if not 0 < count <= 32:
            raise ValueError("Invalid universal executable")
        stream.read(8)
        slices = []
        for _ in range(count):
            record = stream.read(32 if wide else 20)
            if len(record) != (32 if wide else 20):
                raise ValueError("Truncated universal executable")
            if wide:
                cpu, _, offset, length, _, _ = struct.unpack(">IIQQII", record)
            else:
                cpu, _, offset, length, _ = struct.unpack(">IIIII", record)
            if offset + length > member.file_size:
                raise ValueError("Universal slice exceeds executable")
            if cpu == 0x0100000C:
                slices.append((offset, length))
        if len(slices) != 1:
            raise ValueError("Expected one arm64 slice")
        stream.seek(slices[0][0])
        return macho_slice(stream, slices[0][1])


def verify(path, *, target="device", full_crc=False, match_source=False):
    g = profile()
    chain = chain_id(g)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = {entry.filename for entry in entries}
        if len(names) != len(entries):
            raise ValueError("Archive contains duplicate member names")
        for name in names:
            if name.startswith("/") or "\\" in name or ".." in PurePosixPath(name).parts or re.match(r"^[A-Za-z]:", name):
                raise ValueError("Archive contains an unsafe member path")
            if PurePosixPath(name).name.lower() in ("prod.keys", "title.keys") or name.lower().endswith((".p12", ".pfx")):
                raise ValueError("Archive contains private keys or signing material")
        roots = [name[:-len("Info.plist")] for name in names if
                 (re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name) or
                  re.fullmatch(r"[^/]+\.app/Info\.plist", name))]
        if len(roots) != 1:
            raise ValueError("Expected exactly one device or Simulator application")
        root = roots[0]
        info = plistlib.loads(read_member(archive, root + "Info.plist"))
        if not isinstance(info, dict):
            raise ValueError("Info.plist must contain an application dictionary")
        app_identity = g.bundle_id(info.get("CFBundleIdentifier", ""))
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or "/" in executable or "\\" in executable or executable in ("", ".", ".."):
            raise ValueError("Invalid CFBundleExecutable")
        binary = executable_info(archive, root + executable)
        actual = binary["target"]
        if target != "auto" and actual != target:
            raise ValueError(f"This is a {actual} build, not the requested {target} build")
        expected_platform = "iPhoneOS" if actual == "device" else "iPhoneSimulator"
        if info.get("CFBundleSupportedPlatforms") != [expected_platform]:
            raise ValueError("Info.plist and executable platform disagree")
        if (actual == "device") != root.startswith("Payload/"):
            raise ValueError("Archive layout does not match the executable platform")
        marker = root + "romfs/" + g.get("romfs_marker")
        if marker not in names or not archive.getinfo(marker).file_size:
            raise ValueError("Game data marker is missing; a shell build input is not an installable game app")
        check_c1_table(g, read_member(archive, root + "dm/c1_full.tsv"))
        table = read_member(archive, root + "dm/shader_map.tsv")
        if source.data_rows(table) != source.data_rows(g.table("shader_map.tsv").read_bytes()):
            raise ValueError("Bundled shader map does not match the target profile")
        manifest_name = root + "dm/shell.json"
        provenance = "No shell source manifest (native build)"
        if manifest_name in names:
            manifest = json.loads(read_member(archive, manifest_name))
            if (not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA or
                    not re.fullmatch(r"[0-9a-f]{64}", str(manifest.get("source", "")))):
                raise ValueError("Invalid embedded shell manifest schema or source fingerprint")
            if (manifest.get("game"), manifest.get("chain")) != (g.id, chain):
                raise ValueError("Embedded shell profile or chain mismatch")
            if manifest.get("shader_keys") != shader_keys(g):
                raise ValueError("Embedded shell shader inventory mismatch")
            if match_source:
                check_manifest(manifest, REPO, g)
            provenance = "Source checked against checkout" if match_source else "Embedded source manifest present; source not compared"
            guest = executable_info(archive, root + "Frameworks/Guest.framework/Guest")
            if guest["target"] != actual:
                raise ValueError("Guest framework and host executable platforms disagree")
            guest_info = plistlib.loads(read_member(archive, root + "Frameworks/Guest.framework/Info.plist"))
            if not isinstance(guest_info, dict) or guest_info.get("CFBundleIdentifier") != app_identity + ".guest":
                raise ValueError("Guest framework Bundle ID must derive from the app Bundle ID")
        elif match_source:
            raise ValueError("Source matching requires a shell manifest; this native artifact does not provide one")
        keys = shader_keys(g)
        compiled, runtime_source = 0, 0
        for key in keys:
            prefix = root + f"msl/b-{chain}/{key}_b"
            metadata = json.loads(read_member(archive, prefix + ".json"))
            if not isinstance(metadata, dict) or metadata.get("chain") != chain:
                raise ValueError(f"Shader reflection chain mismatch: {key}")
            with archive.open(prefix + ".metallib") as stream:
                header = stream.read(4096)
                magic = header[:4]
            if magic == b"MTLB":
                compiled += 1
                if actual == "simulator":
                    if metadata.get("metal_platform") != "iphonesimulator":
                        raise ValueError(f"Shader is not tagged for Simulator: {key}")
                elif (metadata.get("metal_platform") == "iphonesimulator" or
                      "iphoneos" not in str(metadata.get("chain_metal", ""))):
                    raise ValueError(f"Compiled shader is not recorded as iPhoneOS: {key}")
            else:
                if actual == "simulator":
                    raise ValueError("Simulator requires compiled shader libraries")
                try:
                    source_header = header.decode("utf-8-sig")
                except UnicodeDecodeError as error:
                    raise ValueError(f"Shader payload is neither a Metal library nor UTF-8 source: {key}") from error
                if (archive.getinfo(prefix + ".metallib").file_size < 64 or
                        "#include <metal_stdlib>" not in source_header or
                        "using namespace metal;" not in source_header):
                    raise ValueError(f"Shader source payload is incomplete: {key}")
                runtime_source += 1
        if full_crc:
            bad = archive.testzip()
            if bad:
                raise ValueError("Archive CRC failed")
    return dict(status="artifact-structure-verified", target=actual, bundle_id=app_identity, executable=binary,
                shader_chain=chain, shaders=len(keys), compiled_shaders=compiled,
                runtime_compiled_sources=runtime_source, provenance=provenance,
                archive_crc="passed" if full_crc else "not-checked",
                signing="Not verified; unsigned output must be signed by the user's sideloading tool",
                runtime="Not tested by this command")


def build(args):
    g = profile()
    folder, keys = private_path(args.nsp_dir), private_path(args.keys)
    shell = private_path(args.shell) if args.shell else None
    if not folder.is_dir() or not keys.is_file() or (shell and not shell.is_file()):
        raise ValueError("NSP folder, keys, or shell is missing")
    if sys.platform == "win32" and shell is None:
        raise ValueError("Windows packaging requires --shell from a matching source release")
    if sys.platform not in ("darwin", "win32"):
        raise ValueError("Packaging is supported on macOS and Windows")
    package = args.package or g.get("package")
    if package not in g.builds():
        raise ValueError("Package must be registered in the target profile")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = private_path(args.out or folder / f"{Path(g.get('ipa')).stem}-{stamp}.ipa")
    if output.suffix.lower() != ".ipa":
        raise ValueError("Device output must end in .ipa")
    if output.exists() and not args.replace:
        raise ValueError("Output already exists; choose a new path or explicitly approve --replace")
    route = "shell" if shell else "mac"
    command = [sys.executable, str(REPO / "scripts" / (
        "build_ipa_from_shell.py" if shell else "build_ipa_from_nsp.py")),
        str(folder), "--keys", str(keys), "--out", str(output), "--package", package]
    if shell:
        command += ["--shell", str(shell)]
        if args.spirv_cross_sha256:
            command += ["--spirv-cross-sha256", args.spirv_cross_sha256]
        if args.replace:
            command.append("--replace")
    if args.keep_extracted:
        command.append("--keep-extracted")
    if getattr(args, "bundle_id", None) is not None:
        command += ["--bundle-id", g.bundle_id(args.bundle_id)]
    if args.dry_run:
        return dict(status="build-plan", command=command, output=str(output),
                    environment="Not checked; no build was started")
    environment = doctor(route=route, shell=shell, work_dir=folder,
                         expected_hash=args.spirv_cross_sha256)
    if environment["status"] != "environment-ready":
        return environment
    subprocess.run(command, cwd=REPO, check=True)
    return dict(status="build-complete", output=str(output), verification=verify(output))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("doctor", help="Read-only environment and optional shell checks")
    check.add_argument("--route", choices=("auto", "mac", "shell"), default="auto")
    check.add_argument("--shell", type=Path)
    check.add_argument("--work-dir", type=Path)
    check.add_argument("--spirv-cross-sha256", default=os.environ.get("DM_SPIRV_CROSS_SHA256"))
    package = commands.add_parser("build", help="Run the existing unsigned device packer")
    package.add_argument("nsp_dir", type=Path)
    package.add_argument("--keys", required=True, type=Path)
    package.add_argument("--shell", type=Path)
    package.add_argument("-o", "--out", type=Path)
    package.add_argument("-p", "--package")
    package.add_argument("--bundle-id", help="Override the app identity for native or shell packaging")
    package.add_argument("--spirv-cross-sha256", default=os.environ.get("DM_SPIRV_CROSS_SHA256"))
    package.add_argument("--keep-extracted", action="store_true")
    package.add_argument("--dry-run", action="store_true")
    package.add_argument("--replace", action="store_true", help="Only use after the user approves replacing the named output")
    artifact = commands.add_parser("verify", help="Inspect platform, profile and shaders without installing")
    artifact.add_argument("artifact", type=Path)
    artifact.add_argument("--target", choices=("device", "simulator", "auto"), default="device")
    artifact.add_argument("--full-crc", action="store_true", help="Read all archive contents to check CRCs")
    artifact.add_argument("--match-source", action="store_true", help="Require a shell manifest matching this exact checkout")
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor":
            result = doctor(route=args.route, shell=args.shell, work_dir=args.work_dir,
                            expected_hash=args.spirv_cross_sha256)
        elif args.command == "build":
            result = build(args)
        else:
            result = verify(args.artifact, target=args.target, full_crc=args.full_crc,
                            match_source=args.match_source)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile,
            subprocess.SubprocessError, ElementTree.ParseError) as error:
        from prepare_issue import sanitize
        parser.exit(1, f"Player support failed: {sanitize(str(error))}\n")
    print_json(result)
    return 1 if result["status"] == "environment-incomplete" else 0


if __name__ == "__main__":
    sys.exit(main())
