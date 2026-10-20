[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ToolRoot = (Join-Path $env:USERPROFILE 'src'),
    [string]$ZstdPath,
    [switch]$SkipInstall,
    [switch]$SkipVisualStudio,
    [switch]$SkipSpirvCross,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$SpirvCrossTag = 'vulkan-sdk-1.4.357.0'
$SpirvCrossCommit = '6c09849fe88c48eaed08413aa022aaa136a3a057'
$ZstdVersion = '1.5.7'
$ZstdUrl = "https://github.com/facebook/zstd/releases/download/v$ZstdVersion/zstd-v$ZstdVersion-win64.zip"
$ZstdSha512 = 'a96dc5417943c03fa231bf2d6a586b7ae7254fa52fdc15d302f296b5ff88e1ff0f07120a720149eb82ea0f0c65444393ebf05d2ee1bd1db341b803ff65a2e675'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-Executable {
    param([string]$Name)
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE: $Command $($Arguments -join ' ')"
    }
}

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @()
    )
    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode: $Command $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($machine, $user, $env:Path) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ -split ';' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = ($parts | Select-Object -Unique) -join ';'
}

function Require-Winget {
    $winget = Get-Executable 'winget.exe'
    if ($null -eq $winget) {
        throw 'winget is not available. Install or update App Installer from the Microsoft Store, then rerun this script.'
    }
    return $winget
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Override
    )
    $winget = Require-Winget
    $arguments = @(
        'install', '--id', $Id, '--exact',
        '--accept-source-agreements', '--accept-package-agreements'
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $arguments += @('--override', $Override)
    }
    Invoke-Checked $winget $arguments
    Refresh-Path
}

function Get-PythonCommand {
    $launcher = Get-Executable 'py.exe'
    if ($null -ne $launcher) {
        return @($launcher, '-3')
    }
    $python = Get-Executable 'python.exe'
    if ($null -ne $python) {
        return @($python)
    }
    return $null
}

function Get-PythonVersion {
    param([string[]]$PythonCommand)
    $pythonArgs = @()
    if ($PythonCommand.Length -gt 1) {
        $pythonArgs = $PythonCommand[1..($PythonCommand.Length - 1)]
    }
    $pythonLauncher = $PythonCommand[0]
    $output = & $pythonLauncher @pythonArgs --version 2>&1
    $versionText = ($output -join ' ')
    $match = [regex]::Match($versionText, 'Python\s+(\d+)\.(\d+)')
    if (-not $match.Success) {
        throw "Could not determine the Python version from: $versionText"
    }
    return [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value)
}

function Find-VisualStudio {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    foreach ($vswhere in $candidates) {
        $path = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null |
            Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $path.Trim()
        }
    }
    return $null
}

function Ensure-Zstd {
    param([string]$Root)
    if (-not [string]::IsNullOrWhiteSpace($ZstdPath)) {
        $candidate = (Resolve-Path -LiteralPath $ZstdPath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            [IO.Path]::GetFileName($candidate) -notin @('zstd.exe', 'zstd')) {
            throw "-ZstdPath must point to zstd.exe: $candidate"
        }
        return $candidate
    }

    Refresh-Path
    $existing = Get-Executable 'zstd.exe'
    if ($null -ne $existing) {
        return $existing
    }
    if ($SkipInstall) {
        throw 'zstd.exe is missing. Install it or pass -ZstdPath C:\path\to\zstd.exe.'
    }

    $installRoot = Join-Path $Root "zstd-v$ZstdVersion"
    $archive = Join-Path $Root "zstd-v$ZstdVersion-win64.zip"
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $downloaded = $null
    if (Test-Path -LiteralPath $installRoot -PathType Container) {
        $downloaded = Get-ChildItem -LiteralPath $installRoot -Filter 'zstd.exe' -File -Recurse |
            Select-Object -First 1
    }
    if ($null -eq $downloaded) {
        Write-Step "Downloading official zstd v$ZstdVersion"
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or $Force) {
            $download = Join-Path $Root "zstd-v$ZstdVersion.download-$([guid]::NewGuid().ToString('N')).zip"
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $ZstdUrl -OutFile $download
                $downloadHash = (Get-FileHash -Algorithm SHA512 -LiteralPath $download).Hash.ToLowerInvariant()
                if ($downloadHash -ne $ZstdSha512) {
                    throw "The downloaded zstd archive failed its SHA-512 check: $ZstdUrl"
                }
                if (Test-Path -LiteralPath $archive) {
                    $backup = "$archive.backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))"
                    Move-Item -LiteralPath $archive -Destination $backup
                    Write-Host "Existing zstd archive moved to: $backup" -ForegroundColor Yellow
                }
                Move-Item -LiteralPath $download -Destination $archive
            } finally {
                if (Test-Path -LiteralPath $download) {
                    Remove-Item -LiteralPath $download -Force
                }
            }
        }
        $archiveHash = (Get-FileHash -Algorithm SHA512 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($archiveHash -ne $ZstdSha512) {
            throw "The existing zstd archive failed its SHA-512 check and was left untouched. Rerun with -Force to download a verified copy: $archive"
        }
        if (Test-Path -LiteralPath $installRoot) {
            $backup = "$installRoot.backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))"
            Move-Item -LiteralPath $installRoot -Destination $backup
            Write-Host "Existing zstd directory moved to: $backup" -ForegroundColor Yellow
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $installRoot -Force
        $downloaded = Get-ChildItem -LiteralPath $installRoot -Filter 'zstd.exe' -File -Recurse |
            Select-Object -First 1
    }
    if ($null -eq $downloaded) {
        throw "The downloaded zstd archive did not contain zstd.exe: $ZstdUrl"
    }
    $env:Path = "$(Split-Path $downloaded.FullName);$env:Path"
    return $downloaded.FullName
}

