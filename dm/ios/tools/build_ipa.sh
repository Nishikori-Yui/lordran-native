#!/bin/bash
# Build one unsigned all-in-one IPA: the rewritten modules compiled into the executable, iOS shader libraries, and the game files (RomFS) at DmIOS.app/romfs. At install time a signing tool (AltStore / Sideloadly etc.) swaps in your own certificate and bundle ID.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa]; environment: GAME=game profile (dm/games/<base game title ID>, required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the bundle ID is org.nxnative.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_BUNDLE_ID override them);
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
#   DM_IOS_TARGET=simulator builds an arm64 Simulator .app.zip instead; MSL_IOS must contain Simulator libraries from build_simulator_shaders.py.
set -u
cd "$(dirname "$0")/.." || exit 1
IOS=$PWD; DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
[ -n "${GAME:-}" ] || die "GAME is not set: GAME=<base game title ID> $0; profiles: $(python3 "$DM/games/game.py" list | awk -F'\t' '{printf "%s (%s)  ", $1, $3}')"
export GAME; GD=$DM/games/$GAME   # the make that gen_build.py runs uses the same GAME
gp() { python3 "$DM/games/game.py" "$GAME" "$1" || die "game profile $GD: $1"; }   # read a key of the game profile
[ -f "$GD/game.tsv" ] || die "no game profile $GD/game.tsv"
[ -n "${W:-}" ] || die "W is not set: W=<NSP folder>/$GAME-work (the game's work folder) $0"
PKG=$(gp package)
PATCHED=${PATCHED:-$W/build/patched_$PKG}; ROMFS=${ROMFS:-$W/data/$PKG/RomFS}
BUILD_FLAGS=(ONLY_ACTIVE_ARCH=NO)
case "${DM_IOS_TARGET:-device}" in
  device)
    SDK=iphoneos; DESTINATION='generic/platform=iOS'; STAGE=Payload
    MSL_IOS=${MSL_IOS:-$W/build/ios/dmsh_b}
    OUT_IPA=${1:-$(dirname "$W")/$(gp ipa)}; O=$W/build/ios/pkg
    ;;
  simulator)
    SDK=iphonesimulator; DESTINATION='generic/platform=iOS Simulator'; STAGE=Simulator
    MSL_IOS=${MSL_IOS:-$W/build/ios-simulator/dmsh_b}
    OUT_IPA=${1:-$(dirname "$W")/DarkSoulsRemastered-Simulator.app.zip}; O=$W/build/ios-simulator/pkg
    [[ "$OUT_IPA" == *.zip ]] || die "Simulator output must end in .zip (contains DmIOS.app, not an IPA)"
    BUILD_FLAGS=(ARCHS=arm64 ONLY_ACTIVE_ARCH=NO)
    ;;
  *) die "DM_IOS_TARGET must be device or simulator" ;;
esac
DD=$O/dd
MODS=$(gp modules); MARKER=$(gp romfs_marker)
NACP=$W/data/v0/control.nacp; [ -f "$NACP" ] || NACP=$(dirname "$ROMFS")/control.nacp
[ -n "${DM_DISPLAY_NAME:-}" ] || DM_DISPLAY_NAME=$(python3 "$DM/tools/nacp.py" "$NACP") || die "no game name in $NACP (re-extract with nx_extract, or set DM_DISPLAY_NAME)"
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.nxnative.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_CATEGORY=$(gp app_category) DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
[ -e "$ROMFS/$MARKER" ] || die "no RomFS at $ROMFS (missing $MARKER)"
V=$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$GD/dmsh_chain.h")
[ -n "$V" ] && ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$' || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"
if [ "$SDK" = iphonesimulator ]; then
  python3 - "$MSL_IOS/b-$V" "$GD/shader_map.tsv" "$V" <<'PY' || die "Simulator shader validation failed"
import json
from pathlib import Path
import sys
root, table, chain = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
for line in table.read_text().splitlines():
    if not line or line.startswith(("#", "package\t")):
        continue
    key = line.split("\t")[3]
    metadata = json.loads((root / f"{key}_b.json").read_text())
    if metadata.get("chain") != chain or metadata.get("metal_platform") != "iphonesimulator":
        sys.exit(f"Wrong shader platform or chain: {key}")
    if not (root / f"{key}_b.metallib").is_file():
        sys.exit(f"Missing Simulator shader library: {key}")
PY
fi

