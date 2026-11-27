@echo off
setlocal
cd /d "%~dp0"
set "PROJECT_ROOT=%~dp0"
set "PYTHON=%PROJECT_ROOT%.venv\Scripts\python.exe"
if exist "%PYTHON%" goto rebuild

rem Use the verified installed copy when this is a clean source release folder.
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
set "RESOLVER=%~dp0scripts\INSTALL-ROOT.ps1"
if not exist "%RESOLVER%" goto no_python
set "RESOLVED_ROOT="
for /f "usebackq delims=" %%R in (`"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ". '%RESOLVER%'; $d=Join-Path $env:LOCALAPPDATA 'Programs\LocalAI Creative Studio'; $r=Get-VerifiedLocalAIInstallRoot -FallbackRoot $d; if ((Test-LocalAIInstallOwnerMarker $r) -or (Test-LocalAILegacyInstall $r)) { $r }"`) do set "RESOLVED_ROOT=%%R"
if not defined RESOLVED_ROOT goto no_python
set "PYTHON=%RESOLVED_ROOT%\.venv\Scripts\python.exe"
if not exist "%PYTHON%" goto no_python
set "PROJECT_ROOT=%RESOLVED_ROOT%\"

:rebuild
"%PYTHON%" "%PROJECT_ROOT%scripts\build_manifest.py"
if errorlevel 1 (
  echo Could not rebuild the package manifest.
  pause
  exit /b 1
)
echo Manifest rebuilt. Review every changed file before redistributing the package.
pause
endlocal
exit /b 0

:no_python
echo No verified prepared Studio Python environment was found.
echo Run SETUP-AND-START.bat once, then retry REBUILD-MANIFEST.bat.
pause
exit /b 1
