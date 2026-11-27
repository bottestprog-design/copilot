@echo off
setlocal
cd /d "%~dp0"
title LocalAI Creative Studio - Install or Update
echo ============================================================
echo   LOCALAI CREATIVE STUDIO - ONE FILE INSTALL / UPDATE
echo   First run: installs the app and creates its Desktop icon.
echo   Future releases: updates the installed app and refreshes the icon.
echo   Daily use: open the Desktop icon only.
echo ============================================================
echo.
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\INSTALL-DESKTOP-APP.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo INSTALL / UPDATE FAILED. Review the log before retrying.
  pause
)
exit /b %RESULT%
