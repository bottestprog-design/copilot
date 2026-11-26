$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = 'D:\LocalAI'
$Platform = Join-Path $Root 'Platform'
$Data = Join-Path $Platform 'Data'
$Logs = Join-Path $Root 'Logs'
$FilterDir = Join-Path $Platform 'Filters'
$Cache = Join-Path $Root 'Cache'
# Verify the extracted package before touching the target installation.
$manifestPath = Join-Path $PSScriptRoot 'MANIFEST-SHA256.txt'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Package manifest is missing. Re-extract the complete ZIP before installing.' }
$manifestLines = Get-Content -LiteralPath $manifestPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') }
if (@($manifestLines).Count -lt 10) { throw 'Package manifest is incomplete. Re-download and re-extract the ZIP.' }
foreach ($manifestLine in $manifestLines) {
    if ($manifestLine -notmatch '^([0-9A-Fa-f]{64})\s+(.+)$') { throw "Invalid manifest line: $manifestLine" }
    $expectedHash = $matches[1].ToLowerInvariant()
    $relativePath = $matches[2].Trim()
    if ($relativePath.StartsWith('*')) { $relativePath = $relativePath.Substring(1) }
    if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe package path: $relativePath" }
    $candidatePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relativePath))
    $packageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($packageRoot,[StringComparison]::OrdinalIgnoreCase)) { throw "Package path escapes extracted folder: $relativePath" }
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { throw "Package file is missing: $relativePath" }
    $actualHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Package integrity mismatch: $relativePath. Extract the ZIP again." }
}
Write-Host "[OK] Package integrity verified ($(@($manifestLines).Count) files)." -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $Root,$Platform,$Data,$Logs,$FilterDir,$Cache,(Join-Path $Data 'Temp'),(Join-Path $Cache 'pip'),(Join-Path $Data 'cache\huggingface'),(Join-Path $Data 'cache\whisper\models'),(Join-Path $Platform 'Secrets') | Out-Null
$env:TEMP = Join-Path $Data 'Temp'
$env:TMP = $env:TEMP
$env:TMPDIR = $env:TEMP
$script:Logs = $Logs
$LogFile = Join-Path $Logs ('platform-continuation-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Start-Transcript -Path $LogFile -Force | Out-Null
$StatusFile = Join-Path $Platform 'PLATFORM-STATUS.txt'
$FullStatusFile = Join-Path $Root 'FULL-STATUS.txt'
$EngineStatusFile = Join-Path $Root 'ENGINE-STATUS.txt'
$RequiredWebUI = '0.13.5'
$script:KeepAwakeEnabled = $false
$script:BackupRoot = $null
$script:BackupReady = $false
$script:ManagedFilesBeforeUpdate = @{}
$script:ManagedRelativePaths = New-Object System.Collections.ArrayList
function Backup-ManagedPlatformFiles {
    $script:BackupRoot = Join-Path $Root ('Backups\Platform-PreUpdate-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Force -Path $script:BackupRoot | Out-Null
    foreach ($line in $manifestLines) {
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s+(.+)$') { continue }
        $relative = $matches[2].Trim().Replace('/',[IO.Path]::DirectorySeparatorChar)
        $null = $script:ManagedRelativePaths.Add($relative)
        $target = [IO.Path]::GetFullPath((Join-Path $Platform $relative))
        $prefix = [IO.Path]::GetFullPath($Platform).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Managed path escapes platform folder: $relative" }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $backupFile = Join-Path $script:BackupRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupFile) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backupFile -ErrorAction Stop
            $script:ManagedFilesBeforeUpdate[$relative] = $true
        }
    }
    # The manifest cannot hash itself, but it must still be restorable if a package update fails.
    $manifestRelative='MANIFEST-SHA256.txt'
    if(-not $script:ManagedRelativePaths.Contains($manifestRelative)){
        $null=$script:ManagedRelativePaths.Add($manifestRelative)
        $manifestTarget=Join-Path $Platform $manifestRelative
        if(Test-Path -LiteralPath $manifestTarget -PathType Leaf){
            $manifestBackup=Join-Path $script:BackupRoot $manifestRelative
            Copy-Item -LiteralPath $manifestTarget -Destination $manifestBackup -ErrorAction Stop
            $script:ManagedFilesBeforeUpdate[$manifestRelative]=$true
        }
    }
    @("Created: $(Get-Date -Format o)","Platform: $Platform","Backup: $script:BackupRoot","Manifest files considered: $($script:ManagedRelativePaths.Count)","Existing managed files saved: $($script:ManagedFilesBeforeUpdate.Count)","Open WebUI Data, chats, secrets, Ollama stores and model blobs are not package-managed files and are not modified by this backup.") | Set-Content -LiteralPath (Join-Path $script:BackupRoot 'BACKUP-SUMMARY.txt') -Encoding UTF8
    $script:BackupReady = $true
    Write-Host "[BACKUP] Package-managed files saved to $script:BackupRoot" -ForegroundColor Cyan
}
function Restore-ManagedPlatformFiles {
    if (-not $script:BackupReady -or -not $script:BackupRoot -or -not (Test-Path -LiteralPath $script:BackupRoot -PathType Container)) { return }
    foreach ($relative in $script:ManagedRelativePaths) {
        $target = Join-Path $Platform $relative
        if (-not $script:ManagedFilesBeforeUpdate.ContainsKey($relative) -and (Test-Path -LiteralPath $target -PathType Leaf)) {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        }
    }
    $backupFiles = @(Get-ChildItem -LiteralPath $script:BackupRoot -Recurse -File -ErrorAction Stop | Where-Object { $_.Name -ne 'BACKUP-SUMMARY.txt' })
    foreach ($item in $backupFiles) {
        $relative = $item.FullName.Substring($script:BackupRoot.Length).TrimStart([char[]]@([char]92,[char]47))
        $target = Join-Path $Platform $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
    }
    @("Rollback completed: $(Get-Date -Format o)","Files restored: $($backupFiles.Count)","Backup retained: $script:BackupRoot","User Data and Ollama model storage were not part of rollback scope.") | Set-Content -LiteralPath (Join-Path $script:BackupRoot 'ROLLBACK-RESULT.txt') -Encoding UTF8
    Write-Host "[ROLLBACK] Restored managed files from $script:BackupRoot" -ForegroundColor Green
}
try {
    if (-not ('LocalAI.PowerManagement' -as [type])) {
        $powerTypeDefinition = @'
using System;
using System.Runtime.InteropServices;
namespace LocalAI {
    public static class PowerManagement {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SetThreadExecutionState(uint esFlags);
    }
}
'@
        Add-Type -TypeDefinition $powerTypeDefinition -ErrorAction Stop
    }
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED: prevent idle sleep only while this installer runs.
    $powerState = [LocalAI.PowerManagement]::SetThreadExecutionState([Convert]::ToUInt32('2147483649'))
    if ($powerState -eq 0) { throw 'Windows did not accept the temporary stay-awake request.' }
    $script:KeepAwakeEnabled = $true
} catch { Write-Host "Could not request temporary keep-awake state: $($_.Exception.Message)" -ForegroundColor Yellow }
$Warnings = New-Object System.Collections.Generic.List[string]
$Failures = New-Object System.Collections.Generic.List[string]
function Quote-Arg([string]$Value) {
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
function Read-AppendedLogText([string]$Path,[long]$Offset) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Text=''; Offset=$Offset } }
    $stream = $null; $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $Offset) { $Offset = 0 }
        [void]$stream.Seek($Offset,[System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream,[System.Text.Encoding]::UTF8,$true,4096,$true)
        $text = $reader.ReadToEnd()
        return [pscustomobject]@{ Text=$text; Offset=[long]$stream.Position }
    } catch { return [pscustomobject]@{ Text=''; Offset=$Offset } }
    finally { if ($reader) { $reader.Dispose() }; if ($stream) { $stream.Dispose() } }
}
function Write-LogDelta([string]$Text,[ConsoleColor]$Color) {
    if ([string]::IsNullOrEmpty($Text)) { return }
    foreach ($line in (($Text -replace "`r", "`n") -split "`n")) { if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host $line -ForegroundColor $Color } }
}
function Invoke-NativeLogged {
    param([string]$Executable,[string[]]$Arguments,[string]$Label,[int]$NoticeSeconds=180)
    $id = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $script:Logs ($id + '.stdout.log'); $errFile = Join-Path $script:Logs ($id + '.stderr.log')
    $argLine = (($Arguments | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    Write-Host "`n>>> $Label" -ForegroundColor Cyan; Write-Host "Live logs: $outFile | $errFile" -ForegroundColor DarkGray
    $proc = Start-Process -FilePath $Executable -ArgumentList $argLine -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
    $outOffset=[long]0;$errOffset=[long]0;$lastNotice=Get-Date;$lastOutput=Get-Date;$startedAt=Get-Date
    while(-not $proc.HasExited){
        Start-Sleep -Seconds 2;$proc.Refresh();$od=Read-AppendedLogText -Path $outFile -Offset $outOffset;$ed=Read-AppendedLogText -Path $errFile -Offset $errOffset;$outOffset=$od.Offset;$errOffset=$ed.Offset
        if($od.Text){Write-LogDelta -Text $od.Text -Color Gray;$lastOutput=Get-Date};if($ed.Text){Write-LogDelta -Text $ed.Text -Color DarkYellow;$lastOutput=Get-Date}
        if(-not $proc.HasExited -and ((Get-Date)-$lastNotice).TotalSeconds -ge $NoticeSeconds){
            $ob=if(Test-Path $outFile){(Get-Item $outFile).Length}else{0};$eb=if(Test-Path $errFile){(Get-Item $errFile).Length}else{0};$quiet=[int]((Get-Date)-$lastOutput).TotalSeconds;$elapsed=[int]((Get-Date)-$startedAt).TotalMinutes;$cpu=0.0
            try{$proc.Refresh();$cpu=[math]::Round($proc.CPU,1)}catch{}
            Write-Host ("{0} is still running (PID {1}); elapsed {2} min; CPU {3}s; stdout {4:N0} KB, stderr {5:N0} KB; last output {6}s ago. No duplicate process started." -f $Label,$proc.Id,$elapsed,$cpu,($ob/1KB),($eb/1KB),$quiet) -ForegroundColor Yellow
            Write-Host "Logs: $outFile | $errFile" -ForegroundColor DarkGray;$lastNotice=Get-Date
        }
    }
    $proc.WaitForExit();$od=Read-AppendedLogText -Path $outFile -Offset $outOffset;$ed=Read-AppendedLogText -Path $errFile -Offset $errOffset
    Write-LogDelta -Text $od.Text -Color Gray;Write-LogDelta -Text $ed.Text -Color DarkYellow
    $stdout=if(Test-Path $outFile){[IO.File]::ReadAllText($outFile)}else{''};$stderr=if(Test-Path $errFile){[IO.File]::ReadAllText($errFile)}else{''};$exitCode=[int]$proc.ExitCode
    if($exitCode -eq 0){Write-Host "[OK] $Label completed successfully." -ForegroundColor Green}else{Write-Host "[FAIL] $Label exited with code $exitCode. See $outFile and $errFile" -ForegroundColor Red}
    return [pscustomobject]@{ExitCode=$exitCode;StdOut=$stdout;StdErr=$stderr;StdOutPath=$outFile;StdErrPath=$errFile}
}
function Refresh-UserPath { $machine=[Environment]::GetEnvironmentVariable('Path','Machine');$user=[Environment]::GetEnvironmentVariable('Path','User');$links=Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links';$parts=@($machine,$user,$links)|Where-Object{-not [string]::IsNullOrWhiteSpace($_)};$env:Path=[string]::Join(';',$parts) }
function Find-Python {
    $candidates=@((Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),(Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),(Join-Path $env:ProgramFiles 'Python311\python.exe'),(Join-Path $env:ProgramFiles 'Python312\python.exe'),'C:\Python311\python.exe','C:\Python312\python.exe')
    foreach($candidate in $candidates){if(Test-Path -LiteralPath $candidate -PathType Leaf){$probe=Invoke-NativeLogged -Executable $candidate -Arguments @('-c','import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")') -Label 'Validate system Python';if($probe.ExitCode -eq 0){$v=($probe.StdOut -split "`r?`n"|Where-Object{$_ -match '^3\.(11|12)\.'}|Select-Object -First 1);if($v){return [pscustomobject]@{Exe=$candidate;Version=$v}}}}}
    $pythonCommand=Get-Command python.exe -ErrorAction SilentlyContinue
    if($pythonCommand){
        $candidate=[string]$pythonCommand.Source
        if($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf) -and $candidate -notin $candidates){
            $probe=Invoke-NativeLogged -Executable $candidate -Arguments @('-c','import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")') -Label 'Validate Python found on PATH'
            if($probe.ExitCode -eq 0){$v=$probe.StdOut -split "`r?`n"|Where-Object{$_ -match '^3\.(11|12)\.'}|Select-Object -First 1;if($v){return [pscustomobject]@{Exe=$candidate;Version=$v}}}
        }
    }
    $launcher=Get-Command py.exe -ErrorAction SilentlyContinue
    if($launcher){foreach($minor in @('3.11','3.12')){$p=Invoke-NativeLogged -Executable $launcher.Source -Arguments @('-'+$minor,'-c','import sys;print(sys.executable);print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")') -Label "Probe Python $minor launcher";if($p.ExitCode -eq 0 -and $p.StdOut -match '(?m)^3\.(11|12)\.'){$lines=$p.StdOut -split "`r?`n"|Where-Object{-not [string]::IsNullOrWhiteSpace($_)};return [pscustomobject]@{Exe=$launcher.Source;Prefix=@('-'+$minor);Version=$lines[-1]}}}}
    return $null
}
function Invoke-Python([string]$Python,[string[]]$Arguments,[string]$Label) { $res=Invoke-NativeLogged -Executable $Python -Arguments $Arguments -Label $Label -NoticeSeconds 180;if($res.ExitCode -ne 0){throw "$Label failed (exit $($res.ExitCode)). STDERR: $($res.StdErr) | STDOUT: $($res.StdOut)"};return $res }
function Get-Ffmpeg {
    Refresh-UserPath;$cmd=Get-Command ffmpeg.exe -ErrorAction SilentlyContinue;if($cmd){return $cmd.Source}
    $candidates=@((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'),(Join-Path $env:ProgramFiles 'FFmpeg\bin\ffmpeg.exe'),'C:\ffmpeg\bin\ffmpeg.exe')
    foreach($p in $candidates){if(Test-Path -LiteralPath $p -PathType Leaf){return $p}}
    $packages=Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if(Test-Path -LiteralPath $packages -PathType Container){
        $vendorFolders=@(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue)
        foreach($vendorFolder in $vendorFolders){
            $found=Get-ChildItem -LiteralPath $vendorFolder.FullName -Filter 'ffmpeg.exe' -File -Recurse -ErrorAction SilentlyContinue|Select-Object -First 1
            if($found){return $found.FullName}
        }
    }
    return $null
}

$installMutex=[System.Threading.Mutex]::new($false,'Local\LocalAIStudio-Installer')
$ownsInstallMutex=$false
try{$ownsInstallMutex=$installMutex.WaitOne(0)}catch [System.Threading.AbandonedMutexException]{$ownsInstallMutex=$true}
if(-not $ownsInstallMutex){$installMutex.Dispose();try{Stop-Transcript|Out-Null}catch{};throw 'Another LocalAI Studio installer is already running. No second installer was started.'}
try {
    Write-Host 'LOCAL AI - PLATFORM INSTALLER v3.4' -ForegroundColor Cyan
    Write-Host 'Chat platform only. Existing Ollama and Qwen data are reused; no image/video generation stack is installed.'
    try{$version=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 8}catch{throw 'Ollama local API is not responding on 127.0.0.1:11434. Start Ollama first; this installer will not restart it.'}
    Write-Host "[OK] Ollama $($version.version) is responding. Model manager will reuse the configured local Qwen model." -ForegroundColor Green
    $backupCandidates=@(Get-ChildItem -LiteralPath $Platform -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('open-webui.pid','MODEL-STATUS.json')})
    $venv=Join-Path $Platform '.venv';$VenvPython=Join-Path $venv 'Scripts\python.exe';$PythonVersion=$null
    if(Test-Path $VenvPython){$existing=Invoke-NativeLogged -Executable $VenvPython -Arguments @('-c','import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")') -Label 'Check existing project Python';if($existing.ExitCode -eq 0 -and ($existing.StdOut.Trim() -eq '3.11' -or $existing.StdOut.Trim() -eq '3.12')){$PythonVersion=$existing.StdOut.Trim()}else{$backup=Join-Path $Platform ('.venv-backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss'));Write-Host "Existing invalid/incompatible virtualenv will be preserved as $backup" -ForegroundColor Yellow;Move-Item -LiteralPath $venv -Destination $backup}}
    if(-not(Test-Path $VenvPython)){$python=Find-Python;if(-not $python){throw 'Python 3.11 or 3.12 was not found. Install Python 3.11/3.12 from python.org, then rerun.'};$PythonVersion=$python.Version;if($python.Prefix){$venvArgs=@($python.Prefix+@('-m','venv',$venv))}else{$venvArgs=@('-m','venv',$venv)};$null=Invoke-Python $python.Exe $venvArgs 'Create isolated platform virtual environment'}
    if(-not(Test-Path $VenvPython)){throw 'Project virtual environment was not created.'}
    $actual=Invoke-NativeLogged -Executable $VenvPython -Arguments @('-c','import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")') -Label 'Verify virtual environment Python'
    if($actual.ExitCode -ne 0 -or $actual.StdOut -notmatch '^3\.(11|12)\.') {throw 'Project venv is not using supported Python 3.11/3.12.'}
    $PythonVersion=($actual.StdOut -split "`r?`n"|Select-Object -First 1).Trim();Write-Host "[OK] Project venv uses Python $PythonVersion." -ForegroundColor Green
    $env:PIP_CACHE_DIR=Join-Path $Cache 'pip';$env:PIP_PROGRESS_BAR='on';$env:PIP_DISABLE_PIP_VERSION_CHECK='1';$env:PIP_DEFAULT_TIMEOUT='180';$env:PIP_RETRIES='5'
    $env:HF_HOME=Join-Path $Data 'cache\huggingface';$env:HUGGINGFACE_HUB_CACHE=Join-Path $env:HF_HOME 'hub';$env:WHISPER_MODEL_DIR=Join-Path $Data 'cache\whisper\models'
    New-Item -ItemType Directory -Force -Path $env:PIP_CACHE_DIR,$env:HF_HOME,$env:HUGGINGFACE_HUB_CACHE,$env:WHISPER_MODEL_DIR|Out-Null
    $webuiPackage='open-webui=='+$RequiredWebUI
    $webUiProbeCode='import importlib.metadata as md; import open_webui; print("OPEN_WEBUI="+md.version("open-webui"))'
    $webUiProbe=Invoke-NativeLogged -Executable $VenvPython -Arguments @('-c',$webUiProbeCode) -Label 'Check existing Open WebUI package'
    $webUiReady=($webUiProbe.ExitCode -eq 0 -and $webUiProbe.StdOut -match ('OPEN_WEBUI='+[regex]::Escape($RequiredWebUI)) -and (Test-Path -LiteralPath (Join-Path $venv 'Scripts\open-webui.exe') -PathType Leaf))
    if($webUiReady){Write-Host "[OK] Open WebUI $RequiredWebUI already installed; skipping pip bootstrap and large reinstall." -ForegroundColor Green}
    else{
        $null=Invoke-Python $VenvPython @('-m','pip','install','--upgrade','pip','setuptools','wheel','--retries','5','--timeout','180','--disable-pip-version-check') 'Upgrade pip build tools'
        $null=Invoke-Python $VenvPython @('-m','pip','install','--progress-bar','on','--prefer-binary','--retries','5','--timeout','180','--disable-pip-version-check',$webuiPackage) "Install Open WebUI $RequiredWebUI"
    }
    $audioProbeCode='import importlib.util; print("AV_AVAILABLE="+str(importlib.util.find_spec("av") is not None)); print("FASTER_WHISPER_AVAILABLE="+str(importlib.util.find_spec("faster_whisper") is not None))'
    $audioProbe=Invoke-NativeLogged -Executable $VenvPython -Arguments @('-c',$audioProbeCode) -Label 'Inspect optional audio dependencies'
    $audioReady=($audioProbe.ExitCode -eq 0 -and $audioProbe.StdOut -match 'AV_AVAILABLE=True' -and $audioProbe.StdOut -match 'FASTER_WHISPER_AVAILABLE=True')
    if($audioReady){Write-Host '[OK] Optional audio Python modules are already available.' -ForegroundColor Green}
    else{Write-Host '[INFO] Optional audio modules are not installed. They are not required for text chat and will not be installed automatically.' -ForegroundColor DarkGray}
    $null=Invoke-Python $VenvPython @('-m','pip','check') 'Check Python dependency consistency'
    $probeCode='import open_webui; from importlib.metadata import version; print("OPEN_WEBUI="+version("open-webui"))'
    $probe=Invoke-NativeLogged -Executable $VenvPython -Arguments @('-c',$probeCode) -Label 'Verify Open WebUI core imports'
    if($probe.ExitCode -ne 0 -or $probe.StdOut -notmatch 'OPEN_WEBUI=0\.13\.5'){throw 'Open WebUI core import verification failed. See the probe log.'}
    $OpenWebUIExe=Join-Path $venv 'Scripts\open-webui.exe';if(-not(Test-Path $OpenWebUIExe)){throw 'open-webui.exe is missing after package installation.'}
    $FfmpegExe=Get-Ffmpeg
    if(-not $FfmpegExe){Write-Host '[INFO] FFmpeg is not installed. It is optional for text chat; no package manager install will be started.' -ForegroundColor DarkGray}
    if($FfmpegExe){$ffmpegDir=Split-Path -Parent $FfmpegExe;if(($env:Path -split ';') -notcontains $ffmpegDir){$env:Path=$ffmpegDir+';'+$env:Path};Set-Content -Path (Join-Path $Platform 'ffmpeg-path.txt') -Value $FfmpegExe -Encoding UTF8;$ff=Invoke-NativeLogged -Executable $FfmpegExe -Arguments @('-version') -Label 'Validate existing optional FFmpeg';if($ff.ExitCode -ne 0){Write-Host '[WARN] FFmpeg was found but its version command failed; audio features may be unavailable.' -ForegroundColor Yellow}else{$FfmpegLine=($ff.StdOut -split "`r?`n"|Select-Object -First 1);Write-Host "[OK] $FfmpegLine" -ForegroundColor Green}}
    $secret=Join-Path $Platform 'Secrets\webui_secret_key.txt'
    if(-not(Test-Path $secret)){$bytes=New-Object byte[] 48;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();$rng.GetBytes($bytes);$rng.Dispose();[IO.File]::WriteAllText($secret,([BitConverter]::ToString($bytes)-replace '-','').ToLowerInvariant())}
    $account=[Security.Principal.WindowsIdentity]::GetCurrent().Name;$icacls=Get-Command icacls.exe -ErrorAction Stop
    $acl=Invoke-NativeLogged -Executable $icacls.Source -Arguments @($secret,'/inheritance:r','/grant:r',($account+':(F)'),'SYSTEM:(F)') -Label 'Protect WebUI signing key'
    if($acl.ExitCode -ne 0){$null=$Warnings.Add('Could not restrict signing-key ACL. Review Windows folder permissions.')}
    # Backup only files explicitly managed by the package manifest; never back up or overwrite Data/Models.
    Backup-ManagedPlatformFiles
    # Do not delete files outside the current package manifest. Older helper files may be user-modified.
    $sourceFilters=Join-Path $PSScriptRoot 'Filters'
    if([IO.Path]::GetFullPath($sourceFilters) -ne [IO.Path]::GetFullPath($FilterDir)){New-Item -ItemType Directory -Force -Path $FilterDir|Out-Null;Copy-Item -Path (Join-Path $sourceFilters '*.py') -Destination $FilterDir -Force}
    $runtimeFiles=@('SETUP-LOCALAI.bat','SETUP-LOCALAI.ps1','LAUNCH-LOCALAI-APP.ps1','TEST-MODEL-INTEGRITY.ps1','TEST-PLATFORM-BACKUP.ps1','TEST-FILTER-POLICY.py','TEST-RELEASE.py','LocalAI-Studio.bat','START-CHAT.ps1','STOP-CHAT.ps1','REPAIR-AND-RESUME.ps1','INSTALL-PLATFORM.ps1','CHECK-LOCALAI.ps1','VERIFY-MODEL.ps1','VERIFY-PACKAGE.ps1','IMPORT-FILTERS.ps1','RESTORE-OPENWEBUI-STYLE.ps1','LOCALAI-STUDIO-THEME.css','TEST-FILTERS.py','README-AR.md','CHANGELOG-AR.md','TEST-REPORT-AR.txt','MANIFEST-SHA256.txt','ENSURE-MODELS.ps1','MODELS.json','WHISPER-MODEL-MANAGER.py','TEST-MODEL-MANAGER.py','TEST-WINDOWS-PROCESS-LAUNCH.ps1')
    foreach($fileName in $runtimeFiles){$sourceFile=Join-Path $PSScriptRoot $fileName;if(-not(Test-Path -LiteralPath $sourceFile -PathType Leaf)){throw "Required project file is missing: $fileName"};$targetFile=Join-Path $Platform $fileName;if([IO.Path]::GetFullPath($sourceFile) -ne [IO.Path]::GetFullPath($targetFile)){Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force}}
    $sourceAssets=Join-Path $PSScriptRoot 'Assets';$targetAssets=Join-Path $Platform 'Assets';if((Test-Path -LiteralPath $sourceAssets -PathType Container) -and [IO.Path]::GetFullPath($sourceAssets) -ne [IO.Path]::GetFullPath($targetAssets)){New-Item -ItemType Directory -Force -Path $targetAssets|Out-Null;Copy-Item -Path (Join-Path $sourceAssets '*.ico') -Destination $targetAssets -Force}
    $releaseTest=Invoke-NativeLogged -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-RELEASE.py')) -Label 'Run release integrity and desktop-app contract tests';if($releaseTest.ExitCode -ne 0){throw 'Release contract tests failed.'}
    $filterTest=Invoke-NativeLogged -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-FILTERS.py'),'--filters-dir',$FilterDir) -Label 'Run filter syntax and behavior tests'
    if($filterTest.ExitCode -ne 0 -or $filterTest.StdOut -notmatch 'FILTER_TESTS: SUCCESS'){throw 'Filter tests did not pass. See filter-test log.'}
    $policyTest=Invoke-NativeLogged -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-FILTER-POLICY.py')) -Label 'Test optional reasoning and model-download policies'
    if($policyTest.ExitCode -ne 0){throw 'Filter/model policy tests failed.'}
    $integrityTest=Invoke-NativeLogged -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Platform 'TEST-MODEL-INTEGRITY.ps1')) -Label 'Test Qwen local blob integrity (scratch files only)'
    if($integrityTest.ExitCode -ne 0){throw 'Qwen model integrity tests failed.'}
    $backupTest=Invoke-NativeLogged -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Platform 'TEST-PLATFORM-BACKUP.ps1')) -Label 'Test platform backup and rollback (temporary files only)'
    if($backupTest.ExitCode -ne 0){throw 'Platform backup/rollback tests failed.'}
    $modelUnitTest=Invoke-NativeLogged -Executable $VenvPython -Arguments @((Join-Path $Platform 'TEST-MODEL-MANAGER.py')) -Label 'Run offline Whisper model-manager tests'
    if($modelUnitTest.ExitCode -ne 0){throw 'Whisper model-manager tests failed. See test log.'}
    $launchRegression=Invoke-NativeLogged -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $Platform 'TEST-WINDOWS-PROCESS-LAUNCH.ps1')) -Label 'Test Windows paths containing spaces'
    if($launchRegression.ExitCode -ne 0){throw 'Windows process path regression test failed.'}
    $modelManager=Join-Path $Platform 'ENSURE-MODELS.ps1'
    $modelCheck=Invoke-NativeLogged -Executable (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$modelManager) -Label 'Verify existing Qwen model; Whisper remains optional' -NoticeSeconds 180
    if($modelCheck.ExitCode -ne 0){throw 'Required Qwen model could not be verified. See MODEL-STATUS.txt.'}
    $engineStatus=Get-Content -LiteralPath (Join-Path $Platform 'MODEL-STATUS.json') -Raw -Encoding UTF8|ConvertFrom-Json
    foreach($modelWarning in @($engineStatus.warnings)){if(-not [string]::IsNullOrWhiteSpace([string]$modelWarning)){$null=$Warnings.Add([string]$modelWarning)}}
    $ModelId=[string]$engineStatus.ollama.tag;if(-not $ModelId){throw 'Model manager returned success without a Qwen tag.'}
    if($engineStatus.whisper.status -eq 'not_requested'){Write-Host '[INFO] Whisper skipped intentionally; text chat remains ready.' -ForegroundColor DarkGray}
    elseif($engineStatus.whisper.status -ne 'ready'){$null=$Warnings.Add("Whisper $($engineStatus.whisper.model) is not ready; text chat remains available. Use ENSURE-MODELS.ps1 -RequireWhisper when audio is needed.")}
    $status=if($Warnings.Count -gt 0){'SUCCESS_WITH_WARNINGS'}else{'SUCCESS'};$warningText=if($Warnings.Count -gt 0){$Warnings -join "`r`n- "}else{'None'}
    @"
