<#
.SYNOPSIS
    Install the built SoftEther VPN desktop-client trio (vpncmd / vpnclient /
    vpncmgr) into a local folder, optionally pre-staging the Neo6 virtual-NIC
    driver in the Windows driver store.

.DESCRIPTION
    Run-in-place style install intended for manual testing and dev iteration
    of the binaries produced by ci\build-desktop-client.ps1. Performs:

      1. Validates the repo has the three expected binaries under src\bin\.
      2. Creates the destination folder (default: %USERPROFILE%\SoftEtherVPN).
      3. Copies vpncmd_x64.exe, vpnclient_x64.exe, vpncmgr_x64.exe and the
         entire hamcore\ runtime tree.
      4. Drops three convenience launchers:
           - run-vpnclient-usermode.cmd  (foreground /usermode — tray icon, no admin)
           - run-vpncmgr.cmd             (launches the GUI manager)
           - run-vpncmd.cmd              (CLI against localhost)
      5. If -InstallDriver is set, pre-stages Neo6_x64_VPN.inf in the Windows
         driver store via pnputil /add-driver /install. This step REQUIRES
         administrator privileges and will self-elevate via UAC if needed.

    The install is non-destructive: nothing is written to Program Files,
    no Windows service is registered, no PATH entries are added. Uninstall
    is "delete the folder" (driver remains in the store; remove it with
    `pnputil /delete-driver oem<n>.inf` if desired).

.PARAMETER DestinationPath
    Target install folder. Default: $env:USERPROFILE\SoftEtherVPN.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the script's parent's parent
    (assumes the script lives in <repo>\ci\).

.PARAMETER InstallDriver
    If specified, runs pnputil /add-driver /install on Neo6_x64_VPN.inf so
    the OS trusts the virtual-NIC driver ahead of first vpnclient NicCreate.
    Will self-elevate to admin if the current shell is not elevated.

.PARAMETER Force
    Overwrite existing files in the destination without prompting.

.EXAMPLE
    PS> .\ci\install-local.ps1
    Copies binaries to %USERPROFILE%\SoftEtherVPN without touching the driver
    store. Good for a quick UI smoke test (use run-vpnclient-usermode.cmd to
    launch the engine; vpncmgr will then connect to it on localhost).

.EXAMPLE
    PS> .\ci\install-local.ps1 -InstallDriver
    Copies binaries AND pre-stages the Neo6 driver. UAC prompt expected.

.EXAMPLE
    PS> .\ci\install-local.ps1 -DestinationPath C:\sevpn -InstallDriver -Force
    Custom destination, driver staging, overwrite anything in the way.

.NOTES
    Driver caveat for Windows 11 24H2+: if HVCI / Memory Integrity is
    enabled, the Neo6 driver may fail to load because its signature uses
    a legacy cross-cert chain. Temporarily disable Memory Integrity in
    Settings -> Privacy & security -> Windows Security -> Device security
    -> Core isolation, reboot, then re-run the install.

    For a CLI sanity check after install, open two PowerShell windows:
      Window A:  & "$env:USERPROFILE\SoftEtherVPN\run-vpnclient-usermode.cmd"
      Window B:  & "$env:USERPROFILE\SoftEtherVPN\vpncmd_x64.exe" localhost /CLIENT
#>

