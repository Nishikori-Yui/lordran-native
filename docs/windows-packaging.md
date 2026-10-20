# Windows packaging (experimental)

[简体中文](windows-packaging.zh-CN.md)

This guide is written for **PowerShell**, not `cmd.exe`. Every command block
below uses PowerShell syntax. Open a new PowerShell window after installing a
tool so that `PATH` changes are visible. PowerShell 7 is recommended; Windows
PowerShell 5.1 also supports the commands in this guide.

This route creates an unsigned iOS IPA on Windows without Xcode. If you have
never used this project before, read the short explanation below before
running commands.

### What the files mean

- **Repository:** a local copy of this source code. The commands below assume
  it is checked out at `C:\src\lordran-native`.
- **Shell ZIP:** a public, game-free build input produced by GitHub Actions.
  It contains native app code and public resources, but no game data. It is
  not an app and cannot be installed directly.
- **NSP:** your own Nintendo Switch game package. You need the base game and
  the 1.0.3 update. They are large files and are not included in this
  repository.
- **`prod.keys`:** your own key file used to read your NSPs. Never upload it
  or paste its contents into a report.
- **IPA:** the unsigned iOS package produced at the end. It must be signed
  with your own Apple account before installation.

The commands are intentionally written as separate PowerShell blocks. Run
them from top to bottom in one PowerShell window; do not paste the `PS>` prompt
if your terminal displays one.

The workflow is:

1. Download a game-free shell ZIP built from the same source revision as this
   checkout.
2. Build the pinned Windows SPIRV-Cross executable and record its SHA-256.
3. Put your own NSP files and `prod.keys` in the ignored `game/` directory.
4. Run the preflight checks, build the IPA, and verify the archive.
5. Sign and sideload the IPA with your own Apple signing workflow.

The shell ZIP is only build input. It is not an installable app and contains no
game files. The GitHub Actions workflow builds it only for a manual dispatch or
a tag push; ordinary commits and pull requests do not trigger it. Workflow
artifacts are retained for 30 days. For a tag with an existing GitHub Release,
the workflow also uploads the ZIP to that release.

## Quick setup (recommended)

The repository includes `scripts/setup_windows_packaging.ps1` for first-time
users. It installs the public tools, configures the Visual Studio C++ workload,
downloads the official zstd command-line tool when it is not already available,
builds the pinned SPIRV-Cross executable, creates the repository-local Python
environment, and runs the read-only preflight check. It never downloads or
opens NSPs, `prod.keys`, or any other private game data.

Run this from the repository root in a normal PowerShell window. The command
uses a temporary execution-policy bypass for this one invocation; it does not
change the machine or user policy permanently:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1
```

The script uses `winget` for Git, Python 3.12, .NET 10, CMake, Ninja, and
Visual Studio Build Tools. The Visual Studio installer can display a UAC prompt
and may take several minutes. An Internet connection is required for public
downloads. At the end, the script prints the SPIRV-Cross executable, its
SHA-256 file, and the Python interpreter path. Keep those values for the
packaging commands below. It uses CMake's Visual Studio generator, so this
automatic route does not require a separate Developer PowerShell window.

The script can be run again safely when the checkout is already prepared. Useful
options are:

```powershell
# Verify an existing installation without installing packages or downloading zstd.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -SkipInstall

# Use an existing zstd.exe instead of downloading the pinned portable copy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -ZstdPath 'C:\tools\zstd.exe'

