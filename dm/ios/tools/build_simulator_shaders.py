#!/usr/bin/env python3
"""Compile existing Dark Souls MSL and reflection for the iOS Simulator."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
GAME = "01004AB00A260000"
METAL = [
    "xcrun", "--sdk", "iphonesimulator", "metal", "-c",
    "-target", "air64-apple-ios18.0-simulator", "-fmetal-math-mode=relaxed",
]
METALLIB = ["xcrun", "--sdk", "iphonesimulator", "metallib"]
RECORD = " ".join(METAL) + "; " + " ".join(METALLIB)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Existing b-<chain> folder containing MSL and reflection")
    parser.add_argument("output", type=Path, help="Simulator shader cache root")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 1, 12))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    profile = ROOT / "dm/games" / GAME
    chain = re.search(r'^#define DMSH_CHAIN "([^"]+)"', (profile / "dmsh_chain.h").read_text(), re.M)[1]
    source = args.source.resolve()
    if source.name != f"b-{chain}":
        parser.error(f"Source directory must match the host chain b-{chain}")
    output = args.output.resolve() / f"b-{chain}"
    if source == output:
        parser.error("Simulator output must be separate from the source cache")
    rows = [line.split("\t") for line in (profile / "shader_map.tsv").read_text().splitlines()
        if line and not line.startswith(("#", "package\t"))]
    keys = sorted({row[3] for row in rows})
    inputs = []
    for key in keys:
        metal = source / f"{key}_b.metal"
        reflection = source / f"{key}_b.json"
        if not metal.is_file() or not reflection.is_file():
            parser.error(f"Missing MSL or reflection for {key}")
        metadata = json.loads(reflection.read_text())
        if metadata.get("chain") != chain or metadata.get("route") != "B":
            parser.error(f"Stale or unsupported reflection for {key}")
        variant = source / f"{key}_bf.metal"
        if metadata.get("fetch") and not variant.is_file():
            parser.error(f"Readable-tile variant MSL must be retained for {key}")
        inputs.append((metal, metadata, variant if metadata.get("fetch") else None))
    compiler = subprocess.check_output(METAL[:4] + ["--version"], text=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"], text=True)
    tool_id = (RECORD + compiler + sdk).encode()
    output.mkdir(parents=True, exist_ok=True)
    completed = cached = 0

    with tempfile.TemporaryDirectory(prefix="simulator-metal-", dir=output.parent) as temporary:
        temporary = Path(temporary)

        def build(item):
            metal, metadata, variant = item
            stem = metal.stem
            payload = metal.read_bytes() + json.dumps(metadata, sort_keys=True).encode() + tool_id
            if variant:
                payload += variant.read_bytes()
            fingerprint = hashlib.sha256(payload).hexdigest()
            target = output / f"{stem}.metallib"
            reflection = output / f"{stem}.json"
            variant_target = output / variant.with_suffix(".metallib").name if variant else None
            old = json.loads(reflection.read_text()) if reflection.is_file() else {}
            if (target.is_file() and old.get("simulator_build") == fingerprint
                    and (not variant_target or variant_target.is_file())):
                return True
            for src, dst in [(metal, target)] + ([(variant, variant_target)] if variant else []):
                air = temporary / f"{src.stem}.air"
                library = temporary / f"{src.stem}.metallib"
                subprocess.run([*METAL, str(src), "-o", str(air)], check=True, capture_output=True, text=True)
                subprocess.run([*METALLIB, str(air), "-o", str(library)], check=True, capture_output=True, text=True)
                os.replace(library, dst)
                air.unlink()
            value = dict(metadata, chain_metal=RECORD, metal_platform="iphonesimulator", simulator_build=fingerprint)
            pending = temporary / f"{stem}.json"
            pending.write_text(json.dumps(value, sort_keys=True) + "\n")
            os.replace(pending, reflection)
            return False

        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            futures = [pool.submit(build, item) for item in inputs]
            for future in concurrent.futures.as_completed(futures):
                try:
                    cached += future.result()
                except subprocess.CalledProcessError as error:
                    print(error.stderr, flush=True)
                    raise
                completed += 1
                if completed == 1 or completed % 250 == 0 or completed == len(inputs):
                    print(f"Simulator shaders: {completed}/{len(inputs)} cached={cached}", flush=True)
    print(f"Simulator shader cache: {output}", flush=True)


if __name__ == "__main__":
    main()
