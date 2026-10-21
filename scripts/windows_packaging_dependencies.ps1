# Public, pinned x64 downloads used when winget is unavailable or disabled.
$WindowsDownloads = @{
    Git = @{
        Url = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/MinGit-2.56.0.2-64-bit.zip'
        Hash = 'da35e72aa21c005a5a0d298cfbae110bc1609a815730ea0dde84b01a1b3cd3be'
        Directory = 'mingit-2.56.0.2'; Executable = 'cmd\git.exe'
    }
    Python = @{
        Url = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
        Hash = '4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3'
        Directory = 'tools-python'; Executable = 'python.exe'
    }
    Dotnet = @{
        Url = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.402/dotnet-sdk-10.0.402-win-x64.zip'
        Hash = 'ae4fd528cb7e9f6af6aaf7de36715a69f761f183744f1bb3025d19f5a92447090ec561410e46266c1d10a63781ed6f3de771760bc76c876d87daabc367b898cd'
        Algorithm = 'SHA512'; Directory = 'dotnet-10.0.402'; Executable = 'dotnet.exe'
    }
    CMake = @{
        Url = 'https://github.com/Kitware/CMake/releases/download/v3.31.12/cmake-3.31.12-windows-x86_64.zip'
        Hash = '0c4baa40f28b3f8225eb3fdf6946c987b4fe901403b4eaf2fbbd9378100aaa0c'
        Directory = 'cmake-3.31.12'; Executable = 'cmake-3.31.12-windows-x86_64\bin\cmake.exe'
    }
    Ninja = @{
        Url = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip'
        Hash = 'f550fec705b6d6ff58f2db3c374c2277a37691678d6aba463adcbb129108467a'
        Directory = 'ninja-1.12.1'; Executable = 'ninja.exe'
    }
    Pip = @{
        Url = 'https://files.pythonhosted.org/packages/5d/95/6b5cb3461ea5673ba0995989746db58eb18b91b54dbf331e72f569540946/pip-26.1.2-py3-none-any.whl'
        Hash = '382ff9f685ee3bc25864f820aa50505825f10f5458ffff07e30a6d96e5715cab'
    }
}

function Get-VerifiedDownload {
    param([hashtable]$Spec, [string]$CacheRoot)
    New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
    $file = Join-Path $CacheRoot ([IO.Path]::GetFileName(([uri]$Spec.Url).AbsolutePath))
    $algorithm = if ($Spec.Algorithm) { $Spec.Algorithm } else { 'SHA256' }
    if (Test-Path -LiteralPath $file) {
        $hash = (Get-FileHash -LiteralPath $file -Algorithm $algorithm).Hash
        if ($hash -eq $Spec.Hash) { return $file }
        if (-not $Force) {
            throw "Cached download failed its $algorithm check and was left untouched: $file. Rerun with -Force to move it aside."
        }
        Move-SetupBackup $file
    }
    if ($SkipInstall) { throw "A verified public download is missing: $file. Rerun without -SkipInstall." }
    $temporary = "$file.download-$([guid]::NewGuid().ToString('N'))"
    try {
        Write-Step "Downloading $([IO.Path]::GetFileName($file))"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $oldProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $Spec.Url -OutFile $temporary
        } finally { $ProgressPreference = $oldProgress }
        $hash = (Get-FileHash -LiteralPath $temporary -Algorithm $algorithm).Hash
        if ($hash -ne $Spec.Hash) { throw "Download failed its $algorithm check: $($Spec.Url)" }
        Move-Item -LiteralPath $temporary -Destination $file
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $file
}

function Move-SetupBackup {
    param([string]$Path)
    $backup = "$Path.backup-$([guid]::NewGuid().ToString('N'))"
    Move-Item -LiteralPath $Path -Destination $backup
    Write-Host "Existing setup data moved to: $backup" -ForegroundColor Yellow
}

function Get-PortableExecutable {
    param([string]$Name, [string]$Root)
    $spec = $WindowsDownloads[$Name]
    return Join-Path (Join-Path $Root $spec.Directory) $spec.Executable
}