# Move aside an unexpected SPIRV-Cross directory and clone the pinned source again.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -Force
```

`-SkipVisualStudio` and `-SkipSpirvCross` are intended for machines that have
already been prepared manually. The script still verifies the corresponding
toolchain and saved SPIRV-Cross hash; it does not silently accept an arbitrary
compiler or executable.

After setup, continue with the shell download and private-input steps in
section 5. If setup cannot use `winget`, follow the manual installation
fallback below, then rerun the script with `-SkipInstall`.

## 1. Manual tool installation (fallback)

If Git, Python, or .NET is not installed, the following `winget` commands are
an optional starting point. Run them in a normal PowerShell window, then close
and reopen PowerShell:

```powershell
winget install --id Git.Git -e
winget install --id Python.Python.3.12 -e
winget install --id Microsoft.DotNet.SDK.10 -e
winget install --id Kitware.CMake -e
winget install --id Ninja-build.Ninja -e
```

You also need `zstd.exe` and an MSVC C++ compiler. Install Visual Studio or the
Visual Studio Build Tools with the **Desktop development with C++** workload,
then install a Windows build of zstd and add the folder containing
`zstd.exe` to `PATH`. If `winget` cannot find one of these packages, use the
official installer instead; the project does not require a particular package
manager.

You will use two kinds of PowerShell window:

- **Normal PowerShell:** clone the repository, create the Python environment,
  and run the packaging commands.
- **Developer PowerShell for Visual Studio:** build SPIRV-Cross. Open it from
  the Visual Studio Start-menu folder so `cl.exe` and the Windows SDK are
  already configured.

## 2. Requirements

Use a 64-bit Windows 10 or Windows 11 machine with:

- Python 3.12 or later, available as `py -3`.
- .NET 10 SDK.
- Git, CMake, Ninja, and an MSVC C++ toolchain. The easiest build shell is
  **Developer PowerShell for Visual Studio**, because it sets the compiler
  environment for CMake.
- `zstd.exe` on `PATH` for shader-container extraction.
- About 15 GB free before building. Keep at least 30 GB free if you want to
  retain extracted game data and build caches.
- Your own base NSP, the 1.0.3 update NSP (`v196608`), and your own
  `prod.keys`. Do not put keys in Git, issue reports, or logs.

Install the tools using your organization's approved package source or the
official installers. Close and reopen PowerShell afterward. Confirm the tools
in the **same PowerShell window** that will run the build:

```powershell
$ErrorActionPreference = 'Stop'
py -3 --version
dotnet --list-sdks
git --version
cmake --version
ninja --version
zstd --version
```

The first command must report Python 3.12 or newer, and the SDK list must
contain a .NET 10 SDK. If a command is not recognized, fix `PATH` before
continuing; do not mix tools from different shells.

## 3. Download the repository and define paths

If you do not already have a checkout, run this in a normal PowerShell window.
Use a release tag when possible; the shell ZIP and the source checkout must
come from the same release.

```powershell
New-Item -ItemType Directory -Force -Path 'C:\src' | Out-Null
Set-Location 'C:\src'
git clone https://github.com/Nishikori-Yui/lordran-native.git
Set-Location 'C:\src\lordran-native'
```

If you were told to use a particular release tag, replace `v0.1.0` below with
that tag. If you are following the repository's current development branch,
keep the checkout and shell from the same commit instead.

```powershell
git fetch --tags
git checkout v0.1.0
```

Now define the paths used by the rest of this guide. Replace the first path
only if you cloned the repository somewhere else. These are PowerShell
variables and are reused by the copyable commands below.

```powershell
$ErrorActionPreference = 'Stop'
Set-Location 'C:\src\lordran-native'

$Repo = (Get-Location).Path
$GameDir = Join-Path $Repo 'game\01004AB00A260000'
$Keys = Join-Path $GameDir 'prod.keys'
$Shell = Join-Path $GameDir 'LordranNative-shell-build-input.zip'
$Output = Join-Path $GameDir 'LordranNative-Windows.ipa'
$BuildWork = Join-Path $GameDir '01004AB00A260000_shell_build'

New-Item -ItemType Directory -Force -Path $GameDir | Out-Null
Write-Host "Repository: $Repo"
Write-Host "Private game directory: $GameDir"
```

The repository's `game/` directory is ignored by Git. Keep NSPs, keys, shell
ZIPs, extracted files, logs, and IPA outputs there. The builder refuses output
paths outside this checkout's `game/` directory.

## 4. Build pinned SPIRV-Cross

Windows must use SPIRV-Cross built from this exact upstream source:

- Tag: `vulkan-sdk-1.4.357.0`
- Commit: `6c09849fe88c48eaed08413aa022aaa136a3a057`

Run this section from **Developer PowerShell for Visual Studio**. Choose an
empty parent directory. The script below deliberately stops if the checkout
already exists, so it cannot silently build from an unknown source tree.

```powershell
$ToolRoot = Join-Path $env:USERPROFILE 'src'
$SpirvCrossRoot = Join-Path $ToolRoot 'SPIRV-Cross'
$SpirvCrossTag = 'vulkan-sdk-1.4.357.0'
$SpirvCrossCommit = '6c09849fe88c48eaed08413aa022aaa136a3a057'

New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
if (Test-Path $SpirvCrossRoot) {
    throw "Refusing to reuse existing SPIRV-Cross checkout: $SpirvCrossRoot"
}

git clone --branch $SpirvCrossTag --depth 1 `
    'https://github.com/KhronosGroup/SPIRV-Cross' $SpirvCrossRoot

$ActualCommit = (git -C $SpirvCrossRoot rev-parse HEAD).Trim()
if ($ActualCommit -ne $SpirvCrossCommit) {
    throw "Unexpected SPIRV-Cross commit: $ActualCommit"
}

$SpirvCrossBuild = Join-Path $SpirvCrossRoot 'build'
$SpirvCrossBin = Join-Path $SpirvCrossBuild 'bin'
cmake -S $SpirvCrossRoot -B $SpirvCrossBuild -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DSPIRV_CROSS_ENABLE_TESTS=OFF `
    "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=$SpirvCrossBin"
