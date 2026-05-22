<#
.SYNOPSIS
    Self-contained installer / uninstaller for the SoftEther VPN desktop
    client (vpncmd / vpnclient / vpncmgr) built by this VS2026 fork.

.DESCRIPTION
    A per-user, no-admin installer written in plain PowerShell (5.1+). Unlike
    ci\install-local.ps1 (a minimal "run-in-place" deploy), this script
    behaves like a real installer:

      INSTALL (default):
        1. Validates the three binaries + the hamcore\ runtime tree exist
           under src\bin\ (and warns if hamcore\PenCore.dll is missing).
        2. Copies them into the install folder
           (default: %LOCALAPPDATA%\Programs\SoftEtherVPN).
        3. Copies this script next to them so uninstall is self-contained
           even if the repo is later moved or deleted.
        4. Writes a vpncmd.cmd shim and an uninstall.cmd wrapper.
        5. Creates Start Menu + Desktop shortcuts (unless -NoShortcuts).
        6. Adds the install folder to the *user* PATH (unless -NoPath) so
           `vpncmd` works from any prompt.
        7. Registers an "Apps & features / Add-Remove Programs" entry under
           HKCU so the client shows up and can be uninstalled from Settings.
        8. If -InstallDriver: stages the Neo6 virtual-NIC driver in the
           Windows driver store (this single step self-elevates via UAC;
           the rest of the install never needs admin).

      UNINSTALL (-Uninstall):
        Removes shortcuts, the PATH entry, the Add-Remove Programs key, and
        deletes the install folder. Prints the pnputil commands to remove the
        Neo6 driver from the store (driver removal needs admin and is left to
        the user on purpose, since other tools may rely on it).

    Nothing is ever written to Program Files and no Windows service is
    registered; the client runs in "user mode" (tray icon) on demand.

.PARAMETER DestinationPath
    Target install folder. Default: %LOCALAPPDATA%\Programs\SoftEtherVPN.

.PARAMETER RepoRoot
    Repository root. Defaults to the script's parent's parent (the script is
    expected to live in <repo>\ci\). Ignored in -Uninstall mode.

.PARAMETER Version
    Version string recorded in Add-Remove Programs. Default: 4.44.9807.

.PARAMETER InstallDriver
    Stage the Neo6 driver in the driver store (self-elevates via UAC).

.PARAMETER NoShortcuts
    Skip Start Menu / Desktop shortcut creation.

.PARAMETER NoPath
    Skip adding the install folder to the user PATH.

.PARAMETER Force
    Overwrite existing binaries even if a same-hash copy is already present.

.PARAMETER Uninstall
    Run the uninstaller instead of installing. When launched from the copy
    inside the install folder (as Add-Remove Programs does), the install
    folder is auto-detected from the script's own location.

.PARAMETER StageDriverOnly
    Internal: only stage the Neo6 driver, then exit. Used as the elevated
    child process by -InstallDriver and the "Install Neo6 Driver" shortcut.
    Self-elevates if the current process is not already admin.

.EXAMPLE
    PS> .\ci\installer.ps1
    Installs to %LOCALAPPDATA%\Programs\SoftEtherVPN with shortcuts + PATH,
    no driver staging.

.EXAMPLE
    PS> .\ci\installer.ps1 -InstallDriver
    Full install plus Neo6 driver staging (one UAC prompt for the driver).

.EXAMPLE
    PS> .\ci\installer.ps1 -Uninstall
    Removes shortcuts, PATH entry, the Add-Remove Programs entry, and the
    install folder.

.NOTES
    Driver caveat (Windows 11 24H2+): if HVCI / Memory Integrity is enabled,
    the Neo6 driver may fail to load because its signature uses a legacy
    cross-cert chain. The script warns when it detects HVCI is running.
    See RUN_WINDOWS.md / BUILD_WINDOWS.md for the mitigation.
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [string] $DestinationPath = (Join-Path $env:LOCALAPPDATA 'Programs\SoftEtherVPN'),
    [string] $RepoRoot,
    [string] $Version = '4.44.9807',
    [switch] $InstallDriver,
    [switch] $NoShortcuts,
    [switch] $NoPath,
    [switch] $Force,
    [switch] $Uninstall,
    [switch] $StageDriverOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --------------------------------------------------------------- constants ---

$AppName    = 'SoftEther VPN Client'
$AppId      = 'SoftEtherVPNClient'                 # registry / folder key
$Publisher  = 'SoftEther VPN Project (VS2026 fork)'
$HelpLink   = 'https://github.com/SoftEtherVPN/SoftEtherVPN_Stable'
$ArpKey     = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppId"
$DriverRel  = 'hamcore\DriverPackages\Neo6_Win10\x64\Neo6_x64_VPN.inf'

