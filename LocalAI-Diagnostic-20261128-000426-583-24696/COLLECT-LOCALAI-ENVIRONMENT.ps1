#requires -Version 5.1
<#
LocalAI Creative Studio - Read-only environment and model inventory
- Does not install, uninstall, move, rename, modify, or delete existing applications or models.
- Only writes its own report files into a new timestamped folder on the Desktop (or TEMP fallback).
- Makes read-only HTTP GET requests to localhost Ollama/ComfyUI endpoints.
- Model files are inventoried by path/size/date only; contents are never opened or hashed.
#>
[CmdletBinding()]
param(
    [int]$MaxDiscoveryDirectories = 5000,
    [int]$MaxModelDirectories = 20000,
    [int]$MaxModelFiles = 30000
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:OutDir = $null
$script:Stage = 'initialization'

# Preserve a useful failure report instead of exposing only a generic PowerShell exception.
trap {
    $fatalRecord = $_
    $fatalLines = @(
        ('Stage: {0}' -f $script:Stage)
        ('Message: {0}' -f $fatalRecord.Exception.Message)
        ('Category: {0}' -f $fatalRecord.CategoryInfo)
        ('Line: {0}' -f $fatalRecord.InvocationInfo.ScriptLineNumber)
        ('Position: {0}' -f $fatalRecord.InvocationInfo.PositionMessage)
        ('ScriptStackTrace: {0}' -f $fatalRecord.ScriptStackTrace)
        ('Exception: {0}' -f $fatalRecord.Exception.ToString())
    )
    if ($script:OutDir -and (Test-Path -LiteralPath $script:OutDir -PathType Container)) {
        try { Set-Content -LiteralPath (Join-Path $script:OutDir 'FATAL-ERROR.txt') -Value $fatalLines -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
        try {
            $partialZip = "$script:OutDir.zip"
            Get-ChildItem -LiteralPath $script:OutDir -File -Force | Compress-Archive -DestinationPath $partialZip -CompressionLevel Optimal -Force -ErrorAction Stop
        } catch { }
    }
    Write-Host ''
    Write-Host 'DIAGNOSTIC COLLECTION FAILED' -ForegroundColor Red
    Write-Host ('Stage: {0}' -f $script:Stage) -ForegroundColor Yellow
    Write-Host ('Error: {0}' -f $fatalRecord.Exception.Message) -ForegroundColor Red
    Write-Host ('Line: {0}' -f $fatalRecord.InvocationInfo.ScriptLineNumber) -ForegroundColor Yellow
    if ($fatalRecord.ScriptStackTrace) { Write-Host $fatalRecord.ScriptStackTrace -ForegroundColor DarkYellow }
    if ($script:OutDir) { Write-Host ('Partial report: {0}' -f $script:OutDir) -ForegroundColor Yellow }
    exit 1
}
$script:Issues = New-Object System.Collections.Generic.List[string]
$script:PathRows = New-Object System.Collections.Generic.List[object]
$script:ModelRows = New-Object System.Collections.Generic.List[object]
$script:PythonRows = New-Object System.Collections.Generic.List[object]
$script:EngineRows = New-Object System.Collections.Generic.List[object]
$script:AppRows = New-Object System.Collections.Generic.List[object]
$script:ComfyRoots = New-Object System.Collections.Generic.List[string]
$script:StudioRoots = New-Object System.Collections.Generic.List[string]
$script:ModelRoots = New-Object System.Collections.Generic.List[string]
$script:ExtraConfigRows = New-Object System.Collections.Generic.List[object]
$script:EventRows = New-Object System.Collections.Generic.List[object]
$script:LogRows = New-Object System.Collections.Generic.List[object]
$script:PortRows = New-Object System.Collections.Generic.List[object]
$script:Notes = New-Object System.Collections.Generic.List[string]

function Add-Issue([string]$Message) {
    if ($Message) { [void]$script:Issues.Add($Message) }
}
function Add-PathRow([string]$Kind, [string]$Path, [string]$Status, [string]$Details) {
    if ($Path) {
        [void]$script:PathRows.Add([pscustomobject]@{
            Kind = $Kind; Path = $Path; Exists = (Test-Path -LiteralPath $Path)
            Status = $Status; Details = $Details
        })
    }
}
function Get-SafeProperty($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}
function Resolve-ExistingPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"').Trim("'"))
        if (Test-Path -LiteralPath $expanded) { return (Get-Item -LiteralPath $expanded -Force -ErrorAction Stop).FullName }
    } catch { }
    return $null
}
function Add-UniqueString($List, [string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $v = $Value.Trim()
        if ($v -notmatch '^[A-Za-z]:\\$') { $v = $v.TrimEnd('\') }
        if (-not ($List | Where-Object { $_ -ieq $v })) { [void]$List.Add($v) }
    }
}
function Invoke-LocalGet([string]$Uri, [int]$TimeoutSec = 3) {
    try {
        return Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    } catch { return $null }
}
function Invoke-ReadOnlyProcess([string]$FilePath, [string]$Arguments, [int]$TimeoutSec = 12) {
    $result = [ordered]@{ FilePath=$FilePath; Arguments=$Arguments; Started=$false; TimedOut=$false; ExitCode=$null; StdOut=''; StdErr=''; Error=$null }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { $result.Error = 'Executable not found'; return [pscustomobject]$result }
    $process = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $result.Started = $process.Start()
        if (-not $result.Started) { $result.Error = 'Process.Start returned false'; return [pscustomobject]$result }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $result.TimedOut = $true
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
        }
        $result.ExitCode = $process.ExitCode
        $result.StdOut = [string]$outTask.Result
        $result.StdErr = [string]$errTask.Result
    } catch {
        $result.Error = $_.Exception.Message
        if ($process -and $process.HasExited) { try { $result.ExitCode = $process.ExitCode } catch { } }
    } finally { if ($process) { $process.Dispose() } }
    return [pscustomobject]$result
}
function Add-RegistryPythonCandidates([System.Collections.Generic.List[string]]$List) {
    $keys = @(
        'HKCU:\Software\Python\PythonCore\*\InstallPath',
        'HKLM:\Software\Python\PythonCore\*\InstallPath',
        'HKLM:\Software\WOW6432Node\Python\PythonCore\*\InstallPath'
    )
    foreach ($key in $keys) {
        try {
            Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | ForEach-Object {
                $p = $_.ExecutablePath
                if (-not $p) {
                    try {
                        $regPath = 'Registry::' + ($_.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::','')
                        $regItem = Get-Item -LiteralPath $regPath -ErrorAction Stop
                        $installDir = [string]$regItem.GetValue('')
                        if ($installDir) { $p = Join-Path $installDir 'python.exe' }
                    } catch { }
                }
                if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { Add-UniqueString $List $p }
            }
        } catch { Add-Issue "Python registry lookup: $($_.Exception.Message)" }
    }
}
function Test-PythonCandidate([string]$Exe) {
    $probe = "import sys,struct,ssl,sqlite3,ctypes,venv,ensurepip,json,importlib.util; print(json.dumps({'executable':sys.executable,'version':sys.version,'bits':struct.calcsize('P')*8,'prefix':sys.prefix,'base_prefix':sys.base_prefix,'openssl':ssl.OPENSSL_VERSION,'sqlite':sqlite3.sqlite_version,'pip':importlib.util.find_spec('pip') is not None}))"
    $arg = '-I -c "' + $probe + '"'
    $r = Invoke-ReadOnlyProcess -FilePath $Exe -Arguments $arg -TimeoutSec 18
    $version = $null; $bits = $null; $hasPip = $false; $details = $r.StdOut.Trim()
    if ($r.ExitCode -eq 0 -and $r.StdOut) {
        try { $parsed = $r.StdOut.Trim() | ConvertFrom-Json; $version = $parsed.version; $bits = $parsed.bits; $hasPip = [bool]$parsed.pip } catch { }
    }
    [void]$script:PythonRows.Add([pscustomobject]@{
        Executable=$Exe; Exists=(Test-Path -LiteralPath $Exe -PathType Leaf); ExitCode=$r.ExitCode
        TimedOut=$r.TimedOut; Version=$version; Bits=$bits; PipAvailable=$hasPip; ProbeJson=$details
        StdErr=$r.StdErr.Trim(); Error=$r.Error
        Passed=($r.ExitCode -eq 0 -and $bits -eq 64 -and $hasPip -and $version -match '^3\.(11|12|13|14)\.')
    })
}
function Add-DirectoryTree([string]$Root, [int]$MaxDepth, [int]$MaxDirs, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{Path=(Get-Item -LiteralPath $Root -Force).FullName;Depth=0})
    $seen = 0
    while ($queue.Count -gt 0 -and $seen -lt $MaxDirs) {
        $node = $queue.Dequeue(); $seen++
        $dir = $node.Path
        try {
            $di = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $children = Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($child.Name -match '^(Windows|WinSxS|System Volume Information|\$Recycle\.Bin|ProgramData|node_modules|\.git|\.cache|Cache|Caches|Temp|tmp)$') { continue }
                if ($Kind -eq 'Discovery') {
                    if ($child.Name -match '(?i)(ComfyUI|LocalAI|Creative.?Studio|Open.?WebUI|stable.?diffusion|automatic1111|sd.?webui|Fooocus|Forge|Ollama)') {
                        Add-UniqueString $script:DiscoveredFolders $child.FullName
                    }
                }
                if ($node.Depth + 1 -lt $MaxDepth) { $queue.Enqueue([pscustomobject]@{Path=$child.FullName;Depth=$node.Depth+1}) }
            }
            if ($Kind -eq 'Discovery') {
                if ((Test-Path -LiteralPath (Join-Path $dir 'main.py') -PathType Leaf) -and ((Split-Path $dir -Leaf) -match '(?i)ComfyUI|Comfy')) { Add-UniqueString $script:DiscoveredFolders $dir }
                if ((Test-Path -LiteralPath (Join-Path $dir 'ComfyUI\main.py') -PathType Leaf) -and ((Split-Path $dir -Leaf) -match '(?i)portable|Comfy')) { Add-UniqueString $script:DiscoveredFolders $dir }
                if ((Test-Path -LiteralPath (Join-Path $dir 'studio\app.py') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $dir 'VERSION'))) { Add-UniqueString $script:DiscoveredFolders $dir }
            }
        } catch { }
    }
    if ($queue.Count -gt 0) { Add-Issue "Directory discovery cap reached under $Root ($MaxDirs examined)." }
}
function Add-ModelFilesFromRoot([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    Add-UniqueString $script:ModelRoots $Root
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{Path=(Get-Item -LiteralPath $Root -Force).FullName;Depth=0})
    $seenDirs = 0; $found = 0
    $extensions = @('.safetensors','.ckpt','.pt','.pth','.bin','.gguf','.ggml','.onnx','.engine','.tflite','.pb','.weights','.model')
    while ($queue.Count -gt 0 -and $seenDirs -lt $MaxModelDirectories -and $found -lt $MaxModelFiles) {
        $node = $queue.Dequeue(); $seenDirs++
        try {
            $di = Get-Item -LiteralPath $node.Path -Force -ErrorAction Stop
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $node.Path -File -Force -ErrorAction SilentlyContinue)) {
                if ($extensions -contains $f.Extension.ToLowerInvariant()) {
                    [void]$script:ModelRows.Add([pscustomobject]@{Root=$Root;Path=$f.FullName;Name=$f.Name;Extension=$f.Extension;SizeBytes=[int64]$f.Length;SizeGB=[math]::Round($f.Length/1GB,3);LastWriteTime=$f.LastWriteTime})
                    $found++
                    if ($found -ge $MaxModelFiles) { break }
                }
            }
            if ($node.Depth -lt 14) {
                foreach ($d in (Get-ChildItem -LiteralPath $node.Path -Directory -Force -ErrorAction SilentlyContinue)) {
                    if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if ($d.Name -match '^(\.git|__pycache__|node_modules|\.cache|temp|tmp|venv|\.venv)$') { continue }
                    $queue.Enqueue([pscustomobject]@{Path=$d.FullName;Depth=$node.Depth+1})
                }
            }
        } catch { }
    }
    if ($queue.Count -gt 0) { Add-Issue "Model scan limit reached under $Root (files=$found, directories=$seenDirs)." }
}