function Ensure-SpirvCross {
    param([string]$Root)
    $sourceRoot = Join-Path $Root 'SPIRV-Cross'
    $hashFile = Join-Path $sourceRoot 'spirv-cross.sha256'

    if ($SkipSpirvCross) {
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            throw "-SkipSpirvCross was specified, but the checkout is missing: $sourceRoot"
        }
        $actualSource = (Invoke-Captured 'git' @('-C', $sourceRoot, 'rev-parse', 'HEAD')).Trim()
        if ($actualSource -ne $SpirvCrossCommit) {
            throw "-SkipSpirvCross was specified, but the checkout is not pinned to $SpirvCrossCommit: $actualSource"
        }
        $buildRoot = Join-Path $sourceRoot 'build-vs'
        $existing = Get-ChildItem -LiteralPath $buildRoot -Filter 'spirv-cross.exe' -File -Recurse |
            Sort-Object @{ Expression = { $_.FullName.Length } } |
            Select-Object -First 1
        if ($null -eq $existing -or -not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
            throw "-SkipSpirvCross was specified, but a built executable and hash are missing under: $sourceRoot"
        }
        $savedHash = (Get-Content -Raw -LiteralPath $hashFile).Trim().ToLowerInvariant()
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $existing.FullName).Hash.ToLowerInvariant()
        if ($savedHash -ne $actualHash) {
            throw "Saved SPIRV-Cross SHA-256 does not match: $($existing.FullName)"
        }
        $env:Path = "$(Split-Path $existing.FullName);$env:Path"
        $env:DM_SPIRV_CROSS_SHA256 = $actualHash
        return [pscustomobject]@{
            Path = $existing.FullName
            Hash = $actualHash
            HashFile = $hashFile
            Source = $sourceRoot
            VisualStudio = (Find-VisualStudio)
        }
    } else {
        $reuse = $false
        if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
            $gitDir = Join-Path $sourceRoot '.git'
            if (Test-Path -LiteralPath $gitDir) {
                $actual = (Invoke-Captured 'git' @('-C', $sourceRoot, 'rev-parse', 'HEAD')).Trim()
                $dirty = (Invoke-Captured 'git' @('-C', $sourceRoot, 'status', '--porcelain')).Trim()
                if ($actual -eq $SpirvCrossCommit -and [string]::IsNullOrWhiteSpace($dirty)) {
                    $reuse = $true
                } elseif (-not $Force) {
                    throw "SPIRV-Cross already exists but is not a clean checkout of $SpirvCrossCommit. Use -Force to move it aside and clone the pinned source again: $sourceRoot"
                } else {
                    $backup = "$sourceRoot.backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
                    Move-Item -LiteralPath $sourceRoot -Destination $backup
                    Write-Host "Existing SPIRV-Cross checkout moved to: $backup" -ForegroundColor Yellow
                }
            } elseif (-not $Force) {
                throw "SPIRV-Cross exists but is not a Git checkout: $sourceRoot. Use -Force to move it aside."
            } else {
                $backup = "$sourceRoot.backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))"
                Move-Item -LiteralPath $sourceRoot -Destination $backup
                Write-Host "Existing SPIRV-Cross directory moved to: $backup" -ForegroundColor Yellow
            }
        }

        if (-not $reuse) {
            Write-Step "Cloning pinned SPIRV-Cross $SpirvCrossTag"
            New-Item -ItemType Directory -Force -Path $Root | Out-Null
            Invoke-Checked 'git' @('clone', '--branch', $SpirvCrossTag, '--depth', '1',
                'https://github.com/KhronosGroup/SPIRV-Cross', $sourceRoot)
        }

        $actual = (Invoke-Captured 'git' @('-C', $sourceRoot, 'rev-parse', 'HEAD')).Trim()
        if ($actual -ne $SpirvCrossCommit) {
            throw "Unexpected SPIRV-Cross commit: $actual (expected $SpirvCrossCommit)"
        }
    }

    $buildRoot = Join-Path $sourceRoot 'build-vs'
    $cmake = Get-Executable 'cmake.exe'
    if ($null -eq $cmake) {
        throw 'cmake.exe is missing. Install CMake before building SPIRV-Cross.'
    }
    $ninja = Get-Executable 'ninja.exe'
    if ($null -eq $ninja) {
        throw 'ninja.exe is missing. Install Ninja before building SPIRV-Cross.'
    }
    $vsRoot = Find-VisualStudio
    if ($null -eq $vsRoot) {
        throw 'A Visual Studio C++ toolchain was not found. Run this script without -SkipVisualStudio.'
    }

    Write-Step 'Configuring and building SPIRV-Cross for Windows x64'
    Invoke-Checked $cmake @('-S', $sourceRoot, '-B', $buildRoot,
        '-G', 'Visual Studio 17 2022', '-A', 'x64',
        '-DSPIRV_CROSS_ENABLE_TESTS=OFF')
    Invoke-Checked $cmake @('--build', $buildRoot, '--config', 'Release',
        '--target', 'spirv-cross', '--parallel')

    $executable = Get-ChildItem -LiteralPath $buildRoot -Filter 'spirv-cross.exe' -File -Recurse |
        Sort-Object @{ Expression = { $_.FullName.Length } } |
        Select-Object -First 1
    if ($null -eq $executable) {
        throw "CMake completed but spirv-cross.exe was not found under: $buildRoot"
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable.FullName).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $hashFile -Value $hash -Encoding ASCII -NoNewline
    $env:Path = "$(Split-Path $executable.FullName);$env:Path"
    $env:DM_SPIRV_CROSS_SHA256 = $hash

    return [pscustomobject]@{
        Path = $executable.FullName
        Hash = $hash
        HashFile = $hashFile
        Source = $sourceRoot
        VisualStudio = $vsRoot
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'This script must run on Windows PowerShell or PowerShell 7 on Windows.'
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'The Windows packaging route requires a 64-bit Windows installation.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$gameDir = Join-Path $RepoRoot 'game\01004AB00A260000'
$buildWork = Join-Path $gameDir '01004AB00A260000_shell_build'
$venv = Join-Path $gameDir 'tools-venv'

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git') -PathType Container)) {
    throw "RepoRoot is not a Git checkout: $RepoRoot"
}

