$ErrorActionPreference = 'Stop'
$Root = 'D:\LocalAI'
$Platform = Join-Path $Root 'Platform'
$Logs = Join-Path $Root 'Logs'
$Data = Join-Path $Platform 'Data'
$TempRoot = Join-Path $Data 'Temp'
$VenvPython = Join-Path $Platform '.venv\Scripts\python.exe'
$OpenWebUIExe = Join-Path $Platform '.venv\Scripts\open-webui.exe'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$InstallerScript = Join-Path $PSScriptRoot 'INSTALL-PLATFORM.ps1'
$script:LogState = @{}

function Quote-ProcessArgument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $slash=[string][char]92;$quote=[char]34;$builder=[System.Text.StringBuilder]::new();[void]$builder.Append($quote);$slashes=0
    foreach($character in $Value.ToCharArray()){
        if([int]$character -eq 92){$slashes++;continue}
        if($character -eq $quote){if($slashes -gt 0){[void]$builder.Append(($slash*(2*$slashes)))};[void]$builder.Append($slash);[void]$builder.Append($quote);$slashes=0;continue}
        if($slashes -gt 0){[void]$builder.Append(($slash*$slashes));$slashes=0};[void]$builder.Append($character)
    }
    if($slashes -gt 0){[void]$builder.Append(($slash*(2*$slashes)))};[void]$builder.Append($quote);return $builder.ToString()
}
function Invoke-CapturedProcess([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds=45) {
    $id=[guid]::NewGuid().ToString('N');$temp=Join-Path $env:TEMP ('localai-probe-'+$id);New-Item -ItemType Directory -Force -Path $temp|Out-Null
    $stdout=Join-Path $temp 'stdout.txt';$stderr=Join-Path $temp 'stderr.txt';$line=(($Arguments|ForEach-Object{Quote-ProcessArgument ([string]$_)}) -join ' ');$proc=$null
    try{
        $proc=Start-Process -FilePath $Executable -ArgumentList $line -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        if(-not $proc.WaitForExit($TimeoutSeconds*1000)){
            try{$proc.Kill();[void]$proc.WaitForExit(5000)}catch{}
            $out=if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''};$err=if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''}
            if(-not [string]::IsNullOrWhiteSpace($err)){$err+=[Environment]::NewLine};$err+="Process timed out after $TimeoutSeconds seconds."
            return [pscustomobject]@{ExitCode=124;StdOut=$out;StdErr=$err;TimedOut=$true}
        }
        $proc.Refresh();$out=if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''};$err=if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''}
        return [pscustomobject]@{ExitCode=[int]$proc.ExitCode;StdOut=$out;StdErr=$err;TimedOut=$false}
    }finally{try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}}
}
function Get-OpenWebUIState {
    if(-not(Test-Path -LiteralPath $VenvPython -PathType Leaf)){return [pscustomobject]@{Installed=$false;Version=$null;AudioReady=$false;Detail='project Python not present'}}
    $code=@'
import importlib.metadata as md, json
try: version=md.version("open-webui")
except md.PackageNotFoundError: version=None
try: import open_webui; core_import=True; core_error=None
except Exception as e: core_import=False; core_error=type(e).__name__+": "+str(e)[:300]
try: import av, faster_whisper; audio=True; av_version=getattr(av,"__version__",None)
except Exception as e: audio=False; av_version=None; audio_error=type(e).__name__+": "+str(e)[:300]
print(json.dumps({"version":version,"core_import":core_import,"core_error":core_error,"audio":audio,"av_version":av_version,"audio_error":locals().get("audio_error")}))
'@
    $result=Invoke-CapturedProcess -Executable $VenvPython -Arguments @('-c',$code) -TimeoutSeconds 60
    if($result.ExitCode -ne 0){return [pscustomobject]@{Installed=$false;Version=$null;AudioReady=$false;Detail=('Python probe failed: '+$result.StdErr+' '+$result.StdOut)}}
    try{$info=$result.StdOut|ConvertFrom-Json}catch{return [pscustomobject]@{Installed=$false;Version=$null;AudioReady=$false;Detail=('Could not parse package probe: '+$result.StdOut+' '+$result.StdErr)}}
    $core=($info.version -eq '0.13.5' -and $info.core_import -eq $true -and (Test-Path -LiteralPath $OpenWebUIExe -PathType Leaf))
    return [pscustomobject]@{Installed=$core;Version=$info.version;AudioReady=($info.audio -eq $true -and $info.av_version -eq '14.0.1');Detail=($info|ConvertTo-Json -Compress)}
}
function Get-ActiveInstallProcesses {
    $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue);$found=@()
    foreach($p in $all){$cmd=[string]$p.CommandLine;$exe=[string]$p.ExecutablePath
        if($p.Name -match '^(powershell|pwsh)\.exe$' -and $cmd -match '(?i)INSTALL-PLATFORM\.ps1'){$found+=$p;continue}
        if($p.Name -match '^python(w)?\.exe$' -and $exe -match '(?i)\\LocalAI\\Platform\\\.venv\\Scripts\\python(w)?\.exe$' -and $cmd -match '(?i)(-m\s+pip\s+install|pip\.exe\s+install)' -and $cmd -match '(?i)open-webui'){$found+=$p;continue}
        if($p.Name -match '^python(w)?\.exe$' -and $exe -match '(?i)\\LocalAI\\Platform\\\.venv\\Scripts\\python(w)?\.exe$' -and $cmd -match '(?i)pip' -and $cmd -match '(?i)0\.13\.5'){$found+=$p}
    }
    return @($found|Sort-Object ProcessId -Unique)
}
function Show-ChangedLog([string]$Path) {
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return};$item=Get-Item -LiteralPath $Path;$key=$Path.ToLowerInvariant();$state="$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
    if($script:LogState.ContainsKey($key) -and $script:LogState[$key] -eq $state){return};$script:LogState[$key]=$state
    Write-Host "`n--- $($item.Name) | $($item.Length) bytes | $($item.LastWriteTime) ---" -ForegroundColor Cyan
    Get-Content -LiteralPath $Path -Tail 14 -ErrorAction SilentlyContinue|ForEach-Object{Write-Host $_}
}
function Watch-Installer([int]$MaximumWaitMinutes=120) {
    $deadline=(Get-Date).AddMinutes($MaximumWaitMinutes)
    Write-Host 'An existing installer/pip process is active. Monitoring; no duplicate installer will be started and no process will be killed.' -ForegroundColor Yellow
    while($true){
        $active=@(Get-ActiveInstallProcesses);$recent=@(Get-ChildItem -LiteralPath $Logs -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '\.(stdout|stderr)\.log$'}|Sort-Object LastWriteTime -Descending|Select-Object -First 4)
        foreach($f in $recent){Show-ChangedLog -Path $f.FullName}
        if($active.Count -eq 0){break}
        if((Get-Date) -ge $deadline){$pids=($active|ForEach-Object{$_.ProcessId}) -join ', ';throw "Waited $MaximumWaitMinutes minutes for installer process(es) $pids. They were not terminated. Inspect logs and rerun repair after they finish."}
        $pids=($active|ForEach-Object{$_.ProcessId}) -join ', '
        if(-not $script:LastWaitNotice -or ((Get-Date)-$script:LastWaitNotice).TotalSeconds -ge 180){Write-Host "Installer-related processes still active: PID $pids. Waiting safely." -ForegroundColor Yellow;$script:LastWaitNotice=Get-Date}
        Start-Sleep -Seconds 30
    }
    Write-Host 'Existing install process exited. Verifying installed files before resuming.' -ForegroundColor Green
}
$script:RepairBackupRoot = $null
$script:RepairBackupReady = $false
$script:RepairManagedPaths = New-Object System.Collections.ArrayList
$script:RepairOriginalPaths = @{}
function Backup-RepairManagedFiles {
    param([Parameter(Mandatory=$true)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Package manifest missing: $ManifestPath" }
    $platformFull=[IO.Path]::GetFullPath($Platform).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))
    $prefix=$platformFull+[IO.Path]::DirectorySeparatorChar
    $script:RepairBackupRoot=Join-Path $Root ('Backups\Platform-PreRepair-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Force -Path $script:RepairBackupRoot|Out-Null
    foreach($line in Get-Content -LiteralPath $ManifestPath -Encoding UTF8){
        if($line -notmatch '^([0-9A-Fa-f]{64})\s+(.+)$'){continue}
        $relative=$matches[2].Trim().Replace('/',[IO.Path]::DirectorySeparatorChar)
        if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)'){throw "Unsafe package path in repair manifest: $relative"}
        $null=$script:RepairManagedPaths.Add($relative)
        $target=[IO.Path]::GetFullPath((Join-Path $platformFull $relative))
        if(-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw "Repair package path escaped platform directory: $relative"}
        if(Test-Path -LiteralPath $target -PathType Leaf){
            $saved=Join-Path $script:RepairBackupRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved)|Out-Null
            Copy-Item -LiteralPath $target -Destination $saved -ErrorAction Stop
            $script:RepairOriginalPaths[$relative]=$true
        }
    }
    # The manifest cannot hash itself, but it must be restored if the refresh fails.
    $manifestRelative='MANIFEST-SHA256.txt'
    if(-not $script:RepairManagedPaths.Contains($manifestRelative)){
        $null=$script:RepairManagedPaths.Add($manifestRelative)
        $manifestTarget=Join-Path $Platform $manifestRelative
        if(Test-Path -LiteralPath $manifestTarget -PathType Leaf){
            $manifestBackup=Join-Path $script:RepairBackupRoot $manifestRelative
            Copy-Item -LiteralPath $manifestTarget -Destination $manifestBackup -ErrorAction Stop
            $script:RepairOriginalPaths[$manifestRelative]=$true
        }
    }
    @("Created: $(Get-Date -Format o)","Platform: $platformFull","Manifest-managed paths: $($script:RepairManagedPaths.Count)","Existing managed files saved: $($script:RepairOriginalPaths.Count)","User data, chat database, signing keys and Ollama models are outside this repair backup.")|Set-Content -LiteralPath (Join-Path $script:RepairBackupRoot 'BACKUP-SUMMARY.txt') -Encoding UTF8
    $script:RepairBackupReady=$true
    Write-Host "[BACKUP] Package-managed files saved to $script:RepairBackupRoot" -ForegroundColor Cyan
}
function Restore-RepairManagedFiles {
    if(-not $script:RepairBackupReady -or -not $script:RepairBackupRoot -or -not(Test-Path -LiteralPath $script:RepairBackupRoot -PathType Container)){return}
    foreach($relative in $script:RepairManagedPaths){
        if(-not $script:RepairOriginalPaths.ContainsKey($relative)){
            $target=Join-Path $Platform $relative
            if(Test-Path -LiteralPath $target -PathType Leaf){Remove-Item -LiteralPath $target -Force -ErrorAction Stop}
        }
    }
    $savedFiles=@(Get-ChildItem -LiteralPath $script:RepairBackupRoot -Recurse -File -ErrorAction Stop|Where-Object{$_.Name -ne 'BACKUP-SUMMARY.txt'})
    foreach($item in $savedFiles){
        $relative=$item.FullName.Substring($script:RepairBackupRoot.Length).TrimStart([char[]]@([char]92,[char]47))
        $target=Join-Path $Platform $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)|Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
    }
    @("Rollback completed: $(Get-Date -Format o)","Restored files: $($savedFiles.Count)","Backup retained: $script:RepairBackupRoot")|Set-Content -LiteralPath (Join-Path $script:RepairBackupRoot 'ROLLBACK-RESULT.txt') -Encoding UTF8
    Write-Host "[ROLLBACK] Restored package-managed files from $script:RepairBackupRoot" -ForegroundColor Green
}

