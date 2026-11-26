@echo off
setlocal
set "PROJECT_ROOT=%~dp0"
if not exist "%PROJECT_ROOT%.venv\Scripts\python.exe" (
  if exist "%LOCALAPPDATA%\Programs\LocalAI Creative Studio\.venv\Scripts\python.exe" set "PROJECT_ROOT=%LOCALAPPDATA%\Programs\LocalAI Creative Studio\"
)
if not exist "%PROJECT_ROOT%.venv\Scripts\python.exe" (
  echo No prepared Studio Python environment was found.
  echo Run SETUP-AND-START.bat once, then retry RUN-TESTS.bat.
  pause
  exit /b 1
)
cd /d "%PROJECT_ROOT%"
title LocalAI Creative Studio - Tests
"%PROJECT_ROOT%.venv\Scripts\python.exe" -m unittest discover -s tests -v
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" echo ALL TESTS PASSED.
if not "%RESULT%"=="0" echo TESTS FAILED.
pause
exit /b %RESULT%
