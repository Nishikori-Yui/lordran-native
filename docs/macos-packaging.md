# macOS setup and packaging

This guide covers the standard Apple silicon Mac route. The setup script can
install the public build dependencies and create either an unsigned iOS IPA or
a local macOS `.app` from your own game files.

## Before you start

You need:

- An Apple silicon Mac running a supported macOS release.
- Xcode installed from the Mac App Store, opened once, and ready to use. The
  script checks Xcode but does not install it or accept its license for you.
- Homebrew. The script uses it to install Python 3.12, XcodeGen, zstd,
  SPIRV-Cross, and the .NET 10 SDK when needed.
- Your own base-game NSP, 1.0.3 update NSP (`v196608`), and `prod.keys` for a
  build. The script never downloads these files.
- Enough free storage for the NSPs, extraction and shader caches, and final
  output. A macOS `.app` contains a local copy of the game data and can be
  several gigabytes.

Keep NSPs, keys, build outputs, and the final app inside the repository's
ignored `game/` directory. Never commit or upload them.

## Set up the tools

Open Terminal, change to the repository root, and run:

```bash
bash scripts/setup_macos_packaging.sh --target setup-only
```

### Optional mirrors for mainland China

Before setup, use USTC for Homebrew bottle downloads and its metadata API,
and TUNA for Python packages. These variables affect the current terminal and
its child processes only; they do not rewrite shell configuration or Git
remotes. Run subsequent IPA/app build commands in the same terminal.

```bash
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
bash scripts/setup_macos_packaging.sh --target setup-only
```