$Binaries = @('vpncmd_x64.exe', 'vpnclient_x64.exe', 'vpncmgr_x64.exe')

# Captured at script scope: inside functions $PSBoundParameters refers to the
# function's own params, so record here whether the caller passed -DestinationPath.
$DestinationProvided = $PSBoundParameters.ContainsKey('DestinationPath')

# ----------------------------------------------------------------- helpers ---

function Write-Section([string] $msg) {
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

function Test-HvciRunning {
    # Returns $true if HVCI / Memory Integrity is active (value 2 present in
    # SecurityServicesRunning), which is what blocks the legacy-signed Neo6
    # driver on Win11 24H2+.
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard `
                -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        return ($dg.SecurityServicesRunning -contains 2)
    } catch {
        return $false   # class missing on older builds = HVCI not a concern
    }
}

function New-Shortcut {
    param(
        [string] $LinkPath,
        [string] $TargetPath,
        [string] $Arguments       = '',
        [string] $WorkingDir      = '',
        [string] $IconLocation    = '',
        [string] $Description     = ''
    )
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($LinkPath)
    $sc.TargetPath = $TargetPath
    if ($Arguments)    { $sc.Arguments        = $Arguments }
    if ($WorkingDir)   { $sc.WorkingDirectory = $WorkingDir }
    if ($IconLocation) { $sc.IconLocation     = $IconLocation }
    if ($Description)  { $sc.Description       = $Description }
    $sc.Save()
}

function Get-SelfPath {
    # Absolute path to *this* script as it was launched.
    if ($PSCommandPath) { return $PSCommandPath }
    return (Join-Path $PSScriptRoot 'installer.ps1')
}

function Get-PowerShellExe {
    $p = (Get-Process -Id $PID).Path
    if ($p) { return $p }
    return (Join-Path $PSHOME 'powershell.exe')
}

# ============================================================================
#  MODE 1 - STAGE DRIVER ONLY (elevated child)
# ============================================================================

function Invoke-StageDriverOnly {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Driver staging needs administrator rights; requesting elevation...' -ForegroundColor Yellow
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = (Get-PowerShellExe)
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StageDriverOnly -DestinationPath "{1}"' -f (Get-SelfPath), $DestinationPath
        $psi.Verb      = 'runas'
        try {
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
            exit $p.ExitCode
        } catch {
            Write-Host "  Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    Write-Section 'Staging Neo6 driver in the Windows driver store'

    $inf = Join-Path $DestinationPath $DriverRel
    if (-not (Test-Path $inf)) {
        Write-Host "  ERROR: driver INF not found: $inf" -ForegroundColor Red
        Write-Host '  Was the client installed to this DestinationPath first?' -ForegroundColor Red
        exit 1
    }
    Write-Host "  INF: $inf"

    if (Test-HvciRunning) {
        Write-Host ''
        Write-Host '  [WARN] HVCI / Memory Integrity is ON. The driver will be added to' -ForegroundColor Yellow
        Write-Host '         the store, but creating a virtual NIC (NicCreate) will likely' -ForegroundColor Yellow
        Write-Host '         fail with Error 31 until Memory Integrity is disabled + reboot.' -ForegroundColor Yellow
        Write-Host '         See RUN_WINDOWS.md for the mitigation.' -ForegroundColor Yellow
        Write-Host ''
    }

    $pnpArgs = @('/add-driver', "`"$inf`"", '/install')
    Write-Host "  Running: pnputil $($pnpArgs -join ' ')"
    $proc = Start-Process -FilePath 'pnputil.exe' -ArgumentList $pnpArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 259) {
        Write-Host "  pnputil exit code: $($proc.ExitCode)" -ForegroundColor Yellow
        Write-Host '  Driver staging did NOT complete cleanly. Check eventvwr.msc ->' -ForegroundColor Yellow
        Write-Host '  Windows Logs -> Setup for details.' -ForegroundColor Yellow
        exit $proc.ExitCode
    }
    Write-Host '  [OK] Neo6 driver staged.' -ForegroundColor Green
    exit 0
}

# ============================================================================
#  MODE 2 - UNINSTALL
# ============================================================================

