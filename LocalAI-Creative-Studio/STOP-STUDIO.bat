@echo off
setlocal
cd /d "%~dp0"
title LocalAI Creative Studio - Exit
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\STOP-STUDIO.ps1"
echo.
pause
endlocal
