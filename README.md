# Lordran Native

[English](README.md) | [简体中文](README.zh-CN.md)

Lordran Native brings **Dark Souls: Remastered** (`01004AB00A260000`) natively to Apple platforms. The game's ARM64 code runs directly on Apple hardware. The rewriter adapts kernel-dependent instructions, the host provides Horizon services, and the graphics layer implements NVN on Metal.

This project is based on [seedds/nxnative](https://github.com/seedds/nxnative) and is now maintained independently, with a focus on Dark Souls: Remastered.

**The port is experimental.** Mac bring-up is the primary development target; the iOS build produces an unsigned IPA for iPhone and iPad. Graphics and device compatibility still need validation. This repository supports Dark Souls: Remastered only (`01004AB00A260000`).

You need your own game NSPs and `prod.keys`. The repository contains no game files or keys and is not affiliated with Nintendo or the game's publishers.

## Requirements

- An Apple silicon Mac with Xcode and Homebrew to build the port.
- The base game NSP and the **1.0.3 update** (`v196608`). Both are required for shader extraction, even when packing the base version.
- Your own `prod.keys`.
- For the IPA: an iPhone or iPad running **iOS / iPadOS 26 or later**, and a sideloading tool.
- Free disk space of roughly twice the total NSP size plus 10 GB.

## Build an unsigned IPA

### 1. Install the build tools

```sh
git clone https://github.com/Nishikori-Yui/nxnative.git lordran-native
cd lordran-native
brew install xcodegen zstd spirv-cross
brew install --cask dotnet-sdk
python3 -m pip install lz4 capstone fonttools
```

The build also requires the .NET 10 SDK and Xcode's Metal compiler. If Python requires a virtual environment, install the Python packages there and use that environment for the build command.

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

### 4. Sideload the IPA

Use your sideloading tool to sign and install the unsigned IPA. The app uses the game's name and icon from the NSP.

## Controls

- **Touch:** the left stick moves your character. In the 3D layout, swipe empty screen space to turn the camera; stopping or lifting your finger stops the turn. Buttons are handled separately, and R3 locks on to a target.
- **Floating menu:** tap the semi-transparent edge-docked ball to open controls. It contains the FPS switch, timestamped log export and input settings. In **Edit controls**, drag a framed control to move it, drag its lower-right handle to resize it, and use the centre **Done** button to save. Rotation, opacity and shape are adjusted for the selected control.
- **Controller:** connecting a physical controller hides the touch controls by default and provides the full button layout. The menu supports controller selection, automatic Nintendo/Xbox face mapping and a configurable stick dead zone.
- **Mac:** use a DualSense controller, or the PC-style keyboard and mouse mapping. Launch the host with `DM_WINDOW=1` to open a game window.

## Settings and saves

On iOS, open the semi-transparent floating menu to change the language, operation mode, FPS display and other input settings. Language and operation mode changes ask for confirmation and restart the app so the game can load them from the next launch. Other diagnostic switches still live in `Documents/env.txt`, with one `KEY=VALUE` per line.

The menu owns the language, operation mode and performance-panel settings; do not add these three values to `env.txt`.

The performance panel shows displayed FPS and frame time. Tap it to expand or collapse game FPS, GPU time, memory, resolution and thermal status.

Saves are in `save/`. Before reinstalling, back up `save/` and `pso_user.tsv`: some sideloading tools create a new app data folder. Restore both to retain your saves and pipeline prewarm list.

The first visit to a scene can stutter while Metal compiles new pipelines. The app records them in `pso_user.tsv` for prewarming on later launches.

## Troubleshooting

If the game fails to start, exits unexpectedly or renders incorrectly, export a diagnostic report:

1. Open the semi-transparent floating menu and tap **Export log / 导出日志**. The menu remains available while the performance panel is hidden.
2. Save or share the timestamped diagnostic report (`*-diagnostics-<UTC timestamp>-<ID>.txt`) using the system share sheet. A copy is also stored in the app's `diagnostics/` folder.
3. Include your device model, OS version and the steps that caused the problem.

After an interrupted foreground session, the next launch offers diagnostic export before starting the game again. Reports include the current and previous app logs, device/GPU information and a performance snapshot. Each log is limited to its last 8 MiB. Reports do not include saves, game files or system crash reports.

You can also retrieve `log.txt` and `log.prev.txt` from the app's folder. New log lines use UTC timestamps with millisecond precision; retained logs from older builds keep their original text. Build failures are recorded in `01004AB00A260000_build/logs/` beside the NSPs.

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