# Output destination: a new report folder only.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop -PathType Container)) { $desktop = $env:TEMP }
$script:OutDir = Join-Path $desktop "LocalAI-Diagnostic-$stamp-$PID"
New-Item -ItemType Directory -Path $script:OutDir -Force | Out-Null
$script:StartTime = Get-Date

Write-Host ''
Write-Host 'LOCALAI CREATIVE STUDIO - READ-ONLY DIAGNOSTICS' -ForegroundColor Cyan
Write-Host 'No existing app, model, configuration, or shortcut will be modified.'
Write-Host "Report folder: $script:OutDir"

$script:Stage = 'system and drive inventory'
Write-Host '[scan] System and drives...'
# System and drives.
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{Name=$_.Name;DriverVersion=$_.DriverVersion;DriverDate=$_.DriverDate;AdapterRAM=$_.AdapterRAM} })
$drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{Drive=$_.DeviceID;FileSystem=$_.FileSystem;SizeGB=if ($_.Size) {[math]::Round($_.Size/1GB,2)} else {$null};FreeGB=if ($_.FreeSpace) {[math]::Round($_.FreeSpace/1GB,2)} else {$null};VolumeName=$_.VolumeName} })

# PATH entries and specifically relevant environment variables only (never dump the full environment).
$pathEntries = @($env:Path -split ';' | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_)} })
$relevantEnvNames = @('LOCALAPPDATA','APPDATA','USERPROFILE','PROGRAMFILES','PROGRAMFILES(X86)','ProgramW6432','TEMP','TMP','OLLAMA_MODELS','OLLAMA_HOST','COMFYUI_ROOT','COMFYUI_PATH','LOCALAI_STUDIO_DATA','LOCALAI_DATA_DIR','PYTHONHOME','PYTHONPATH','PYTHONUSERBASE','VIRTUAL_ENV')
$relevantEnv = @{}
foreach ($n in $relevantEnvNames) { $v=[Environment]::GetEnvironmentVariable($n,'Process'); if ($v) { $relevantEnv[$n]=$v } }

