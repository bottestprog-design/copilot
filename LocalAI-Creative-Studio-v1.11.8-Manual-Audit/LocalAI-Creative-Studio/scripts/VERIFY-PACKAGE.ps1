$ErrorActionPreference = 'Stop'
$Root = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package root is a junction or symbolic link; refusing to verify through it.' }
$Manifest = Join-Path $Root 'MANIFEST-SHA256.txt'
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    throw 'MANIFEST-SHA256.txt is missing. The package cannot be trusted without its manifest.'
}

$expectedMap = @{}
$failed = [System.Collections.Generic.List[string]]::new()

# An installed copy owns one small metadata marker outside the release manifest.
# Validate its identity and exact path before excluding it from package-file comparison.
$ownerMarker = Join-Path $Root '.localai-creative-studio-owner.json'
if (Test-Path -LiteralPath $ownerMarker) {
    try {
        $ownerItem = Get-Item -LiteralPath $ownerMarker -Force -ErrorAction Stop
        if ($ownerItem.PSIsContainer -or (($ownerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'Ownership marker is not a regular file.'
        }
        $ownerRecord = Get-Content -LiteralPath $ownerMarker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $savedRoot = [System.IO.Path]::GetFullPath([string]$ownerRecord.install_root).TrimEnd('\')
        $expectedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($ownerRecord.product_id -ne 'localai-creative-studio' -or $ownerRecord.schema_version -ne 1 -or $savedRoot -ine $expectedRoot) {
            throw 'Ownership marker does not match this LocalAI installation directory.'
        }
    } catch {
        $failed.Add("INVALID LOCALAI INSTALLATION MARKER: $($_.Exception.Message)")
    }
}
$lineNumber = 0
foreach ($entry in Get-Content -LiteralPath $Manifest -ErrorAction Stop) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if ($entry -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
        $failed.Add("INVALID MANIFEST RECORD at line $lineNumber")
        continue
    }

    $expected = $Matches[1].ToLowerInvariant()
    $relative = $Matches[2].Replace('/', '\')
    $segments = @($relative.Split('\'))
    $unsafeSegment = $false
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
            $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment -match '(?i)^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            $unsafeSegment = $true; break
        }
    }
    if ([System.IO.Path]::IsPathRooted($relative) -or
        $relative -match '[:*?<>|"\x00]' -or
        $relative.StartsWith('\') -or $relative -match '\\$' -or
        $relative -ne $relative.Trim() -or $unsafeSegment) {
        $failed.Add("UNSAFE MANIFEST PATH: $relative")
        continue
    }
    if ($expectedMap.ContainsKey($relative)) {
        $failed.Add("DUPLICATE MANIFEST ENTRY: $relative")
        continue
    }
    $expectedMap[$relative] = $expected

    try {
        $path = [System.IO.Path]::GetFullPath((Join-Path $Root $relative))
        $rootPrefix = $Root + '\'
        if (-not $path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $failed.Add("PATH ESCAPES PACKAGE ROOT: $relative")
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failed.Add("MISSING: $relative")
            continue
        }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $failed.Add("REPARSE POINT FILE: $relative")
            continue
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { $failed.Add("HASH MISMATCH: $relative") }
    } catch {
        $failed.Add("CHECK ERROR: $relative — $($_.Exception.Message)")
    }
}
if ($expectedMap.Count -lt 10) { $failed.Add('MANIFEST CONTAINS TOO FEW PACKAGE FILES.') }

$excludedDirectories = '(^|[\\/])(\.git|\.venv|\.venv\.next|\.venv\.next\.incomplete-[^\\/]+|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|node_modules|\.idea|\.vscode|\.venv\.previous-[^\\/]+|\.venv\.failed-[^\\/]+)([\\/]|$)'
$excludedExtensions = @('.pyc','.pyo','.sqlite','.sqlite3','.db','.log','.tmp','.bak','.sqlite-wal','.sqlite-shm','.sqlite3-wal','.sqlite3-shm','.sqlite-journal','.sqlite3-journal','.db-wal','.db-shm','.db-journal')
try {
    $allItems = @(Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop)
    foreach ($directory in ($allItems | Where-Object { $_.PSIsContainer -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) })) {
        $relativeDir = $directory.FullName.Substring($Root.Length).TrimStart('\')
        if ($relativeDir -notmatch $excludedDirectories) { $failed.Add("REPARSE POINT DIRECTORY: $relativeDir") }
    }
    $actualFiles = @($allItems | Where-Object {
        -not $_.PSIsContainer -and
        $_.FullName -ne $Manifest -and
        $_.FullName -ine $ownerMarker -and
        $_.FullName -notmatch $excludedDirectories -and
        $_.Extension.ToLowerInvariant() -notin $excludedExtensions -and
        $_.Name -notin @('.DS_Store','Thumbs.db','desktop.ini')
    })
    foreach ($file in $actualFiles) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
        if (-not $expectedMap.ContainsKey($relative)) { $failed.Add("UNLISTED FILE: $relative") }
    }
} catch {
    $failed.Add("PACKAGE ENUMERATION FAILED: $($_.Exception.Message)")
}

if ($failed.Count) {
    $failed | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "Package verification failed ($($failed.Count) issue(s)). No installer or updater should continue."
}
Write-Host "OK: $($expectedMap.Count) files passed SHA-256 verification; no unsafe, reparse-point, or unlisted package files were found." -ForegroundColor Green
