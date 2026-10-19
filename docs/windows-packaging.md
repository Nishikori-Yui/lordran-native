# Windows packaging (experimental)

[简体中文](windows-packaging.zh-CN.md)

`LordranNative-shell-build-input.zip` is an unsigned iOS build input with no game files. It contains the host executable, the public game-profile tables and font resources only. It is not an installable app. The `Build unsigned iOS shell` GitHub Actions workflow runs only manually or when a tag is pushed, and uploads the ZIP as a 30-day artifact. Ordinary commits and pull requests do not trigger a build. For a tag with an existing GitHub release, the workflow also attaches the ZIP to that release. If the release is created afterward, rerun the workflow manually on that tag to attach the shell.

## Requirements

- Windows 10/11 x64, Python 3.12 or later, and .NET 10 SDK.
- `zstd` on `PATH` for shader-container extraction.
- `spirv-cross` must match the repository's locked binary fingerprint. The packer checks its SHA-256 prefix before translating; the upstream source tag is not a substitute for this check.
- SPIRV-Cross built from upstream tag `vulkan-sdk-1.4.357.0`. Install CMake and Ninja, then build it with:

  ```powershell
  git clone --branch vulkan-sdk-1.4.357.0 --depth 1 https://github.com/KhronosGroup/SPIRV-Cross
  cmake -S SPIRV-Cross -B SPIRV-Cross/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DSPIRV_CROSS_ENABLE_TESTS=OFF
  cmake --build SPIRV-Cross/build --target spirv-cross
  $env:Path += ";$PWD\SPIRV-Cross\build\bin\Release"
  ```

- The base NSP, the 1.0.3 update NSP (`v196608`), and your own `prod.keys`.
- About 15 GB free for extracted files, shader work and caches.

Check the tools in the same PowerShell window that will run the build:

```powershell
py -3 --version
dotnet --list-sdks
spirv-cross --version
zstd --version
```

The translation step performs a binary-fingerprint check. If the SPIRV-Cross
binary built from the command above does not match the locked hash, the script
stops rather than silently accepting a different translator. Follow the exact
binary/version instructions printed by the error; do not edit `dmsh_chain.lock`
or `dmsh_chain.h` to work around it.

## Build

Use the source checkout from the same GitHub release as the shell. Keep the NSPs, key file, work output and IPA under `game/`; this directory is ignored by Git.

```powershell
py -3 -m pip install lz4 capstone
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip
```

The builder checks the shell's source fingerprint, profile, shader chain and shader inventory before use. It identifies the NSP title IDs and versions, checks rewritten module build IDs against the profile, builds the in-repository shader translator, extracts and rewrites the selected game build, translates all profile shaders to MSL, creates `Guest.framework`, and assembles the IPA. Intermediates and logs stay in `<NSP folder>/01004AB00A260000_shell_build/`; extraction is deleted after success unless `--keep-extracted` is passed. Add `-p v0` to package the base game after the required shader versions have been extracted.

Useful options:

```powershell
# Preserve extracted ExeFS/RomFS after a successful build.
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --keep-extracted

# Pack the registered base-game build instead of the default update build.
py -3 scripts/build_ipa_from_shell.py game/01004AB00A260000 `
  --keys game/01004AB00A260000/prod.keys `
  --shell game/01004AB00A260000/LordranNative-shell-build-input.zip `
  --package v0 `
  --out game/01004AB00A260000/DarkSoulsRemastered-v0.ipa

# Show every supported option without reading the game files.
py -3 scripts/build_ipa_from_shell.py -h
```

The output directory must remain under this checkout's `game/`. The default
output is `<NSP folder>/DarkSoulsRemastered.ipa`. Do not run two builds against
the same work folder concurrently.

## Install and first launch

The ZIP downloaded from Actions is only a shell input. Sign and sideload the generated IPA with a tool such as AltStore or Sideloadly. The tool must replace the placeholder signing identity with your own. Because Windows cannot run Apple's Metal compiler, the IPA contains MSL source in place of precompiled libraries. On first use, iOS compiles each shader as it is loaded and caches the result; initial scene loads can take several minutes. Later launches reuse the system cache. This path has not been verified on every iOS device.

## Troubleshooting

- **Shell/source mismatch:** download the shell and checkout the same release tag.
- **Unsupported title or build ID:** use the Dark Souls: Remastered base NSP and a profile-registered version. This repository supports title `01004AB00A260000` only.
- **Missing tools:** confirm `dotnet`, `spirv-cross`, `zstd`, and `py -3` resolve in the same PowerShell session. Install `lz4` and `capstone` into the interpreter used by the command.
- **SPIRV-Cross fingerprint mismatch:** use the binary matching `dm/gfx/tools/dmsh_chain.lock`. A source release tag alone does not guarantee an identical binary. Do not change the lock unless intentionally changing the shader toolchain for the whole project.
- **Extraction failure:** check the matching `nx_extract_build.log` or `extract_<version>.log`; confirm the base and update NSP are complete, the keys file is the user's own valid `prod.keys`, and there is enough disk space. Never print the keys or copy them into a log.
- **Module build ID mismatch:** the NSP version is not registered in `dm/games/01004AB00A260000/game.tsv`; stop rather than bypassing the check.
- **Shell ZIP missing/unexpected paths:** the shell producer allowlist and consumer allowlist intentionally fail closed. Do not broaden either allowlist until proving each new resource is public and contains no game-derived or private data.
- **IPA will not install:** the packager emits unsigned output by design. Use a supported sideloading workflow to sign it with the user's identity; do not add CI signing or commit certificates/profiles.
- **Shader chain mismatch or missing shader keys:** use the matching shell/source release and SPIRV-Cross tag above; do not mix cached shader output from another build.
- **First launch is slow:** this is expected for a source-shader IPA. Keep the app in the foreground until shader compilation finishes.

This route is experimental. Mac/Xcode remains the recommended path when available because it compiles the shaders before installation.