Write-Host 'Lordran Native Windows packaging setup' -ForegroundColor Green
Write-Host "Repository: $RepoRoot"
Write-Host "Tool root:  $ToolRoot"
Write-Host 'This script installs public tools only; it never downloads NSPs, keys, or game data.'

if ($SkipInstall) {
    Write-Host 'Skipping winget and public-tool installation because -SkipInstall was specified.' -ForegroundColor Yellow
} else {
    Write-Step 'Installing or updating the public command-line tools'
    $packages = @(
        @{ Id = 'Git.Git'; Name = 'Git' },
        @{ Id = 'Python.Python.3.12'; Name = 'Python 3.12' },
        @{ Id = 'Microsoft.DotNet.SDK.10'; Name = '.NET 10 SDK' },
        @{ Id = 'Kitware.CMake'; Name = 'CMake' },
        @{ Id = 'Ninja-build.Ninja'; Name = 'Ninja' }
    )
    foreach ($package in $packages) {
        Write-Host "Installing $($package.Name) ($($package.Id))..."
        Install-WingetPackage -Id $package.Id
    }
    if (-not $SkipVisualStudio) {
        Write-Step 'Installing or updating Visual Studio Build Tools C++ workload'
        Install-WingetPackage -Id 'Microsoft.VisualStudio.2022.BuildTools' `
            -Override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    }
    Refresh-Path
}

Write-Step 'Checking the required public tools'
$git = Get-Executable 'git.exe'
if ($null -eq $git) { throw 'git.exe is missing. Install Git and reopen PowerShell.' }
$pythonCommand = @(Get-PythonCommand)
if ($pythonCommand.Count -eq 0) { throw 'Python 3.12+ is missing. Install it and reopen PowerShell.' }
$pythonVersion = Get-PythonVersion $pythonCommand
if ($pythonVersion -lt [version]'3.12') {
    throw "Python 3.12 or newer is required; found $pythonVersion."
}
$dotnet = Get-Executable 'dotnet.exe'
if ($null -eq $dotnet) { throw 'dotnet.exe is missing. Install the .NET 10 SDK and reopen PowerShell.' }
$sdks = Invoke-Captured $dotnet @('--list-sdks')
if ($sdks -notmatch '(?m)^10\.') {
    throw "The .NET 10 SDK was not found. Detected SDKs:`n$sdks"
}
$cmake = Get-Executable 'cmake.exe'
if ($null -eq $cmake) { throw 'cmake.exe is missing. Install CMake and reopen PowerShell.' }
$ninja = Get-Executable 'ninja.exe'
if ($null -eq $ninja) { throw 'ninja.exe is missing. Install Ninja and reopen PowerShell.' }

if ($SkipVisualStudio) {
    Write-Host 'Skipping Visual Studio installation because -SkipVisualStudio was specified.' -ForegroundColor Yellow
}
$visualStudio = Find-VisualStudio
if ($null -eq $visualStudio) {
    throw 'Visual Studio Build Tools with the C++ workload were not found.'
}
$zstd = Ensure-Zstd -Root $ToolRoot
$env:Path = "$(Split-Path $zstd);$env:Path"
Write-Host "zstd:       $zstd"
Write-Host "Visual Studio: $visualStudio"

$spirv = Ensure-SpirvCross -Root $ToolRoot

Write-Step 'Creating the repository-local Python environment'
New-Item -ItemType Directory -Force -Path $gameDir | Out-Null
$pythonArgs = @()
if ($pythonCommand.Length -gt 1) {
    $pythonArgs = $pythonCommand[1..($pythonCommand.Length - 1)]
}
$pythonLauncher = $pythonCommand[0]
Invoke-Checked $pythonLauncher @($pythonArgs + @('-m', 'venv', $venv))
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Python virtual environment was not created: $python"
}
Invoke-Checked $python @('-m', 'pip', 'install', '--upgrade', 'pip')
Invoke-Checked $python @('-m', 'pip', 'install', 'lz4', 'capstone', 'fonttools')

