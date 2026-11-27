@echo off
setlocal
cd /d "%~dp0"
title LocalAI Creative Studio - Package Integrity
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\VERIFY-PACKAGE.ps1"
set RESULT=%ERRORLEVEL%
echo.
if "%RESULT%"=="0" echo PACKAGE INTEGRITY VERIFIED.
if not "%RESULT%"=="0" echo PACKAGE VERIFICATION FAILED.
pause
exit /b %RESULT%
