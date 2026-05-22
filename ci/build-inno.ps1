<#
.SYNOPSIS
    Compile installer\SoftEtherVPN.iss into a single self-contained
    setup.exe with the Inno Setup compiler (ISCC.exe).

.DESCRIPTION
    Wraps Inno Setup so you don't have to remember the /D defines:

      1. Validates the three desktop-client binaries + the hamcore\ tree
         (and PenCore.dll) exist under src\bin\.
      2. Locates ISCC.exe (Inno Setup 6). If missing, optionally installs
         Inno Setup via winget when -InstallInno is passed.
      3. Runs ISCC with absolute SourceBin / InstallerSrc / OutDir defines.
      4. Reports the produced installer under dist\.

    The resulting dist\SoftEtherVPN-Client-Setup.exe bundles everything
    (exes + hamcore) and installs per-user with no admin required for the
    app itself; only the optional Neo6 driver step elevates.

.PARAMETER RepoRoot
    Repository root. Defaults to the script's parent's parent (the script is
    expected to live in <repo>\ci\).

.PARAMETER Version
    Version stamped into the installer (AppVersion). Default: 4.44.9807.

.PARAMETER OutputDir
    Where the setup.exe is written. Default: <repo>\dist.

.PARAMETER InstallInno
    If ISCC.exe is not found, install Inno Setup via winget, then continue.

.EXAMPLE
    PS> .\ci\build-inno.ps1
    Builds dist\SoftEtherVPN-Client-Setup.exe (Inno Setup must be installed).

.EXAMPLE
    PS> .\ci\build-inno.ps1 -InstallInno
    Installs Inno Setup via winget first if it's missing, then builds.

.NOTES
    Exit codes: 0 success, 2 prerequisite missing, 3 compile failure,
    4 output validation failure.
#>

[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $Version   = '4.44.9807',
    [string] $OutputDir,
    [switch] $InstallInno
)

$ErrorActionPreference = 'Stop'

function Write-Section([string] $msg) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $msg -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Fail([int] $code, [string] $msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit $code
}

# --------------------------------------------------------------- locate -------

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

$srcBin       = Join-Path $RepoRoot 'src\bin'
$srcHamcore   = Join-Path $srcBin   'hamcore'
$installerDir = Join-Path $RepoRoot 'installer'
$iss          = Join-Path $installerDir 'SoftEtherVPN.iss'
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }

Write-Section 'Pre-flight'
Write-Host "Repo root      : $RepoRoot"
Write-Host "Source bin     : $srcBin"
Write-Host "Installer src  : $installerDir"
Write-Host "Output dir     : $OutputDir"
Write-Host "Version        : $Version"

if (-not (Test-Path $iss)) { Fail 2 "Inno script not found: $iss" }

$required = @('vpncmd_x64.exe', 'vpnclient_x64.exe', 'vpncmgr_x64.exe')
foreach ($name in $required) {
    $p = Join-Path $srcBin $name
    if (-not (Test-Path $p)) {
        $tgt = $name -replace '_x64\.exe$', ''
        Fail 2 "Missing binary: $p. Build it: .\ci\build-binary.ps1 -Target $tgt"
    }
    Write-Host ("  [OK] {0,-20} {1,10:N0} bytes" -f $name, (Get-Item $p).Length)
}
if (-not (Test-Path $srcHamcore -PathType Container)) {
    Fail 2 "src\bin\hamcore\ not found; the runtime relies on it."
}
$penCore = Join-Path $srcHamcore 'PenCore.dll'
if (-not (Test-Path $penCore)) {
    Fail 2 "hamcore\PenCore.dll is missing - vpnclient/vpncmgr won't start. Build it: .\ci\build-binary.ps1 -Target PenCore"
}
Write-Host ("  [OK] {0,-20} {1,10:N0} bytes" -f 'hamcore\PenCore.dll', (Get-Item $penCore).Length)

foreach ($helper in @('vpncmd.cmd', 'install-driver.cmd')) {
    $hp = Join-Path $installerDir $helper
    if (-not (Test-Path $hp)) { Fail 2 "Installer helper not found: $hp" }
}

# --------------------------------------------------------------- find ISCC ----

Write-Section 'Locating Inno Setup compiler (ISCC.exe)'

function Find-Iscc {
    # 1. Fixed locations: per-machine (Program Files) AND per-user (winget often
    #    installs Inno to %LOCALAPPDATA%\Programs when not elevated).
    $bases = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles,
        (Join-Path $env:LOCALAPPDATA 'Programs')
    ) | Where-Object { $_ }
    foreach ($b in $bases) {
        $exe = Join-Path $b 'Inno Setup 6\ISCC.exe'
        if (Test-Path $exe) { return $exe }
    }

    # 2. On PATH already?
    $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 3. Registry uninstall keys (most reliable post-winget): read InstallLocation.
    $regRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $prop = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($prop.DisplayName -like 'Inno Setup*' -and $prop.InstallLocation) {
                $exe = Join-Path $prop.InstallLocation 'ISCC.exe'
                if (Test-Path $exe) { return $exe }
            }
        }
    }

    # 4. Last resort: shallow recursive search of likely roots.
    $searchRoots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($sr in $searchRoots) {
        $hit = Get-ChildItem -Path $sr -Filter 'ISCC.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    return $null
}

$iscc = Find-Iscc
if (-not $iscc -and $InstallInno) {
    Write-Host '  ISCC not found; installing Inno Setup via winget...' -ForegroundColor Yellow
    & winget install --exact --id JRSoftware.InnoSetup --silent --accept-package-agreements --accept-source-agreements
    $iscc = Find-Iscc
}
if (-not $iscc) {
    Fail 2 ("ISCC.exe not found. Install Inno Setup 6 (https://jrsoftware.org/isdl.php) " +
            "or re-run with -InstallInno. winget: winget install --id JRSoftware.InnoSetup")
}
Write-Host "  ISCC: $iscc"

# --------------------------------------------------------------- compile ------

Write-Section 'Compiling installer'

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$isccArgs = @(
    ("/DSourceBin={0}"    -f $srcBin),
    ("/DInstallerSrc={0}" -f $installerDir),
    ("/DOutDir={0}"       -f $OutputDir),
    ("/DMyAppVersion={0}" -f $Version),
    $iss
)
Write-Host ("  Command: `"{0}`" {1}" -f $iscc, ($isccArgs -join ' '))
& $iscc @isccArgs
$rc = $LASTEXITCODE
if ($rc -ne 0) { Fail 3 "ISCC exited with code $rc" }

# --------------------------------------------------------------- verify -------

Write-Section 'Verifying output'

$setupExe = Join-Path $OutputDir 'SoftEtherVPN-Client-Setup.exe'
if (-not (Test-Path $setupExe)) {
    Fail 4 "Expected installer not found: $setupExe"
}
$item = Get-Item $setupExe
Write-Host ("Built: {0}  ({1:N0} bytes, {2})" -f $item.FullName, $item.Length, $item.LastWriteTime)
Write-Host ''
Write-Host 'Inno installer built.' -ForegroundColor Green
Write-Host "Share / run: $setupExe" -ForegroundColor Cyan
exit 0
