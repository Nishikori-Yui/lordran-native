#!/bin/bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Set up the native macOS build tools and optionally build an IPA or macOS app.

Usage:
  bash scripts/setup_macos_packaging.sh [options]

Options:
  --target setup-only|ipa|macos-app   Configure tools only, or build an artifact.
                                      Default: setup-only.
  --nsp-dir PATH                      Folder under game/ containing your NSPs.
                                      Default: game/01004AB00A260000.
  --keys PATH                         Your prod.keys file under game/.
                                      Default: game/01004AB00A260000/prod.keys.
  --out PATH                          Output IPA or .app path under game/.
  --keep-extracted                    Keep extracted game files after building.
  -h, --help                          Show this help.

This script installs public tools only. It never downloads NSPs or keys.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(cd -- "$script_dir/.." && pwd -P)"
game_dir="$repo/game/01004AB00A260000"
target=setup-only
nsp_dir="$game_dir"
keys="$game_dir/prod.keys"
out=""
keep_extracted=0

while (($#)); do
  case "$1" in
    --target|--nsp-dir|--keys|--out)
      (($# >= 2)) || die "Missing value for $1"
      option="$1"; value="$2"; shift 2
      case "$option" in
        --target) target="$value" ;;
        --nsp-dir) nsp_dir="$value" ;;
        --keys) keys="$value" ;;
        --out) out="$value" ;;
      esac
      ;;
    --keep-extracted) keep_extracted=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

case "$target" in
  setup-only|ipa|macos-app) ;;
  *) die "--target must be setup-only, ipa, or macos-app" ;;
esac

[[ "$(uname -s)" == Darwin ]] || die 'Run this script on macOS.'
[[ "$(uname -m)" == arm64 ]] || die 'The standard Mac build requires an Apple silicon Mac.'
command -v brew >/dev/null 2>&1 || die 'Homebrew is required. Install it from https://brew.sh, then rerun this script.'
command -v xcodebuild >/dev/null 2>&1 || die 'Install Xcode from the Mac App Store, open it once, accept its license, then rerun this script.'

if ! xcodebuild -version >/dev/null 2>&1 ||
   ! xcrun --sdk iphoneos --show-sdk-version >/dev/null 2>&1 ||
   ! xcrun --sdk iphoneos metal --version >/dev/null 2>&1; then
  die 'Xcode is not ready. Open Xcode, finish first-launch setup and accept its license, then rerun this script.'
fi

brew_prefix="$(brew --prefix)"
export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"

install_formula() {
  local formula="$1"
  if ! brew list --formula --versions "$formula" >/dev/null 2>&1; then
    printf '\n==> Installing %s with Homebrew\n' "$formula"
    brew install "$formula"
  fi
}

for formula in python@3.12 xcodegen zstd spirv-cross; do
  install_formula "$formula"
done

dotnet_root=""
for candidate in \
  "$(brew --prefix dotnet 2>/dev/null || true)/libexec" \
  "$brew_prefix/share/dotnet" \
  /usr/local/share/dotnet; do
  if [[ -n "$candidate" && -d "$candidate/host/fxr" ]]; then
    dotnet_root="$candidate"
    break
  fi
done

has_dotnet10() {
  command -v dotnet >/dev/null 2>&1 &&
    dotnet --list-sdks 2>/dev/null | grep -Eq '^10\.'
}

if ! has_dotnet10; then
  printf '\n==> Installing the .NET SDK with Homebrew\n'
  brew install --cask dotnet-sdk || die 'Install the .NET 10 SDK from https://dotnet.microsoft.com/download/dotnet/10.0, then rerun this script.'
  hash -r
  for candidate in "$brew_prefix/share/dotnet" /usr/local/share/dotnet; do
    if [[ -d "$candidate/host/fxr" ]]; then
      dotnet_root="$candidate"
      break
    fi
  done
fi

has_dotnet10 || die 'The .NET 10 SDK is not available. Install .NET 10 and rerun this script.'
if [[ -n "$dotnet_root" ]]; then
  export DOTNET_ROOT="$dotnet_root"
  export DOTNET_ROOT_ARM64="$dotnet_root"
fi

python_prefix="$(brew --prefix python@3.12)"
python="$python_prefix/bin/python3.12"
[[ -x "$python" ]] || die "Python 3.12 was not found at $python"
venv="$game_dir/tools-venv-mac"
mkdir -p "$game_dir"
"$python" -m venv "$venv"
venv_python="$venv/bin/python"
"$venv_python" -m pip install --upgrade pip
"$venv_python" -m pip install lz4 capstone fonttools

printf '\n==> Checking the Mac build environment\n'
"$venv_python" "$repo/scripts/player_support.py" doctor --route mac

printf '\nSetup complete.\n'
printf 'Python: %s\n' "$venv_python"
printf 'DOTNET_ROOT: %s\n' "${DOTNET_ROOT:-not set}"
printf 'Private game directory: %s\n' "$game_dir"
printf 'No NSP, key, or game data was downloaded by this script.\n'

if [[ "$target" == setup-only ]]; then
  printf '\nNext: use --target ipa or --target macos-app with your owned NSPs and prod.keys.\n'
  exit 0
fi

[[ -d "$nsp_dir" ]] || die "NSP folder does not exist: $nsp_dir"
[[ -f "$keys" ]] || die "prod.keys file does not exist: $keys"

nsp_dir="$(cd -- "$nsp_dir" && pwd -P)"
keys="$("$venv_python" -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$keys")"
private_root="$(cd -- "$repo/game" && pwd -P)"
case "$nsp_dir/" in "$private_root/"*) ;; *) die "Keep the NSP folder under this checkout's game/ directory." ;; esac
case "$keys" in "$private_root/"*) ;; *) die "Keep prod.keys under this checkout's game/ directory." ;; esac

default_ipa="$("$venv_python" - "$repo" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/dm/games")
import game
print(game.load().get("ipa"))
PY
)"
if [[ -z "$out" ]]; then
  if [[ "$target" == ipa ]]; then
    out="$nsp_dir/$default_ipa"
  else
    out="$nsp_dir/LordranNative.app"
  fi
fi

out_parent="$(cd -- "$(dirname -- "$out")" 2>/dev/null && pwd -P)" || die "Output parent directory does not exist: $(dirname -- "$out")"
out="$out_parent/$(basename -- "$out")"
case "$out" in "$private_root/"*) ;; *) die "Keep the output artifact under this checkout's game/ directory." ;; esac
if [[ "$target" == macos-app && "${out##*.}" != app ]]; then
  die 'A macOS app output path must end in .app.'
fi

build_args=("$repo/scripts/build_ipa_from_nsp.py" "$nsp_dir" --keys "$keys")
if [[ "$target" == macos-app ]]; then
  build_args+=(--target macos-app)
fi
build_args+=(--out "$out")
if ((keep_extracted)); then
  build_args+=(--keep-extracted)
fi

printf '\n==> Building %s\n' "$target"
"$venv_python" "${build_args[@]}"

if [[ "$target" == ipa ]]; then
  printf '\n==> Verifying the IPA archive\n'
  "$venv_python" "$repo/scripts/player_support.py" verify "$out" --target device --full-crc
else
  /usr/bin/plutil -lint "$out/Contents/Info.plist"
  printf 'macOS app created: %s\n' "$out"
  printf 'The app is unsigned; local launch may require right-click > Open if Gatekeeper warns.\n'
fi
