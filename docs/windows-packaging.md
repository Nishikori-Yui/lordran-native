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
users. It reuses compatible public tools and installs only missing dependencies,
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

**You do not need winget or the Microsoft Store.** If `winget` is available,
the script tries it for missing tools; otherwise it downloads official portable
archives automatically. A failed winget install also falls back to those
downloads. To avoid winget even when it is installed, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -NoWinget
```

The no-winget route works as follows:

| Dependency | What setup does when a compatible copy is missing |
| --- | --- |
| Git | Extract Git for Windows MinGit 2.56.0.2. |
| Python | Extract official Python 3.12.10 into `game/01004AB00A260000/tools-python/`; bootstrap pip from a verified wheel. No Windows Installer service is needed. |
| .NET | Extract the official .NET SDK 10.0.402 ZIP. No system-wide SDK change is needed. |
| CMake / Ninja | Extract official CMake 3.31.12 and Ninja 1.12.1 ZIPs. |
| C++ compiler | Reuse Visual Studio 2022, or an existing Clang/MinGW compiler after a successful compile, link, and x64 executable check. If none works, start Microsoft's official Visual Studio 2022 Build Tools installer. |
| zstd | Reuse `zstd.exe`, or extract the pinned official 1.5.7 archive. |

Public archives are checked against pinned SHA-256/SHA-512 values before
extraction. The Visual Studio installer is checked for a valid Microsoft
Authenticode signature before it runs. Public portable tools and downloads stay
under `$HOME\src` by default (`-ToolRoot` changes this); Python and its packages
stay in the ignored repository `game/` folder. The script updates `PATH` only
inside its process, not your permanent user or machine settings. Rerunning setup
finds its own tools again, including in a new PowerShell window.

An Internet connection is needed for missing tools, Python packages, and
SPIRV-Cross source. Portable tools do not require administrator access. If no
working C++ compiler exists, Visual Studio installation can request UAC approval
and a restart; restart Windows and rerun the same command if instructed. Setup
does not bypass administrator or organization policies. The automatic downloads
target x64 Windows, not Windows on ARM.

At the end, setup prints the SPIRV-Cross executable, its SHA-256 file, and the
exact Python interpreter path. Keep those values for the commands below. This
automatic route does not require a separate Developer PowerShell window.

### Set up and build in one run

The setup script can continue directly into packaging. First put the shell ZIP
from the same release as this checkout, your base and `v196608` update NSPs,
and your `prod.keys` in `game/01004AB00A260000/`. The shell and source must match;
the script does not download a shell, game files, or keys. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -Build
```

This installs/checks the public toolchain, prepares the Python environment,
runs the shell compatibility preflight, builds the unsigned IPA, and verifies
the resulting archive. By default, the input paths above are used and the
timestamped IPA is written beside the NSPs. To package after a previous setup,
run the same command with `-SkipInstall -SkipSpirvCross`; the saved pinned
SPIRV-Cross executable and hash are checked before use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -SkipInstall -SkipSpirvCross -Build
```

Useful build options include `-NspDirectory`, `-KeysFile`, `-ShellZip`, and
`-OutputPath` (all paths must remain under this checkout's `game/` folder),
`-Package v0`, and `-KeepExtracted`. The script refuses to overwrite an
existing output unless you also pass `-ReplaceOutput`.

The script can be run again safely when the checkout is already prepared. Useful
options are:

```powershell
# Reuse public tools without installing missing tools. Python packages may still need downloading.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -SkipInstall

# Use an existing zstd.exe instead of downloading the pinned portable copy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -ZstdPath 'C:\tools\zstd.exe'

# Move aside an unexpected SPIRV-Cross directory and clone the pinned source again.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup_windows_packaging.ps1 -Force
```

`-SkipVisualStudio` prevents compiler installation; an existing C++ compiler
must pass the probe when rebuilding SPIRV-Cross. `-SkipSpirvCross` verifies and
reuses the pinned checkout's executable and saved hash; it does not require a
compiler, CMake, or Ninja just to package again. Neither option disables the
shell/source or shader fingerprint checks.

After setup, continue with the shell download and private-input steps in
section 5. The manual installation below is optional, not required when winget
is missing.

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

- x64 Python 3.12 or later. The manual commands use `py -3`; automatic setup
  can also use `python.exe` or its own portable Python.
- .NET 10 SDK.
- Git, CMake, Ninja, and a working C++ toolchain. The manual example uses MSVC;
  automatic setup can also reuse a working Clang/MinGW compiler. The easiest MSVC build shell is
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

If you used automatic setup, use the Python path it printed and skip the
environment-creation block. To restore it in a new PowerShell window:

```powershell
$Python = Join-Path $GameDir 'tools-venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    $Python = Join-Path $GameDir 'tools-python\python.exe'
}
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw 'Packaging Python is missing. Run the setup script first.'
}
& $Python --version
```

For manual setup with a regular Python installation, create a repository-local
virtual environment and install the Python packages:

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

- **No winget or Microsoft Store:** run setup normally or add `-NoWinget`.
  App Installer is not a prerequisite. If an official download fails, check the
  URL, network/proxy policy, and available disk space; do not disable hash checks.
- **No administrator access:** existing Clang/MinGW may avoid Visual Studio
  installation if its compiler probe succeeds. Otherwise ask an administrator
  to install the C++ workload. `-NoWinget` does not bypass UAC.
- **A command is not recognized:** reopen the same PowerShell type used for the
  build and rerun the checks in section 1. Do not mix an ordinary PowerShell
  window with a Developer PowerShell window while building SPIRV-Cross.
- **Shell/source mismatch:** download the shell from the same release tag as
  the checkout. Do not mix a shell from `main` with an older source checkout.
- **SPIRV-Cross fingerprint mismatch:** verify `Get-Command spirv-cross`,
  `$SpirvCrossExe`, and `$env:DM_SPIRV_CROSS_SHA256`. Rebuild the pinned source
  if necessary; do not change the repository shader lock.
- **Missing Python package:** verify that `$Python` points inside
  `game/01004AB00A260000/tools-venv` or `tools-python`, then rerun `& $Python -m pip install
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
