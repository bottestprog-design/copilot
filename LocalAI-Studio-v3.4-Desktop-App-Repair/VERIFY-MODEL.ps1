$ErrorActionPreference = 'Stop'
$uri = 'http://127.0.0.1:11434/api/chat'
$tags = Invoke-RestMethod 'http://127.0.0.1:11434/api/tags' -TimeoutSec 10 -ErrorAction Stop
$model = $tags.models | Where-Object { $_.name -eq 'local-qwen35:latest' -or $_.name -like 'local-qwen35*' } | Select-Object -First 1
if (-not $model) { $model = $tags.models | Where-Object { $_.name -like 'qwen3.5:9b-q4_K_M*' } | Select-Object -First 1 }
if (-not $model) { throw 'Qwen model tag not found. This test will not download anything.' }
$body = @{
    model = [string]$model.name
    messages = @(@{ role = 'user'; content = 'Reply in one short sentence: say READY, then calculate 2+2.' })
    think = $false
    stream = $false
    options = @{ num_ctx = 4096; num_predict = 128; temperature = 0.1 }
}
$json = ConvertTo-Json -InputObject $body -Depth 10 -Compress
Write-Host "Testing actual inference with $($model.name). This may take several minutes on CPU; no model download is performed." -ForegroundColor Cyan
$startedAt = Get-Date
try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 900 -ErrorAction Stop
} catch { throw "Ollama chat request failed: $($_.Exception.Message)" }
$content = [string]$response.message.content
$thinking = [string]$response.message.thinking
if ([string]::IsNullOrWhiteSpace($content)) {
    if (-not [string]::IsNullOrWhiteSpace($thinking)) { throw "Model returned thinking but no final content. done=$($response.done) reason=$($response.done_reason). The test uses think=false; inspect Ollama logs." }
    throw 'Model response content is empty. Inspect Ollama server logs; model installation alone does not verify inference.'
}
if ($response.done -ne $true) { throw "Response did not finish. done_reason=$($response.done_reason)" }
$duration = { param($name) if ($response.PSObject.Properties.Name -contains $name) { [double]$response.$name } else { 0.0 } }
$loadNs = & $duration 'load_duration'
$promptNs = & $duration 'prompt_eval_duration'
$evalNs = & $duration 'eval_duration'
$totalNs = & $duration 'total_duration'
$promptCount = if ($response.PSObject.Properties.Name -contains 'prompt_eval_count') { [long]$response.prompt_eval_count } else { 0 }
$evalCount = if ($response.PSObject.Properties.Name -contains 'eval_count') { [long]$response.eval_count } else { 0 }
$loadSec = if ($loadNs -gt 0) { [math]::Round($loadNs / 1000000000.0, 3) } else { 'n/a' }
$promptSec = if ($promptNs -gt 0) { [math]::Round($promptNs / 1000000000.0, 3) } else { 'n/a' }
$evalSec = if ($evalNs -gt 0) { [math]::Round($evalNs / 1000000000.0, 3) } else { 'n/a' }
$totalSec = if ($totalNs -gt 0) { [math]::Round($totalNs / 1000000000.0, 3) } else { [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3) }
$tps = if ($evalNs -gt 0 -and $evalCount -gt 0) { [math]::Round($evalCount / ($evalNs / 1000000000.0), 2) } else { 'n/a' }
Write-Host '[SUCCESS] Model inference completed.' -ForegroundColor Green
Write-Host "MODEL RESPONSE: $content"
Write-Host "Load: $loadSec s | Prompt: $promptCount tokens / $promptSec s | Generated: $evalCount tokens / $evalSec s | $tps tokens/s | Total: $totalSec s" -ForegroundColor Cyan
$logRoot = 'D:\LocalAI\Logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$report = Join-Path $logRoot ('model-inference-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
@("Model: $($model.name)", "Done: $($response.done)", "Done reason: $($response.done_reason)", "Load seconds: $loadSec", "Prompt tokens: $promptCount", "Prompt eval seconds: $promptSec", "Generated tokens: $evalCount", "Generation seconds: $evalSec", "Generation tokens per second: $tps", "Total seconds: $totalSec", 'Keep alive: Ollama server default/environment setting (not overridden)', "Response: $content") | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Report: $report"
