@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0" >nul 2>&1
if errorlevel 1 goto :NO_ROOT
set "PSHOST=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSHOST%" set "PSHOST=powershell.exe"
set "TASK=%~1"
if not defined TASK set "TASK=start"
if /I "%TASK%"=="start" goto :START_TASK
if /I "%TASK%"=="repair" goto :REPAIR_TASK
if /I "%TASK%"=="install" goto :REPAIR_TASK
if /I "%TASK%"=="stop" goto :STOP_TASK
if /I "%TASK%"=="check" goto :CHECK_TASK
if /I "%TASK%"=="test" goto :TEST_TASK
if /I "%TASK%"=="filters" goto :FILTERS_TASK
if /I "%TASK%"=="restore-style" goto :RESTORE_TASK
if /I "%TASK%"=="verify" goto :VERIFY_TASK
if /I "%TASK%"=="help" goto :HELP
goto :UNKNOWN
:START_TASK
if /I not "%CD%"=="D:\LocalAI\Platform" goto :SETUP_TASK
if not exist "%~dp0LAUNCH-LOCALAI-APP.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0LAUNCH-LOCALAI-APP.ps1"
exit /b %ERRORLEVEL%
:SETUP_TASK
if not exist "%~dp0SETUP-LOCALAI.bat" goto :MISSING_LAUNCHER
call "%~dp0SETUP-LOCALAI.bat"
exit /b %ERRORLEVEL%
:REPAIR_TASK
for %%F in (VERIFY-PACKAGE.ps1 REPAIR-AND-RESUME.ps1) do if not exist "%~dp0%%F" (echo MISSING FILE: "%~dp0%%F"& pause& exit /b 2)
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY-PACKAGE.ps1"
if errorlevel 1 goto :FAILED
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0REPAIR-AND-RESUME.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:STOP_TASK
if not exist "%~dp0STOP-CHAT.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0STOP-CHAT.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:CHECK_TASK
if not exist "%~dp0CHECK-LOCALAI.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0CHECK-LOCALAI.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:TEST_TASK
if not exist "%~dp0VERIFY-MODEL.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY-MODEL.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:FILTERS_TASK
if not exist "%~dp0IMPORT-FILTERS.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0IMPORT-FILTERS.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:RESTORE_TASK
if not exist "%~dp0RESTORE-OPENWEBUI-STYLE.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RESTORE-OPENWEBUI-STYLE.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:VERIFY_TASK
if not exist "%~dp0VERIFY-PACKAGE.ps1" goto :MISSING_LAUNCHER
"%PSHOST%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0VERIFY-PACKAGE.ps1"
set "RC=%ERRORLEVEL%"
goto :MAINTENANCE_DONE
:MAINTENANCE_DONE
echo.
if "%RC%"=="0" (echo Operation finished successfully.) else (echo Operation failed with exit code %RC%.)
pause
exit /b %RC%
:FAILED
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" set "RC=1"
echo.
echo LocalAI operation failed with exit code %RC%.
echo Check the latest logs in D:\LocalAI\Logs and D:\LocalAI\Platform\Logs.
pause
exit /b %RC%
:MISSING_LAUNCHER
echo Required LocalAI Studio files are missing.
echo Extract the complete release ZIP and run SETUP-LOCALAI.bat.
pause
exit /b 2
:UNKNOWN
echo Unknown command: %TASK%
:HELP
echo.
echo LocalAI Studio v3.4 - Chat Platform
echo Run SETUP-LOCALAI.bat after extracting a release or update ZIP.
echo Daily startup is through the LocalAI Studio desktop icon.
echo.
echo Optional maintenance commands:
echo   LocalAI-Studio.bat repair        Repair the installed platform
echo   LocalAI-Studio.bat stop          Stop Open WebUI only; Ollama/Qwen stay running
echo   LocalAI-Studio.bat check         Run diagnostics
echo   LocalAI-Studio.bat test          Test a real Qwen response
echo   LocalAI-Studio.bat filters       Import the optional Open WebUI filters
echo   LocalAI-Studio.bat restore-style Restore the original Open WebUI CSS
echo   LocalAI-Studio.bat verify        Verify package files
echo.
pause
exit /b 0
:NO_ROOT
echo Could not access the LocalAI project folder: "%~dp0"
pause
exit /b 2
