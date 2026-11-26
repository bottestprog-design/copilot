$ErrorActionPreference='Stop'
# LocalAI Studio chat-only launcher. Ollama is external and is never started/stopped here.
$Root='D:\LocalAI';$Platform=Join-Path $Root 'Platform';$Data=Join-Path $Platform 'Data';$Logs=Join-Path $Platform 'Logs'
$Python=Join-Path $Platform '.venv\Scripts\python.exe';$OpenWebUI=Join-Path $Platform '.venv\Scripts\open-webui.exe'
$PowerShellExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$SecretPath=Join-Path $Platform 'Secrets\webui_secret_key.txt';$FfmpegPathFile=Join-Path $Platform 'ffmpeg-path.txt';$TempRoot=Join-Path $Data 'Temp';$PidFile=Join-Path $Platform 'open-webui.pid'
$BaseUrl='http://127.0.0.1:11434';$WebUrl='http://127.0.0.1:8080';$Mutex=$null;$OwnsMutex=$false;$StartedProcess=$null

function Show-RecentLogs([string]$Out,[string]$Err){
    Write-Host ([Environment]::NewLine+'--- Recent Open WebUI output ---') -ForegroundColor Yellow
    if(Test-Path -LiteralPath $Err -PathType Leaf){Get-Content -LiteralPath $Err -Tail 45 -ErrorAction SilentlyContinue}
    if(Test-Path -LiteralPath $Out -PathType Leaf){Get-Content -LiteralPath $Out -Tail 25 -ErrorAction SilentlyContinue}
    Write-Host "Logs: $Out | $Err" -ForegroundColor DarkGray
}
function Set-TempEnvironment {
    New-Item -ItemType Directory -Force -Path $TempRoot|Out-Null
    $env:TEMP=$TempRoot;$env:TMP=$TempRoot;$env:TMPDIR=$TempRoot
}
function Invoke-PythonText([string]$Code){
    $scriptPath=Join-Path $TempRoot ('localai-python-'+[guid]::NewGuid().ToString('N')+'.py')
    [IO.File]::WriteAllText($scriptPath,$Code,[System.Text.UTF8Encoding]::new($false))
    $oldPreference=$ErrorActionPreference
    try{
        # PowerShell 5.1 can promote native stderr to NativeCommandError under Stop.
        # Keep stderr visible in the captured result without aborting a valid Python probe.
        $ErrorActionPreference='Continue'
        $lines=@(& $Python $scriptPath 2>&1)
        $exitCode=[int]$LASTEXITCODE
        return [pscustomobject]@{ExitCode=$exitCode;Output=@($lines)}
    }finally{
        $ErrorActionPreference=$oldPreference
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}
function Get-LocalAIListener {
    try{return Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction Stop|Select-Object -First 1}catch{}
    try{
        $lines=@(& (Join-Path $env:SystemRoot 'System32\netstat.exe') -ano -p tcp 2>$null)
        foreach($line in $lines){if($line -match '^\s*TCP\s+(?:127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\[::\]):8080\s+\S+\s+LISTENING\s+(\d+)\s*$'){return [pscustomobject]@{LocalPort=8080;OwningProcess=[int]$matches[1]}}}
    }catch{}
    return $null
}
function Test-LocalAIReadyEndpoint {
    try{Invoke-RestMethod ($WebUrl+'/ready') -TimeoutSec 3 -ErrorAction Stop|Out-Null;return $true}catch{return $false}
}
function Assert-ExpectedOpenWebUIProcess([int]$ProcessId){
    $tracked=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if(-not $tracked -or [string]::IsNullOrWhiteSpace([string]$tracked.ExecutablePath)){throw "Could not verify Windows process information for port 8080 PID $ProcessId."}
    $actual=[IO.Path]::GetFullPath([string]$tracked.ExecutablePath);$expected=[IO.Path]::GetFullPath($OpenWebUI)
    if(-not $actual.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw "Port 8080 belongs to a different executable. PID $ProcessId path: $actual. No process was stopped."}
    $commandLine=[string]$tracked.CommandLine
    if($commandLine -notmatch '(?i)\bserve\b' -or $commandLine -notmatch '(?i)--port\s+8080' -or $commandLine -notmatch '(?i)--host\s+127\.0\.0\.1'){
        throw "PID $ProcessId uses the expected executable but its command line is not the LocalAI Studio loopback server. No process was adopted or stopped."
    }
    return $tracked
}
function Repair-OpenWebUIWindowsTempPath {
    $probeCode='import importlib.util,json; from importlib.metadata import version; from pathlib import Path; s=importlib.util.find_spec("open_webui"); print(json.dumps({"version":version("open-webui"),"package":str(Path(s.origin).parent) if s and s.origin else ""}))'
    $probeResult=Invoke-PythonText $probeCode;$probe=$probeResult.Output
    if($probeResult.ExitCode -ne 0 -or $probe.Count -eq 0){throw "Could not locate installed Open WebUI package: $($probe -join ' ')"}
    try{$info=([string]($probe|Select-Object -Last 1))|ConvertFrom-Json}catch{throw "Could not parse Open WebUI package information: $($probe -join ' ')"}
    if(-not $info.package){throw 'Open WebUI package folder was not found.'}
    if($info.version -ne '0.13.5'){throw "Windows temp-path compatibility patch supports Open WebUI 0.13.5 only, not $($info.version). No vendor source was changed."}
    $managed=Join-Path ([string]$info.package) 'utils\machines\managed.py'
    if(-not(Test-Path -LiteralPath $managed -PathType Leaf)){throw "Open WebUI compatibility source missing: $managed"}
    $source=[IO.File]::ReadAllText($managed)
    $old="RUN_DIR = Path(tempfile.mkdtemp(prefix='open-webui-', dir='/tmp'))"
    $fixed="RUN_DIR = Path(tempfile.mkdtemp(prefix='open-webui-', dir=str(_RUN_TMP_ROOT)))"
    $backup=Join-Path $Platform 'Backups\OpenWebUI\managed.py.original'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup)|Out-Null
    if($source.Contains($old)){
        if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){Copy-Item -LiteralPath $managed -Destination $backup -Force}
        $replacement="_RUN_TMP_ROOT = Path(tempfile.gettempdir())"+[Environment]::NewLine+"_RUN_TMP_ROOT.mkdir(parents=True, exist_ok=True)"+[Environment]::NewLine+$fixed
        [IO.File]::WriteAllText($managed,$source.Replace($old,$replacement),[System.Text.UTF8Encoding]::new($false))
        Write-Host '[OK] Applied Open WebUI Windows temp-path fix.' -ForegroundColor Green
    }elseif($source.Contains($fixed)-and $source.Contains('tempfile.gettempdir()')){Write-Host '[OK] Windows temp-path fix already applied.' -ForegroundColor Green}
    else{throw "Expected /tmp compatibility line not found. No vendor file changed: $managed"}
    $result=Invoke-PythonText 'import os,tempfile; p=tempfile.gettempdir(); d=tempfile.mkdtemp(prefix="localai-check-",dir=p); os.rmdir(d); print("TEMP_OK="+p)'
    if($result.ExitCode -ne 0 -or -not(($result.Output -join [Environment]::NewLine)-match 'TEMP_OK=')){throw "Windows temp folder is not writable: $TempRoot. $($result.Output -join ' ')"}
    Write-Host "[OK] Python temp folder: $TempRoot" -ForegroundColor Green
}
function Apply-LocalAITheme {
    $source=Join-Path $PSScriptRoot 'LOCALAI-STUDIO-THEME.css';$target=Join-Path $Platform 'LOCALAI-STUDIO-THEME.css'
    if((Test-Path -LiteralPath $source -PathType Leaf) -and [IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}
    if(-not(Test-Path -LiteralPath $target -PathType Leaf)){return}
    try{
        $probe=Invoke-PythonText 'import importlib.util,pathlib; s=importlib.util.find_spec("open_webui"); print(str(pathlib.Path(s.origin).parent/"static"/"custom.css") if s and s.origin else "")'
        if($probe.ExitCode -ne 0 -or $probe.Output.Count -eq 0){throw 'Could not locate Open WebUI static assets.'}
        $css=([string]($probe.Output|Select-Object -Last 1)).Trim();if(-not $css){throw 'Open WebUI custom.css path is empty.'}
        $static=Split-Path -Parent $css;if(-not(Test-Path -LiteralPath $static -PathType Container)){throw "Static assets folder missing: $static"}
        $backup=Join-Path $Platform 'Backups\OpenWebUI\custom.css.original';New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup)|Out-Null
        if(-not(Test-Path -LiteralPath $backup -PathType Leaf)){if(Test-Path -LiteralPath $css -PathType Leaf){Copy-Item -LiteralPath $css -Destination $backup -Force}else{[IO.File]::WriteAllText($backup,'')}}
        Copy-Item -LiteralPath $target -Destination $css -Force
        Write-Host '[OK] LocalAI Studio styling applied.' -ForegroundColor Green
    }catch{Write-Host "Theme skipped; chat can still run: $($_.Exception.Message)" -ForegroundColor Yellow}
}