$script:Stage = 'Python discovery and isolated probes'
Write-Host '[scan] Python candidates...'
# Python command resolution and registry installs.
$pythonCandidates = New-Object System.Collections.Generic.List[string]
Add-RegistryPythonCandidates $pythonCandidates
foreach ($cmdName in @('python.exe','python3.exe','py.exe')) {
    try { Get-Command $cmdName -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Source) { Add-UniqueString $pythonCandidates $_.Source } } } catch { }
}
$knownPython = @(
    (Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime\Python314-LocalAI\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime\Python314\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
    'D:\LocalAI\CreativeStudioData\runtime\Python314\python.exe',
    'D:\LocalAI\CreativeStudioData\runtime\Python313\python.exe'
)
foreach ($p in $knownPython) { if (Test-Path -LiteralPath $p -PathType Leaf) { Add-UniqueString $pythonCandidates $p } }
$pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pyLauncher -and $pyLauncher.Source) {
    $pyList = Invoke-ReadOnlyProcess -FilePath $pyLauncher.Source -Arguments '-0p' -TimeoutSec 10
    if ($pyList.StdOut) {
        Set-Content -LiteralPath (Join-Path $script:OutDir 'PY-LAUNCHER-LIST.txt') -Value $pyList.StdOut -Encoding UTF8
        foreach ($match in [regex]::Matches($pyList.StdOut,'(?im)([A-Z]:\\[^\r\n]*?pythonw?\.exe)')) { Add-UniqueString $pythonCandidates $match.Groups[1].Value.Trim() }
    }
}
foreach ($exe in $pythonCandidates) {
    if ($exe -match '(?i)\\Microsoft\\WindowsApps\\python(?:3)?\.exe$') {
        [void]$script:PythonRows.Add([pscustomobject]@{Executable=$exe;Exists=$true;ExitCode=$null;TimedOut=$false;Version=$null;Bits=$null;PipAvailable=$false;ProbeJson=$null;StdErr=$null;Error='Microsoft Store execution alias; intentionally not launched during diagnostics.';Passed=$false})
    } else { Test-PythonCandidate $exe }
}

