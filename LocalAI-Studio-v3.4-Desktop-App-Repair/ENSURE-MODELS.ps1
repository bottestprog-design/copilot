[CmdletBinding()]
param([switch]$RequireWhisper)

$ErrorActionPreference = 'Stop'
$Root = 'D:\LocalAI'
$Platform = Join-Path $Root 'Platform'
$Data = Join-Path $Platform 'Data'
$Python = Join-Path $Platform '.venv\Scripts\python.exe'
$BaseUrl = 'http://127.0.0.1:11434'
$ConfigPath = Join-Path $PSScriptRoot 'MODELS.json'
$StatusPath = Join-Path $Platform 'MODEL-STATUS.json'
$script:Config = $null
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:ModelIntegrityFailures = New-Object System.Collections.Generic.List[string]
$script:OllamaExe = $null
$script:Status = [ordered]@{
    schema_version = 1
    checked_at = (Get-Date).ToString('o')
    ollama = [ordered]@{ status = 'pending'; tag = ''; source = ''; store = ''; size_bytes = 0 }
    whisper = [ordered]@{ status = 'pending'; model = ''; path = ''; cache_dir = ''; source = '' }
    warnings = @()
    error = ''
}

function Save-ModelStatus {
    $script:Status.checked_at = (Get-Date).ToString('o')
    $script:Status.warnings = @($script:Warnings)
    Set-Content -LiteralPath $StatusPath -Value ($script:Status | ConvertTo-Json -Depth 8) -Encoding UTF8
    @(
        'MODEL MANAGER STATUS'
        "Checked: $($script:Status.checked_at)"
        "Qwen: $($script:Status.ollama.status)"
        "Qwen tag: $($script:Status.ollama.tag)"
        "Ollama store: $($script:Status.ollama.store)"
        "Whisper $($script:Status.whisper.model): $($script:Status.whisper.status)"
        "Whisper path: $($script:Status.whisper.path)"
        "Whisper source: $($script:Status.whisper.source)"
        "Warnings: $(@($script:Warnings).Count)"
    ) | Set-Content -LiteralPath (Join-Path $Platform 'MODEL-STATUS.txt') -Encoding UTF8
    @(
        "STATUS: $($script:Status.ollama.status)"
        "API: $BaseUrl"
        "Model: $($script:Status.ollama.tag)"
        "Model source: $($script:Status.ollama.source)"
        "Model store: $($script:Status.ollama.store)"
        "Model size bytes: $($script:Status.ollama.size_bytes)"
        "Whisper: $($script:Status.whisper.status)"
        "Whisper path: $($script:Status.whisper.path)"
        "Completed: $($script:Status.checked_at)"
    ) | Set-Content -LiteralPath (Join-Path $Root 'ENGINE-STATUS.txt') -Encoding UTF8
    if ($script:Status.ollama.store) {
        Set-Content -LiteralPath (Join-Path $Root 'MODEL-STORE-PATH.txt') -Value $script:Status.ollama.store -Encoding UTF8
    }
}

function Get-OllamaExe {
    $command = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles 'Ollama\ollama.exe'),
        (Join-Path $env:LOCALAPPDATA 'Ollama\ollama.exe'),
        'C:\Program Files\Ollama\ollama.exe'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Get-OllamaTags {
    $response = Invoke-RestMethod -Uri ($BaseUrl + '/api/tags') -TimeoutSec 30 -ErrorAction Stop
    return @($response.models)
}

