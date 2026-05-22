@echo off
REM Shim so `vpncmd` resolves to vpncmd_x64.exe once the install folder is on
REM PATH. Forwards all arguments through.
"%~dp0vpncmd_x64.exe" %*
