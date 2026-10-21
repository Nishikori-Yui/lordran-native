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
