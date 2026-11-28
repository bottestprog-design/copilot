@echo off
setlocal
cd /d "%~dp0"
title LocalAI Creative Studio - Apply Desktop Update
echo ============================================================
echo   LOCALAI CREATIVE STUDIO - DESKTOP UPDATE
echo   Updates the installed app and refreshes its Desktop icon.
echo   Preserves app settings, generated media, history and models.
echo ============================================================
echo.
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\APPLY-UPDATE.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" (
  echo UPDATE COMPLETE. Use the refreshed Desktop icon from now on.
) else (
  echo UPDATE FAILED. Review the update log before retrying.
  pause
)
exit /b %RESULT%