function Get-ActiveModelStore {
    $configured = @(
        $env:OLLAMA_MODELS,
        [Environment]::GetEnvironmentVariable('OLLAMA_MODELS','User'),
        [Environment]::GetEnvironmentVariable('OLLAMA_MODELS','Machine')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1
    if ($configured) { return [IO.Path]::GetFullPath([string]$configured) }
    # The user's existing Ollama store was established as D:\LocalAI\Models.
    # Prefer it when it contains manifests, rather than importing into a new empty default folder.
    $knownStore = Join-Path $Root 'Models'
    if (Test-Path -LiteralPath (Join-Path $knownStore 'manifests') -PathType Container) {
        return [IO.Path]::GetFullPath($knownStore)
    }
    return Join-Path $env:USERPROFILE '.ollama\models'
}

function Get-ModelStoreRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $candidates = @(
        (Get-ActiveModelStore),
        (Join-Path $env:USERPROFILE '.ollama\models'),
        (Join-Path $Root 'Models'),
        (Join-Path $Root 'Ollama\Models')
    ) + @($script:Config.ollama.search_store_roots)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            $full = [IO.Path]::GetFullPath([string]$candidate).TrimEnd('\')
            if (-not $roots.Contains($full)) { $roots.Add($full) }
        } catch {}
    }
    return @($roots)
}

function Get-ManifestModelTag([string]$RelativePath) {
    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -gt 0 -and $parts[0] -eq 'registry.ollama.ai' -and $parts.Count -gt 1) { $parts = @($parts | Select-Object -Skip 1) }
    if ($parts.Count -gt 0 -and $parts[0] -eq 'library' -and $parts.Count -gt 1) { $parts = @($parts | Select-Object -Skip 1) }
    if ($parts.Count -lt 2) { return '' }
    $tag = [string]$parts[$parts.Count - 1]
    $nameParts = @()
    for ($i=0; $i -lt ($parts.Count - 1); $i++) { $nameParts += [string]$parts[$i] }
    $name = $nameParts -join '/'
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($tag)) { return '' }
    return ($name + ':' + $tag)
}

function Test-OllamaManifest {
    param([string]$StoreRoot,[string]$ManifestFile,[string]$RelativePath)
    try {
        $manifest = Get-Content -LiteralPath $ManifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $manifest.config.digest -or -not $manifest.layers) {
            $script:ModelIntegrityFailures.Add("Local Qwen manifest has no config digest or layers: $ManifestFile")
            return $null
        }
        $items = New-Object System.Collections.Generic.List[object]
        $items.Add($manifest.config)
        foreach ($layer in @($manifest.layers)) { $items.Add($layer) }
        $blobs = New-Object System.Collections.Generic.List[object]
        foreach ($item in $items) {
            $digest = [string]$item.digest
            if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
                $script:ModelIntegrityFailures.Add("Local Qwen manifest contains an invalid digest: $ManifestFile")
                return $null
            }
            $hash = $digest.Substring(7).ToLowerInvariant()
            $blobPath = Join-Path (Join-Path $StoreRoot 'blobs') ('sha256-' + $hash)
            if (-not (Test-Path -LiteralPath $blobPath -PathType Leaf)) {
                $script:ModelIntegrityFailures.Add("Local Qwen manifest references a missing blob: $blobPath")
                return $null
            }
            $blobInfo = Get-Item -LiteralPath $blobPath
            if ($item.size -and $blobInfo.Length -ne [long]$item.size) {
                $script:ModelIntegrityFailures.Add("Local Qwen blob size mismatch: $blobPath (expected $($item.size), actual $($blobInfo.Length))")
                return $null
            }
            try { $actualDigest = (Get-FileHash -LiteralPath $blobPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
            catch {
                $script:ModelIntegrityFailures.Add("Could not read/hash local Qwen blob '$blobPath': $($_.Exception.Message)")
                return $null
            }
            if ($actualDigest -ne $hash) {
                $script:ModelIntegrityFailures.Add("Qwen blob SHA-256 mismatch in source store '$StoreRoot': $blobPath (expected $hash, actual $actualDigest)")
                return $null
            }
            $blobs.Add([pscustomobject]@{ Source=$blobPath; Name=('sha256-' + $hash); Size=[long]$blobInfo.Length })
        }
        return [pscustomobject]@{ Tag=(Get-ManifestModelTag -RelativePath $RelativePath); RelativePath=$RelativePath; ManifestFile=$ManifestFile; Blobs=@($blobs) }
    } catch {
        $script:ModelIntegrityFailures.Add("Could not validate local Qwen manifest '$ManifestFile': $($_.Exception.Message)")
        return $null
    }
}