$script:Stage = 'bounded application directory discovery'
Write-Host '[scan] Application folders...'
# Locate installations by bounded directory discovery. No whole-disk file-content search.
$script:DiscoveredFolders = New-Object System.Collections.Generic.List[string]
$searchRoots = New-Object System.Collections.Generic.List[string]
foreach ($p in @(
    (Join-Path $env:LOCALAPPDATA 'Programs'),$env:APPDATA,$env:LOCALAPPDATA,
    (Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Downloads'),(Join-Path $env:USERPROFILE 'Documents'),
    'C:\AI','C:\LocalAI','C:\ComfyUI','D:\AI','D:\LocalAI','D:\ComfyUI','D:\StableDiffusion','E:\AI','E:\LocalAI','E:\ComfyUI'
)) { if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { Add-UniqueString $searchRoots $p } }
# Also inspect only the first-level folders of non-system fixed drives; bounded traversal below.
foreach ($d in $drives) {
    $root = "$($d.Drive)\"
    try {
        foreach ($child in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($child.Name -match '(?i)(AI|LocalAI|Comfy|Stable|Studio|Models|Apps|Tools|Downloads|Generative|Diffusion)') { Add-UniqueString $searchRoots $child.FullName }
        }
    } catch { }
}
foreach ($root in $searchRoots) { Add-DirectoryTree -Root $root -MaxDepth 4 -MaxDirs ([math]::Max(100,[int]($MaxDiscoveryDirectories / [math]::Max(1,$searchRoots.Count)))) -Kind 'Discovery' }

# Classify discovered folders and known locations.
$allPotentialRoots = New-Object System.Collections.Generic.List[string]
foreach ($f in $script:DiscoveredFolders) { Add-UniqueString $allPotentialRoots $f }
foreach ($p in @('D:\LocalAI','C:\LocalAI',(Join-Path $env:LOCALAPPDATA 'LocalAI'),(Join-Path $env:APPDATA 'ComfyUI'),(Join-Path $env:LOCALAPPDATA 'Programs\ComfyUI'),(Join-Path $env:USERPROFILE '.ollama'))) {
    if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { Add-UniqueString $allPotentialRoots $p }
}
foreach ($r in $allPotentialRoots) {
    $leaf = Split-Path $r -Leaf
    if ($leaf -match '(?i)ComfyUI|Comfy|portable|stable.?diffusion|automatic1111|Forge|Fooocus') {
        if ((Test-Path -LiteralPath (Join-Path $r 'main.py')) -or (Test-Path -LiteralPath (Join-Path $r 'ComfyUI\main.py')) -or $leaf -match '(?i)ComfyUI|Comfy|portable') { Add-UniqueString $script:ComfyRoots $r }
    }
    if ((Test-Path -LiteralPath (Join-Path $r 'VERSION')) -and (Test-Path -LiteralPath (Join-Path $r 'studio'))) { Add-UniqueString $script:StudioRoots $r }
    if ($r -match '(?i)LocalAI' -and (Test-Path -LiteralPath (Join-Path $r 'CreativeStudioData'))) { Add-UniqueString $script:StudioRoots (Join-Path $r 'CreativeStudioData') }
}

$script:Stage = 'ComfyUI extra model-path configuration'
Write-Host '[scan] ComfyUI model path configuration...'
# Search for extra_model_paths.yaml within identified ComfyUI roots and common ComfyUI folders.
$extraConfigs = New-Object System.Collections.Generic.List[string]
foreach ($r in $script:ComfyRoots) {
    foreach ($candidate in @((Join-Path $r 'extra_model_paths.yaml'),(Join-Path $r 'ComfyUI\extra_model_paths.yaml'),(Join-Path $r 'user\default\ComfyUI-Manager\config.ini'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Add-UniqueString $extraConfigs $candidate }
    }
}
foreach ($p in @('D:\LocalAI\CreativeStudioData','C:\LocalAI\CreativeStudioData',(Join-Path $env:APPDATA 'ComfyUI'),(Join-Path $env:USERPROFILE 'ComfyUI'))) {
    if (Test-Path -LiteralPath $p -PathType Container) {
        try { Get-ChildItem -LiteralPath $p -Filter 'extra_model_paths.yaml' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Add-UniqueString $extraConfigs $_.FullName } } catch { }
    }
}
foreach ($cfg in $extraConfigs) {
    Add-PathRow 'ComfyUI model-path config' $cfg 'Found' 'Configuration file path only; only path entries are extracted.'
    try {
        $lines = Get-Content -LiteralPath $cfg -ErrorAction Stop
        foreach ($line in $lines) {
            if ($line -match '^\s*([A-Za-z0-9_-]*(?:path|paths|checkpoints|vae|loras|unet|diffusion_models|text_encoders|clip|controlnet|embeddings|upscale_models|checkpoints|model)[A-Za-z0-9_-]*)\s*:\s*(.+?)\s*$') {
                $value = $matches[2].Trim().Trim('"').Trim("'")
                if ($value -and $value -notmatch '^\{') {
                    $expanded = [Environment]::ExpandEnvironmentVariables($value)
                    $resolved = $null
                    if ([IO.Path]::IsPathRooted($expanded)) { $resolved = Resolve-ExistingPath $expanded }
                    else { $resolved = Resolve-ExistingPath (Join-Path (Split-Path $cfg -Parent) $expanded) }
                    [void]$script:ExtraConfigRows.Add([pscustomobject]@{Config=$cfg;Key=$matches[1];ConfiguredPath=$expanded;ResolvedPath=$resolved;Exists=[bool]$resolved})
                    if ($resolved) { Add-UniqueString $script:ModelRoots $resolved }
                }
            }
        }
    } catch { Add-Issue "Could not inspect path entries in $cfg : $($_.Exception.Message)" }
}

$script:Stage = 'model directory and weight-file inventory'
Write-Host '[scan] Model folders and weight files...'
# Candidate model stores. Ollama's blob store is content-addressed; API model names are reported separately.
foreach ($r in $script:ComfyRoots) {
    foreach ($candidate in @((Join-Path $r 'models'),(Join-Path $r 'ComfyUI\models'))) { if (Test-Path -LiteralPath $candidate -PathType Container) { Add-UniqueString $script:ModelRoots $candidate } }
}
foreach ($p in @(
    $env:OLLAMA_MODELS,(Join-Path $env:USERPROFILE '.ollama\models'),(Join-Path $env:LOCALAPPDATA 'Ollama\models'),
    'D:\LocalAI\CreativeStudioData\models','D:\LocalAI\models','C:\LocalAI\models',
    (Join-Path $env:USERPROFILE 'Documents\ComfyUI\models')
)) { if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { Add-UniqueString $script:ModelRoots $p } }
foreach ($root in $script:ModelRoots) { Add-ModelFilesFromRoot $root }

$script:Stage = 'Ollama API and CLI metadata'
Write-Host '[scan] Ollama...'
# Ollama API / CLI.
$ollamaExe = $null
try { $oc = Get-Command ollama.exe -ErrorAction SilentlyContinue | Select-Object -First 1; if ($oc) { $ollamaExe=$oc.Source } } catch { }
if (-not $ollamaExe) {
    foreach ($p in @((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),'C:\Program Files\Ollama\ollama.exe')) { if (Test-Path -LiteralPath $p -PathType Leaf) { $ollamaExe=$p; break } }
}
$ollamaVersion = Invoke-LocalGet 'http://127.0.0.1:11434/api/version'
$ollamaTags = Invoke-LocalGet 'http://127.0.0.1:11434/api/tags'
$ollamaModels = @()
if ($ollamaTags -and $ollamaTags.models) {
    $ollamaModels = @($ollamaTags.models | ForEach-Object { [pscustomobject]@{Name=$_.name;Model=$_.model;SizeBytes=$_.size;SizeGB=if ($_.size) {[math]::Round($_.size/1GB,3)} else {$null};ModifiedAt=$_.modified_at;Digest=$_.digest;Family=$_.details.family;ParameterSize=$_.details.parameter_size;Quantization=$_.details.quantization_level} })
}
$ollamaCli = $null
if ($ollamaExe) { $ollamaCli = Invoke-ReadOnlyProcess -FilePath $ollamaExe -Arguments 'list' -TimeoutSec 15 }
[void]$script:EngineRows.Add([pscustomobject]@{Engine='Ollama';Executable=$ollamaExe;ApiResponding=[bool]$ollamaVersion;Version=if ($ollamaVersion) {$ollamaVersion.version} else {$null};ModelCount=$ollamaModels.Count;Models=$ollamaModels;CliExitCode=if ($ollamaCli) {$ollamaCli.ExitCode} else {$null};CliOutput=if ($ollamaCli) {$ollamaCli.StdOut.Trim()} else {$null}})
if ($ollamaModels.Count -gt 0) { $ollamaModels | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:OutDir 'OLLAMA-MODELS.json') -Encoding UTF8 }

