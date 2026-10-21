#!/usr/bin/env python3
"""Generate public AVC patterns and verify every decoded Y/U/V sample on macOS."""

import argparse
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_WORK = ROOT / "game/01004AB00A260000-work/issue-16"
FRAMES = 24
# Untagged 64x64 reproduces #16; the other cases separate reordering, color
# metadata, visible cropping/row alignment, and the historical 720p control.
CASES = (
    ("64-bframes", 64, 64, 2, False),
    ("64-no-bframes", 64, 64, 0, False),
    ("64-bt709", 64, 64, 2, True),
    ("80x50-bframes", 80, 50, 2, True),
    ("720p-bframes", 1280, 720, 2, True),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK)
    parser.add_argument(
        "--apple-reference", action="store_true",
        help="also diagnose AVAssetReader; its known chroma mismatch is not a software-reference failure",
    )
    args = parser.parse_args()
    work = args.work_dir.resolve()
    if not work.is_relative_to(ROOT / "game"):
        parser.error("--work-dir must be under this checkout's ignored game/ folder")
    if sys.platform != "darwin":
        parser.error("this test requires macOS VideoToolbox and AVFoundation")
    for tool in ("ffmpeg", "ffprobe", "make", "clang"):
        if not shutil.which(tool):
            parser.error(f"required tool not found: {tool}")
    fixtures = work / "fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    build = work / "build"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    log_path = work / f"validation-{stamp}.log"
    with log_path.open("w", encoding="utf-8") as log:
        def run(command, expected=0):
            command = [str(arg) for arg in command]
            log.write("\n$ " + " ".join(command) + "\n")
            log.flush()
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            log.write(f"exit={result.returncode}\n")
            log.flush()
            if expected is not None and result.returncode != expected:
                raise RuntimeError(f"expected exit {expected}, got {result.returncode}: {command[0]}")
            return result.returncode

        run(["git", "rev-parse", "HEAD"])
        run(["sw_vers"])
        run(["ffmpeg", "-version"])
        run(["make", "-C", "dm/host/tests", "movie-avc-build", f"MOVIE_B={build}"])
        run([build / "t_movie_sps"])
        binary = build / "t_movie_avc"
        for name, width, height, bframes, tagged in CASES:
            video = fixtures / f"{name}.mp4"
            raw = fixtures / f"{name}.nv12"
            command = [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                "-i", f"testsrc2=size={width}x{height}:rate=12:duration=2",
                "-an", "-c:v", "libx264", "-threads:v", "1", "-pix_fmt", "yuv420p",
                "-crf", "18", "-bf", str(bframes), "-g", str(FRAMES),
            ]
            if tagged:
                command += ["-color_range", "tv", "-colorspace", "bt709",
                            "-color_primaries", "bt709", "-color_trc", "bt709"]
            run(command + [video])
            run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams", "-of", "json", video])
            # Force software H.264 decoding. Planar 4:2:0 -> NV12 only
            # interleaves U/V; no scaling, RGB conversion or range remapping.
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-c:v", "h264",
                 "-i", video, "-map", "0:v:0", "-an", "-pix_fmt", "nv12",
                 "-fps_mode", "passthrough", "-f", "rawvideo", raw])
            if raw.stat().st_size != width * height * 3 // 2 * FRAMES:
                raise RuntimeError(f"unexpected software-reference size: {name}")
            run([binary, "--nv12-reference", raw, video])
            print(f"PASS {name}: {FRAMES} frames x AVCC/Annex-B, exact Y/U/V")
            if args.apple_reference:
                result = run([binary, video], expected=None)
                if result not in (0, 1):
                    raise RuntimeError(f"AVAssetReader diagnostic did not complete: {name}")
                print(f"AVAssetReader {name}: {'MATCH' if result == 0 else 'MISMATCH (diagnostic only)'}")

        # A one-code-value change at the last sample in just one frame must
        # fail, even in V (which the former x += 8 comparison never read).
        video = fixtures / "64-bframes.mp4"
        good = (fixtures / "64-bframes.nv12").read_bytes()
        for component, offset in (("Y", 64 * 64 - 1), ("U", 64 * 64 * 3 // 2 - 2),
                                  ("V", 64 * 64 * 3 // 2 - 1)):
            bad = bytearray(good)
            bad[offset] ^= 1
            corrupted = fixtures / f"corrupt-{component}.nv12"
            corrupted.write_bytes(bad)
            run([binary, "--nv12-reference", corrupted, video], expected=1)
            print(f"PASS negative control: isolated final {component} sample rejected")
    print(f"Validation log: {log_path}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        sys.exit(str(error))
