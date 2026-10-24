# Lordran Native

[English](README.md) | [简体中文](README.zh-CN.md)

Lordran Native brings **Dark Souls: Remastered** (`01004AB00A260000`) natively to Apple platforms. The game's ARM64 code runs directly on Apple hardware. The rewriter adapts kernel-dependent instructions, the host provides Horizon services, and the graphics layer implements NVN on Metal.

This project is based on [seedds/nxnative](https://github.com/seedds/nxnative) and is now maintained independently, with a focus on Dark Souls: Remastered.

**The port is experimental.** Mac bring-up is the primary development target; the iOS build produces an unsigned IPA for iPhone and iPad. Graphics and device compatibility still need validation. This repository supports Dark Souls: Remastered only (`01004AB00A260000`).

You need your own game NSPs and `prod.keys`. The repository contains no game files or keys and is not affiliated with Nintendo or the game's publishers.

## Requirements

- For the standard build route: an Apple silicon Mac with Xcode and Homebrew.
  The [Mac packaging guide](docs/macos-packaging.md) includes a setup script
  for building an iOS IPA or a local macOS app.
- For the experimental Windows shell route: 64-bit Windows 10/11 and the
  [Windows packaging guide](docs/windows-packaging.md), which includes an
  automated PowerShell setup script.
- The base game NSP and the **1.0.3 update** (`v196608`). Both are required for shader extraction, even when packing the base version.
- Your own `prod.keys`.
- For the IPA: an iPhone or iPad running **iOS / iPadOS 26 or later**, and a sideloading tool.
- Free disk space of roughly twice the total NSP size plus 10 GB.

## One-command Mac setup

Install Xcode from the Mac App Store and Homebrew first. From the repository
root, this command installs the remaining public tools and checks the
environment without reading any game files:

```bash
bash scripts/setup_macos_packaging.sh --target setup-only
```

For networks in mainland China, the [Chinese Mac guide](docs/macos-packaging.zh-CN.md#配置构建环境)
provides session-only USTC Homebrew and TUNA PyPI settings, their coverage limits,
and commands to retry with official sources. The script does not choose mirrors by locale.

To configure the environment and build an unsigned iOS IPA in one run:

```bash
bash scripts/setup_macos_packaging.sh \
  --target ipa \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

To build a local macOS `.app` instead, change the target:

```bash
bash scripts/setup_macos_packaging.sh \
  --target macos-app \
  --nsp-dir "$PWD/game/01004AB00A260000" \
  --keys "$PWD/game/01004AB00A260000/prod.keys"
```

Put your own base-game NSP, `v196608` update NSP, and `prod.keys` under the
private `game/01004AB00A260000/` folder before building. The script installs
public tools only; it never downloads game files or keys. See the
[Mac packaging guide](docs/macos-packaging.md) for Xcode requirements, output
locations, savedata, replacement, and troubleshooting.

## Let an agent help

If you use Codex, Claude Code, or another agent with access to local files and
commands, copy one of these prompts. The [player support skill](skills/lordran-native-support/SKILL.md)
selects the existing guides and tools for your task. It can be read directly;
installing it through your agent's supported skill installer is optional. Use
the skill folder from the same repository revision, and let the agent know
which local checkout or release you are using.

**Prepare the environment and package:**

```text
Help me set up Lordran Native on this macOS or Windows computer. Read
https://raw.githubusercontent.com/Nishikori-Yui/lordran-native/main/skills/lordran-native-support/SKILL.md
and follow the applicable repository documents it links. Check the tools
already installed, help prepare the missing dependencies, and package my
owned local game inputs with the matching source and shell when ready.
Keep game files and keys local. Tell me the exact action when a step needs
administrator approval or manual SDK installation, and wait for me.
Verify the unsigned output and report which checks actually passed.
```

**Prepare a bug report:**

```text
Help me prepare feedback for Lordran Native from my attached diagnostic
report and reproduction description. Read
https://raw.githubusercontent.com/Nishikori-Yui/lordran-native/main/skills/lordran-native-support/SKILL.md
and the current issue template it links. Review and sanitize relevant
evidence, keep unverified facts marked as unknown, and give me Markdown
that I can preview and paste. Suggest an existing issue if one matches.
Prepare feedback only; ask before publishing or starting a code fix.
```

The feedback task does not require a GitHub login or a build environment.
Without a checkout, the agent can read the public template and prepare the
draft in the conversation. Review any redactions before sharing.

### Local support commands

From a checkout, these Python commands provide reproducible checks. On Windows
use `py -3`, or the virtual environment's Python executable, in place of
`python3`. They use the existing packers and templates.

```sh
# Inspect tools without installing anything or extracting game inputs.
python3 scripts/player_support.py doctor

# Create timestamped draft and excerpt files under game/.
python3 scripts/prepare_issue.py "path/to/diagnostic-report.txt" --symptom "Describe the problem" --step "Describe the triggering action"

# Show a packaging command without starting it.
python3 scripts/player_support.py build game/01004AB00A260000 --keys game/01004AB00A260000/prod.keys --dry-run

# Check a device IPA without installing or running it.
python3 scripts/player_support.py verify game/01004AB00A260000/LordranNative.ipa
```

Remove `--dry-run` to run the existing packer after the environment checks;
successful packaging is followed by archive inspection. Windows builds require
`--shell` and the tool fingerprint from the [Windows guide](docs/windows-packaging.md).
The default support-build output is timestamped; an explicit existing output
requires approval and `--replace`.

Doctor reports missing dependencies, the SDK matching the extractor project,
profile/chain consistency, and available disk space. Use `doctor --route shell
--shell <matching-shell.zip>` to also run the shell consumer's compatibility
checks; omit `--shell` when checking tools before a download. The command does
not install tools or verify the contents of your keys.

Archive inspection checks the arm64 platform, app layout, game-data marker,
shader inventory and reflection chain. It distinguishes a shell input, device
IPA, and Simulator archive. Use `--target simulator` for the latter. Optional
`--full-crc` reads every archive entry to check CRCs; `--match-source` additionally
requires a shell manifest matching this exact checkout. The default check does
not compare source fingerprints. No signing or runtime result is inferred.

For feedback, select `--kind performance` for the performance template and
provide `--expected`, `--actual`, `--frequency`, or repeated `--step` arguments
when known. Give `--build` only for an independently verified source revision.
The helper preserves the current/previous log distinction and treats metadata
as an export snapshot. It does not alter the original report, publish issues,
or make network requests. Optional `--issues-json <file>` accepts a local
`gh issue list --state all --json number,title,state --limit 100` snapshot and
suggests title matches for review; matching is not proof of a duplicate.
Use `--out-dir` for another private output directory under `game/`.

## Build an unsigned IPA

### 1. Install the build tools

```sh
git clone https://github.com/Nishikori-Yui/lordran-native.git lordran-native
cd lordran-native
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m venv game/01004AB00A260000/tools-venv
source game/01004AB00A260000/tools-venv/bin/activate
python -m pip install lz4 capstone fonttools
```

The build also requires the .NET 10 SDK and Xcode's Metal compiler. Use the
virtual environment's interpreter for the checks and build. If a package
manager installs a different SDK series, install the SDK matching the project
as reported by doctor; keep other working SDKs.

### 2. Prepare the game files

Keep your NSPs and keys under the game's private work folder in `game/`, which is excluded from Git. For example:

```text
game/01004AB00A260000/
  prod.keys
  [01004AB00A260000][v0].nsp
  [01004AB00A260800][v196608].nsp
```

### 3. Run the packer

From the repository root:

```sh
python3 scripts/build_ipa_from_nsp.py game/01004AB00A260000 -k game/01004AB00A260000/prod.keys -o game/01004AB00A260000/LordranNative.ipa
```

This command writes `game/01004AB00A260000/LordranNative.ipa`. Without `-o`, the output filename comes from the game profile. Intermediate files, shader caches and build logs stay in `01004AB00A260000_build/` beside the NSPs. The first build extracts the game and translates its shaders; later builds reuse the caches. Extracted game files are deleted after a successful build unless you pass `--keep-extracted`.

Run `python3 scripts/build_ipa_from_nsp.py -h` for options, including `-o` for the output path and `--app-name` for the home-screen name. See the [development guide](docs/development.md) for version selection and manual Mac builds.

A separate opt-in `--experimental-60fps` packaging option adjusts the limiter
argument for the verified 1.0.3 build, with build-ID and instruction checks.
It preserves the limiter function, stays off by default, and is not a guarantee
of correct gameplay timing or sustained 60 FPS. Do not combine it with imported
cheats or patches.

Experimental local cheats and IPS/IPS32 patches (including a 60 FPS candidate)
can be imported when building, with an optional in-game switchable mode. Patch
files must match the main NSO build ID. Runtime groups start off by default;
open **Cheats** from the iOS floating menu, or press F6 on Mac (F7/F8 to select,
F9 to toggle). See [supported formats and usage](docs/development.md#experimental-static-cheats-and-60-fps-patches).

For an experimental Apple silicon iOS Simulator build, follow the [Simulator build steps](docs/development.md#build-for-ios-simulator-apple-silicon). It produces a separate `.app.zip` rather than a device IPA.

### Build on Windows without Xcode

This is an experimental route for users who do not have access to Xcode. The
[Windows packaging guide](docs/windows-packaging.md) is the complete runbook.
It includes a PowerShell script that installs the public build dependencies,
builds the pinned SPIRV-Cross tool, creates the repository-local Python
environment, and runs the read-only preflight check. It never downloads NSPs,
keys, or other private game data.

From the repository root, run this in PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1
```

Use `-PipIndexUrl 'https://pypi.tuna.tsinghua.edu.cn/simple'` to select TUNA PyPI
for this run, or another approved HTTPS index. Windows setup keeps pip isolated,
so `PIP_INDEX_URL` alone does not change its index. The default is official PyPI;
public tool archives still use their existing official sources. See the
[Windows guide](docs/windows-packaging.md#python-package-mirrors).

winget and Microsoft Store are optional: the script reuses compatible tools,
then uses winget or verified official portable downloads for missing ones.
Add `-NoWinget` to use official downloads explicitly. A working Clang/MinGW
compiler can be reused; only machines without a usable C++ compiler need the
Visual Studio installer, which may request administrator approval. Public
downloads and SPIRV-Cross require an Internet connection. The script also
prints the exact path and SHA-256 needed by the later packaging command. After
it finishes, download the matching shell ZIP from the same release, then put
the base game NSP, the 1.0.3 update NSP, and your own `prod.keys` in the
private `game/01004AB00A260000/` directory (that directory is ignored by Git).

New shell filenames include the exact release tag, for example
`LordranNative-shell-build-input-v0.2.0.zip`, or `dev-<12-character-commit>`
for development builds. This is a naming example, not a recommendation to use
an unreleased tag. Keep the downloaded filename. `-Build` discovers a single
versioned or legacy shell ZIP in that directory; if more than one exists, pass
`-ShellZip <matching-file>` explicitly. Historical releases keep their original
unversioned assets. Filenames do not replace the source/manifest checks.

To install dependencies and build the unsigned IPA in one run after placing all
four inputs above, use `-Build`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -Build
```

If setup has already completed, add `-SkipInstall -SkipSpirvCross -Build` to
recheck the saved toolchain and build without reinstalling it. The script
verifies the resulting IPA; signing and sideloading remain your steps.

If you are following the manual fallback in the [Windows guide](docs/windows-packaging.md#2-requirements) instead of the setup script, first build the pinned SPIRV-Cross executable and record `$spirvCrossSha256`. Create a private Python environment, then use its interpreter for the preflight and build. This avoids changing PowerShell's activation policy or installing dependencies into another Python environment:

```powershell
py -3 -m venv game/01004AB00A260000/tools-venv
$python = (Resolve-Path game/01004AB00A260000/tools-venv/Scripts/python.exe).Path
& $python -m pip install lz4 capstone fonttools
& $python scripts/player_support.py doctor --route shell
$Shell = 'game/01004AB00A260000/LordranNative-shell-build-input-v0.2.0.zip' # Use your downloaded filename.
& $python scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell $Shell `
  --spirv-cross-sha256 $spirvCrossSha256
```

Once the shell is downloaded, add `--shell $Shell` to the doctor check. The [support build command](#local-support-commands) can preview a build with `--dry-run` and structurally verify its output.

The shell and source checkout must come from the same release. Before building, follow the [Windows packaging notes](docs/windows-packaging.md) to build the pinned SPIRV-Cross source and record its SHA-256 in `DM_SPIRV_CROSS_SHA256` (or pass `--spirv-cross-sha256`). The script checks the title and registered module builds, rewrites the game modules locally, and creates an unsigned IPA. It does not upload NSPs, keys, extracted files or the finished IPA. This no-Xcode route ships translated Metal source, so the iPhone compiles shaders on first launch; the first visit can take several minutes. The normal Mac route still compiles shaders ahead of time. The shell ZIP is build input, not an installable app; sideload and sign only the resulting IPA.

### App Version And Build Identity

Native iOS, Simulator, macOS app, and new shell builds share the same version
resolver. At the exact `v0.2.0` tag, the displayed app version is `0.2.0`.
The Apple build version is `1.2.0`: its first component is the tag's major
version plus one because Apple requires a positive first build component.
Prerelease/build suffixes (for example `v0.2.0-rc.1+build.7`) stay in the full
source identity, not the numeric Apple fields. Arbitrary non-SemVer tags use
display version `0.0.0` / build `1.0.0`, with the full tag still recorded.

Development commits use `0.0.0` / `1.0.0` and `dev-<commit>`; the resolver never
uses the nearest older tag. Modified code uses `dev-<commit>-dirty-<content-hash>`
and the numeric development fallback. A source download without `.git` uses
`dev-source-<content-hash>`, not a guessed release. Windows packaging retains
the prebuilt shell's identity even without Git. Old shells keep their original
versions and are identified by their source fingerprint rather than a guessed
tag. The complete identity is stored in `dm/app-version.json`, included in iOS
diagnostic exports and logged by the macOS app launcher. See the
[Mac guide](docs/macos-packaging.md#app-version-metadata) and
[Windows guide](docs/windows-packaging.md#app-version-metadata) for constraints.

### 4. Sideload the IPA

Use your sideloading tool to sign and install the unsigned IPA. The app uses the game's name and icon from the NSP.

The default Bundle ID is `dev.nishikori.lordran-native`, shared by the
native, Simulator, and CI shell builds. Use `--bundle-id` with either Python
packer or the support build command to override it; manual builds accept
`DM_BUNDLE_ID`. Windows injection retains the shell's ID unless overridden,
and its Guest framework uses `<app-bundle-id>.guest`.

## Controls

- **Touch:** the left stick moves your character. In the 3D layout, swipe empty screen space to turn the camera; swipe travel is accumulated until the game reads it, without display-tick zeroes overwriting short gestures. A normal lift allows one pending sample; cancellation clears it immediately, and unconsumed motion expires after 100 ms. **Input & controller → Touch camera** provides separate horizontal and vertical inversion switches and sensitivity from 0.05x to 3x with Slow (0.5x), Standard (1x), and Fast (2x) presets. New 1x matches the previous 3x response; saved values migrate once to preserve their previous response. Reset selects the new 1x default. These preferences apply immediately to swiping and the virtual right stick, and are saved for the next launch. Buttons are handled separately, and R3 locks on to a target.
- **Floating menu:** tap the semi-transparent edge-docked ball to open controls. It contains the FPS switch, timestamped log export and input settings. In **Edit controls**, drag a framed control to move it, drag its lower-right handle to resize it, and use the centre **Done** button to save. Rotation, opacity and shape are adjusted for the selected control.
- **Controller:** connecting a physical controller hides the touch controls by default and provides the full button layout. The menu supports controller selection, automatic Nintendo/Xbox face mapping and a configurable stick dead zone.
- **Mac:** use a DualSense controller, or the PC-style keyboard and mouse mapping. Launch the host with `DM_WINDOW=1` to open a game window.

## Settings and saves

On iOS, open the semi-transparent floating menu to change the language, operation mode, FPS display and other input settings. Language and operation mode changes ask for confirmation and restart the app so the game can load them from the next launch. Other diagnostic switches still live in `Documents/env.txt`, with one `KEY=VALUE` per line.

The menu owns the language, operation mode and performance-panel settings; do not add these three values to `env.txt`.

The performance panel shows displayed FPS and frame time. Tap it to expand or collapse game FPS, GPU time, memory, resolution and thermal status.

On Mac, fluorescent green performance text appears directly in the upper-right
corner, with no background or buttons. Press **F5** to cycle
**Simple → Detailed → Off**; some Mac keyboards require **Fn-F5**.
The same action is available in the **View** menu. The mode is saved.
The text does not intercept mouse or keyboard input.

Saves are in `save/`. Before reinstalling, back up `save/` and `pso_user.tsv`: some sideloading tools create a new app data folder. Restore both to retain your saves and pipeline prewarm list.

The first visit to a scene can stutter while Metal compiles new pipelines. The app records them in `pso_user.tsv` for prewarming on later launches.

## Troubleshooting

If the game fails to start, exits unexpectedly or renders incorrectly, export a diagnostic report:

1. Open the semi-transparent floating menu and tap **Export log / 导出日志**. The menu remains available while the performance panel is hidden.
2. Save or share the timestamped diagnostic report (`*-diagnostics-<UTC timestamp>-<ID>.txt`) using the system share sheet. A copy is also stored in the app's `diagnostics/` folder.
3. Include your device model, OS version and the steps that caused the problem.

After an interrupted foreground session, the next launch offers diagnostic export before starting the game again. Reports include the current and previous app logs, device/GPU information and a performance snapshot. Each log is limited to its last 8 MiB. Reports do not include saves, game files or system crash reports.

You can also retrieve `log.txt` and `log.prev.txt` from the app's folder. New log lines use UTC timestamps with millisecond precision; retained logs from older builds keep their original text. Build failures are recorded in `01004AB00A260000_build/logs/` beside the NSPs.

You can give the report and your reproduction description to an agent using
the [feedback prompt](#let-an-agent-help), or fill the issue template yourself.
Keep full private logs out of public issues. The local helper's draft and
excerpt require your review: automatic redaction cannot identify every
personal detail or custom credential.

## Known limitations

- No online features or amiibo support.
- Some graphics paths and water effects remain under investigation on the Mac.
- A successful Mac test or unsigned IPA build does not establish compatibility with a physical iPhone or iPad. See the [bring-up notes](dm/games/01004AB00A260000/bringup.md) for validation evidence and unresolved issues.

## Development

- [Documentation index](docs/README.md): map of the user, development and implementation references.
- [Development guide](docs/development.md): architecture, packer options, manual builds and regression checks.
- [Porting and debugging guide](docs/porting/README.md): extraction, host bring-up, graphics and diagnostics.
- [Game profile](dm/games/README.md): supported builds, game-specific settings and shader data.
- [Graphics layer](dm/gfx/README.md): NVN-to-Metal implementation and tools.

## Acknowledgements

This project is built on other people's work:

- **[seedds/nxnative](https://github.com/seedds/nxnative)**: the project on which Lordran Native is based. Thanks to seedds and its contributors for the foundation on which this port is built.
- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** (MIT): developed the native-execution approach that informed nxnative's foundation.
- **Ryujinx** (MIT): its shader translator (`Ryujinx.Graphics.Shader`, `Ryujinx.Common` and `Spv.Generator` 1.3.2, unmodified in `dm/third_party/ryujinx`) turns the game's Maxwell shaders into SPIR-V. Its emulation of the kernel and system services is also a reference when the host's behaviour is in doubt.
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**: its kernel, mesosphère, is the reference for Horizon's synchronization semantics (address arbiter, condition variables).
- **yuzu**: Maxwell instruction encodings for the shader reference tool, and a cross-check for kernel behaviour.
- **[LibHac](https://github.com/Thealexbarney/LibHac)**: reads NSPs and layers updates over the base game in `dm/tools/nx_extract`. **hactool** did the first extractions.
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**: SPIR-V to Metal Shading Language.
- **deko3d** (zlib): its texture layout size algorithm is ported in `dm/gfx/nvn/nvn_tex.c`.
- **libvpx** (VP9 movies), **stb_vorbis** (movie sound), **libdeflate**, **bcdec** and **NVIDIA FLIP** ship in `dm/third_party` with their licenses ([list](dm/third_party/README.md)).
- **Capstone**, **lz4**, **fontTools** and **XcodeGen** are used by the build.

## License

MIT; see [LICENSE](LICENSE). Third-party components retain their own licenses; see the [third-party inventory](dm/third_party/README.md).