t "app: $DM_DISPLAY_NAME ($DM_BUNDLE_ID)"
t "generate Gen/ (host sources, embedded modules, tables, shader libraries)"
rm -rf Gen && mkdir -p Gen/dm Gen/msl || die "mkdir Gen"
python3 tools/gen_build.py ../host Gen > Gen/dm.xcconfig || die "gen_build"
F=$(python3 tools/gen_embed.py "$PATCHED" Gen/embed.S $MODS) || die "gen_embed"
echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.params.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv Gen/dm/ || die "copy rewriter tables"
cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" Gen/dm/ || die "copy shader tables"
# Diagnostic build: DM_ENV_FILE=file → dm/env.txt in the bundle (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" Gen/dm/env.txt || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
cp -cR "$MSL_IOS/b-$V" Gen/msl/ || die "copy shader libraries"
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p Gen/dm/font && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" Gen/dm/font/standard.ttf || die "copy standard font (STD_FONT=a TTF)"
${FONT_PY:-python3} "$DM/tools/make_ext_font.py" Gen/dm/font/nintendo_ext.ttf > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# App icon: the game's own icon (icon.jpg saved from the control data by nx_extract, the English 256x256 one). DM_ICON can point at another image; by default the icon.jpg next to the RomFS is used.
# It is scaled to a 1024x1024 PNG in the asset catalog Gen/Assets.xcassets (a single-size app icon; actool generates the other sizes); with neither, no icon is set and the home-screen icon is blank.
# The catalog is always created (the project always lists it, see project.yml); without an icon it stays empty and DM_APPICON is not set
ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}
mkdir -p Gen/Assets.xcassets && printf '{"info":{"author":"xcode","version":1}}\n' > Gen/Assets.xcassets/Contents.json || die "asset catalog"
if [ -f "$ICON" ]; then
  AI=Gen/Assets.xcassets/AppIcon.appiconset; mkdir -p "$AI" || die "mkdir $AI"
  sips -s format png -z 1024 1024 "$ICON" --out "$AI/icon.png" > /dev/null || die "sips: cannot convert the icon $ICON"
  printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' > "$AI/Contents.json"
  echo "DM_APPICON = AppIcon" >> Gen/dm.xcconfig
  t "app icon: $ICON"
else t "no app icon ($ICON not found): the home-screen icon stays blank"; fi
xcodegen generate -q > /dev/null || die "xcodegen"

t "xcodebuild (Release, unsigned, $SDK)"
mkdir -p "$O"
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -sdk "$SDK" -destination "$DESTINATION" -derivedDataPath "$DD" \
  "${BUILD_FLAGS[@]}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build > "$O/build.log" 2>&1 \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
# When Xcode's Locations setting is a custom location, products ignore -derivedDataPath: take the actual path from this build's log
APP=$DD/Build/Products/Release-$SDK/DmIOS.app; [ -d "$APP" ] || APP=$(grep -o "/[^ ]*/Release-$SDK/DmIOS\\.app" "$O/build.log" | tail -1)
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"
if [ "$SDK" = iphonesimulator ]; then
  xcrun vtool -show-build "$APP/DmIOS" | grep -q 'platform IOSSIMULATOR' || die "executable is not built for the iOS Simulator"
fi

t "assemble $STAGE (app + RomFS)"
rm -rf "$O/$STAGE" && mkdir -p "$O/$STAGE" && cp -cR "$APP" "$O/$STAGE/DmIOS.app" || die "copy app"
A=$O/$STAGE/DmIOS.app; rm -rf "$A/_CodeSignature" "$A/embedded.mobileprovision"
cp -cR "$ROMFS" "$A/romfs" || die "copy RomFS"

t "zip (already-compressed game files stored, everything else deflated)"
if [ "$SDK" = iphonesimulator ]; then
  rm -f "$O/out.zip"
  ( cd "$O/$STAGE" && zip -qry -n "$(gp zip_store)" ../out.zip DmIOS.app ) || die "zip Simulator app"
  mv "$O/out.zip" "$OUT_IPA" || die "move Simulator archive"
  t "Simulator app: $A"
else
  rm -f "$O/out.ipa"
  ( cd "$O" && zip -qry -n "$(gp zip_store)" out.ipa Payload ) || die "zip"
  mv "$O/out.ipa" "$OUT_IPA" || die "move ipa"
  rm -rf "$O/Payload"
fi
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
