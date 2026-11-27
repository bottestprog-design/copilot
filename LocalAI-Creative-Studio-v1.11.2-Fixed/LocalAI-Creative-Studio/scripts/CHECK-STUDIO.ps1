$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'INSTALL-ROOT.ps1')
$Root = Get-VerifiedLocalAIInstallRoot -FallbackRoot (Split-Path -Parent $PSScriptRoot)
. (Join-Path $PSScriptRoot 'DATA-PATH.ps1')
$DataRoot = Get-LocalAIDataRoot -RecoverLegacyStatus
$ReportDir = Join-Path $DataRoot 'logs'
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
$Report = Join-Path $ReportDir ('creative-studio-check-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$lines = [System.Collections.Generic.List[string]]::new()
function Add-Result([string]$Name, [bool]$Ok, [string]$Details) {
    $label = if ($Ok) { 'OK' } else { 'CHECK' }
    $line = "[$label] $Name — $Details"
    $lines.Add($line)
    $color = if ($Ok) { 'Green' } else { 'Yellow' }
    Write-Host $line -ForegroundColor $color
}
Write-Host 'LOCALAI CREATIVE STUDIO - READ-ONLY DIAGNOSTICS' -ForegroundColor Cyan
Write-Host 'No installations, model downloads, service restarts or file deletions are performed.'
$python = Join-Path $Root '.venv\Scripts\python.exe'
Add-Result 'Studio virtual environment' (Test-Path $python) $(if (Test-Path $python) { $python } else { 'Run SETUP-AND-START.bat first' })
foreach ($item in @(@('Studio website',7865),@('ComfyUI image/video engine',8188),@('Ollama language model engine',11434))) {
    $port = [int]$item[1]
    $ok = $false
    try { $ok = Test-NetConnection -ComputerName '127.0.0.1' -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue } catch {}
    Add-Result $item[0] $ok "127.0.0.1:$port"
}
try {
    $health = Invoke-RestMethod -Uri 'http://127.0.0.1:7865/api/ready' -TimeoutSec 3
    Add-Result 'Studio API' $true "version $($health.version)"
    $comfyDetail = if ($health.comfyui.error) { $health.comfyui.error } else { 'responding' }
    $ollamaDetail = if ($health.ollama.error) { $health.ollama.error } else { 'responding' }
    Add-Result 'ComfyUI API' ([bool]$health.comfyui.ok) $comfyDetail
    Add-Result 'Ollama API' ([bool]$health.ollama.ok) $ollamaDetail
} catch {
    Add-Result 'Studio API' $false 'Website is not running; start it with SETUP-AND-START.bat'
}
try {
    $ollama = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3
    $found = @($ollama.models | Where-Object { $_.name -like 'local-qwen35*' }).Count -gt 0
    Add-Result 'Existing local-qwen35 model' $found $(if ($found) { 'model tag detected; files untouched' } else { 'alias not listed; configure the correct model name in Studio settings' })
} catch { Add-Result 'Existing local-qwen35 model' $false 'Ollama API is unavailable; no recovery or pull was attempted' }
$lines | Set-Content -LiteralPath $Report -Encoding UTF8
Write-Host "`nReport saved to: $Report" -ForegroundColor Cyan
