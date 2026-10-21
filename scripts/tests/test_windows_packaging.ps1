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
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