cmake --build $SpirvCrossBuild --target spirv-cross

$SpirvCrossExe = (Resolve-Path (Join-Path $SpirvCrossBin 'spirv-cross.exe')).Path
$SpirvCrossSha256 = (Get-FileHash -Algorithm SHA256 $SpirvCrossExe).Hash.ToLowerInvariant()
$env:Path = "$(Split-Path $SpirvCrossExe);$env:Path"
$env:DM_SPIRV_CROSS_SHA256 = $SpirvCrossSha256
$SpirvCrossHashFile = Join-Path $SpirvCrossRoot 'spirv-cross.sha256'
Set-Content -NoNewline -Path $SpirvCrossHashFile -Value $SpirvCrossSha256

Write-Host "SPIRV-Cross: $SpirvCrossExe"
Write-Host "SPIRV-Cross SHA-256: $SpirvCrossSha256"
```

Save `$SpirvCrossSha256` somewhere private if you will open a new PowerShell
window. The build block also saves it next to the locally built executable.
After opening the PowerShell window that will run the packaging commands,
restore and verify the value with this block. It compares the saved value with
the executable at the exact path used by the build; do not replace either file
with an untrusted download.

```powershell
$SpirvCrossRoot = Join-Path $env:USERPROFILE 'src\SPIRV-Cross'
$SpirvCrossExe = Join-Path $SpirvCrossRoot 'build\bin\spirv-cross.exe'
$SpirvCrossHashFile = Join-Path $SpirvCrossRoot 'spirv-cross.sha256'
if (-not (Test-Path -LiteralPath $SpirvCrossExe -PathType Leaf) -or
    -not (Test-Path -LiteralPath $SpirvCrossHashFile -PathType Leaf)) {
    throw 'SPIRV-Cross executable or saved hash is missing.'
}
$SpirvCrossSha256 = (Get-Content -Raw -LiteralPath $SpirvCrossHashFile).Trim().ToLowerInvariant()
$ActualSpirvCrossSha256 = (Get-FileHash -Algorithm SHA256 $SpirvCrossExe).Hash.ToLowerInvariant()
if ($ActualSpirvCrossSha256 -ne $SpirvCrossSha256) {
    throw 'SPIRV-Cross executable does not match the saved SHA-256.'
}
$env:Path = "$(Split-Path $SpirvCrossExe);$env:Path"
$env:DM_SPIRV_CROSS_SHA256 = $SpirvCrossSha256
Write-Host "Restored SPIRV-Cross SHA-256: $SpirvCrossSha256"
```

The hash detects a different executable selected by `PATH` or a changed binary;
it does not prove source provenance by itself. Do not write the Windows hash into
`dmsh_chain.lock` or `dmsh_chain.h`; the Mac and Windows binaries have different
fingerprints.

## 5. Place inputs and create Python environment

### Download the shell ZIP

On GitHub, open the **Releases** page for the same tag checked out above and
download `LordranNative-shell-build-input.zip`. If the release does not contain
it, open the repository's **Actions** tab, select **Build unsigned iOS shell**,
open a successful run for the same tag, and download the artifact named
`LordranNative-shell-build-input`.

Do not use a shell from a different tag. A mismatch is one of the most common
causes of a failed build.

Copy the shell ZIP, the two NSPs, and your own `prod.keys` into `$GameDir`.
The exact NSP filenames do not matter, but the directory must contain one
supported base version and its `v196608` update.

Check that the private inputs exist:

```powershell
$Required = @($Keys, $Shell)
foreach ($Path in $Required) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing required file: $Path"
    }
}

Get-ChildItem -LiteralPath $GameDir -File |
    Select-Object Name, Length, LastWriteTime
```

Create a repository-local virtual environment and install the Python packages:

```powershell
$PythonVenv = Join-Path $GameDir 'tools-venv'
py -3 -m venv $PythonVenv
$Python = (Resolve-Path (Join-Path $PythonVenv 'Scripts\python.exe')).Path

& $Python -m pip install --upgrade pip
& $Python -m pip install lz4 capstone fonttools
& $Python --version
```

Always invoke the scripts as `& $Python ...` in this session. This avoids
PowerShell execution-policy issues and prevents packages from being installed
into another Python installation.

## 6. Run preflight checks

Run the doctor command before building. It checks the local toolchain and, when
`--shell` is supplied, checks the shell manifest and compatibility data too.

```powershell
& $Python scripts/player_support.py doctor `
    --route shell `
    --shell $Shell `
    --work-dir $BuildWork `
    --spirv-cross-sha256 $SpirvCrossSha256
