@echo off
REM ---------------------------------------------------------------------------
REM  Stage the Neo6 virtual-NIC driver in the Windows driver store.
REM
REM  Driver staging requires administrator rights, so this script self-elevates
REM  via UAC. It resolves the INF relative to its own location (it ships next to
REM  the hamcore\ tree the installer laid down), so it works from the install
REM  folder regardless of the current directory.
REM ---------------------------------------------------------------------------
setlocal

REM Are we elevated? `net session` fails for non-admins.
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo Requesting administrator privileges for driver staging...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "INF=%~dp0hamcore\DriverPackages\Neo6_Win10\x64\Neo6_x64_VPN.inf"
if not exist "%INF%" (
    echo ERROR: driver INF not found:
    echo   %INF%
    echo Was the client installed with its hamcore\ tree intact?
    pause
    exit /b 1
)

echo Staging Neo6 driver:
echo   %INF%
echo.
pnputil /add-driver "%INF%" /install
set RC=%errorlevel%
echo.
echo pnputil exit code: %RC%
echo.
echo If HVCI / Memory Integrity is ON, creating a virtual NIC may still fail
echo with Error 31 until Memory Integrity is disabled and the PC is rebooted.
echo See RUN_WINDOWS.md for the mitigation.
echo.
pause
exit /b %RC%