$script:Stage = 'ComfyUI local status endpoint'
Write-Host '[scan] ComfyUI...'
# ComfyUI local endpoint. Do not query prompt history or queue payloads.
$comfyStats = Invoke-LocalGet 'http://127.0.0.1:8188/system_stats'
[void]$script:EngineRows.Add([pscustomobject]@{Engine='ComfyUI';DetectedRoots=$script:ComfyRoots.ToArray();ApiResponding=[bool]$comfyStats;Api='http://127.0.0.1:8188/system_stats';SystemStats=if ($comfyStats) {$comfyStats} else {$null}})

$script:Stage = 'running processes and listening ports'
Write-Host '[scan] Processes and local ports...'
# Relevant running processes: executable paths only, never command lines/arguments.
$relevantProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)python|ollama|comfy|open.?webui|docker|node|localai' } | ForEach-Object { [pscustomobject]@{Name=$_.Name;ProcessId=$_.ProcessId;ExecutablePath=$_.ExecutablePath;ParentProcessId=$_.ParentProcessId} })

# Known listener ports without exposing network connections outside localhost.
try {
    $listen = Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -in @(3000,5000,7860,8000,8080,8188,11434) }
    foreach ($c in $listen) {
        $procName = $null
        try { $procName=(Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { }
        [void]$script:PortRows.Add([pscustomobject]@{Address=$c.LocalAddress;Port=$c.LocalPort;ProcessId=$c.OwningProcess;ProcessName=$procName})
    }
} catch { Add-Issue "Could not inspect listening ports: $($_.Exception.Message)" }

# Installed application metadata from uninstall registry; no uninstall strings are collected.
$uninstallKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
foreach ($key in $uninstallKeys) {
    try {
        Get-ItemProperty -Path $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '(?i)Python|Ollama|ComfyUI|LocalAI|Open WebUI|Stable Diffusion|Visual C\+\+' } | ForEach-Object {
            [void]$script:AppRows.Add([pscustomobject]@{DisplayName=$_.DisplayName;DisplayVersion=$_.DisplayVersion;Publisher=$_.Publisher;InstallLocation=$_.InstallLocation;RegistryKey=$_.PSPath})
        }
    } catch { }
}