function Find-OllamaManifestByTag {
    param([string]$Tag,[string[]]$StoreRoots)
    foreach($store in @($StoreRoots)){
        if([string]::IsNullOrWhiteSpace([string]$store)){continue}
        $manifestRoot=Join-Path $store 'manifests'
        if(-not(Test-Path -LiteralPath $manifestRoot -PathType Container)){continue}
        $manifestFiles=@(Get-ChildItem -LiteralPath $manifestRoot -File -Recurse -ErrorAction SilentlyContinue)
        foreach($manifestFile in $manifestFiles){
            $relative=$manifestFile.FullName.Substring($manifestRoot.Length)-replace '^[\\/]+',''
            if((Get-ManifestModelTag -RelativePath $relative) -eq $Tag){
                return [pscustomobject]@{StoreRoot=$store;ManifestFile=$manifestFile.FullName;RelativePath=$relative}
            }
        }
    }
    return $null
}

function Import-OllamaManifest {
    param([string]$ActiveRoot,$VerifiedManifest)
    $requiredBytes = [long]0
    foreach ($blob in @($VerifiedManifest.Blobs)) {
        $target = Join-Path (Join-Path $ActiveRoot 'blobs') $blob.Name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $requiredBytes += [long]$blob.Size }
        else {
            $existing = Get-Item -LiteralPath $target
            if ($existing.Length -ne [long]$blob.Size) { throw "Existing Ollama blob has an unexpected size; it will not be overwritten: $target" }
            $existingDigest = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            $expectedDigest = $blob.Name.Substring(7).ToLowerInvariant()
            if ($existingDigest -ne $expectedDigest) { throw "Existing Ollama blob failed SHA-256 verification and was left untouched: $target" }
        }
    }
    if ($requiredBytes -gt 0) {
        $device = [IO.Path]::GetPathRoot($ActiveRoot).TrimEnd('\')
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$device'" -ErrorAction SilentlyContinue
        if ($disk -and [long]$disk.FreeSpace -lt ($requiredBytes + 512MB)) { throw "Not enough free space to import the found model. Additional bytes required: $requiredBytes." }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $ActiveRoot 'blobs') | Out-Null
    foreach ($blob in @($VerifiedManifest.Blobs)) {
        $target = Join-Path (Join-Path $ActiveRoot 'blobs') $blob.Name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Write-Host "[MODEL] Copying verified existing model blob $($blob.Name) through a temporary file" -ForegroundColor DarkCyan
            $temporary = $target + '.localai-import-' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                Copy-Item -LiteralPath $blob.Source -Destination $temporary -ErrorAction Stop
                $digest = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
                $expectedDigest = $blob.Name.Substring(7).ToLowerInvariant()
                if ($digest -ne $expectedDigest) { throw "Temporary model blob failed SHA-256 verification; target was not changed: $temporary" }
                if (Test-Path -LiteralPath $target -PathType Leaf) { throw "Target Ollama blob appeared during import; it was not overwritten: $target" }
                Move-Item -LiteralPath $temporary -Destination $target -ErrorAction Stop
            } finally {
                if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    $targetManifest = Join-Path (Join-Path $ActiveRoot 'manifests') $VerifiedManifest.RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetManifest) | Out-Null
    if (Test-Path -LiteralPath $targetManifest -PathType Leaf) {
        $a = (Get-FileHash -LiteralPath $targetManifest -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $VerifiedManifest.ManifestFile -Algorithm SHA256).Hash
        if ($a -ne $b) {
            Copy-Item -LiteralPath $targetManifest -Destination ($targetManifest + '.localai-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $manifestTemp=$targetManifest+'.localai-import-'+[guid]::NewGuid().ToString('N')+'.tmp'
            try { Copy-Item -LiteralPath $VerifiedManifest.ManifestFile -Destination $manifestTemp -ErrorAction Stop; Move-Item -LiteralPath $manifestTemp -Destination $targetManifest -Force -ErrorAction Stop }
            finally { if(Test-Path -LiteralPath $manifestTemp){Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue} }
        }
    } else { Copy-Item -LiteralPath $VerifiedManifest.ManifestFile -Destination $targetManifest }
    Write-Host "[OK] Existing model manifest imported from $($VerifiedManifest.Tag). The source store was not changed." -ForegroundColor Green
}

function Wait-ForOllamaTag([string]$Tag) {
    for ($attempt=0; $attempt -lt 30; $attempt++) { $tags=Get-OllamaTags; $names=@($tags|ForEach-Object{[string]$_.name}); if($names -contains $Tag){return $tags}; Start-Sleep -Seconds 2 }
    return Get-OllamaTags
}

function Invoke-OllamaCopy([string]$SourceTag,[string]$DestinationTag) {
    try { $body=@{source=$SourceTag;destination=$DestinationTag}|ConvertTo-Json -Compress; Invoke-RestMethod -Uri ($BaseUrl+'/api/copy') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 1800|Out-Null; return $true }
    catch { Write-Host "[WARN] Could not create local alias ${DestinationTag}: $($_.Exception.Message)" -ForegroundColor Yellow; return $false }
}

function Find-QwenTag([string[]]$Names) {
    $preferred=[string]$script:Config.ollama.preferred_tag
    if($Names -contains $preferred){return $preferred}
    foreach($candidate in @($script:Config.ollama.known_tags)){if($Names -contains [string]$candidate){return [string]$candidate}}
    foreach($name in $Names){if($name -match '(?i)^qwen3\.5:9b' -or $name -match '(?i)^local-qwen35:'){return $name}}
    return ''
}

function Ensure-QwenModel {
    $tags=Get-OllamaTags
    $names=@($tags|ForEach-Object{[string]$_.name})
    $selected=Find-QwenTag -Names $names
    if($selected){
        $model=$tags|Where-Object{$_.name -eq $selected}|Select-Object -First 1
        $script:Status.ollama.status='ready_existing';$script:Status.ollama.tag=$selected
        $script:Status.ollama.size_bytes=[long]$model.size
        $manifestLocation=Find-OllamaManifestByTag -Tag $selected -StoreRoots (Get-ModelStoreRoots)
        if($manifestLocation){
            $verified=Test-OllamaManifest -StoreRoot $manifestLocation.StoreRoot -ManifestFile $manifestLocation.ManifestFile -RelativePath $manifestLocation.RelativePath
            if(-not $verified){
                $details=$script:ModelIntegrityFailures -join [Environment]::NewLine
                throw ("Existing Qwen tag '$selected' is registered but its local manifest/blob integrity check failed. No model files were changed and no download was attempted."+[Environment]::NewLine+$details)
            }
            $script:Status.ollama.store=$manifestLocation.StoreRoot
            $script:Status.ollama.source='Existing Ollama API tag; local manifest and every referenced blob passed SHA-256 verification'
            Write-Host "[OK] Existing Qwen model passed manifest and blob SHA-256 checks: $selected." -ForegroundColor Green
        }else{
            $warning="Qwen tag '$selected' is available in Ollama API, but no matching manifest was found in configured/known stores. The service tag is ready; on-disk blob hashes could not be independently checked."
            $null=$script:Warnings.Add($warning)
            $script:Status.ollama.source='Existing Ollama API tag; local manifest was not found in known stores, so blob hashes were not verified'
            Write-Host "[WARN] $warning" -ForegroundColor Yellow
        }
        Write-Host "[OK] Using the existing Qwen model: $selected ($([math]::Round($model.size/1GB,2)) GB)." -ForegroundColor Green
        return
    }
    $activeStore=Get-ActiveModelStore;$script:Status.ollama.store=$activeStore
    $modelPattern='(?i)(local-qwen35|qwen3\.5)';$importedTag=''
    foreach($store in (Get-ModelStoreRoots)){
        if(-not(Test-Path -LiteralPath $store -PathType Container)){continue}
        $manifestRoot=Join-Path $store 'manifests'
        if(-not(Test-Path -LiteralPath $manifestRoot -PathType Container)){continue}
        $manifestFiles=@(Get-ChildItem -LiteralPath $manifestRoot -File -Recurse -ErrorAction SilentlyContinue|Where-Object{$_.FullName -match $modelPattern}|Sort-Object FullName)
        foreach($manifestFile in $manifestFiles){
            $relative=$manifestFile.FullName.Substring($manifestRoot.Length)-replace '^[\\/]+',''
            $tag=Get-ManifestModelTag -RelativePath $relative
            if(-not $tag -or $tag -notmatch '(?i)(local-qwen35|qwen3\.5).*:'){continue}
            $verified=Test-OllamaManifest -StoreRoot $store -ManifestFile $manifestFile.FullName -RelativePath $relative
            if(-not $verified){continue}
            Write-Host "[MODEL] Found complete Qwen files in another local Ollama store: $store" -ForegroundColor Cyan
            Import-OllamaManifest -ActiveRoot $activeStore -VerifiedManifest $verified
            $importedTag=$tag;$tags=Wait-ForOllamaTag -Tag $tag;$names=@($tags|ForEach-Object{[string]$_.name})
            if($names -contains $tag){break}
        }
        if($importedTag -and $names -contains $importedTag){break}
    }
    if(-not $importedTag -or $names -notcontains $importedTag){
        if($script:ModelIntegrityFailures.Count -gt 0){
            $details=$script:ModelIntegrityFailures -join [Environment]::NewLine
            throw ("A local Qwen manifest or blob failed integrity validation. Automatic download is blocked to avoid silently downloading another multi-gigabyte model. Preserve the existing store and inspect these files:"+[Environment]::NewLine+$details)
        }
        if(-not [bool]$script:Config.ollama.auto_download_when_missing){throw 'Qwen 3.5 9B was not found in Ollama API or known local stores; auto-download is disabled. No model was downloaded.'}
        $pullTag=[string]$script:Config.ollama.official_pull_tag
        $device=[IO.Path]::GetPathRoot($activeStore).TrimEnd('\')
        $disk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$device'" -ErrorAction SilentlyContinue
        if($disk -and [long]$disk.FreeSpace -lt 12GB){throw "Qwen 3.5 9B is missing and model store has less than 12 GB free: $activeStore"}
        $script:OllamaExe=Get-OllamaExe
        if(-not $script:OllamaExe){throw 'Ollama CLI was not found. Automatic Qwen download requires ollama.exe in PATH or standard install location.'}
        Write-Host "[MODEL] Downloading official Ollama tag $pullTag because no local copy was found." -ForegroundColor Yellow
        $oldHost=$env:OLLAMA_HOST;$oldPreference=$ErrorActionPreference
        try{$ErrorActionPreference='Continue';$env:OLLAMA_HOST=$BaseUrl;& $script:OllamaExe pull $pullTag;$pullExit=$LASTEXITCODE}
        finally{$ErrorActionPreference=$oldPreference;if($null -eq $oldHost){Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue}else{$env:OLLAMA_HOST=$oldHost}}
        if($pullExit -ne 0){throw "ollama pull $pullTag failed with exit code $pullExit. Ollama was not restarted/reinstalled."}
        $tags=Wait-ForOllamaTag -Tag $pullTag;$names=@($tags|ForEach-Object{[string]$_.name})
        if($names -notcontains $pullTag){throw "Ollama pull completed but $pullTag is missing from /api/tags."}
        $importedTag=$pullTag;$script:Status.ollama.source='Downloaded from official Ollama library because no local copy was found'
    }else{$script:Status.ollama.source='Verified local manifest and blobs imported into active Ollama store';$tags=Get-OllamaTags;$names=@($tags|ForEach-Object{[string]$_.name})}
    $preferred=[string]$script:Config.ollama.preferred_tag
    if($importedTag -and $importedTag -ne $preferred -and $names -notcontains $preferred){if(Invoke-OllamaCopy -SourceTag $importedTag -DestinationTag $preferred){$tags=Wait-ForOllamaTag -Tag $preferred;$names=@($tags|ForEach-Object{[string]$_.name})}}
    $selected=Find-QwenTag -Names $names
    if(-not $selected -and $names -contains $importedTag){$selected=$importedTag}
    if(-not $selected){throw 'Qwen model was imported/downloaded but Ollama exposes no usable Qwen 3.5 9B tag.'}
    $model=$tags|Where-Object{$_.name -eq $selected}|Select-Object -First 1
    $script:Status.ollama.tag=$selected;if($model){$script:Status.ollama.size_bytes=[long]$model.size}
    if($script:Status.ollama.source -like 'Downloaded*'){$script:Status.ollama.status='ready_downloaded'}else{$script:Status.ollama.status='ready_imported'}
    Write-Host "[OK] Qwen model is ready: $selected." -ForegroundColor Green
}

function Ensure-WhisperModel {
    $modelSize=[string]$script:Config.whisper.model_size;$repository=[string]$script:Config.whisper.repository;$relative=[string]$script:Config.whisper.cache_relative_path
    if([string]::IsNullOrWhiteSpace($relative)){throw 'MODELS.json whisper.cache_relative_path is empty.'}
    $modelCache=Join-Path $Platform ($relative -replace '^Data[\\/]','Data\')
    $helper=Join-Path $PSScriptRoot 'WHISPER-MODEL-MANAGER.py'
    if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw "Whisper model helper is missing: $helper"}
    $env:HF_HUB_ETAG_TIMEOUT='30';$env:HF_HUB_DOWNLOAD_TIMEOUT='120';$env:HF_HUB_DISABLE_TELEMETRY='1'
    $env:HF_HOME=Join-Path $Data 'cache\huggingface';$env:HUGGINGFACE_HUB_CACHE=Join-Path $env:HF_HOME 'hub'
    New-Item -ItemType Directory -Force -Path $env:HF_HOME,$env:HUGGINGFACE_HUB_CACHE,$modelCache|Out-Null
    $cacheRoots=@($env:HUGGINGFACE_HUB_CACHE,(Join-Path $env:USERPROFILE '.cache\huggingface\hub'),(Join-Path $env:LOCALAPPDATA 'huggingface\hub'))+@($script:Config.whisper.search_cache_roots)
    $pythonArgs=@($helper,'--model-id',$modelSize,'--cache-dir',$modelCache)
    foreach($cacheRoot in $cacheRoots){if(-not [string]::IsNullOrWhiteSpace([string]$cacheRoot)){$pythonArgs+=@('--cache-root',[string]$cacheRoot)}}
    if(-not [bool]$script:Config.whisper.auto_download_when_missing){$pythonArgs+='--no-download'}
    Write-Host "[MODEL] Preparing optional Whisper model '$modelSize' ($repository)..." -ForegroundColor Cyan
    $oldPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=@(& $Python @pythonArgs 2>&1);$pythonExit=$LASTEXITCODE}
    finally{$ErrorActionPreference=$oldPreference}
    $combined=$output -join [Environment]::NewLine;$snapshotPath='';$selectedCache=$modelCache
    if($pythonExit -eq 0 -and $combined -match '(?m)^WHISPER_READY=(.+)$'){
        $snapshotPath=$matches[1].Trim();if($combined -match '(?m)^WHISPER_CACHE_DIR=(.+)$'){$selectedCache=$matches[1].Trim()}
        $script:Status.whisper.model=$modelSize;$script:Status.whisper.status='ready';$script:Status.whisper.path=$snapshotPath;$script:Status.whisper.cache_dir=$selectedCache
        if($combined -match '(?m)^WHISPER_SOURCE=(.+)$'){$script:Status.whisper.source=$matches[1].Trim()}
        Write-Host "[OK] Whisper '$modelSize' is cached at: $snapshotPath" -ForegroundColor Green;return
    }
    $warning="Whisper $modelSize ($repository) is not ready (Python exit $pythonExit): $combined"
    $script:Status.whisper.model=$modelSize;$script:Status.whisper.status='warning_missing_or_download_failed';$script:Status.whisper.cache_dir=$modelCache
    $script:Warnings.Add($warning);Write-Host "[WARN] $warning" -ForegroundColor Yellow
    if($RequireWhisper){throw $warning}
}

$modelManagerMutex=$null;$ownsModelManagerMutex=$false
try {
    $modelManagerMutex=[System.Threading.Mutex]::new($false,'Local\LocalAIStudio-ModelManager')
    try{$ownsModelManagerMutex=$modelManagerMutex.WaitOne(0)}catch [System.Threading.AbandonedMutexException]{$ownsModelManagerMutex=$true}
    if(-not $ownsModelManagerMutex){Write-Host '[BUSY] Another model-manager operation is active; no shared status/model files were changed.' -ForegroundColor Yellow;exit 3}
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing model configuration: $ConfigPath" }
    $script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Status.whisper.model = [string]$script:Config.whisper.model_size
    if ([int]$script:Config.schema_version -ne 1) { throw 'Unsupported MODELS.json schema version.' }
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "Project Python is missing: $Python. Run LocalAI-Studio.bat repair." }
    New-Item -ItemType Directory -Force -Path $Root,$Platform,$Data,(Join-Path $Data 'Temp') | Out-Null
    $env:TEMP=Join-Path $Data 'Temp';$env:TMP=$env:TEMP;$env:TMPDIR=$env:TEMP
    $apiVersion=Invoke-RestMethod -Uri ($BaseUrl+'/api/version') -TimeoutSec 8 -ErrorAction Stop
    $script:OllamaExe=Get-OllamaExe;$script:Status.ollama.store=Get-ActiveModelStore
    Write-Host "Ollama $($apiVersion.version) is online. Checking required Qwen chat model." -ForegroundColor Cyan
    Ensure-QwenModel
    if($RequireWhisper -or [bool]$script:Config.whisper.required_for_text_chat){Ensure-WhisperModel}
    else{$script:Status.whisper.status='not_requested';$script:Status.whisper.source='Skipped; Whisper is optional for text-only chat. Run ENSURE-MODELS.ps1 -RequireWhisper to prepare audio.';Write-Host '[INFO] Whisper setup skipped; it is not required for text chat.' -ForegroundColor DarkGray}
    Save-ModelStatus
    Write-Host "Model report: $StatusPath" -ForegroundColor Cyan
    if($script:Warnings.Count -gt 0){Write-Host 'Model manager completed with warnings; review MODEL-STATUS.json and MODEL-STATUS.txt.' -ForegroundColor Yellow;if($RequireWhisper){exit 2}}
    exit 0
} catch {
    $script:Status.error=$_.Exception.Message
    try{Save-ModelStatus}catch{}
    Write-Host "MODEL CHECK FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if($ownsModelManagerMutex -and $modelManagerMutex){try{$modelManagerMutex.ReleaseMutex()}catch{}}
    if($modelManagerMutex){$modelManagerMutex.Dispose()}
}
