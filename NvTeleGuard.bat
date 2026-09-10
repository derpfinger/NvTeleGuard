@echo off
rem NvTeleGuard launcher - runs the PowerShell app without needing to change the execution policy.
rem The script requests administrator rights itself (UAC prompt).
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0NvTeleGuard.ps1" %*
endlocal
