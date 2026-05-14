<#
.SYNOPSIS
    Build the complete SoftEther VPN desktop client runtime.

.DESCRIPTION
    Orchestrator that builds the three user-mode binaries needed for a
    SoftEther desktop client installation on Windows:

      vpncmd      - CLI tool for scripting and advanced configuration
      vpnclient   - background Windows service that maintains VPN tunnels
      vpncmgr     - Connection Manager GUI (the icon end-users click)

    Drivers (Neo, Neo6, SeLow) are NOT rebuilt — pre-signed .sys/.cat
    files ship in src/bin/hamcore/DriverPackages/.

    Calls ci/build-binary.ps1 for each target. Stops on first failure.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the script's parent's parent.

.PARAMETER Configuration
    MSBuild configuration. Default: Release.

.PARAMETER Platform
    MSBuild platform. Default: x64.

.PARAMETER ContinueOnError
    Keep building remaining binaries even if one fails. Default: $false.

.EXAMPLE
    PS> .\ci\build-desktop-client.ps1
    Builds all three binaries; aborts on first failure.

.EXAMPLE
    PS> .\ci\build-desktop-client.ps1 -ContinueOnError
    Attempts all three even if some fail. Reports per-binary status at end.

.NOTES
    Exit codes:
      0 - all binaries built successfully
      1 - at least one binary failed
#>

[CmdletBinding()]
param(
    [string] $RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $Configuration = 'Release',
    [string] $Platform      = 'x64',
    [switch] $ContinueOnError
)

$ErrorActionPreference = 'Stop'

$buildBinary = Join-Path $PSScriptRoot 'build-binary.ps1'
if (-not (Test-Path $buildBinary)) {
    Write-Host "ERROR: ci/build-binary.ps1 not found at $buildBinary" -ForegroundColor Red
    exit 2
}

$targets = @('vpncmd', 'vpnclient', 'vpncmgr')
$results = @()
$startTime = Get-Date

foreach ($t in $targets) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor DarkCyan
    Write-Host " Building: $t" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor DarkCyan

    $tStart = Get-Date
    try {
        & $buildBinary -Target $t -RepoRoot $RepoRoot -Configuration $Configuration -Platform $Platform
        $exit = $LASTEXITCODE
    } catch {
        $exit = 99
        Write-Host "EXCEPTION: $_" -ForegroundColor Red
    }
    $tElapsed = (Get-Date) - $tStart

    $results += [PSCustomObject]@{
        Target  = $t
        Exit    = $exit
        Status  = if ($exit -eq 0) { 'OK' } else { 'FAILED' }
        Seconds = [math]::Round($tElapsed.TotalSeconds, 1)
    }

    if ($exit -ne 0 -and -not $ContinueOnError) {
        Write-Host ""
        Write-Host "Aborting: $t failed with exit code $exit (use -ContinueOnError to override)." -ForegroundColor Red
        break
    }
}

$totalElapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "================================================================" -ForegroundColor DarkCyan
Write-Host " Desktop client build summary" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor DarkCyan
$results | Format-Table -AutoSize

Write-Host "Total elapsed: $([math]::Round($totalElapsed.TotalSeconds, 1))s"

$anyFailed = $results | Where-Object { $_.Status -ne 'OK' }
if ($anyFailed) {
    exit 1
}

# Final manifest of produced binaries
Write-Host ""
Write-Host "Output binaries:" -ForegroundColor Cyan
foreach ($t in $targets) {
    $exe = Join-Path $RepoRoot ("src\bin\{0}_x64.exe" -f $t)
    if (Test-Path $exe) {
        $item = Get-Item $exe
        Write-Host ("  {0,-12}  {1,10:N0} bytes  {2}" -f $item.Name, $item.Length, $item.LastWriteTime)
    }
}

Write-Host ""
Write-Host "Desktop client runtime built successfully." -ForegroundColor Green
exit 0
