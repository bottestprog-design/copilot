@echo off
setlocal
cd /d "%~dp0"
set "PYTHON=%~dp0.venv\Scripts\python.exe"
if not exist "%PYTHON%" set "PYTHON=%LOCALAPPDATA%\Programs\LocalAI Creative Studio\.venv\Scripts\python.exe"
if not exist "%PYTHON%" (
  echo No prepared Studio Python environment was found.
  echo Run SETUP-AND-START.bat once, then retry REBUILD-MANIFEST.bat.
  pause
  exit /b 1
)
"%PYTHON%" "%~dp0scripts\build_manifest.py"
if errorlevel 1 (
  echo Could not rebuild the package manifest.
  pause
  exit /b 1
)
echo Manifest rebuilt. Review every changed file before redistributing the package.
pause
endlocal