if ($LASTEXITCODE -ne 0) {
    throw 'Preflight failed; fix the reported problem before building.'
}
```

Then run a dry-run of the support wrapper. This checks the requested paths and
options without creating the final IPA:

```powershell
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256 `
    --dry-run
if ($LASTEXITCODE -ne 0) {
    throw 'Dry-run failed; fix the reported problem before building.'
}
```

## 7. Build the unsigned IPA

Run this only after the doctor and dry-run succeed:

```powershell
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256
if ($LASTEXITCODE -ne 0) {
    throw 'IPA build failed. Inspect the logs under the private game directory.'
}

Get-Item -LiteralPath $Output | Select-Object FullName, Length, LastWriteTime
```

The builder checks the shell source fingerprint, title ID, registered module
build IDs, shader chain, shader inventory, and SPIRV-Cross fingerprint. It then
extracts and rewrites the selected game build, translates profile shaders to
MSL, creates `Guest.framework`, and assembles the unsigned IPA. Logs and
intermediates are stored below `$BuildWork`. Extracted game files are deleted
after a successful build unless `--keep-extracted` is used.

The equivalent direct packer command is useful when debugging the wrapper:

```powershell
& $Python scripts/build_ipa_from_shell.py $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256
```

Do not run two builds against the same `$GameDir` at the same time.

### Optional build commands

Keep extracted `ExeFS`/`RomFS` data for inspection:

```powershell
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --out $Output `
    --spirv-cross-sha256 $SpirvCrossSha256 `
    --keep-extracted
```

Package the registered base-game profile instead of the default `v196608`
update. The update NSP is still required for shader extraction and validation:

```powershell
$BaseOutput = Join-Path $GameDir 'LordranNative-base-v0.ipa'
& $Python scripts/player_support.py build $GameDir `
    --keys $Keys `
    --shell $Shell `
    --package v0 `
    --out $BaseOutput `
    --spirv-cross-sha256 $SpirvCrossSha256
```

Use `--bundle-id` only when you intentionally need a different app identity.
Keep it consistent with the shell and the expected `Guest.framework` identity.

## 8. Verify and install

Run the structural archive check after the build:

```powershell
& $Python scripts/player_support.py verify $Output `
    --target device `
    --full-crc `
    --match-source
if ($LASTEXITCODE -ne 0) {
    throw 'IPA verification failed.'
}
```

This verifies archive structure and checksums; it is not a gameplay test. The
IPA is unsigned by design. Use AltStore, Sideloadly, or another supported tool
to sign it with your own Apple identity and install it on a compatible device.
Windows cannot run Apple's Metal compiler, so this IPA carries MSL source and
iOS compiles shaders on first use. The first scene can take several minutes;
subsequent launches reuse the system cache.

## Troubleshooting

- **A command is not recognized:** reopen the same PowerShell type used for the
  build and rerun the checks in section 1. Do not mix an ordinary PowerShell
  window with a Developer PowerShell window while building SPIRV-Cross.
- **Shell/source mismatch:** download the shell from the same release tag as
  the checkout. Do not mix a shell from `main` with an older source checkout.
- **SPIRV-Cross fingerprint mismatch:** verify `Get-Command spirv-cross`,
  `$SpirvCrossExe`, and `$env:DM_SPIRV_CROSS_SHA256`. Rebuild the pinned source
  if necessary; do not change the repository shader lock.
- **Missing Python package:** verify that `$Python` points inside
  `game/01004AB00A260000/tools-venv`, then rerun `& $Python -m pip install
  lz4 capstone fonttools`.
- **Unsupported title or build ID:** use title `01004AB00A260000` and a version
  registered in `dm/games/01004AB00A260000/game.tsv`. Do not bypass the check.
- **Extraction failure:** inspect `nx_extract_build.log` and
  `extract_<version>.log` under `$BuildWork`. Confirm both NSPs are complete,
  `prod.keys` is valid, and enough disk space remains. Never print key values.
- **Shell ZIP has unexpected files:** the shell producer and consumer use
  fail-closed allowlists. Do not broaden them without proving the resource is
  public and contains no game-derived or private data.
- **IPA does not install:** the output is unsigned. Sign it with your own
  sideloading tool; do not add certificates or provisioning profiles to the
  repository.
- **First launch is slow:** keep the app in the foreground while source shaders
  compile. This is expected for the Windows route.

This route is experimental. Mac/Xcode remains the recommended path when
available because it compiles shaders before installation.
