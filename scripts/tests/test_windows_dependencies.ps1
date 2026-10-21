$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\windows_packaging_dependencies.ps1')

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\setup_windows_packaging.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $statement.Name -in @('Get-Executable', 'Write-Step', 'Invoke-Checked', 'Invoke-Captured', 'Refresh-Path')) {
        Invoke-Expression $statement.Extent.Text
    }
}

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected an error matching: $Pattern"
}

# All dependency-routing checks are offline and do not inspect private inputs.
foreach ($name in @('Git', 'Python', 'Dotnet', 'CMake', 'Ninja')) {
    & {
        param($name)
        $SkipInstall = $false
        $NoWinget = $false
        function Get-PublicTool { return 'already-compatible' }
        function Install-WingetPackage { throw 'Should not install an existing tool' }
        function Install-PortableTool { throw 'Should not download an existing tool' }
        Ensure-PublicTool -Name $name -WingetId 'test.package'
    } $name
}

foreach ($mode in @('winget-absent', 'winget-disabled', 'winget-fails', 'winget-works')) {
    & {
        param($mode)
        $SkipInstall = $false
        $NoWinget = $mode -eq 'winget-disabled'
        $ToolRoot = 'unused-tools'
        $gameDir = 'unused-private-root'
        $script:routeInstalled = $false
        $script:routeWingetCalls = 0
        $script:routePortableCalls = 0
        function Get-PublicTool { if ($script:routeInstalled) { return 'installed-tool' } }
        function Get-Executable { if ($mode -ne 'winget-absent') { return 'winget.exe' } }
        function Install-WingetPackage {
            $script:routeWingetCalls++
            if ($mode -eq 'winget-fails') { throw 'simulated installer failure' }
            $script:routeInstalled = $true
        }
        function Install-PortableTool {
            param($Name, $Root)
            Assert-True ($Root -eq $gameDir) 'Portable Python must stay under the private repository workspace'
            $script:routePortableCalls++
            $script:routeInstalled = $true
            return 'installed-python.exe'
        }
        function Add-ToolPath { }
        Ensure-PublicTool -Name Python -WingetId 'test.python'
        $expectedWinget = if ($mode -in @('winget-fails', 'winget-works')) { 1 } else { 0 }
        $expectedPortable = if ($mode -eq 'winget-works') { 0 } else { 1 }
        Assert-True ($script:routeWingetCalls -eq $expectedWinget) "Wrong winget routing for $mode"
        Assert-True ($script:routePortableCalls -eq $expectedPortable) "Wrong portable routing for $mode"
    } $mode
}

& {
    $SkipInstall = $true
    function Get-PublicTool { return $null }
    function Install-PortableTool { throw 'Unexpected download' }
    function Install-WingetPackage { throw 'Unexpected winget call' }
    Assert-Throws { Ensure-PublicTool Git 'test.git' } 'Rerun without -SkipInstall'
}

& {
    $gameDir = Join-Path $env:TEMP 'lordran-python-discovery-fixture'
    $venv = Join-Path $gameDir 'tools-venv'
    function Test-Path { return $true }
    function Test-PythonRuntime { return $false }
    function Get-Executable { return $null }
    Assert-True (@(Get-PythonCommand).Count -eq 0) 'Incompatible Python must not return a null array item'
}

& {
    $gameDir = Join-Path $env:TEMP 'lordran-python-discovery-fixture'
    $venv = Join-Path $gameDir 'tools-venv'
    function Test-Path { return $true }
    function Test-PythonRuntime { return $true }
    function Get-Executable { return $null }
    $result = @(Get-PythonCommand)
    Assert-True ($result.Count -eq 1) 'A direct Python command must remain an executable path, not characters'
    Assert-True ($result[0] -eq (Join-Path $venv 'Scripts\python.exe')) 'Prepared virtual environment must be reused'
}