Write-Host 'LOCALAI PLATFORM REPAIR / RESUME v3.4' -ForegroundColor Cyan
Write-Host 'Chat platform only. Existing Ollama, Qwen and user data are reused.'
if(-not(Test-Path -LiteralPath $InstallerScript -PathType Leaf)){throw 'INSTALL-PLATFORM.ps1 is missing from this extracted package.'}
New-Item -ItemType Directory -Force -Path $Logs,$TempRoot|Out-Null
$env:TEMP=$TempRoot;$env:TMP=$TempRoot;$env:TMPDIR=$TempRoot
$repairMutex=[System.Threading.Mutex]::new($false,'Local\LocalAIStudio-Repair')
$ownsRepairMutex=$false
try{$ownsRepairMutex=$repairMutex.WaitOne(0)}catch [System.Threading.AbandonedMutexException]{$ownsRepairMutex=$true}
if(-not $ownsRepairMutex){$repairMutex.Dispose();throw 'Another LocalAI Studio repair/resume operation is already running.'}
try {
$packageVerifier=Join-Path $PSScriptRoot 'VERIFY-PACKAGE.ps1'
if(-not(Test-Path -LiteralPath $packageVerifier -PathType Leaf)){throw 'VERIFY-PACKAGE.ps1 is missing from the extracted package.'}
$packageResult=Invoke-CapturedProcess -Executable $PowerShellExe -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$packageVerifier,'-InstalledPlatform') -TimeoutSeconds 180
if($packageResult.ExitCode -ne 0){throw "Package verification failed; no installed package files were changed. $($packageResult.StdErr) $($packageResult.StdOut)"}
$active=@(Get-ActiveInstallProcesses);if($active.Count -gt 0){Watch-Installer}
$state=Get-OpenWebUIState
Write-Host ('Open WebUI package state: Version={0}; CoreReady={1}; AudioImportsReady={2}' -f $state.Version,$state.Installed,$state.AudioReady) -ForegroundColor Cyan
if($state.Installed){
    Write-Host 'Open WebUI core is installed. Optional audio imports are not required for text chat; refreshing project-managed files only.' -ForegroundColor Green
    New-Item -ItemType Directory -Force -Path $Platform,(Join-Path $Platform 'Filters')|Out-Null
    Backup-RepairManagedFiles -ManifestPath (Join-Path $PSScriptRoot 'MANIFEST-SHA256.txt')
    try {
        $runtimeFiles=@('SETUP-LOCALAI.bat','SETUP-LOCALAI.ps1','LAUNCH-LOCALAI-APP.ps1','LocalAI-Studio.bat','START-CHAT.ps1','STOP-CHAT.ps1','REPAIR-AND-RESUME.ps1','INSTALL-PLATFORM.ps1','CHECK-LOCALAI.ps1','VERIFY-MODEL.ps1','VERIFY-PACKAGE.ps1','IMPORT-FILTERS.ps1','RESTORE-OPENWEBUI-STYLE.ps1','LOCALAI-STUDIO-THEME.css','TEST-FILTERS.py','TEST-FILTER-POLICY.py','TEST-MODEL-MANAGER.py','TEST-MODEL-INTEGRITY.ps1','TEST-PLATFORM-BACKUP.ps1','TEST-WINDOWS-PROCESS-LAUNCH.ps1','README-AR.md','CHANGELOG-AR.md','TEST-REPORT-AR.txt','TEST-RELEASE.py','MANIFEST-SHA256.txt','ENSURE-MODELS.ps1','MODELS.json','WHISPER-MODEL-MANAGER.py')
        foreach($fileName in $runtimeFiles){$source=Join-Path $PSScriptRoot $fileName;if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw "Required package file is missing: $fileName"};$target=Join-Path $Platform $fileName;if([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}}
        $sourceFilters=Join-Path $PSScriptRoot 'Filters';$targetFilters=Join-Path $Platform 'Filters'
        if([IO.Path]::GetFullPath($sourceFilters) -ne [IO.Path]::GetFullPath($targetFilters)){Copy-Item -Path (Join-Path $sourceFilters '*.py') -Destination $targetFilters -Force}
        $sourceAssets=Join-Path $PSScriptRoot 'Assets';$targetAssets=Join-Path $Platform 'Assets'
        if((Test-Path -LiteralPath $sourceAssets -PathType Container) -and [IO.Path]::GetFullPath($sourceAssets) -ne [IO.Path]::GetFullPath($targetAssets)){New-Item -ItemType Directory -Force -Path $targetAssets|Out-Null;Copy-Item -Path (Join-Path $sourceAssets '*.ico') -Destination $targetAssets -Force}
        $releaseTest=Invoke-CapturedProcess -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-RELEASE.py')) -TimeoutSeconds 120
        if($releaseTest.ExitCode -ne 0){throw "Release contract tests failed: $($releaseTest.StdOut) $($releaseTest.StdErr)"}
        Write-Host $releaseTest.StdOut.TrimEnd()
        $filterTest=Invoke-CapturedProcess -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-FILTERS.py'),'--filters-dir',$targetFilters) -TimeoutSeconds 120
        if($filterTest.ExitCode -ne 0 -or $filterTest.StdOut -notmatch 'FILTER_TESTS: SUCCESS'){throw "Filter tests failed: $($filterTest.StdOut) $($filterTest.StdErr)"}
        $policyTest=Invoke-CapturedProcess -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-FILTER-POLICY.py')) -TimeoutSeconds 60
        if($policyTest.ExitCode -ne 0 -or $policyTest.StdOut -notmatch 'MODEL_POLICY_TESTS: SUCCESS'){throw "Model/filter policy tests failed: $($policyTest.StdOut) $($policyTest.StdErr)"}
        foreach($testName in @('TEST-MODEL-INTEGRITY.ps1','TEST-PLATFORM-BACKUP.ps1','TEST-WINDOWS-PROCESS-LAUNCH.ps1')){
            $testPath=Join-Path $Platform $testName
            $testResult=Invoke-CapturedProcess -Executable $PowerShellExe -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$testPath) -TimeoutSeconds 180
            if($testResult.ExitCode -ne 0){throw "$testName failed: $($testResult.StdOut) $($testResult.StdErr)"}
            Write-Host $testResult.StdOut.TrimEnd()
        }
        $modelUnitTest=Invoke-CapturedProcess -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-MODEL-MANAGER.py')) -TimeoutSeconds 180
        if(-not [string]::IsNullOrWhiteSpace($modelUnitTest.StdOut)){Write-Host $modelUnitTest.StdOut.TrimEnd()}
        if(-not [string]::IsNullOrWhiteSpace($modelUnitTest.StdErr)){Write-Host $modelUnitTest.StdErr.TrimEnd()}
        if($modelUnitTest.ExitCode -ne 0){throw "Whisper model-manager tests failed: $($modelUnitTest.StdOut) $($modelUnitTest.StdErr)"}
        $modelManager=Join-Path $PSScriptRoot 'ENSURE-MODELS.ps1';if(-not(Test-Path -LiteralPath $modelManager -PathType Leaf)){throw 'ENSURE-MODELS.ps1 is missing from the package.'}
        Write-Host 'Checking Qwen and optional Whisper setup using Windows PowerShell 5.1...' -ForegroundColor Cyan
        $modelResult=Invoke-CapturedProcess -Executable $PowerShellExe -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$modelManager) -TimeoutSeconds 1800
        if(-not [string]::IsNullOrWhiteSpace($modelResult.StdOut)){Write-Host $modelResult.StdOut.TrimEnd()}
        if(-not [string]::IsNullOrWhiteSpace($modelResult.StdErr)){Write-Host $modelResult.StdErr.TrimEnd() -ForegroundColor Yellow}
        $modelExitCode=[int]$modelResult.ExitCode;if($modelExitCode -ne 0){throw "Qwen model verification failed (exit $modelExitCode). $($modelResult.StdErr) See MODEL-STATUS.json."}
        $modelStatus=Get-Content -LiteralPath (Join-Path $Platform 'MODEL-STATUS.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($modelStatus.whisper.status -eq 'not_requested'){Write-Host 'Whisper skipped intentionally; text chat is ready.' -ForegroundColor DarkGray}elseif($modelStatus.whisper.status -ne 'ready'){Write-Host "Whisper optional audio model is not ready: $($modelStatus.whisper.status). Text chat remains available." -ForegroundColor Yellow}
        Write-Host 'Updated platform files and verified the configured chat model. Existing user data and Ollama store were not removed.' -ForegroundColor Green
        exit 0
    } catch {
        try { Restore-RepairManagedFiles } catch { Write-Host "[ROLLBACK FAILED] $($_.Exception.Message). Repair backup retained at $script:RepairBackupRoot" -ForegroundColor Red }
        throw
    }
}
if($state.Installed){Write-Host 'Open WebUI core is present. Optional audio support will not block text chat.' -ForegroundColor DarkGray}
else{Write-Host 'Open WebUI 0.13.5 is not installed or core imports are broken. Starting the installer using the existing venv and pip cache.' -ForegroundColor Yellow}
& $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $InstallerScript
$rc=[int]$LASTEXITCODE
if($rc -ne 0){throw "Platform installer failed with exit code $rc. Inspect stdout/stderr logs in D:\LocalAI\Logs."}
$final=Get-OpenWebUIState
if(-not $final.Installed){throw ('Installer exited successfully but Open WebUI core is not complete: '+$final.Detail)}
if(-not $final.AudioReady){Write-Host 'Optional audio imports are unavailable; text chat is still ready.' -ForegroundColor DarkGray}
Write-Host 'Platform repair completed. Ollama/Qwen data was not reinstalled or downloaded.' -ForegroundColor Green
} finally {
    if($ownsRepairMutex -and $repairMutex){try{$repairMutex.ReleaseMutex()}catch{}}
    if($repairMutex){$repairMutex.Dispose()}
}