[CmdletBinding()]
param(
    [string]$DestinationPath = (Join-Path $env:USERPROFILE 'SoftEtherVPN'),
    [string]$RepoRoot,
    [switch]$InstallDriver,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ------------------------------------------------------------------ helpers --

function Write-Section([string]$msg) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $msg -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfElevate {
    param([string[]]$ForwardArgs)
    Write-Host '  -> not elevated; relaunching this script via UAC...' -ForegroundColor Yellow
    $psi  = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = (Get-Process -Id $PID).Path
    $psi.Arguments = ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " + ($ForwardArgs -join ' '))
    $psi.Verb      = 'runas'
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    exit $p.ExitCode
}

# ----------------------------------------------------------------- locate ----

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$RepoRoot = (Resolve-Path $RepoRoot).Path

$srcBin      = Join-Path $RepoRoot 'src\bin'
$srcHamcore  = Join-Path $srcBin   'hamcore'
$binaries    = @(
    @{ Name = 'vpncmd_x64.exe';    Path = Join-Path $srcBin 'vpncmd_x64.exe'    },
    @{ Name = 'vpnclient_x64.exe'; Path = Join-Path $srcBin 'vpnclient_x64.exe' },
    @{ Name = 'vpncmgr_x64.exe';   Path = Join-Path $srcBin 'vpncmgr_x64.exe'   }
)

Write-Section 'Pre-flight'
Write-Host "Repo root        : $RepoRoot"
Write-Host "Source bin       : $srcBin"
Write-Host "Destination      : $DestinationPath"
Write-Host "Install driver   : $($InstallDriver.IsPresent)"
Write-Host "Force overwrite  : $($Force.IsPresent)"

if (-not (Test-Path $srcBin -PathType Container)) {
    throw "src\bin\ not found under $RepoRoot. Build the binaries first (ci\build-desktop-client.ps1)."
}
foreach ($b in $binaries) {
    if (-not (Test-Path $b.Path)) {
        throw "Missing binary: $($b.Path). Build it with: .\ci\build-binary.ps1 -Target $($b.Name -replace '_x64\.exe$','')"
    }
    $fi = Get-Item $b.Path
    Write-Host ("  [OK] {0,-22} {1,10:N0} bytes  {2}" -f $b.Name, $fi.Length, $fi.LastWriteTime)
}
if (-not (Test-Path $srcHamcore -PathType Container)) {
    throw "src\bin\hamcore\ not found. The runtime relies on this directory."
}

# PenCore.dll is a resource-only DLL the binaries LoadLibrary at startup
# (it holds icons/bitmaps for the GUI and the Cedar resource IDs). It's a
# *separate build target* — not produced by vpncmd/vpnclient/vpncmgr — and
# the runtime aborts with "PenCore.dll not found" if it's missing under
# the hamcore\ directory. Warn loudly if absent so the user can build it
# before continuing.
$penCoreDll = Join-Path $srcHamcore 'PenCore.dll'
if (-not (Test-Path $penCoreDll)) {
    Write-Host ''
    Write-Host '  [WARN] src\bin\hamcore\PenCore.dll is MISSING.' -ForegroundColor Yellow
    Write-Host '         vpnclient / vpncmgr will refuse to start with' -ForegroundColor Yellow
    Write-Host '         "PenCore.dll not found. SoftEther VPN couldnt start."' -ForegroundColor Yellow
    Write-Host '         Build it first:' -ForegroundColor Yellow
    Write-Host '             .\ci\build-binary.ps1 -Target PenCore' -ForegroundColor Yellow
    Write-Host '         then re-run this installer with -Force.' -ForegroundColor Yellow
    Write-Host ''
} else {
    $fi = Get-Item $penCoreDll
    Write-Host ("  [OK] {0,-22} {1,10:N0} bytes  {2}" -f 'hamcore\PenCore.dll', $fi.Length, $fi.LastWriteTime)
}

# -------------------------------------------------------------- driver check -

# If the user asked for driver staging, make sure we're elevated *before*
# we copy anything: if we have to relaunch via UAC, the elevated instance
# will redo the whole install in a separate window, and doubling the work
# would just be wasteful.
if ($InstallDriver -and -not (Test-IsAdmin)) {
    $forward = @(
        "-DestinationPath `"$DestinationPath`""
        "-RepoRoot `"$RepoRoot`""
        "-InstallDriver"
    )
    if ($Force) { $forward += '-Force' }
    Invoke-SelfElevate -ForwardArgs $forward
}

# -------------------------------------------------------------- copy stage ---

Write-Section 'Copying files'

if (-not (Test-Path $DestinationPath)) {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    Write-Host "  Created $DestinationPath"
} else {
    Write-Host "  Destination already exists, reusing it"
}

foreach ($b in $binaries) {
    $dst = Join-Path $DestinationPath $b.Name
    if ((Test-Path $dst) -and -not $Force) {
        $srcHash = (Get-FileHash $b.Path -Algorithm SHA1).Hash
        $dstHash = (Get-FileHash $dst    -Algorithm SHA1).Hash
        if ($srcHash -eq $dstHash) {
            Write-Host "  [SKIP] $($b.Name) (identical hash)"
            continue
        }
        Write-Host "  [DIFF] $($b.Name) already exists with a different hash; use -Force to overwrite" -ForegroundColor Yellow
        continue
    }
    Copy-Item -Path $b.Path -Destination $dst -Force
    Write-Host "  [COPY] $($b.Name)"
}

$dstHamcore = Join-Path $DestinationPath 'hamcore'
$robocopyArgs = @(
    $srcHamcore, $dstHamcore,
    '/E', '/NJH', '/NJS', '/NFL', '/NDL', '/NP', '/R:1', '/W:1'
)
Write-Host "  [SYNC] hamcore\ -> $dstHamcore"
$rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $robocopyArgs `
        -Wait -PassThru -NoNewWindow
# robocopy exit codes 0..7 are success-ish; >=8 is failure
if ($rc.ExitCode -ge 8) {
    throw "robocopy failed copying hamcore (exit $($rc.ExitCode))."
}

# -------------------------------------------------------------- launchers ----

Write-Section 'Writing convenience launchers'

$runTestCmd = Join-Path $DestinationPath 'run-vpnclient-usermode.cmd'
@"
@echo off
REM Run vpnclient in foreground "user mode": opens a tray icon, holds the
REM TCP management listener open (the SoftEther internal port range 9930-9934
REM is scanned by vpncmgr/vpncmd at startup), and does NOT require admin nor
REM register a Windows service. Close it by right-clicking the tray icon ->
REM Exit, or just close this console.
REM
REM /test is the *other* foreground mode: it pops a modal "service is started
REM in test mode" and kills the listener as soon as you click OK — only useful
REM as a sanity check that the binary launches, not for interactive use.
cd /d "%~dp0"
"%~dp0vpnclient_x64.exe" /usermode
"@ | Set-Content -Path $runTestCmd -Encoding ASCII

$runMgrCmd = Join-Path $DestinationPath 'run-vpncmgr.cmd'
@"
@echo off
REM Launch the GUI client manager. Requires vpnclient to be running
REM (start run-vpnclient-usermode.cmd in another window first).
cd /d "%~dp0"
start "" "%~dp0vpncmgr_x64.exe"
"@ | Set-Content -Path $runMgrCmd -Encoding ASCII

$runCmdCmd = Join-Path $DestinationPath 'run-vpncmd.cmd'
@"
@echo off
REM Open vpncmd against the local vpnclient.
cd /d "%~dp0"
"%~dp0vpncmd_x64.exe" localhost /CLIENT
"@ | Set-Content -Path $runCmdCmd -Encoding ASCII

Write-Host "  [WROTE] run-vpnclient-usermode.cmd"
Write-Host "  [WROTE] run-vpncmgr.cmd"
Write-Host "  [WROTE] run-vpncmd.cmd"

# -------------------------------------------------------------- driver stage -

if ($InstallDriver) {
    Write-Section 'Staging Neo6 driver in driver store'

    $neoInf = Join-Path $srcHamcore 'DriverPackages\Neo6_Win10\x64\Neo6_x64_VPN.inf'
    if (-not (Test-Path $neoInf)) {
        throw "Driver INF not found: $neoInf"
    }
    Write-Host "  Using: $neoInf"

    # /install also creates the device node for boot-start drivers; for Neo6
    # (a virtual NIC that vpnclient creates on demand) we mostly need
    # /add-driver so the package is in the store and trusted. Adding /install
    # is harmless and lets pnputil immediately bind any pending unsigned
    # warnings into the trust decision.
    $pnputilArgs = @('/add-driver', "`"$neoInf`"", '/install')
    Write-Host "  Running: pnputil $($pnputilArgs -join ' ')"
    $proc = Start-Process -FilePath 'pnputil.exe' -ArgumentList $pnputilArgs `
            -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 259) {
        # 259 = STATUS_REBOOT_REQUIRED in some pnputil paths; not a hard error.
        Write-Host "  pnputil exit code: $($proc.ExitCode)" -ForegroundColor Yellow
        Write-Host "  Driver staging did NOT succeed cleanly. Check the Setup Event Log:" -ForegroundColor Yellow
        Write-Host "    eventvwr.msc -> Windows Logs -> Setup" -ForegroundColor Yellow
        Write-Host "  Common cause on Win11 24H2+: Memory Integrity is enabled; disable it and retry." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] Neo6 driver staged."
    }
} else {
    Write-Section 'Driver staging SKIPPED'
    Write-Host "  Re-run with -InstallDriver (will prompt for admin) when you" -ForegroundColor DarkGray
    Write-Host "  actually want to create virtual NICs via vpnclient/vpncmgr."  -ForegroundColor DarkGray
}

# -------------------------------------------------------------- summary ------

Write-Section 'Done'
Write-Host "Installed to: $DestinationPath" -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps (run from PowerShell):' -ForegroundColor Cyan
Write-Host "  1. Start vpnclient in test mode (leave this window open):"
Write-Host "       & `"$runTestCmd`""
Write-Host "  2. In another PowerShell window, launch the GUI:"
Write-Host "       & `"$runMgrCmd`""
Write-Host "     ...or the CLI:"
Write-Host "       & `"$runCmdCmd`""
Write-Host ''
Write-Host 'Uninstall:' -ForegroundColor Cyan
Write-Host "  Remove-Item -Recurse -Force `"$DestinationPath`"" 
if ($InstallDriver) {
    Write-Host "  pnputil /enum-drivers              # find the oem<n>.inf for Neo6"
    Write-Host "  pnputil /delete-driver oem<n>.inf  # remove from driver store"
}
Write-Host ''