$script:Stage = 'application logs and Windows crash events'
Write-Host '[scan] Relevant logs and recent crash events...'
# Capture only safe metadata and targeted error tails from the Studio logs (if present).
$logDirs = New-Object System.Collections.Generic.List[string]
foreach ($p in @('D:\LocalAI\CreativeStudioData\logs','C:\LocalAI\CreativeStudioData\logs',(Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioData\logs'))) { if (Test-Path -LiteralPath $p -PathType Container) { Add-UniqueString $logDirs $p } }
foreach ($sd in $script:StudioRoots) { if ((Split-Path $sd -Leaf) -eq 'CreativeStudioData') { $ld=Join-Path $sd 'logs'; if (Test-Path -LiteralPath $ld -PathType Container) { Add-UniqueString $logDirs $ld } } else { $ld=Join-Path $sd 'logs'; if (Test-Path -LiteralPath $ld -PathType Container) { Add-UniqueString $logDirs $ld } } }
$logOutput = New-Object System.Collections.Generic.List[string]
foreach ($ld in $logDirs) {
    try {
        Get-ChildItem -LiteralPath $ld -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(python-runtime|desktop-setup|desktop-update).*\.log$' } | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object {
            [void]$script:LogRows.Add([pscustomobject]@{Path=$_.FullName;SizeBytes=$_.Length;LastWriteTime=$_.LastWriteTime})
            $logOutput.Add("`r`n===== $($_.FullName) (last 100 lines) =====")
            try { (Get-Content -LiteralPath $_.FullName -Tail 100 -ErrorAction Stop) | ForEach-Object { $logOutput.Add($_) } } catch { $logOutput.Add("[READ ERROR] $($_.Exception.Message)") }
        }
    } catch { Add-Issue "Log inspection failed under $ld : $($_.Exception.Message)" }
}
if ($logOutput.Count -gt 0) { Set-Content -LiteralPath (Join-Path $script:OutDir 'RELEVANT-LOG-TAILS.txt') -Value $logOutput.ToArray() -Encoding UTF8 }

# Recent Windows application-crash records may identify the Python faulting module.
try {
    $since = (Get-Date).AddDays(-3)
    $events = Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$since} -MaxEvents 250 -ErrorAction Stop | Where-Object { $_.ProviderName -match 'Application Error|Windows Error Reporting|SideBySide' -and $_.Message -match '(?i)python|ollama|comfy|LocalAI' } | Select-Object -First 25
    foreach ($e in $events) {
        $msg = [string]$e.Message
        if ($msg.Length -gt 2500) { $msg = $msg.Substring(0,2500) + ' ...[truncated]' }
        [void]$script:EventRows.Add([pscustomobject]@{TimeCreated=$e.TimeCreated;Provider=$e.ProviderName;EventId=$e.Id;Message=$msg})
    }
} catch { Add-Issue "Could not read recent Application event log: $($_.Exception.Message)" }

$script:Stage = 'assemble and write report files'
Write-Host '[write] Building inventory files...'
# Build the final path inventory.
foreach ($p in $searchRoots) { Add-PathRow 'Search root' $p 'Scanned (bounded)' 'Only directory names were inspected within bounded depth.' }
foreach ($p in $script:ComfyRoots) { Add-PathRow 'ComfyUI root candidate' $p 'Candidate' 'Check main.py and models subfolder in the map.' }
foreach ($p in $script:StudioRoots) { Add-PathRow 'LocalAI/Studio/Data root candidate' $p 'Candidate' 'Detected by folder name or known data path.' }
foreach ($p in $script:ModelRoots) { Add-PathRow 'Model directory' $p 'Scanned for model file metadata' 'File contents were not read.' }
foreach ($p in $pythonCandidates) { Add-PathRow 'Python executable candidate' $p 'Probed in isolated mode' 'No packages were installed and no runtime was changed.' }
if ($ollamaExe) { Add-PathRow 'Ollama executable' $ollamaExe 'Found' 'Executable path only.' }

# Focused project/config inventory: file metadata only, never file contents.
$projectFileRows = New-Object System.Collections.Generic.List[object]
$projectScanRoots = New-Object System.Collections.Generic.List[string]
foreach ($r in $script:StudioRoots) { Add-UniqueString $projectScanRoots $r }
foreach ($r in $script:ComfyRoots) { Add-UniqueString $projectScanRoots $r }
foreach ($r in $projectScanRoots) {
    $folderTargets = @($r,(Join-Path $r 'scripts'),(Join-Path $r 'studio'),(Join-Path $r 'tests'),(Join-Path $r 'config'),(Join-Path $r 'workflows'),(Join-Path $r 'user'),(Join-Path $r 'downloads'),(Join-Path $r 'runtime'),(Join-Path $r 'logs'),(Join-Path $r 'database'),(Join-Path $r 'db'),(Join-Path $r 'models'),(Join-Path $r 'media'),(Join-Path $r 'outputs'))
    foreach ($folder in $folderTargets) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            try {
                Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Extension -match '(?i)^\.(py|ps1|bat|cmd|vbs|json|ya?ml|toml|ini|md|txt|css|html|js|db|sqlite|sqlite3|log)$' -or $_.Name -match '^(VERSION|Manifest|requirements.*|package.*|Dockerfile)$'
                } | ForEach-Object {
                    [void]$projectFileRows.Add([pscustomobject]@{Root=$r;Path=$_.FullName;Name=$_.Name;Extension=$_.Extension;SizeBytes=[int64]$_.Length;LastWriteTime=$_.LastWriteTime})
                }
            } catch { }
        }
    }
}
$projectFileRows | Sort-Object Root,Path -Unique | Export-Csv -LiteralPath (Join-Path $script:OutDir 'PROJECT-AND-CONFIG-FILES.csv') -NoTypeInformation -Encoding UTF8

