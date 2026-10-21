$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\windows_packaging_common.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) "lordran-git-status-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
try {
    & git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & git -C $root config user.name 'Windows Packaging Test'
    if ($LASTEXITCODE -ne 0) { throw 'git config user.name failed' }
    & git -C $root config user.email 'windows-packaging-test@example.invalid'
    if ($LASTEXITCODE -ne 0) { throw 'git config user.email failed' }

    Set-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Value 'project(test)' -Encoding ASCII
    & git -C $root add CMakeLists.txt
    if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
    & git -C $root commit --quiet -m 'fixture'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }

    New-Item -ItemType Directory -Path (Join-Path $root 'build-vs\Release') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'build-vs\Release\spirv-cross.exe') -Value 'fixture'
    Set-Content -LiteralPath (Join-Path $root 'spirv-cross.sha256') -Value ('a' * 64)
    $changes = @(Get-UnexpectedGitChanges -Path $root -GeneratedPaths @('build-vs/', 'spirv-cross.sha256'))
    if ($changes.Count -ne 0) {
        throw "Generated SPIRV-Cross files should be accepted on rerun: $($changes -join '; ')"
    }

    Add-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Value '# modified source'
    $changes = @(Get-UnexpectedGitChanges -Path $root -GeneratedPaths @('build-vs/', 'spirv-cross.sha256'))
    if ($changes.Count -eq 0) {
        throw 'Modified tracked SPIRV-Cross source must not be accepted'
    }

    Set-Content -LiteralPath (Join-Path $root 'CMakeLists.txt') -Value 'project(test)' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'unexpected.txt') -Value 'source-tree change'
    $changes = @(Get-UnexpectedGitChanges -Path $root -GeneratedPaths @('build-vs/', 'spirv-cross.sha256'))
    if ($changes.Count -eq 0) {
        throw 'Unexpected untracked source files must not be accepted'
    }

    Write-Host 'Windows SPIRV-Cross rerun status checks passed.'

    $shellDirectory = Join-Path $root 'shells with spaces'
    New-Item -ItemType Directory -Path $shellDirectory | Out-Null
    function Assert-ShellDiscoveryFails {
        param([string]$Message)
        try {
            Get-PackagingShellZip -GameDirectory $shellDirectory | Out-Null
        } catch {
            if ($_.Exception.Message -like "*$Message*") { return }
            throw
        }
        throw "Expected shell discovery failure containing: $Message"
    }
    Assert-ShellDiscoveryFails 'No shell ZIP'
    $legacy = Join-Path $shellDirectory 'LordranNative-shell-build-input.zip'
    $versioned = Join-Path $shellDirectory 'LordranNative-shell-build-input-v0.2.0.zip'
    $dev = Join-Path $shellDirectory 'LordranNative-shell-build-input-dev-123456789abc.zip'
    $partialTag = Join-Path $shellDirectory 'LordranNative-shell-build-input-v0.2.0.partial.zip'
    foreach ($candidate in @($legacy, $versioned, $dev, $partialTag)) {
        Set-Content -LiteralPath $candidate -Value 'synthetic archive'
        if ((Get-PackagingShellZip -GameDirectory $shellDirectory) -ne $candidate) {
            throw 'A single legacy, release, or development shell must be discovered.'
        }
        Remove-Item -LiteralPath $candidate
    }
    Set-Content -LiteralPath $legacy -Value 'synthetic legacy archive'
    Set-Content -LiteralPath $versioned -Value 'synthetic release archive'
    Assert-ShellDiscoveryFails '-ShellZip PATH'
    Remove-Item -LiteralPath $legacy
    Set-Content -LiteralPath $dev -Value 'synthetic development archive'
    Assert-ShellDiscoveryFails 'Multiple shell ZIPs'
    Remove-Item -LiteralPath $dev
    New-Item -ItemType Directory -Path $dev | Out-Null
    Set-Content -LiteralPath (Join-Path $shellDirectory 'unrelated.zip') -Value 'not a shell'
    Set-Content -LiteralPath (Join-Path $shellDirectory 'LordranNative-shell-build-input-v0.3.0.zip.partial') -Value 'partial'
    if ((Get-PackagingShellZip -GameDirectory $shellDirectory) -ne $versioned) {
        throw 'Discovery must ignore directories, unrelated ZIPs, and incomplete shell outputs.'
    }
    Write-Host 'Windows shell ZIP discovery checks passed.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