STATUS: $status
Open WebUI: $RequiredWebUI
Python: $PythonVersion
Ollama URL: http://127.0.0.1:11434
Verified model tag: $ModelId
Platform: $Platform
Data: $Data
Open WebUI executable: $OpenWebUIExe
Optional audio imports ready: $audioReady
FFmpeg: $FfmpegExe
Whisper status: $($engineStatus.whisper.status)
Filter sources copied: 3; syntax and behavior tests passed
Web search: ENABLE_WEB_SEARCH=true; WEB_SEARCH_ENGINE=duckduckgo; DDGS_BACKEND=auto
Network scope: localhost only (127.0.0.1:8080)
Warnings:
- $warningText
Installer log: $LogFile
Ollama was not restarted or reinstalled. Existing Qwen was reused if present. Automatic Qwen download is disabled by default.
"@ | Set-Content -Path $StatusFile -Encoding UTF8
    @"
STATUS: $status
Ollama: $($version.version)
Model: $ModelId
Open WebUI: $RequiredWebUI
Platform: $Platform
Warnings: $warningText
Completed: $(Get-Date -Format o)
"@ | Set-Content -Path $FullStatusFile -Encoding UTF8
    Write-Host "`nPLATFORM INSTALLATION $status" -ForegroundColor Green
    Write-Host "Open WebUI: $RequiredWebUI; Model: $ModelId; Python: $PythonVersion"
    Write-Host "Status: $StatusFile";Write-Host "Log: $LogFile"
    if($Warnings.Count -gt 0){Write-Host 'Warnings:' -ForegroundColor Yellow;foreach($w in $Warnings){Write-Host (' - '+$w) -ForegroundColor Yellow}}
    Write-Host 'Next: click the LocalAI Studio desktop shortcut. It opens the chat in an app window.' -ForegroundColor Cyan
} catch {
    $msg=$_.Exception.Message;$Failures.Add($msg)
    @"
STATUS: FAILED
Error: $msg
Installer log: $LogFile
Existing Ollama/Qwen model files were not intentionally deleted or modified.
"@ | Set-Content -Path $StatusFile -Encoding UTF8
    @"
STATUS: FAILED
Error: $msg
Completed: $(Get-Date -Format o)
"@ | Set-Content -Path $FullStatusFile -Encoding UTF8
    Write-Host "`nPLATFORM INSTALLATION FAILED: $msg" -ForegroundColor Red
    Write-Host "Read the newest platform-continuation log in $Logs" -ForegroundColor Yellow
    try { Restore-ManagedPlatformFiles } catch { Write-Host "[ROLLBACK FAILED] $($_.Exception.Message). Backup retained at: $script:BackupRoot" -ForegroundColor Red }
    exit 1
} finally {
    if ($script:KeepAwakeEnabled -and ('LocalAI.PowerManagement' -as [type])) { [void][LocalAI.PowerManagement]::SetThreadExecutionState([Convert]::ToUInt32('2147483648')) }
    try { Stop-Transcript | Out-Null } catch {}
    if($ownsInstallMutex -and $installMutex){try{$installMutex.ReleaseMutex()}catch{}}
    if($installMutex){$installMutex.Dispose()}
}
