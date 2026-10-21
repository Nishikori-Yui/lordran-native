function Get-PackagingShellZip {
    param([Parameter(Mandatory = $true)][string]$GameDirectory)

    $candidates = @(Get-ChildItem -LiteralPath $GameDirectory -File | Where-Object {
        $_.Name -eq 'LordranNative-shell-build-input.zip' -or
        $_.Name -like 'LordranNative-shell-build-input-*.zip'
    } | Sort-Object Name)
    if ($candidates.Count -eq 0) {
        throw 'No shell ZIP found. Download the matching shell into the game directory or pass -ShellZip PATH.'
    }
    if ($candidates.Count -ne 1) {
        throw "Multiple shell ZIPs found: $($candidates.Name -join ', '). Pass -ShellZip PATH to select the matching one."
    }
    # Discovery never establishes compatibility; the Python builder checks the manifest.
    return $candidates[0].FullName
}

function Get-UnexpectedGitChanges {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$GeneratedPaths = @()
    )

    $status = & git -C $Path status --porcelain --untracked-files=all 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Could not inspect Git changes under ${Path}: $($status -join "`n")"
    }

    $unexpected = @()
    foreach ($line in $status) {
        $entry = $line.ToString()
        if ($entry.Length -lt 4) {
            continue
        }
        $relativePath = $entry.Substring(3)
        $isGenerated = $false
        foreach ($generatedPath in $GeneratedPaths) {
            if ($generatedPath.EndsWith('/')) {
                if ($relativePath.StartsWith($generatedPath, [StringComparison]::Ordinal)) {
                    $isGenerated = $true
                    break
                }
            } elseif ($relativePath -eq $generatedPath) {
                $isGenerated = $true
                break
            }
        }
        if (-not $isGenerated) {
            $unexpected += $entry
        }
    }
    return $unexpected
}
