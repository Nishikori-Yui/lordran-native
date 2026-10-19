#!/usr/bin/env python3
"""Run the existing shader chain with source output and no Apple tools.

Uses d2r-mobile's nometal_run.py approach (MIT, Copyright (c) 2026 jhaizhou;
see ../LICENSE). Interception is confined to this child process. The packer
must verify every source and reflection against the Mac shell's manifest.
Neither the chain lock nor the profile header is rewritten.
"""
import builtins
import hashlib
import os
import re
import runpy
import shutil
import subprocess
import sys
from pathlib import Path


def main():
    repo = Path(__file__).resolve().parents[1]
    tools = repo / "dm/gfx/tools"
    sys.path.insert(0, str(tools))
    import dmsh_chain

    real_run, real_open = subprocess.run, builtins.open
    xlate = Path(os.environ.get("XLATE", tools / "dmsh_xlate_bin/dmsh_xlate"))
    lock = dict(line.split("\t", 1) for line in Path(dmsh_chain.LOCK).read_text(
        encoding="utf-8").splitlines() if "\t" in line and not line.startswith("#"))

    def run(args, *a, **kw):
        cmd = [str(x) for x in args]
        output = ""
        if cmd[0] == str(xlate):
            if xlate.suffix.lower() == ".dll":
                return real_run(["dotnet", str(xlate), *cmd[1:]], *a, **kw)
            return real_run(args, *a, **kw)
        if cmd[0] == "xcrun" and "metal" in cmd and "--version" in cmd:
            result = subprocess.CompletedProcess(args, 0, "none\n", "")
            if not (kw.get("text") or kw.get("universal_newlines") or kw.get("encoding")):
                result.stdout = result.stdout.encode()
            return result
        if cmd[0] == "cp" and cmd[1:2] == ["-c"]:
            shutil.copyfile(cmd[2], cmd[3])
        elif cmd[0] == "which" and len(cmd) == 2:
            output = (shutil.which(cmd[1]) or "") + "\n"
        elif cmd[0] == "xcrun" and "metal" in cmd and "-c" in cmd:
            sources = [x for i, x in enumerate(cmd) if x.endswith(".metal") and i != cmd.index("-o") + 1]
            if len(sources) != 1:
                raise ValueError(f"Unrecognized Metal source command: {cmd}")
            Path(cmd[cmd.index("-o") + 1]).write_bytes(
                Path(sources[0]).read_bytes().replace(b"\r\n", b"\n"))
        elif cmd[0] == "xcrun" and "metallib" in cmd:
            shutil.copyfile(cmd[cmd.index("metallib") + 1], cmd[cmd.index("-o") + 1])
        elif cmd[0] == "xcrun":
            raise ValueError(f"Apple tool invocation in source-only build: {cmd}")
        else:
            return real_run(args, *a, **kw)
        if not (kw.get("text") or kw.get("universal_newlines") or kw.get("encoding")):
            output = output.encode()
        return subprocess.CompletedProcess(args, 0, output, output)

    def check_tools():
        spirv_cross = shutil.which("spirv-cross")
        bad = []
        if not spirv_cross:
            bad.append("SPIRV-Cross is not on PATH")
        elif sys.platform == "win32":
            expected = os.environ.get("DM_SPIRV_CROSS_SHA256", "").lower()
            if not re.fullmatch(r"[0-9a-f]{64}", expected):
                bad.append("Windows builds require the verified SPIRV-Cross SHA-256 from the private toolchain record")
            elif hashlib.sha256(Path(spirv_cross).read_bytes()).hexdigest() != expected:
                bad.append("SPIRV-Cross binary does not match the verified Windows toolchain SHA-256")
        elif dmsh_chain.sha16(spirv_cross) != lock.get("spirv-cross"):
            bad.append("SPIRV-Cross binary does not match the release toolchain lock")
        result = run([str(xlate), "--source-sha"], capture_output=True, text=True, check=True)
        if result.stdout.strip() != dmsh_chain.xlate_source_sha():
            bad.append("Translator source does not match this checkout")
        return bad

    def utf8_open(file, mode="r", *args, **kwargs):
        if "b" not in mode and not args:
            kwargs.setdefault("encoding", "utf-8")
            kwargs.setdefault("newline", "\n")
        return real_open(file, mode, *args, **kwargs)

    # Existing scripts use locale-dependent open(); normalize generated tables
    # and source before computing their hashes on Windows.
    builtins.open = utf8_open
    subprocess.run = run
    dmsh_chain.check_tools = check_tools
    os.environ["XLATE"] = str(xlate)
    os.environ.pop("IOSOUT", None)
    sys.argv = [str(tools / "dmsh_build.py"), *sys.argv[1:]]
    runpy.run_path(sys.argv[0], run_name="__main__")


if __name__ == "__main__":
    main()