function Invoke-Uninstall {
    # If DestinationPath wasn't explicitly passed, infer it from where this
    # script copy lives (Add-Remove Programs launches the in-folder copy).
    if (-not $DestinationProvided -and $PSScriptRoot) {
        $DestinationPath = $PSScriptRoot
    }

    Write-Section "Uninstalling $AppName"
    Write-Host "Install folder : $DestinationPath"

    # 1. Shortcuts -----------------------------------------------------------
    $startDir = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
    if (Test-Path $startDir) {
        Remove-Item $startDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [DEL] Start Menu folder"
    }
    $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
    if (Test-Path $desktopLnk) {
        Remove-Item $desktopLnk -Force -ErrorAction SilentlyContinue
        Write-Host "  [DEL] Desktop shortcut"
    }

    # 2. PATH entry ----------------------------------------------------------
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object {
            $_ -and ($_.TrimEnd('\') -ne $DestinationPath.TrimEnd('\'))
        }
        $newPath = ($parts -join ';')
        if ($newPath -ne $userPath) {
            [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
            Write-Host "  [DEL] removed install folder from user PATH"
        }
    }

    # 3. Add-Remove Programs key --------------------------------------------
    if (Test-Path $ArpKey) {
        Remove-Item $ArpKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [DEL] Add-Remove Programs entry"
    }

    # 4. Install folder ------------------------------------------------------
    # We may be running from inside it (Add-Remove Programs), so the .ps1 file
    # is in use. Delete everything we can now, then hand the folder itself to
    # a detached cmd that waits a moment and removes it after we exit.
    if (Test-Path $DestinationPath) {
        Set-Location $env:TEMP
        $rd = 'ping 127.0.0.1 -n 3 >nul & rd /s /q "{0}"' -f $DestinationPath
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $rd -WindowStyle Hidden | Out-Null
        Write-Host "  [DEL] scheduling removal of install folder"
    }

    Write-Section 'Uninstall complete'
    Write-Host 'The Neo6 driver (if you staged it) was left in the driver store.' -ForegroundColor DarkGray
    Write-Host 'To remove it (admin):' -ForegroundColor DarkGray
    Write-Host '  pnputil /enum-drivers                 # find the oem<n>.inf whose Original Name is Neo6_x64_VPN.inf' -ForegroundColor DarkGray
    Write-Host '  pnputil /delete-driver oem<n>.inf /uninstall' -ForegroundColor DarkGray
    exit 0
}

# ============================================================================
#  MODE 3 - INSTALL (default)
# ============================================================================

function Invoke-Install {

    # ---- locate repo ------------------------------------------------------
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent (Get-SelfPath))
    }
    $RepoRoot = (Resolve-Path $RepoRoot).Path
    $srcBin     = Join-Path $RepoRoot 'src\bin'
    $srcHamcore = Join-Path $srcBin   'hamcore'

    Write-Section "Installing $AppName  (v$Version)"
    Write-Host "Repo root      : $RepoRoot"
    Write-Host "Source bin     : $srcBin"
    Write-Host "Destination    : $DestinationPath"
    Write-Host "Shortcuts      : $(-not $NoShortcuts)"
    Write-Host "Add to PATH    : $(-not $NoPath)"
    Write-Host "Stage driver   : $($InstallDriver.IsPresent)"

    # ---- pre-flight -------------------------------------------------------
    if (-not (Test-Path $srcBin -PathType Container)) {
        throw "src\bin\ not found under $RepoRoot. Build first: ci\build-desktop-client.ps1"
    }
    foreach ($name in $Binaries) {
        $p = Join-Path $srcBin $name
        if (-not (Test-Path $p)) {
            $tgt = $name -replace '_x64\.exe$', ''
            throw "Missing binary: $p. Build it: .\ci\build-binary.ps1 -Target $tgt"
        }
        $fi = Get-Item $p
        Write-Host ("  [OK] {0,-20} {1,10:N0} bytes" -f $name, $fi.Length)
    }
    if (-not (Test-Path $srcHamcore -PathType Container)) {
        throw "src\bin\hamcore\ not found; the runtime relies on it."
    }
    $penCore = Join-Path $srcHamcore 'PenCore.dll'
    if (-not (Test-Path $penCore)) {
        Write-Host ''
        Write-Host '  [WARN] hamcore\PenCore.dll is MISSING - vpnclient/vpncmgr will refuse' -ForegroundColor Yellow
        Write-Host '         to start ("PenCore.dll not found"). Build it first:'            -ForegroundColor Yellow
        Write-Host '             .\ci\build-binary.ps1 -Target PenCore'                       -ForegroundColor Yellow
        Write-Host '         then re-run this installer with -Force.'                         -ForegroundColor Yellow
    } else {
        Write-Host ("  [OK] {0,-20} {1,10:N0} bytes" -f 'hamcore\PenCore.dll', (Get-Item $penCore).Length)
    }

    # ---- copy binaries ----------------------------------------------------
    Write-Section 'Copying files'
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        Write-Host "  Created $DestinationPath"
    }
    foreach ($name in $Binaries) {
        $src = Join-Path $srcBin $name
        $dst = Join-Path $DestinationPath $name
        if ((Test-Path $dst) -and -not $Force) {
            $sh = (Get-FileHash $src -Algorithm SHA1).Hash
            $dh = (Get-FileHash $dst -Algorithm SHA1).Hash
            if ($sh -eq $dh) { Write-Host "  [SKIP] $name (identical)"; continue }
        }
        Copy-Item $src $dst -Force
        Write-Host "  [COPY] $name"
    }

    $dstHamcore = Join-Path $DestinationPath 'hamcore'
    Write-Host "  [SYNC] hamcore\ -> $dstHamcore"
    $rcArgs = @($srcHamcore, $dstHamcore, '/E', '/NJH', '/NJS', '/NFL', '/NDL', '/NP', '/R:1', '/W:1')
    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
    if ($rc.ExitCode -ge 8) { throw "robocopy failed copying hamcore (exit $($rc.ExitCode))." }

    # ---- copy self (for self-contained uninstall) -------------------------
    $selfDst = Join-Path $DestinationPath 'installer.ps1'
    Copy-Item (Get-SelfPath) $selfDst -Force
    Write-Host "  [COPY] installer.ps1 (for uninstall)"

    # ---- helper cmd files -------------------------------------------------
    Write-Section 'Writing helper scripts'
    $psExe = Get-PowerShellExe

    # vpncmd shim so `vpncmd` (no _x64) works once the folder is on PATH.
    $vpncmdShim = Join-Path $DestinationPath 'vpncmd.cmd'
