$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'INSTALL-ROOT.ps1')
$Root = Get-VerifiedLocalAIInstallRoot -FallbackRoot (Split-Path -Parent $PSScriptRoot)
$PythonExpected = [System.IO.Path]::GetFullPath((Join-Path $Root '.venv\Scripts\python.exe'))
$matches = @(Get-CimInstance Win32_Process -Filter "name='python.exe' OR name='pythonw.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and [System.IO.Path]::GetFullPath($_.ExecutablePath) -ieq $PythonExpected -and
    $_.CommandLine -match 'uvicorn\s+studio\.server:app' -and $_.CommandLine -match '--port\s+7865'
})
if ($matches.Count -eq 0) {
    Write-Host 'The LocalAI Creative Studio service is already stopped.' -ForegroundColor Yellow
    exit 0
}
foreach ($process in $matches) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    Write-Host "Stopped only this Studio service (PID $($process.ProcessId))." -ForegroundColor Green
}
