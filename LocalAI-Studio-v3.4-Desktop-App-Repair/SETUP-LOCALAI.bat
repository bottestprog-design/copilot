@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title LocalAI Studio - Setup and Update
set "PSHOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSHOST%" (
  echo Windows PowerShell 5.1 was not found.
  pause
  exit /b 2
)
if not exist "%~dp0SETUP-LOCALAI.ps1" (
  echo SETUP-LOCALAI.ps1 is missing. Extract the complete ZIP file again.
  pause
  exit /b 2
)
echo.
echo ============================================================
echo  LOCALAI STUDIO - ONE-CLICK SETUP / UPDATE
echo  Installs the desktop shortcut, refreshes its icon, prepares
echo  the local chat platform, then opens the app window.
echo ============================================================
echo.
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0SETUP-LOCALAI.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Setup/update failed with exit code %RC%.
  echo Review the latest logs under D:\LocalAI\Logs.
  pause
)
exit /b %RC%
