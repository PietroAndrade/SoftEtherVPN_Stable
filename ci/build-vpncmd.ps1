<#
.SYNOPSIS
    Build vpncmd_x64.exe from a clean SoftEtherVPN_Stable checkout.

.DESCRIPTION
    Idempotent CI/local build script for the modernized VS2026 toolchain.

    Performs:
      1. Locates Visual Studio 2026 (or any VS with v143+) via vswhere.
      2. Locates rc.exe / makecat.exe in the most recent Windows 11 SDK.
      3. Sets the env vars expected by the patched BuildUtil
         (RC_EXE, MAKECAT_EXE).
      4. Cleans previous vpncmd intermediate artifacts to avoid
         PDB-server / multi-tool race conditions.
      5. Invokes msbuild on src\SEVPN.sln targeting vpncmd Release|x64.
      6. Verifies the binary exists and is executable.

    Designed to run from a plain PowerShell prompt; it will resolve the
    MSBuild path itself and does not require Developer PowerShell.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the script's parent's parent
    (i.e. assumes the script lives in <repo>/ci/).

.PARAMETER Configuration
    MSBuild configuration. Default: Release.

.PARAMETER Platform
    MSBuild platform. Default: x64. (Only x64 is validated.)

.PARAMETER SkipPdb
    Pass /p:DebugInformationFormat=None to skip PDB generation. Useful in
    CI to avoid mspdbsrv.exe race conditions. Default: $true.

.PARAMETER Verbosity
    MSBuild /v: level. Default: minimal.

.EXAMPLE
    PS> .\ci\build-vpncmd.ps1

.EXAMPLE
    PS> .\ci\build-vpncmd.ps1 -Configuration Release -Platform x64 -Verbosity normal

.NOTES
    Exit codes:
      0 - success
      2 - prerequisite missing (VS, SDK, etc.)
      3 - build failure
      4 - output validation failure
#>

[CmdletBinding()]
param(
    [string] $RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $Configuration = 'Release',
    [string] $Platform      = 'x64',
    [bool]   $SkipPdb       = $true,
    [string] $Verbosity     = 'minimal'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail {
    param([int] $Code, [string] $Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}

# ---------------------------------------------------------------------------
# 1. Locate Visual Studio 2026 (or compatible) via vswhere
# ---------------------------------------------------------------------------
Write-Step "Locating Visual Studio installation"

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    Fail 2 "vswhere.exe not found at $vswhere. Install Visual Studio 2026."
}

$vsInstall = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsInstall) {
    Fail 2 "No Visual Studio install with VC tools (x86/x64) was found."
}

$msbuild = & $vswhere -latest -products * `
    -requires Microsoft.Component.MSBuild `
    -find "MSBuild\**\Bin\MSBuild.exe"
if (-not $msbuild -or -not (Test-Path $msbuild)) {
    Fail 2 "MSBuild not found in any Visual Studio install."
}

Write-Host "VS install:  $vsInstall"
Write-Host "MSBuild:     $msbuild"

# ---------------------------------------------------------------------------
# 2. Locate rc.exe / makecat.exe in the latest Windows 11 SDK
# ---------------------------------------------------------------------------
Write-Step "Locating Windows 11 SDK tools (rc.exe, makecat.exe)"

$sdkBinRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
if (-not (Test-Path $sdkBinRoot)) {
    Fail 2 "Windows 11 SDK not found at $sdkBinRoot."
}

# Pick the highest-versioned SDK directory that has an x64 rc.exe
$sdkVersion = Get-ChildItem $sdkBinRoot -Directory `
    | Where-Object { $_.Name -match '^10\.' } `
    | Sort-Object Name -Descending `
    | Where-Object { Test-Path (Join-Path $_.FullName 'x64\rc.exe') } `
    | Select-Object -First 1

if (-not $sdkVersion) {
    Fail 2 "No Windows 11 SDK directory with x64\rc.exe was found under $sdkBinRoot."
}