function Install-PortableTool {
    param([string]$Name, [string]$Root)
    $spec = $WindowsDownloads[$Name]
    $destination = Join-Path $Root $spec.Directory
    $executable = Get-PortableExecutable $Name $Root
    if (Test-Path -LiteralPath $destination) {
        if (-not $Force) {
            throw "The existing $Name installation is unusable and was left untouched: $destination. Rerun with -Force to move it aside."
        }
        Move-SetupBackup $destination
    }
    $archive = Get-VerifiedDownload $spec (Join-Path $ToolRoot 'downloads')
    $staging = "$destination.extract-$([guid]::NewGuid().ToString('N'))"
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $staging
        if (-not (Test-Path -LiteralPath (Join-Path $staging $spec.Executable) -PathType Leaf)) {
            throw "The verified $Name archive did not contain $($spec.Executable)."
        }
        if ($Name -eq 'Python') {
            # Restore normal script-directory imports and site-packages for subprocesses.
            Remove-Item -LiteralPath (Join-Path $staging 'python312._pth')
            New-Item -ItemType Directory -Force -Path (Join-Path $staging 'Lib\site-packages') | Out-Null
        }
        Move-Item -LiteralPath $staging -Destination $destination
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    return $executable
}

function Add-ToolPath {
    param([string]$Executable)
    if (Test-Path -LiteralPath $Executable -PathType Leaf) {
        $env:Path = "$(Split-Path $Executable);$env:Path"
    }
}

function Test-DotnetSdk {
    param([string]$Executable)
    if (-not $Executable) { return $false }
    try { $sdks = & $Executable --list-sdks 2>&1 } catch { return $false }
    return ($LASTEXITCODE -eq 0 -and ($sdks -join "`n") -match '(?m)^10\.')
}

function Test-PythonRuntime {
    param([string[]]$Command)
    if ($Command.Count -eq 0) { return $false }
    $arguments = @($Command | Select-Object -Skip 1)
    $executable = $Command[0]
    try {
        $null = & $executable @arguments -c "import struct, sys, zlib; sys.exit(0 if sys.version_info >= (3, 12) and struct.calcsize('P') == 8 else 1)" 2>&1
    } catch { return $false }
    return $LASTEXITCODE -eq 0
}

function Get-PythonCommand {
    $candidates = @(
        ,@((Join-Path $venv 'Scripts\python.exe'))
        ,@((Get-PortableExecutable 'Python' $gameDir))
    )
    $launcher = Get-Executable 'py.exe'
    if ($launcher) {
        $candidates += ,@($launcher, '-3.12')
        $candidates += ,@($launcher, '-3')
    }
    $python = Get-Executable 'python.exe'
    if ($python -and $python -notmatch '\\WindowsApps\\') { $candidates += ,@($python) }
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate[0] -PathType Leaf) -and (Test-PythonRuntime $candidate)) {
            return $candidate
        }
    }
    return
}

function Get-PublicTool {
    param([string]$Name)
    if ($Name -eq 'Python') { return Get-PythonCommand }
    $fileName = @{ Git = 'git.exe'; Dotnet = 'dotnet.exe'; CMake = 'cmake.exe'; Ninja = 'ninja.exe' }[$Name]
    $candidates = @((Get-PortableExecutable $Name $ToolRoot), (Get-Executable $fileName))
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            if ($Name -eq 'Dotnet') {
                if (-not (Test-DotnetSdk $candidate)) { continue }
            } else {
                try { $null = & $candidate --version 2>&1 } catch { continue }
                if ($LASTEXITCODE -ne 0) { continue }
            }
            Add-ToolPath $candidate
            return $candidate
        }
    }
    return
}

function Ensure-PublicTool {
    param([string]$Name, [string]$WingetId)
    $existing = @(Get-PublicTool $Name | Where-Object { $_ })
    if ($existing.Count -gt 0) {
        Write-Host "Reusing ${Name}: $($existing -join ' ')"
        return
    }
    if ($SkipInstall) { throw "$Name is missing or incompatible. Rerun without -SkipInstall to install public tools." }
    if (-not $NoWinget -and (Get-Executable 'winget.exe')) {
        try { Install-WingetPackage -Id $WingetId } catch {
            Write-Warning "winget could not install $Name. Trying the official portable download. $($_.Exception.Message)"
        }
        if (@(Get-PublicTool $Name | Where-Object { $_ }).Count -gt 0) { return }
    }
    $root = if ($Name -eq 'Python') { $gameDir } else { $ToolRoot }
    $executable = Install-PortableTool $Name $root
    Add-ToolPath $executable
    if (@(Get-PublicTool $Name | Where-Object { $_ }).Count -eq 0) {
        throw "The installed $Name tool could not run. Check Windows compatibility and rerun setup."
    }
}