Write-Step 'Running the repository preflight check'
New-Item -ItemType Directory -Force -Path $buildWork | Out-Null
Invoke-Checked $python @(
    (Join-Path $RepoRoot 'scripts/player_support.py'), 'doctor',
    '--route', 'shell', '--work-dir', $buildWork,
    '--spirv-cross-sha256', $spirv.Hash
)

$shell = Join-Path $gameDir 'LordranNative-shell-build-input.zip'
$keys = Join-Path $gameDir 'prod.keys'
Write-Host ''
Write-Host 'Setup completed.' -ForegroundColor Green
Write-Host "SPIRV-Cross: $($spirv.Path)"
Write-Host "SHA-256:     $($spirv.Hash)"
Write-Host "Hash file:   $($spirv.HashFile)"
Write-Host "Python:      $python"
Write-Host ''
Write-Host 'Next steps (manual files are intentionally not downloaded):' -ForegroundColor Yellow
Write-Host "1. Put the matching shell ZIP at: $shell"
Write-Host "2. Put your own base/update NSPs and prod.keys under: $gameDir"
Write-Host '3. In a new PowerShell window, read the saved hash and run the shell doctor:'
Write-Host "   `$SpirvCrossSha256 = (Get-Content -Raw '$($spirv.HashFile)').Trim().ToLowerInvariant()"
Write-Host "   `$Python = (Resolve-Path '$python').Path"
Write-Host "   & `$Python '$RepoRoot\scripts\player_support.py' doctor --route shell --shell '$shell' --work-dir '$buildWork' --spirv-cross-sha256 `$SpirvCrossSha256"
Write-Host 'The setup script did not access or print any key, NSP, or private game data.'