# Data bundle: redact no actual filesystem paths because they are the purpose of this report.
# Windows PowerShell 5.1 can throw 'Argument types do not match' for @() over New-Object List[object].
# Use .ToArray() for every generic List in the JSON payload instead.
$inventory = [ordered]@{
    GeneratedAt=(Get-Date).ToString('o');Computer=[ordered]@{ComputerName=$env:COMPUTERNAME;UserName=$env:USERNAME;UserProfile=$env:USERPROFILE;OSCaption=$os.Caption;OSVersion=$os.Version;BuildNumber=$os.BuildNumber;OSArchitecture=$os.OSArchitecture;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ProcessArchitecture=$env:PROCESSOR_ARCHITECTURE;NativeArchitecture=$env:PROCESSOR_ARCHITEW6432}
    Hardware=[ordered]@{Manufacturer=$cs.Manufacturer;Model=$cs.Model;TotalPhysicalMemoryGB=if ($cs.TotalPhysicalMemory) {[math]::Round($cs.TotalPhysicalMemory/1GB,2)} else {$null};CPU=$cpu.Name;GPU=$gpu;ProcessArchitecture=$env:PROCESSOR_ARCHITECTURE;NativeArchitecture=$env:PROCESSOR_ARCHITEW6432}
    Drives=$drives;RelevantEnvironment=$relevantEnv;PathEntries=$pathEntries;PythonCandidates=$script:PythonRows.ToArray();Engines=$script:EngineRows.ToArray()
    ComfyUIRoots=$script:ComfyRoots.ToArray();StudioRoots=$script:StudioRoots.ToArray();ModelRoots=$script:ModelRoots.ToArray();ExtraModelPathEntries=$script:ExtraConfigRows.ToArray()
    ModelFileCount=$script:ModelRows.Count;ModelFileTotalGB=[math]::Round((($script:ModelRows | Measure-Object -Property SizeBytes -Sum).Sum)/1GB,3)
    Processes=$relevantProcesses;ListeningPorts=$script:PortRows.ToArray();InstalledApps=$script:AppRows.ToArray();LogFiles=$script:LogRows.ToArray();RecentCrashEvents=$script:EventRows.ToArray();Issues=$script:Issues.ToArray()
}
$inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:OutDir 'INVENTORY.json') -Encoding UTF8
$script:PathRows | Export-Csv -LiteralPath (Join-Path $script:OutDir 'PATH-INVENTORY.csv') -NoTypeInformation -Encoding UTF8
$script:ModelRows | Sort-Object Root,Path | Export-Csv -LiteralPath (Join-Path $script:OutDir 'MODEL-FILES.csv') -NoTypeInformation -Encoding UTF8
$script:PythonRows | Export-Csv -LiteralPath (Join-Path $script:OutDir 'PYTHON-PROBES.csv') -NoTypeInformation -Encoding UTF8
$script:ExtraConfigRows | Export-Csv -LiteralPath (Join-Path $script:OutDir 'COMFYUI-EXTRA-MODEL-PATHS.csv') -NoTypeInformation -Encoding UTF8
$script:EventRows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:OutDir 'WINDOWS-CRASH-EVENTS.json') -Encoding UTF8

