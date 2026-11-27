@echo off
setlocal
set "PROJECT_ROOT=%~dp0"
if exist "%PROJECT_ROOT%.venv\Scripts\python.exe" goto run_tests

rem Resolve the installed copy through the shared owner/manifest verifier.
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
set "RESOLVER=%~dp0scripts\GET-VERIFIED-INSTALL-ROOT.ps1"
if not exist "%RESOLVER%" goto no_python
for /f "usebackq delims=" %%R in (`"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RESOLVER%"`) do set "PROJECT_ROOT=%%R\"
if exist "%PROJECT_ROOT%.venv\Scripts\python.exe" goto run_tests

:no_python
echo No verified Studio Python environment was found.
echo Run SETUP-AND-START.bat once, then retry RUN-TESTS.bat.
pause
exit /b 1

:run_tests
cd /d "%PROJECT_ROOT%"
title LocalAI Creative Studio - Tests
"%PROJECT_ROOT%.venv\Scripts\python.exe" -m unittest discover -s tests -v
set "RESULT=%ERRORLEVEL%"
echo.
if "%RESULT%"=="0" echo ALL TESTS PASSED.
if not "%RESULT%"=="0" echo TESTS FAILED.
pause
exit /b %RESULT%