& {
    $gameDir = Join-Path $env:TEMP 'lordran-python-environment-fixture'
    $venv = Join-Path $gameDir 'tools-venv'
    $python = Join-Path $venv 'Scripts\python.exe'
    $script:pipArguments = @()
    function Invoke-Checked {
        param($Command, $Arguments)
        Assert-True ($Command -eq $python) 'Package installation must use the selected interpreter'
        $script:pipArguments = $Arguments
    }
    $result = Initialize-PackagingPython @($python)
    Assert-True ($result -eq $python) 'Python initialization must return only its interpreter path'
    Assert-True ('--isolated' -in $script:pipArguments -and '--no-user' -in $script:pipArguments) 'pip must not install into user-site packages'
    $indexPosition = [Array]::IndexOf($script:pipArguments, '--index-url')
    Assert-True ($indexPosition -ge 0 -and $script:pipArguments[$indexPosition + 1] -eq 'https://pypi.org/simple') 'Default index must be explicit'
    $null = Initialize-PackagingPython @($python) -IndexUrl 'https://pypi.tuna.tsinghua.edu.cn/simple'
    Assert-True ($script:pipArguments[$indexPosition + 1] -eq 'https://pypi.tuna.tsinghua.edu.cn/simple') 'Selected mirror must reach isolated pip'
    Assert-True ('--isolated' -in $script:pipArguments -and '--no-user' -in $script:pipArguments) 'Mirrors must not disable Python isolation'
}

# Exercise actual parameter binding as well as offline pip argument routing.
$setupScript = Join-Path $PSScriptRoot '..\setup_windows_packaging.ps1'
foreach ($index in @('https://pypi.org/simple', 'https://pypi.tuna.tsinghua.edu.cn/simple')) {
    $null = & $setupScript -PipIndexUrl $index -Help
}
foreach ($index in @('http://example.invalid/simple', 'file:///tmp/index',
        'relative/simple', 'https://user:test@example.invalid/simple',
        'https://example.invalid/simple?token=test', 'https://example.invalid/simple#fragment')) {
    Assert-Throws { & $setupScript -PipIndexUrl $index -Help } 'absolute HTTPS'
}
Assert-True ($ast.Extent.Text -match 'Initialize-PackagingPython \$pythonCommand -IndexUrl \$PipIndexUrl') 'Setup must forward the selected package index'

& {
    $SkipInstall = $true
    $SkipVisualStudio = $false
    Assert-Throws { Install-VisualStudioTools } 'No working C\+\+ toolchain'
}

$root = Join-Path ([IO.Path]::GetTempPath()) "lordran-dependency-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
try {
    & {
        $ToolRoot = $root
        $SkipInstall = $false
        $Force = $false
        $archiveRoot = Join-Path $root 'fixture'
        New-Item -ItemType Directory -Path $archiveRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $archiveRoot 'fixture.exe') -Value 'public test fixture' -Encoding ASCII
        $cache = Join-Path $root 'downloads'
        New-Item -ItemType Directory -Path $cache | Out-Null
        $zip = Join-Path $cache 'fixture.zip'
        Compress-Archive -Path (Join-Path $archiveRoot '*') -DestinationPath $zip
        $spec = @{
            Url = 'https://example.invalid/fixture.zip'
            Hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            Directory = 'fixture-installed'; Executable = 'fixture.exe'
        }
        $WindowsDownloads = @{ Fixture = $spec }
        function Invoke-WebRequest { throw 'Tests must not download anything' }
        Assert-True ((Get-VerifiedDownload $spec $cache) -eq $zip) 'Verified cached archives must be reused'
        $installed = Install-PortableTool Fixture $root
        Assert-True (Test-Path -LiteralPath $installed -PathType Leaf) 'Verified archive must extract successfully'
        Assert-Throws { Install-PortableTool Fixture $root } 'left untouched'
        Assert-True ((Get-Content -Raw -LiteralPath $installed) -match 'public test fixture') 'Existing tools must be preserved'
        Add-Content -LiteralPath $zip -Value 'tampered'
        Assert-Throws { Get-VerifiedDownload $spec $cache } 'failed its SHA256 check'
        Assert-True (Test-Path -LiteralPath $zip) 'Mismatched cached archives must be preserved without -Force'
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }

Write-Host 'Windows dependency reuse, no-winget fallback, skip-install, and checksum checks passed.'