try{
    New-Item -ItemType Directory -Force -Path $Data,$Logs,$Platform|Out-Null;Set-TempEnvironment
    $Mutex=[System.Threading.Mutex]::new($false,'Local\LocalAIStudio-Start')
    try{$OwnsMutex=$Mutex.WaitOne(0)}catch [System.Threading.AbandonedMutexException]{$OwnsMutex=$true}
    if(-not $OwnsMutex){throw 'Another LocalAI Studio start request is already running. Wait for that request to finish.'}
    if(-not(Test-Path -LiteralPath $Python -PathType Leaf)){throw "Project Python missing: $Python. Run LocalAI-Studio.bat repair."}
    if(-not(Test-Path -LiteralPath $OpenWebUI -PathType Leaf)){throw "Open WebUI missing: $OpenWebUI. Run LocalAI-Studio.bat repair."}
    if(-not(Test-Path -LiteralPath $SecretPath -PathType Leaf)){throw "Persistent WebUI secret missing: $SecretPath. Do not delete Data; run LocalAI-Studio.bat repair."}
    try{$null=Invoke-RestMethod ($BaseUrl+'/api/version') -TimeoutSec 8 -ErrorAction Stop}catch{throw 'Ollama API is not responding. Open Ollama and wait for it to become ready; this launcher will not start or restart it.'}
    # Query Ollama first. Do not run the model manager on every daily chat startup.
    $tags=Invoke-RestMethod ($BaseUrl+'/api/tags') -TimeoutSec 15 -ErrorAction Stop
    $model=$tags.models|Where-Object{$_.name -eq 'local-qwen35:latest' -or $_.name -like 'local-qwen35*'}|Select-Object -First 1
    if(-not $model){$model=$tags.models|Where-Object{$_.name -like 'qwen3.5:9b-q4_K_M*'}|Select-Object -First 1}
    if(-not $model){
        $modelManager=Join-Path $PSScriptRoot 'ENSURE-MODELS.ps1'
        if(-not(Test-Path -LiteralPath $modelManager -PathType Leaf)){throw "Model manager missing: $modelManager. Run LocalAI-Studio.bat repair."}
        $oldPreference=$ErrorActionPreference
        try{$ErrorActionPreference='Continue';$managerOutput=@(& $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $modelManager 2>&1);$managerExit=[int]$LASTEXITCODE}
        finally{$ErrorActionPreference=$oldPreference}
        if($managerExit -ne 0){throw "Qwen model verification did not complete (exit $managerExit). Automatic download is disabled by default. Review MODEL-STATUS.txt. $($managerOutput -join ' ')"}
        $tags=Invoke-RestMethod ($BaseUrl+'/api/tags') -TimeoutSec 15 -ErrorAction Stop
        $model=$tags.models|Where-Object{$_.name -eq 'local-qwen35:latest' -or $_.name -like 'local-qwen35*'}|Select-Object -First 1
        if(-not $model){$model=$tags.models|Where-Object{$_.name -like 'qwen3.5:9b-q4_K_M*'}|Select-Object -First 1}
    }
    if(-not $model){throw 'Qwen 3.5 9B is not registered in the running Ollama API. Run repair to inspect the local model store; no model was downloaded.'}
    $ModelId=[string]$model.name
    $env:DATA_DIR=$Data;$env:WEBUI_SECRET_KEY=(Get-Content -LiteralPath $SecretPath -Raw).Trim();$env:OLLAMA_BASE_URL=$BaseUrl;$env:ENABLE_OLLAMA_API='true';$env:DEFAULT_MODELS=$ModelId
    Remove-Item Env:DEFAULT_MODEL_METADATA -ErrorAction SilentlyContinue
    $env:DEFAULT_LOCALE='ar';$env:WEBUI_NAME='LocalAI Studio'
    $env:DEFAULT_INTERFACE_SETTINGS='{"widescreenMode":true,"chatBubble":false,"copyFormatted":true,"showChatTitleInTab":true,"title":{"auto":false},"autoFollowUps":false,"autoTags":false,"promptAutocomplete":false}'
    $env:ENABLE_AUTOCOMPLETE_GENERATION='false';$env:ENABLE_FOLLOW_UP_GENERATION='false';$env:ENABLE_TAGS_GENERATION='false';$env:WEBUI_URL=$WebUrl
    $env:ENABLE_WEB_SEARCH='true';$env:ENABLE_WEB_SEARCH_CONFIRMATION='true';$env:WEB_SEARCH_ENGINE='duckduckgo';$env:DDGS_BACKEND='auto'
    $env:ENABLE_FUNCTIONS='true';$env:ENABLE_PLUGINS='true';$env:ENABLE_API_KEYS='true';$env:ENABLE_PIP_INSTALL_FRONTMATTER_REQUIREMENTS='false';$env:UVICORN_WORKERS='1'
    if(Test-Path -LiteralPath $FfmpegPathFile){$ffmpeg=(Get-Content -LiteralPath $FfmpegPathFile -Raw).Trim();if(Test-Path -LiteralPath $ffmpeg -PathType Leaf){$ffdir=Split-Path -Parent $ffmpeg;if(($env:Path -split ';') -notcontains $ffdir){$env:Path=$ffdir+';'+$env:Path}}else{Write-Host 'FFmpeg path record is stale; text chat still works.' -ForegroundColor Yellow}}
    $env:OMP_NUM_THREADS='3';$env:MKL_NUM_THREADS='3';$env:TOKENIZERS_PARALLELISM='false'
    # Whisper is optional. Only expose its cache when the manager has verified a complete local snapshot.
    $modelStatusPath=Join-Path $Platform 'MODEL-STATUS.json'
    if(Test-Path -LiteralPath $modelStatusPath -PathType Leaf){
        try{$modelStatus=Get-Content -LiteralPath $modelStatusPath -Raw -Encoding UTF8|ConvertFrom-Json;$candidateCache=[string]$modelStatus.whisper.cache_dir;$snapshot=[string]$modelStatus.whisper.path
            if($modelStatus.whisper.status -eq 'ready' -and (Test-Path -LiteralPath $snapshot -PathType Container) -and (Test-Path -LiteralPath (Join-Path $snapshot 'model.bin') -PathType Leaf) -and (Test-Path -LiteralPath $candidateCache -PathType Container)){
                $env:WHISPER_MODEL=[string]$modelStatus.whisper.model;$env:WHISPER_MODEL_DIR=$candidateCache;$env:HF_HOME=Join-Path $Data 'cache\huggingface';$env:HUGGINGFACE_HUB_CACHE=Join-Path $env:HF_HOME 'hub'
                $env:WHISPER_COMPUTE_TYPE='int8';$env:WHISPER_MULTILINGUAL='true';$env:WHISPER_VAD_FILTER='true';$env:WHISPER_LANGUAGE='';$env:AUDIO_STT_ENGINE='';$env:AUDIO_TTS_ENGINE=''
                New-Item -ItemType Directory -Force -Path $env:WHISPER_MODEL_DIR,$env:HF_HOME,$env:HUGGINGFACE_HUB_CACHE|Out-Null
            }
        }catch{Write-Host 'Optional Whisper cache status could not be loaded; voice model path remains unset.' -ForegroundColor Yellow}
    }
    Repair-OpenWebUIWindowsTempPath
    $listener=Get-LocalAIListener
    if($listener){
        if(-not(Test-LocalAIReadyEndpoint)){throw "Port 8080 already has a listener PID $($listener.OwningProcess), but Open WebUI is not ready. No second server was started."}
        $verified=Assert-ExpectedOpenWebUIProcess -ProcessId ([int]$listener.OwningProcess)
        if(Test-Path -LiteralPath $PidFile -PathType Leaf){$savedPid=0;$saved=(Get-Content -LiteralPath $PidFile -Raw).Trim();if(-not [int]::TryParse($saved,[ref]$savedPid) -or $savedPid -ne [int]$listener.OwningProcess){throw 'Tracked PID file does not match the process listening on port 8080.'}}
        else{Set-Content -LiteralPath $PidFile -Value ([int]$listener.OwningProcess) -Encoding ASCII}
        Apply-LocalAITheme;Write-Host 'Verified existing LocalAI Studio service. The desktop launcher opens the app window.' -ForegroundColor DarkGray
        Write-Host "LocalAI Studio already running (verified PID $($verified.ProcessId))." -ForegroundColor Green;exit 0
    }
    if(Test-Path -LiteralPath $PidFile -PathType Leaf){
        $stalePid=0;$saved=(Get-Content -LiteralPath $PidFile -Raw).Trim()
        if(-not [int]::TryParse($saved,[ref]$stalePid) -or $stalePid -le 0){throw 'Tracked PID file is invalid; refusing to start another server.'}
        $stale=Get-CimInstance Win32_Process -Filter "ProcessId=$stalePid" -ErrorAction SilentlyContinue
        if($stale){$actual=[string]$stale.ExecutablePath;if(-not $actual -or -not [IO.Path]::GetFullPath($actual).Equals([IO.Path]::GetFullPath($OpenWebUI),[StringComparison]::OrdinalIgnoreCase)){throw "PID file refers to a different process (PID $stalePid). It was not touched."};throw "Tracked Open WebUI process $stalePid is still running but port 8080 is not listening. Inspect its logs; no duplicate was started."}
        Remove-Item -LiteralPath $PidFile -Force
    }
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$stdout=Join-Path $Logs ('webui-'+$stamp+'.stdout.log');$stderr=Join-Path $Logs ('webui-'+$stamp+'.stderr.log')
    $StartedProcess=Start-Process -FilePath $OpenWebUI -ArgumentList 'serve --host 127.0.0.1 --port 8080' -WorkingDirectory $Data -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Set-Content -LiteralPath $PidFile -Value $StartedProcess.Id -Encoding ASCII
    Write-Host "Starting LocalAI Studio chat with $ModelId ..." -ForegroundColor Cyan
    $ready=$false
    for($i=0;$i -lt 180;$i++){
        Start-Sleep -Seconds 2;$StartedProcess.Refresh()
        if($StartedProcess.HasExited){$StartedProcess.WaitForExit();$code='unavailable';try{$code=[string]$StartedProcess.ExitCode}catch{};Show-RecentLogs -Out $stdout -Err $stderr;Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue;throw "Open WebUI stopped during startup (exit code: $code)."}
        if(Test-LocalAIReadyEndpoint){$ready=$true;break}
        if(($i%20)-eq 0){Write-Host 'First startup may run database migrations; still starting...' -ForegroundColor Yellow}
    }
    if(-not $ready){Show-RecentLogs -Out $stdout -Err $stderr;throw "Open WebUI did not become ready within 6 minutes. Process remains available for inspection. Logs: $stdout and $stderr"}
    $listener=Get-LocalAIListener
    if(-not $listener -or [int]$listener.OwningProcess -ne [int]$StartedProcess.Id){throw 'Open WebUI readiness was detected, but the listener PID could not be matched to the process started by this launcher.'}
    [void](Assert-ExpectedOpenWebUIProcess -ProcessId ([int]$listener.OwningProcess))
    Apply-LocalAITheme;Write-Host 'The desktop launcher will open the LocalAI Studio app window.' -ForegroundColor DarkGray
    Write-Host 'SUCCESS: LocalAI Studio chat is ready and running in the background.' -ForegroundColor Green
    Write-Host 'Open WebUI: http://127.0.0.1:8080' -ForegroundColor Cyan
    Write-Host 'To stop it, run LocalAI-Studio.bat stop. Ollama and Qwen remain running.' -ForegroundColor DarkGray
    exit 0
}catch{
    Write-Host ([Environment]::NewLine+"LOCALAI START FAILED: $($_.Exception.Message)") -ForegroundColor Red
    exit 1
}finally{
    if($OwnsMutex -and $Mutex){try{$Mutex.ReleaseMutex()}catch{}}
    if($Mutex){$Mutex.Dispose()}
}
