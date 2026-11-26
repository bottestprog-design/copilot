[CmdletBinding()]
param([switch]$InstalledPlatform)
$ErrorActionPreference = 'Stop'
$installedRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$installedRoot = $installedRoot.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
$autoInstalled = $installedRoot.Equals('D:\LocalAI\Platform', [StringComparison]::OrdinalIgnoreCase)
$isInstalledPlatform = ([bool]$InstalledPlatform -or $autoInstalled)
$manifestPath = Join-Path $PSScriptRoot 'MANIFEST-SHA256.txt'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Write-Host 'FAIL: MANIFEST-SHA256.txt is missing.' -ForegroundColor Red; exit 2 }
$manifestLines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') })
if ($manifestLines.Count -lt 10) { Write-Host 'FAIL: manifest is incomplete.' -ForegroundColor Red; exit 2 }
$ok = 0
$bad = 0
$manifestNames = @{}
$manifestPowerShellFiles = New-Object System.Collections.ArrayList
$rootFull = [IO.Path]::GetFullPath($PSScriptRoot)
$rootFull = $rootFull.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
$rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
foreach ($line in $manifestLines) {
    $parts = $line.Trim() -split '\s+', 2
    if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9A-Fa-f]{64}$') { Write-Host "BAD MANIFEST LINE: $line" -ForegroundColor Red; $bad++; continue }
    $expected = $parts[0].ToLowerInvariant()
    $relative = $parts[1].Trim()
    if ($relative.StartsWith('*')) { $relative = $relative.Substring(1) }
    $manifestKey = $relative.Replace('/', '\').ToLowerInvariant()
    if ($manifestNames.ContainsKey($manifestKey)) { Write-Host "DUPLICATE MANIFEST PATH: $relative" -ForegroundColor Red; $bad++; continue }
    $manifestNames[$manifestKey] = $true
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative -match '^[A-Za-z]:') { Write-Host "UNSAFE PATH: $relative" -ForegroundColor Red; $bad++; continue }
    $localRelative = $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $rootFull $localRelative))
    if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { Write-Host "PATH ESCAPES PACKAGE: $relative" -ForegroundColor Red; $bad++; continue }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Host "MISSING: $relative" -ForegroundColor Red; $bad++; continue }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { Write-Host "HASH MISMATCH: $relative" -ForegroundColor Red; $bad++ } else { Write-Host "OK: $relative" -ForegroundColor Green; $ok++ }
    if ($relative.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) { $null = $manifestPowerShellFiles.Add($path) }
}
if (-not $isInstalledPlatform) {
    # In an extracted release folder, every payload file must be tracked by the manifest.
    $packageFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Force | Where-Object { $_.FullName -ne $manifestPath -and $_.Extension -ne '.pyc' -and $_.Name -notin @('Thumbs.db','desktop.ini','.DS_Store') -and $_.FullName -notmatch '[\/]__pycache__([\/]|$)' })
    foreach ($file in $packageFiles) {
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart([char[]]@([char]92, [char]47))
        $key = $relative.Replace('/', '\').ToLowerInvariant()
        if (-not $manifestNames.ContainsKey($key)) { Write-Host "UNMANIFESTED PACKAGE FILE: $relative" -ForegroundColor Red; $bad++ }
    }
} else {
    Write-Host '[INFO] Installed-platform mode: generated data, virtualenv files, secrets, logs and backups are outside manifest coverage.' -ForegroundColor DarkGray
}
foreach ($scriptPath in $manifestPowerShellFiles) {
    $scriptFile = Get-Item -LiteralPath $scriptPath -ErrorAction Stop
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $bad++
            Write-Host ('POWERSHELL SYNTAX ERROR: {0}:{1}:{2} {3}' -f $scriptFile.Name, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message) -ForegroundColor Red
        }
    } else { Write-Host "POWERSHELL SYNTAX OK: $($scriptFile.Name)" -ForegroundColor Green }
}
$required = @(
    'SETUP-LOCALAI.bat', 'SETUP-LOCALAI.ps1', 'LAUNCH-LOCALAI-APP.ps1', 'LocalAI-Studio.bat',
    'INSTALL-PLATFORM.ps1', 'README-AR.md', 'CHANGELOG-AR.md', 'TEST-REPORT-AR.txt',
    'REPAIR-AND-RESUME.ps1', 'START-CHAT.ps1', 'STOP-CHAT.ps1', 'CHECK-LOCALAI.ps1',
    'VERIFY-MODEL.ps1', 'IMPORT-FILTERS.ps1', 'RESTORE-OPENWEBUI-STYLE.ps1', 'ENSURE-MODELS.ps1',
    'WHISPER-MODEL-MANAGER.py', 'TEST-MODEL-MANAGER.py', 'TEST-WINDOWS-PROCESS-LAUNCH.ps1',
    'TEST-MODEL-INTEGRITY.ps1', 'TEST-PLATFORM-BACKUP.ps1', 'TEST-FILTER-POLICY.py',
    'TEST-FILTERS.py', 'TEST-RELEASE.py', 'MODELS.json',
    'Filters\01-Trusted-Content-Guard.py', 'Filters\02-Accuracy-Thinking.py', 'Filters\03-Selective-Self-Review.py',
    'Assets\LocalAI-Studio.ico'
)
foreach ($requiredFile in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $requiredFile) -PathType Leaf)) { Write-Host "MISSING REQUIRED PROJECT FILE: $requiredFile" -ForegroundColor Red; $bad++ }
}
$modelsPath = Join-Path $PSScriptRoot 'MODELS.json'
try {
    $modelConfig = Get-Content -LiteralPath $modelsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$modelConfig.schema_version -ne 1 -or
        [string]$modelConfig.ollama.official_pull_tag -ne 'qwen3.5:9b-q4_K_M' -or
        [string]::IsNullOrWhiteSpace([string]$modelConfig.ollama.preferred_tag) -or
        $modelConfig.ollama.auto_download_when_missing -ne $false -or
        $modelConfig.whisper.required_for_text_chat -ne $false) {
        throw 'MODELS.json is missing required settings or has an unsafe Qwen download policy.'
    }
    Write-Host '[OK] MODELS.json is valid; Qwen auto-download is disabled and Whisper is optional.' -ForegroundColor Green
} catch { Write-Host "INVALID MODELS.json: $($_.Exception.Message)" -ForegroundColor Red; $bad++ }
Write-Host ("Package verification: OK={0} BAD={1}" -f $ok, $bad)
if ($bad -gt 0) { exit 1 }
Write-Host 'PACKAGE_INTEGRITY: SUCCESS' -ForegroundColor Green
exit 0
