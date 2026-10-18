#!/bin/bash
# Build an unsigned diagnostic IPA. Installation is a separate, authorized step.
set -euo pipefail
SOURCE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?Usage: build_metal_probe.sh <directory under game/>}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
ROOT=$(cd "$SOURCE/../../.." && pwd)
case "$OUT/" in "$ROOT/game/"*) ;; *) echo "Output must be under $ROOT/game/" >&2; exit 1;; esac
APP=$OUT/Payload/MetalProbe.app
mkdir -p "$APP"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun --sdk iphoneos clang -target arm64-apple-ios26.0 -O1 -g -fobjc-arc -Wall \
    "$SOURCE/metal_probe.m" -framework UIKit -framework Foundation -framework Metal \
    -o "$APP/MetalProbe"
python3 - "$OUT" <<'PY'
import pathlib
import plistlib
import sys
import zipfile

out = pathlib.Path(sys.argv[1])
app = out / "Payload/MetalProbe.app"
info = dict(CFBundleIdentifier="org.nxnative.vphone-metal-probe",
            CFBundleExecutable="MetalProbe", CFBundleName="Metal Probe",
            CFBundlePackageType="APPL", CFBundleVersion="1",
            CFBundleShortVersionString="1.0", MinimumOSVersion="26.0",
            UIDeviceFamily=[1, 2], UIFileSharingEnabled=True,
            UIApplicationSceneManifest=dict(UIApplicationSupportsMultipleScenes=False),
            LSSupportsOpeningDocumentsInPlace=True, UILaunchStoryboardName="")
(app / "Info.plist").write_bytes(plistlib.dumps(info))
with zipfile.ZipFile(out / "MetalProbe.ipa", "w", zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.iterdir()):
        archive.write(file, file.relative_to(out))
print(out / "MetalProbe.ipa")
PY