@"
@echo off
REM Shim so `vpncmd` resolves to vpncmd_x64.exe when this folder is on PATH.
"%~dp0vpncmd_x64.exe" %*
"@ | Set-Content -Path $vpncmdShim -Encoding ASCII
    Write-Host "  [WROTE] vpncmd.cmd"

    # uninstall.cmd wrapper (handy outside Add-Remove Programs).
    $uninstallCmd = Join-Path $DestinationPath 'uninstall.cmd'
@"
@echo off
"$psExe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" -Uninstall
"@ | Set-Content -Path $uninstallCmd -Encoding ASCII
    Write-Host "  [WROTE] uninstall.cmd"

    $vpnclientExe = Join-Path $DestinationPath 'vpnclient_x64.exe'
    $vpncmgrExe   = Join-Path $DestinationPath 'vpncmgr_x64.exe'

    # ---- shortcuts --------------------------------------------------------
    if (-not $NoShortcuts) {
        Write-Section 'Creating shortcuts'
        $startDir = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
        New-Item -ItemType Directory -Path $startDir -Force | Out-Null

        New-Shortcut -LinkPath (Join-Path $startDir 'Start VPN Client (Usermode).lnk') `
            -TargetPath $vpnclientExe -Arguments '/usermode' -WorkingDir $DestinationPath `
            -IconLocation "$vpnclientExe,0" `
            -Description 'Start the SoftEther VPN client engine in this user session (tray icon, no admin).'

        New-Shortcut -LinkPath (Join-Path $startDir 'VPN Client Manager.lnk') `
            -TargetPath $vpncmgrExe -WorkingDir $DestinationPath `
            -IconLocation "$vpncmgrExe,0" `
            -Description 'SoftEther VPN Client Manager - create connections and connect. Start the client engine first.'

        New-Shortcut -LinkPath (Join-Path $startDir 'Install Neo6 Driver (Admin).lnk') `
            -TargetPath $psExe `
            -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -StageDriverOnly -DestinationPath "{1}"' -f $selfDst, $DestinationPath) `
            -WorkingDir $DestinationPath -IconLocation "$vpncmgrExe,0" `
            -Description 'Stage the Neo6 virtual-NIC driver (prompts for administrator).'

        New-Shortcut -LinkPath (Join-Path $startDir 'Uninstall SoftEther VPN Client.lnk') `
            -TargetPath $psExe `
            -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall' -f $selfDst) `
            -WorkingDir $DestinationPath -IconLocation "$vpncmgrExe,0" `
            -Description 'Remove the SoftEther VPN client.'
        Write-Host "  [OK] Start Menu folder: $startDir"

        New-Shortcut -LinkPath (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk") `
            -TargetPath $vpncmgrExe -WorkingDir $DestinationPath -IconLocation "$vpncmgrExe,0" `
            -Description 'SoftEther VPN Client Manager.'
        Write-Host "  [OK] Desktop shortcut"
    }

    # ---- PATH -------------------------------------------------------------
    if (-not $NoPath) {
        Write-Section 'Updating user PATH'
        $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if (-not $userPath) { $userPath = '' }
        $already = ($userPath -split ';' | Where-Object { $_.TrimEnd('\') -eq $DestinationPath.TrimEnd('\') })
        if ($already) {
            Write-Host "  [SKIP] already on user PATH"
        } else {
            $newPath = if ($userPath) { "$($userPath.TrimEnd(';'));$DestinationPath" } else { $DestinationPath }
            [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
            Write-Host "  [OK] added $DestinationPath to user PATH"
            Write-Host "       (open a new terminal for it to take effect)" -ForegroundColor DarkGray
        }
    }

    # ---- Add-Remove Programs ---------------------------------------------
    Write-Section 'Registering in Add-Remove Programs'
    $sizeKb = 0
    try {
        $sum = (Get-ChildItem $DestinationPath -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { $sizeKb = [int]($sum / 1024) }
    } catch { }
    New-Item -Path $ArpKey -Force | Out-Null
    $uninstallString = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Uninstall' -f $psExe, $selfDst
    $sets = @{
        DisplayName     = $AppName
        DisplayVersion  = $Version
        Publisher       = $Publisher
        InstallLocation = $DestinationPath
        DisplayIcon     = "$vpncmgrExe,0"
        UninstallString = $uninstallString
        QuietUninstallString = $uninstallString
        HelpLink        = $HelpLink
        NoModify        = 1
        NoRepair        = 1
        EstimatedSize   = $sizeKb
    }
    foreach ($k in $sets.Keys) {
        $type = if ($sets[$k] -is [int]) { 'DWord' } else { 'String' }
        New-ItemProperty -Path $ArpKey -Name $k -Value $sets[$k] -PropertyType $type -Force | Out-Null
    }
    Write-Host "  [OK] HKCU ...\Uninstall\$AppId"

    # ---- driver -----------------------------------------------------------
    if ($InstallDriver) {
        Invoke-DriverStagingChild
    } else {
        Write-Section 'Driver staging SKIPPED'
        Write-Host '  Re-run with -InstallDriver (UAC prompt) or use the' -ForegroundColor DarkGray
        Write-Host '  "Install Neo6 Driver (Admin)" Start Menu shortcut later.' -ForegroundColor DarkGray
    }

    # ---- summary ----------------------------------------------------------
    Write-Section 'Done'
    Write-Host "Installed to: $DestinationPath" -ForegroundColor Green
    Write-Host ''
    Write-Host 'To use it:' -ForegroundColor Cyan
    Write-Host '  1. Start Menu -> SoftEther VPN Client -> "Start VPN Client (Usermode)"'
    Write-Host '     (leave it running - it shows a tray icon)'
    Write-Host '  2. Then open "VPN Client Manager" (Start Menu or Desktop) to connect.'
    Write-Host '  CLI: open a NEW terminal and run  vpncmd  (now on your PATH).'
    if (-not $InstallDriver) {
        Write-Host ''
        Write-Host 'Before creating a virtual NIC, stage the driver once:' -ForegroundColor Cyan
        Write-Host '  Start Menu -> SoftEther VPN Client -> "Install Neo6 Driver (Admin)"'
    }
    Write-Host ''
    Write-Host 'Uninstall: Settings -> Apps, or the "Uninstall" Start Menu shortcut.' -ForegroundColor Cyan
    exit 0
}

function Invoke-DriverStagingChild {
    # Launch this script's installed copy in -StageDriverOnly mode; that child
    # self-elevates so only the driver step touches admin.
    Write-Section 'Staging Neo6 driver (separate elevated step)'
    $psExe   = Get-PowerShellExe
    $selfDst = Join-Path $DestinationPath 'installer.ps1'
    $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StageDriverOnly -DestinationPath "{1}"' -f $selfDst, $DestinationPath
    Write-Host "  Launching elevated: $psExe $a"
    $p = Start-Process -FilePath $psExe -ArgumentList $a -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Host "  [WARN] driver staging returned exit code $($p.ExitCode)." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] driver staging finished." -ForegroundColor Green
    }
}

# ============================================================================
#  Dispatch
# ============================================================================

if ($StageDriverOnly) { Invoke-StageDriverOnly }
elseif ($Uninstall)   { Invoke-Uninstall }
else                  { Invoke-Install }
