# Resolve the installed LocalAI Creative Studio folder for diagnostics, updates and repair.
# Only plain directories with a verified owner marker or a valid legacy package manifest qualify.

function Test-LocalAIPlainRoot {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ($item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0))
    } catch { return $false }
}

function Test-LocalAIInstallOwnerMarker {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if (-not (Test-LocalAIPlainRoot $Path)) { return $false }
        $root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $marker = Join-Path $root '.localai-creative-studio-owner.json'
        $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $record = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $savedRoot = [System.IO.Path]::GetFullPath([string]$record.install_root).TrimEnd('\')
        if ($record.product_id -ne 'localai-creative-studio' -or $record.schema_version -ne 1 -or $savedRoot -ine $root) { return $false }
        foreach ($relative in @('VERSION.txt','Launch-LocalAI-Creative-Studio.vbs','scripts\LAUNCH-DESKTOP.ps1','scripts\STOP-STUDIO.ps1','studio\server.py')) {
            $file = Join-Path $root $relative
            $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
            if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        }
        $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw -ErrorAction Stop).Trim()
        return ($version -match '^\d+\.\d+\.\d+$')
    } catch { return $false }
}

function Test-LocalAILegacyInstall {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if (-not (Test-LocalAIPlainRoot $Path)) { return $false }
        $root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $manifest = Join-Path $root 'MANIFEST-SHA256.txt'
        $manifestItem = Get-Item -LiteralPath $manifest -Force -ErrorAction Stop
        if ($manifestItem.PSIsContainer -or (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $hashes = @{}
        foreach ($line in Get-Content -LiteralPath $manifest -ErrorAction Stop) {
            if ($line -match '^([0-9a-fA-F]{64})  (.+)$') {
                $key = $Matches[2].Replace('\','/').ToLowerInvariant()
                if ($hashes.ContainsKey($key)) { return $false }
                $hashes[$key] = $Matches[1].ToLowerInvariant()
            }
        }
        $critical = @('VERSION.txt','Launch-LocalAI-Creative-Studio.vbs','scripts/INSTALL-DESKTOP-APP.ps1','scripts/LAUNCH-DESKTOP.ps1','studio/server.py')
        foreach ($relative in $critical) {
            $key = $relative.ToLowerInvariant()
            if (-not $hashes.ContainsKey($key)) { return $false }
            $file = Join-Path $root $relative.Replace('/','\')
            $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
            if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
            $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($actual -ne $hashes[$key]) { return $false }
        }
        $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw -ErrorAction Stop).Trim()
        return ($version -match '^\d+\.\d+\.\d+$')
    } catch { return $false }
}

function Get-VerifiedLocalAIInstallRoot {
    param([Parameter(Mandatory=$true)][string]$FallbackRoot)

    $fallback = [System.IO.Path]::GetFullPath($FallbackRoot).TrimEnd('\')
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { return $fallback }

    $programs = [System.IO.Path]::GetFullPath((Join-Path $localAppData 'Programs')).TrimEnd('\')
    if (-not (Test-LocalAIPlainRoot $programs)) { return $fallback }
    $primary = Join-Path $programs 'LocalAI Creative Studio'
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add($primary)
    try {
        foreach ($item in (Get-ChildItem -LiteralPath $programs -Directory -Force -Filter 'LocalAI Creative Studio*' -ErrorAction Stop)) {
            if (-not $candidates.Contains($item.FullName)) { $candidates.Add($item.FullName) }
        }
    } catch { return $fallback }

    foreach ($candidate in $candidates) {
        if (Test-LocalAIInstallOwnerMarker $candidate) { return [System.IO.Path]::GetFullPath($candidate).TrimEnd('\') }
        if (Test-LocalAILegacyInstall $candidate) { return [System.IO.Path]::GetFullPath($candidate).TrimEnd('\') }
    }
    return $fallback
}

function Get-AvailableLocalAIInstallRoot {
    param([Parameter(Mandatory=$true)][string]$DefaultRoot)

    $default = [System.IO.Path]::GetFullPath($DefaultRoot).TrimEnd('\')
    $parent = [System.IO.Path]::GetDirectoryName($default)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw 'Cannot determine the per-user Programs directory.' }
    if (Test-Path -LiteralPath $parent -PathType Container) {
        if (-not (Test-LocalAIPlainRoot $parent)) { throw "Refusing a redirected per-user Programs directory: $parent" }
    } else {
        New-Item -ItemType Directory -Path $parent -ErrorAction Stop | Out-Null
        if (-not (Test-LocalAIPlainRoot $parent)) { throw "The per-user Programs directory is not a plain directory: $parent" }
    }

    if (-not (Test-Path -LiteralPath $default)) { return $default }
    if (Test-LocalAIPlainRoot $default) {
        $items = @(Get-ChildItem -LiteralPath $default -Force -ErrorAction Stop | Select-Object -First 1)
        if ($items.Count -eq 0) { return $default }
    }

    $baseName = 'LocalAI Creative Studio (Managed)'
    for ($suffix = 1; $suffix -le 999; $suffix++) {
        $name = if ($suffix -eq 1) { $baseName } else { "$baseName $suffix" }
        $candidate = Join-Path $parent $name
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "No unused per-user LocalAI installation directory is available under '$parent'. Existing folders were left untouched."
}
