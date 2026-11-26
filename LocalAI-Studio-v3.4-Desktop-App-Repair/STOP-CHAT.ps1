$ErrorActionPreference = 'Stop'
$Platform = 'D:\LocalAI\Platform'
$PidFile = Join-Path $Platform 'open-webui.pid'
$ExpectedExe = Join-Path $Platform '.venv\Scripts\open-webui.exe'
if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { Write-Host 'No tracked Open WebUI PID file. Nothing was stopped.' -ForegroundColor Yellow; exit 0 }
$raw = (Get-Content -LiteralPath $PidFile -Raw).Trim()
$targetPid = 0
if (-not [int]::TryParse($raw,[ref]$targetPid) -or $targetPid -le 0) { throw 'PID file is invalid; refusing to stop any process.' }
$proc = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
if (-not $proc) { Remove-Item -LiteralPath $PidFile -Force; Write-Host 'Tracked Open WebUI process is already closed.' -ForegroundColor Yellow; exit 0 }
$actual = [string]$proc.ExecutablePath
if (-not $actual -or -not [IO.Path]::GetFullPath($actual).Equals([IO.Path]::GetFullPath($ExpectedExe),[StringComparison]::OrdinalIgnoreCase)) {
    throw "PID $targetPid is not the expected Open WebUI executable. Refusing to stop it. Actual path: $actual"
}
$commandLine=[string]$proc.CommandLine
if($commandLine -notmatch '(?i)\bserve\b' -or $commandLine -notmatch '(?i)--port\s+8080' -or $commandLine -notmatch '(?i)--host\s+127\.0\.0\.1') {
    throw "PID $targetPid does not have the LocalAI Studio loopback serve command. Refusing to stop it."
}
$managedProcess = Get-Process -Id $targetPid -ErrorAction Stop
$gracefulRequested = $false
try { $gracefulRequested = $managedProcess.CloseMainWindow() } catch {}
if ($gracefulRequested -and -not $managedProcess.WaitForExit(15000)) {
    Write-Host 'Open WebUI did not close its main window within 15 seconds; applying the tracked-process fallback.' -ForegroundColor Yellow
}
$managedProcess.Refresh()
if (-not $managedProcess.HasExited) {
    Stop-Process -Id $targetPid -Force
    try { [void]$managedProcess.WaitForExit(5000) } catch {}
}
$remaining = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
if ($remaining) { throw "Open WebUI PID $targetPid is still running. PID file was kept for a safe retry." }
Remove-Item -LiteralPath $PidFile -Force
if ($gracefulRequested) { Write-Host 'Requested window-close shutdown and verified the tracked process exited. Ollama and model files were not touched.' -ForegroundColor Green }
else { Write-Host 'No closeable main window was exposed; stopped only the verified tracked Open WebUI process. Ollama and model files were not touched.' -ForegroundColor Green }