function Initialize-PackagingPython {
    param(
        [string[]]$Command,
        [string]$IndexUrl = 'https://pypi.org/simple'
    )
    $portable = Get-PortableExecutable 'Python' $gameDir
    $executable = $Command[0]
    if ($executable -eq $portable) {
        $python = $portable
        $null = & $python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('pip') else 1)"
        if ($LASTEXITCODE -ne 0) {
            $wheel = Get-VerifiedDownload $WindowsDownloads.Pip (Join-Path $ToolRoot 'downloads')
            $sitePackages = Join-Path (Split-Path $python) 'Lib\site-packages'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($wheel, $sitePackages)
        }
    } else {
        $python = Join-Path $venv 'Scripts\python.exe'
        if ($executable -ne $python) {
            $arguments = @($Command | Select-Object -Skip 1)
            Invoke-Checked $executable @($arguments + @('-m', 'venv', $venv)) | Out-Host
        }
    }
    Invoke-Checked $python @('-m', 'pip', '--isolated', 'install', '--no-user',
        '--index-url', $IndexUrl, 'lz4', 'capstone', 'fonttools', 'Pillow') | Out-Host
    return $python
}

function Find-SpirvToolchain {
    $vsRoot = Find-VisualStudio
    if ($vsRoot) {
        return [pscustomobject]@{
            Name = 'Visual Studio 2022'; Directory = 'build-vs'; VisualStudio = $vsRoot
            Arguments = @('-G', 'Visual Studio 17 2022', '-A', 'x64')
        }
    }
    $cmake = Get-Executable 'cmake.exe'
    $ninja = Get-Executable 'ninja.exe'
    if (-not $cmake -or -not $ninja) { return $null }
    foreach ($pair in @(@('clang.exe', 'clang++.exe'), @('gcc.exe', 'g++.exe'))) {
        $cc = Get-Executable $pair[0]
        $cxx = Get-Executable $pair[1]
        if (-not $cc -or -not $cxx) { continue }
        $probe = Join-Path $ToolRoot "compiler-probe-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force -Path $probe | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $probe 'CMakeLists.txt') -Encoding ASCII -Value @'
cmake_minimum_required(VERSION 3.15)
project(packaging_compiler_probe LANGUAGES C CXX)
add_executable(probe probe.cpp)
set_property(TARGET probe PROPERTY CXX_STANDARD 11)
'@
            Set-Content -LiteralPath (Join-Path $probe 'probe.cpp') -Encoding ASCII -Value '#include <iostream>
int main() { std::cout << "compiler ready"; return sizeof(void*) == 8 ? 0 : 1; }'
            $arguments = @('-G', 'Ninja', "-DCMAKE_MAKE_PROGRAM=$ninja", '-DCMAKE_BUILD_TYPE=Release',
                "-DCMAKE_C_COMPILER=$cc", "-DCMAKE_CXX_COMPILER=$cxx")
            $null = Invoke-Captured $cmake (@('-S', $probe, '-B', (Join-Path $probe 'build')) + $arguments)
            $null = Invoke-Captured $cmake @('--build', (Join-Path $probe 'build'))
            $null = Invoke-Captured (Join-Path $probe 'build\probe.exe')
            return [pscustomobject]@{
                Name = $cxx; Directory = 'build-ninja'; VisualStudio = $null; Arguments = $arguments
            }
        } catch {
            Write-Host "Compiler probe failed for ${cxx}: $($_.Exception.Message)" -ForegroundColor Yellow
        } finally { Remove-Item -LiteralPath $probe -Recurse -Force }
    }
    return $null
}

function Install-VisualStudioTools {
    if ($SkipInstall -or $SkipVisualStudio) {
        throw 'No working C++ toolchain was found. Install Visual Studio 2022 Build Tools (Desktop development with C++), or rerun without -SkipInstall/-SkipVisualStudio.'
    }
    if (-not $NoWinget -and (Get-Executable 'winget.exe')) {
        try {
            Install-WingetPackage -Id 'Microsoft.VisualStudio.2022.BuildTools' `
                -Override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        } catch { Write-Warning "winget could not install Visual Studio. Trying Microsoft's official installer." }
        if (Find-VisualStudio) { return }
    }
    $installer = Join-Path $ToolRoot "vs_BuildTools-$([guid]::NewGuid().ToString('N')).exe"
    try {
        Write-Step 'Downloading the official Visual Studio 2022 Build Tools installer (administrator approval may be required)'
        New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $installer
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
            throw 'The Visual Studio installer does not have a valid Microsoft signature. Installation was not started.'
        }
        $process = Start-Process -FilePath $installer -ArgumentList @('--wait', '--passive', '--norestart',
            '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended') -Wait -PassThru
        if ($process.ExitCode -in @(1641, 3010)) { throw 'Visual Studio requires a restart. Restart Windows, then run setup again.' }
        if ($process.ExitCode -ne 0) { throw "Visual Studio installation failed with exit code $($process.ExitCode)." }
    } finally {
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
    }
    Refresh-Path
}
