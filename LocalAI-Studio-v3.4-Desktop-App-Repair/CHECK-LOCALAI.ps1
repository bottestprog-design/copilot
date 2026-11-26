$ErrorActionPreference = 'Continue'
$Root = 'D:\LocalAI'
$Platform = Join-Path $Root 'Platform'
$Venv = Join-Path $Platform '.venv\Scripts\python.exe'
$TempRoot = Join-Path $Platform 'Data\Temp'
$WebUrl = 'http://127.0.0.1:8080'
$BaseUrl = 'http://127.0.0.1:11434'
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
$env:TEMP = $TempRoot
$env:TMP = $TempRoot
$env:TMPDIR = $TempRoot
$results = New-Object System.Collections.Generic.List[string]

function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    $state = if ($Ok) { 'PASS' } else { 'FAIL' }
    $line = "[$state] $Name : $Detail"
    $null = $results.Add($line)
    if ($Ok) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }
}
function Add-Info([string]$Name, [string]$Detail) {
    $line = "[INFO] $Name : $Detail"
    $null = $results.Add($line)
    Write-Host $line -ForegroundColor DarkGray
}
function Invoke-ProjectPython([string]$Code) {
    $scriptPath = Join-Path $TempRoot ('check-' + [guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::WriteAllText($scriptPath, $Code, ([System.Text.UTF8Encoding]::new($false)))
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Venv $scriptPath 2>&1)
        $exitCode = [int]$LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
    } finally {
        $ErrorActionPreference = $oldPreference
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'LOCALAI STUDIO - SYSTEM DIAGNOSTICS' -ForegroundColor Cyan
try {
    $version = Invoke-RestMethod ($BaseUrl + '/api/version') -TimeoutSec 5 -ErrorAction Stop
    Add-Check 'Ollama API' $true ([string]$version.version)
} catch { Add-Check 'Ollama API' $false $_.Exception.Message }
try {
    $tags = Invoke-RestMethod ($BaseUrl + '/api/tags') -TimeoutSec 10 -ErrorAction Stop
    $model = $tags.models | Where-Object { $_.name -like 'local-qwen35*' -or $_.name -like 'qwen3.5:9b-q4_K_M*' } | Select-Object -First 1
    Add-Check 'Qwen model tag' ([bool]$model) $(if ($model) { [string]$model.name } else { 'not found in Ollama API' })
} catch { Add-Check 'Qwen model tag' $false $_.Exception.Message }

Add-Check 'Project Python' (Test-Path -LiteralPath $Venv -PathType Leaf) $Venv
$openWebUI = Join-Path $Platform '.venv\Scripts\open-webui.exe'
Add-Check 'Open WebUI executable' (Test-Path -LiteralPath $openWebUI -PathType Leaf) $openWebUI
try {
    $null = Invoke-RestMethod ($WebUrl + '/ready') -TimeoutSec 4 -ErrorAction Stop
    Add-Check 'Open WebUI ready' $true $WebUrl
} catch { Add-Check 'Open WebUI ready' $false $_.Exception.Message }

if (Test-Path -LiteralPath $Venv -PathType Leaf) {
    $core = Invoke-ProjectPython 'import open_webui; print("OPEN_WEBUI_IMPORT_OK")'
    Add-Check 'Open WebUI Python import' ($core.ExitCode -eq 0 -and (($core.Output -join "`n") -match 'OPEN_WEBUI_IMPORT_OK')) ($core.Output -join ' ')
    $main = Invoke-ProjectPython 'import open_webui.main; print("OPENWEBUI_MAIN_IMPORT_OK")'
    Add-Check 'Open WebUI main import' ($main.ExitCode -eq 0 -and (($main.Output -join "`n") -match 'OPENWEBUI_MAIN_IMPORT_OK')) ($main.Output -join ' ')
    $tempFix = Invoke-ProjectPython 'import importlib.util,pathlib; s=importlib.util.find_spec("open_webui"); p=pathlib.Path(s.origin).parent/"utils"/"machines"/"managed.py"; t=p.read_text(encoding="utf-8"); print("WINDOWS_TEMP_FIX=PASS" if "tempfile.gettempdir()" in t and "dir=str(_RUN_TMP_ROOT)" in t else "WINDOWS_TEMP_FIX=FAIL")'
    Add-Check 'Windows temp compatibility patch' ($tempFix.ExitCode -eq 0 -and (($tempFix.Output -join "`n") -match 'WINDOWS_TEMP_FIX=PASS')) ($tempFix.Output -join ' ')
    $audio = Invoke-ProjectPython 'import av,faster_whisper; print("OPTIONAL_AUDIO_IMPORTS_OK")'
    if ($audio.ExitCode -eq 0 -and (($audio.Output -join "`n") -match 'OPTIONAL_AUDIO_IMPORTS_OK')) {
        Add-Info 'Optional audio dependencies' 'Available.'
    } else {
        Add-Info 'Optional audio dependencies' 'Not installed or not ready. Text chat is unaffected.'
    }
}
$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    $ffmpegPathFile = Join-Path $Platform 'ffmpeg-path.txt'
    if (Test-Path -LiteralPath $ffmpegPathFile -PathType Leaf) {
        $saved = (Get-Content -LiteralPath $ffmpegPathFile -Raw).Trim()
        if (Test-Path -LiteralPath $saved -PathType Leaf) { $ffmpeg = [pscustomobject]@{ Source = $saved } }
    }
}
if ($ffmpeg) { Add-Info 'Optional FFmpeg' ([string]$ffmpeg.Source) }
else { Add-Info 'Optional FFmpeg' 'Not found. Text chat is unaffected.' }

foreach ($fileName in @('01-Trusted-Content-Guard.py', '02-Accuracy-Thinking.py', '03-Selective-Self-Review.py')) {
    $path = Join-Path $Platform ('Filters\' + $fileName)
    Add-Check ('Filter ' + $fileName) (Test-Path -LiteralPath $path -PathType Leaf) $path
}
$launcher = Join-Path $Platform 'LAUNCH-LOCALAI-APP.ps1'
$icon = Join-Path $Platform 'Assets\LocalAI-Studio.ico'
Add-Check 'Desktop app launcher' (Test-Path -LiteralPath $launcher -PathType Leaf) $launcher
Add-Check 'Application icon' (Test-Path -LiteralPath $icon -PathType Leaf) $icon
try {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [string]$shell.SpecialFolders('Desktop')
    $shortcut = Join-Path $desktop 'LocalAI Studio.lnk'
    Add-Check 'Desktop shortcut' (Test-Path -LiteralPath $shortcut -PathType Leaf) $shortcut
} catch { Add-Info 'Desktop shortcut' ('Could not query Desktop folder: ' + $_.Exception.Message) }

$modelStatusPath = Join-Path $Platform 'MODEL-STATUS.json'
if (Test-Path -LiteralPath $modelStatusPath -PathType Leaf) {
    try {
        $modelStatus = Get-Content -LiteralPath $modelStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $modelReady = ([string]$modelStatus.ollama.status -like 'ready*' -and -not [string]::IsNullOrWhiteSpace([string]$modelStatus.ollama.tag) -and [string]::IsNullOrWhiteSpace([string]$modelStatus.error))
        Add-Check 'Qwen model manager status' $modelReady ([string]$modelStatus.ollama.tag)
        if (@($modelStatus.warnings).Count -gt 0) { Add-Info 'Model manager warnings' (@($modelStatus.warnings) -join ' | ') }
        if ([string]$modelStatus.whisper.status -eq 'not_requested') {
            Add-Info 'Whisper' 'Skipped intentionally; it is optional for text chat.'
        } elseif ([string]$modelStatus.whisper.status -ne 'ready') {
            Add-Info 'Whisper' 'Optional audio model is not ready; text chat remains available.'
        } else {
            Add-Info 'Whisper' 'Optional audio model is ready.'
        }
    } catch { Add-Check 'Model manager status' $false $_.Exception.Message }
} else {
    Add-Info 'Model manager status' 'Not created yet. The first setup/start will verify the existing Qwen model.'
}

$logs = Join-Path $Platform 'Logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$report = Join-Path $logs ('CHECK-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$results | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Report: $report" -ForegroundColor Cyan
if (@($results | Where-Object { $_ -match '^\[FAIL\]' }).Count -gt 0) { exit 1 }
exit 0