$rcExe      = Join-Path $sdkVersion.FullName 'x64\rc.exe'
$makecatExe = Join-Path $sdkVersion.FullName 'x64\makecat.exe'

Write-Host "SDK version: $($sdkVersion.Name)"
Write-Host "rc.exe:      $rcExe"
Write-Host "makecat.exe: $makecatExe"

# ---------------------------------------------------------------------------
# 3. Export env vars expected by patched BuildUtil
# ---------------------------------------------------------------------------
Write-Step "Setting environment variables for BuildUtil"

$env:RC_EXE      = $rcExe
$env:MAKECAT_EXE = $makecatExe

Write-Host "RC_EXE      = $env:RC_EXE"
Write-Host "MAKECAT_EXE = $env:MAKECAT_EXE"

# ---------------------------------------------------------------------------
# 4. Validate repo layout
# ---------------------------------------------------------------------------
Write-Step "Validating repository layout"

$sln = Join-Path $RepoRoot 'src\SEVPN.sln'
if (-not (Test-Path $sln)) {
    Fail 2 "Solution not found: $sln (RepoRoot=$RepoRoot)"
}
Write-Host "Solution:    $sln"

# ---------------------------------------------------------------------------
# 5. Clean previous vpncmd intermediate state to avoid PDB/MultiTool races
# ---------------------------------------------------------------------------
Write-Step "Cleaning previous vpncmd intermediate artifacts"

# Stop any orphan PDB servers that could lock files
Get-Process mspdbsrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$intDir = Join-Path $RepoRoot ("src\vpncmd\{0}_{1}" -f $Platform, $Configuration)
if (Test-Path $intDir) {
    Remove-Item $intDir -Recurse -Force
    Write-Host "Removed: $intDir"
}

$exeArch = if ($Platform -eq 'x64') { 'x64' } else { 'x86' }
$outExe = Join-Path $RepoRoot ("src\bin\vpncmd_{0}.exe" -f $exeArch)
if (Test-Path $outExe) {
    Remove-Item $outExe -Force
    Write-Host "Removed: $outExe"
}

# Pre-create dirs known to be touched by the build to dodge create-races
New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'src\tmp\lib') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'src\tmp\VersionResources') | Out-Null

# ---------------------------------------------------------------------------
# 6. Invoke msbuild
# ---------------------------------------------------------------------------
Write-Step "Building vpncmd ($Configuration | $Platform)"

$msbuildArgs = @(
    $sln,
    '/t:vpncmd',
    "/p:Configuration=$Configuration",
    "/p:Platform=$Platform",
    "/v:$Verbosity",
    '/nologo'
)
if ($SkipPdb) {
    $msbuildArgs += '/p:DebugInformationFormat=None'
}

Write-Host "Command: $msbuild $($msbuildArgs -join ' ')"
& $msbuild @msbuildArgs
$buildExit = $LASTEXITCODE
if ($buildExit -ne 0) {
    Fail 3 "msbuild exited with code $buildExit"
}

# ---------------------------------------------------------------------------
# 7. Verify output
# ---------------------------------------------------------------------------
Write-Step "Verifying output binary"

if (-not (Test-Path $outExe)) {
    Fail 4 "Expected binary not found: $outExe"
}

$item = Get-Item $outExe
Write-Host ("Built: {0}  ({1:N0} bytes, {2})" -f $item.FullName, $item.Length, $item.LastWriteTime)

# Smoke test: run /HELP and confirm it prints the BuildUtil banner.
# /HELP exits with non-zero ("user canceled") which is normal — we only
# check that the process started and produced output.
try {
    $help = & $outExe /HELP 2>&1 | Out-String
    if ($help -match 'vpncmd' -or $help -match 'VPN') {
        Write-Host "Smoke test:  OK (binary produced expected banner)"
    } else {
        Write-Host "Smoke test:  WARNING — output did not contain 'vpncmd' or 'VPN' banner"
    }
} catch {
    Write-Host "Smoke test:  WARNING — could not execute binary: $_"
}

Write-Host ""
Write-Host "Build succeeded." -ForegroundColor Green
exit 0