The script does not select mirrors by locale. These mirrors do not proxy every
download: Xcode still comes from Apple, casks such as the .NET SDK and source
archives may still use upstream URLs. Homebrew Git updates and GitHub/NuGet
downloads are unchanged.
Only public dependencies are requested from mirrors, not game inputs or outputs.
Install Homebrew first using its [official instructions](https://brew.sh/) or
consult [USTC's Homebrew help](https://mirrors.ustc.edu.cn/help/brew.git.html).
Keep TLS and package integrity checks enabled.

If a mirror is unreachable, returns HTTP 403, is behind upstream, or returns a
hash mismatch, retry with Homebrew's defaults and official PyPI rather than
disabling verification. For pip's `No matching distribution`, check earlier
`Could not fetch URL` messages: a blocked mirror can cause the same error.

```bash
unset HOMEBREW_BOTTLE_DOMAIN HOMEBREW_API_DOMAIN
export PIP_INDEX_URL="https://pypi.org/simple"
bash scripts/setup_macos_packaging.sh --target setup-only
```

These commands do not change any mirror settings already saved in your shell
configuration. See [USTC bottle help](https://mirrors.ustc.edu.cn/help/homebrew-bottles.html),
[TUNA PyPI help](https://mirrors.tuna.tsinghua.edu.cn/help/pypi/), and the
[Chinese guide](macos-packaging.zh-CN.md#镜像覆盖范围与官方源回退).

### Setup results

The script checks Xcode, installs missing Homebrew dependencies, creates a
repository-local Python environment at
`game/01004AB00A260000/tools-venv-mac`, installs `lz4`, `capstone`, and
`fonttools`, and runs the read-only `doctor` check. It does not extract NSPs,
read key contents, sign apps, or change Xcode settings.

You can also combine setup and the complete build. If the commands below name
the default input locations, first copy your owned files into
`game/01004AB00A260000/`:

```text
game/01004AB00A260000/
  prod.keys
  [01004AB00A260000][v0].nsp
  [01004AB00A260800][v196608].nsp
```

The NSP filenames may differ. Keep one supported base game and its `v196608`
update in the folder.

## Build an iOS IPA

From the repository root, run the setup and build in one command:

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

The unsigned IPA is written next to the NSPs as
`DarkSoulsRemastered.ipa`. The script then checks its archive structure and
CRCs. Sign and install the IPA with your own sideloading tool. The setup script
does not sign apps or store signing credentials.

Use `--out` to choose another output under `game/`:

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys" \
  --out "$PWD/game/01004AB00A260000/LordranNative-test.ipa"
```

## Build a macOS app

To create a local Mac app bundle instead of an iOS IPA:

```bash
bash scripts/setup_macos_packaging.sh \
  --target macos-app \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

The resulting `game/01004AB00A260000/LordranNative.app` contains the native
host, rewritten game modules, the selected RomFS, Mac Metal shader libraries,
and required fonts. NSPs and keys are not copied into the app. The app bundle is
unsigned; if Gatekeeper warns about a locally built app, use Finder's
right-click **Open** action to review and launch it.

The first launch creates writable state under:

```text
~/Library/Application Support/Lordran Native/
  save/
  temp/
  logs/lordran-native.log
```

Back up `save/` before removing or replacing the app if you want to keep
progress. The app is configured for one running instance and opens the normal
Mac game window. The first shader build and app assembly can take a long time.

The setup script refuses to overwrite an existing `.app`. To replace it
deliberately, use the packer directly after setup:

```bash
game/01004AB00A260000/tools-venv-mac/bin/python \
  scripts/build_ipa_from_nsp.py game/01004AB00A260000 \
  --keys game/01004AB00A260000/prod.keys \
  --target macos-app \
  --out game/01004AB00A260000/LordranNative.app \
  --replace
```

You can omit `--replace` to protect an existing app. The app output must stay
inside this checkout's ignored `game/` folder because it contains your game
data.

## Keep extracted data (optional)

By default the packer removes temporary extracted game files after a successful
build. Shader translation caches remain under the private game work folder. To
keep the extracted files as well, pass `--keep-extracted` to the setup script:

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys" \
  --keep-extracted
```

If setup or packaging fails, run `game/01004AB00A260000/tools-venv-mac/bin/python
scripts/player_support.py doctor --route mac` and follow the reported checks.
Detailed manual build steps are in the [development guide](development.md#build-by-hand-mac).

## App version metadata

The app version identifies Lordran Native, not the Nintendo game update selected
by `--package`. Fresh native iOS, Simulator, macOS app and shell builds share
`scripts/app_version.py`; `dm/ios/project.yml` takes its numeric values through
the build scripts rather than hardcoding a version. The shell workflow fetches
tag/history metadata and verifies that a selected tag points at HEAD.

- Exact `vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH` tags set
  `CFBundleShortVersionString` to `MAJOR.MINOR.PATCH`, with no `v` prefix.
- `CFBundleVersion` is `(MAJOR + 1).MINOR.PATCH`, so `v0.2.0` uses `1.2.0`.
  This positive-major mapping is deterministic, not a CI run counter. Supported
  tag components are major 0-9998 and minor/patch 0-99; out-of-range numeric tags
  fail rather than emitting an invalid Apple bundle version.
- Prerelease and build suffixes do not enter Apple's numeric fields. For
  `v0.2.0-rc.1+build.7`, those fields are `0.2.0` and `1.2.0`; the complete tag
  remains in `dm/app-version.json` alongside the full commit ID. Different
  prereleases may share Apple's numeric versions; this is not an App Store
  build-number allocation mechanism.
- Non-SemVer tags retain their complete identity but use numeric fallback
  `0.0.0` / `1.0.0`. Untagged commits and branch Actions runs use that same
  numeric fallback with `dev-<12-character-commit>`, never a nearest older tag.
  Multiple exact local tags require an explicit `GITHUB_REF=refs/tags/<tag>`.
- A checkout with changes under `dm/` or `scripts/` uses the development
  numeric fallback and `dev-<commit>-dirty-<content-hash>`. Its full fingerprint
  and any selected base tag are retained, rather than claiming a clean release.
- Source-only downloads without `.git` use `dev-source-<content-hash>` and the
  numeric development fallback. Build-generated version files are not inputs
  to version resolution; an extracted tree inside another checkout does not
  inherit the enclosing checkout's tag. New shell ZIP names and embedded
  metadata use the same source identity.
- Windows/prebuilt-shell packaging retains the shell's embedded identity and
  numeric versions even when Git is absent. It checks agreement with the shell
  plist and keeps all manifest/source/profile checks. A legacy shell without
  version metadata retains its old plist version and records its manifest
  fingerprint as a legacy identity; the current checkout's tag is not guessed.

The metadata file is `dm/app-version.json` inside the iOS app and
`Contents/Resources/dm/app-version.json` inside the Mac app. iOS diagnostic
exports include the full source identity; the Mac app launcher logs it on each
launch. These records identify a build but do not prove gameplay compatibility,
signing validity, or that a locally modified checkout matches a clean release.