# Human-readable map. Format strings are built separately to avoid nested interpolation
# inside .NET method arguments (Windows PowerShell 5.1 parser compatibility).
$map = New-Object System.Collections.Generic.List[string]
$mapDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
[void]$map.Add('# خريطة الجهاز وLocalAI Creative Studio')
[void]$map.Add('')
[void]$map.Add(('تاريخ الإنشاء: {0}' -f $mapDate))
[void]$map.Add('هذه خريطة مسارات وبيانات وصفية. لم يتم فتح محتويات ملفات النماذج أو تعديلها.')
[void]$map.Add('')
[void]$map.Add('## النظام والأقراص')
$line = '- الجهاز: {0} | المستخدم الحالي: {1}' -f $env:COMPUTERNAME, $env:USERNAME
[void]$map.Add($line)
$line = '- Windows: {0} | الإصدار: {1} | البنية: {2}' -f $os.Caption, $os.Version, $os.OSArchitecture
[void]$map.Add($line)
foreach ($d in $drives) {
    $line = '- {0} — متاح {1} GB من {2} GB' -f $d.Drive, $d.FreeGB, $d.SizeGB
    [void]$map.Add($line)
}
[void]$map.Add('')
[void]$map.Add('## Python')
if ($script:PythonRows.Count -eq 0) { [void]$map.Add('- لم يتم العثور على Python من المسارات المعروفة أو PATH.') }
foreach ($p in $script:PythonRows) {
    $line = '- {0} | صالح: {1} | ExitCode: {2} | Bits: {3} | Pip: {4} | Version: {5}' -f $p.Executable, $p.Passed, $p.ExitCode, $p.Bits, $p.PipAvailable, $p.Version
    [void]$map.Add($line)
}
[void]$map.Add('')
[void]$map.Add('## LocalAI / Creative Studio')
if ($script:StudioRoots.Count -eq 0) { [void]$map.Add('- لم يتم تأكيد جذر المشروع؛ راجع PATH-INVENTORY.csv ونتائج البحث المحدود.') }
foreach ($p in $script:StudioRoots) { [void]$map.Add(('- {0}' -f $p)) }
[void]$map.Add('')
[void]$map.Add('## Ollama والنماذج')
$oe = $script:EngineRows | Where-Object Engine -eq 'Ollama' | Select-Object -First 1
if ($oe) {
    [void]$map.Add(('- EXE: {0}' -f $oe.Executable))
    $line = '- API يعمل: {0} | الإصدار: {1} | عدد النماذج الظاهرة عبر API: {2}' -f $oe.ApiResponding, $oe.Version, $oe.ModelCount
    [void]$map.Add($line)
}
foreach ($m in $ollamaModels) {
    $line = '  - {0} | {1} GB | {2} | {3}' -f $m.Name, $m.SizeGB, $m.ParameterSize, $m.Quantization
    [void]$map.Add($line)
}
[void]$map.Add('- ملفات Ollama الداخلية قد تكون blobs بأسماء غير مفهومة؛ لذلك أسماء النماذج أُخذت من API ولا تُنسب لمسارات ملفات غير مؤكدة.')
[void]$map.Add('')
[void]$map.Add('## ComfyUI')
$ce = $script:EngineRows | Where-Object Engine -eq 'ComfyUI' | Select-Object -First 1
$line = '- API 127.0.0.1:8188 يعمل: {0}' -f $ce.ApiResponding
[void]$map.Add($line)
foreach ($p in $script:ComfyRoots) {
    [void]$map.Add(('- جذر محتمل: {0}' -f $p))
    if (Test-Path -LiteralPath (Join-Path $p 'main.py')) { [void]$map.Add('  - main.py: موجود') }
    elseif (Test-Path -LiteralPath (Join-Path $p 'ComfyUI\main.py')) { [void]$map.Add('  - ComfyUI\main.py: موجود') }
}
foreach ($p in $script:ModelRoots) { [void]$map.Add(('- مجلد نماذج تم فحصه: {0}' -f $p)) }
foreach ($x in $script:ExtraConfigRows) {
    $line = '  - إعداد {0}: {1} | موجود: {2}' -f $x.Key, $x.ConfiguredPath, $x.Exists
    [void]$map.Add($line)
}
[void]$map.Add('')
[void]$map.Add('## ملخص ملفات النماذج')
$line = '- عدد ملفات الأوزان المكتشفة: {0}' -f $script:ModelRows.Count
[void]$map.Add($line)
$sumBytes = ($script:ModelRows | Measure-Object -Property SizeBytes -Sum).Sum
if (-not $sumBytes) { $sumBytes = 0 }
$sumGB = [math]::Round($sumBytes/1GB,3)
$line = '- الحجم الإجمالي: {0} GB' -f $sumGB
[void]$map.Add($line)
[void]$map.Add('- القائمة الكاملة: MODEL-FILES.csv (المسار والحجم والامتداد وتاريخ التعديل).')
[void]$map.Add('')
[void]$map.Add('## السجلات وأخطاء Windows')
foreach ($l in $script:LogRows) {
    $line = '- سجل: {0} | {1}' -f $l.Path, $l.LastWriteTime
    [void]$map.Add($line)
}
$line = '- أحداث أعطال Windows المطابقة خلال آخر 3 أيام: {0} (التفاصيل في WINDOWS-CRASH-EVENTS.json)' -f $script:EventRows.Count
[void]$map.Add($line)
[void]$map.Add('')
[void]$map.Add('## ملفات المشروع والإعدادات')
$line = '- ملفات وصفية مفهرسة: {0} (الأسماء والمسارات والأحجام فقط).' -f $projectFileRows.Count
[void]$map.Add($line)
[void]$map.Add('- القائمة: PROJECT-AND-CONFIG-FILES.csv؛ لم تتم قراءة محتويات ملفات الإعدادات.')
[void]$map.Add('')
[void]$map.Add('## حدود الفحص')
[void]$map.Add('- فحص المجلدات محدود بعمق وعدد مجلدات لمنع فحص القرص بلا نهاية؛ قد توجد مواقع لم تظهر في التقرير.')
[void]$map.Add('- امتدادات الأوزان المفحوصة: safetensors, ckpt, pt, pth, bin, gguf, ggml, onnx, engine, tflite, pb, weights, model.')
[void]$map.Add('- لم يتم قراءة محتوى النماذج أو قواعد البيانات أو ملفات الإعدادات السرية، ولم يتم جمع سطر أوامر العمليات.')
[void]$map.Add('- الطلبات المحلية تقتصر على GET إلى Ollama /api/version و/api/tags وComfyUI /system_stats. لا يوجد اتصال بالإنترنت.')
[void]$map.Add('- راجع ISSUES.txt لأي مجلدات تعذر فحصها أو حدود وصل إليها البحث.')
Set-Content -LiteralPath (Join-Path $script:OutDir 'PATH-MAP-AR.md') -Value $map.ToArray() -Encoding UTF8

if ($script:Issues.Count -gt 0) { Set-Content -LiteralPath (Join-Path $script:OutDir 'ISSUES.txt') -Value $script:Issues.ToArray() -Encoding UTF8 } else { Set-Content -LiteralPath (Join-Path $script:OutDir 'ISSUES.txt') -Value 'No collection errors were recorded.' -Encoding UTF8 }

# Copy this collector into the report for reproducibility; it copies only the script itself.
try { Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $script:OutDir 'COLLECT-LOCALAI-ENVIRONMENT.ps1') -Force } catch { }

# Create ZIP of reports (only the new report folder).
$zipPath = "$script:OutDir.zip"
try {
    Get-ChildItem -LiteralPath $script:OutDir -File | Compress-Archive -DestinationPath $zipPath -CompressionLevel Optimal -Force
} catch { Add-Issue "ZIP creation failed: $($_.Exception.Message)" }

$elapsed = (Get-Date) - $script:StartTime
Write-Host ''
Write-Host 'DIAGNOSTICS COMPLETE' -ForegroundColor Green
Write-Host "Report folder: $script:OutDir" -ForegroundColor Yellow
if (Test-Path -LiteralPath $zipPath -PathType Leaf) { Write-Host "ZIP report: $zipPath" -ForegroundColor Yellow }
Write-Host "Model weight files indexed: $($script:ModelRows.Count)"
Write-Host "Python candidates probed: $($script:PythonRows.Count)"
Write-Host "ComfyUI folders found: $($script:ComfyRoots.Count)"
Write-Host "Elapsed: $([math]::Round($elapsed.TotalSeconds,1)) seconds"
Write-Host 'Send the ZIP report back in this chat. Do not send model files themselves.'
Write-Host ''
Read-Host 'Press Enter to close'
