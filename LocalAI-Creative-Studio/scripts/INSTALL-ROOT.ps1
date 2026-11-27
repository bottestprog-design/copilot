# Resolve the installed LocalAI Creative Studio folder for diagnostics, updates and repair.
# Only plain directories with a verified owner marker or a valid legacy package manifest qualify.

function Test-LocalAIPlainRoot {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return ($item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0))
    } catch { return $false }
}

function Test-LocalAIPlainRelativeFile {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Relative
    )
    try {
        $segments = @($Relative -split '[\\/]')
        if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') { return $false }
        $current = $Root
        for ($index = 0; $index -lt $segments.Count; $index++) {
            $current = Join-Path $current $segments[$index]
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($index -lt ($segments.Count - 1)) {
                if (-not $item.PSIsContainer) { return $false }
            } elseif ($item.PSIsContainer) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-LocalAIInstallOwnerMarker {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if (-not (Test-LocalAIPlainRoot $Path)) { return $false }
        $root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        if (-not (Test-LocalAIPlainRelativeFile -Root $root -Relative '.localai-creative-studio-owner.json')) { return $false }
        $marker = Join-Path $root '.localai-creative-studio-owner.json'
        $record = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $savedRoot = [System.IO.Path]::GetFullPath([string]$record.install_root).TrimEnd('\')
        if ($record.product_id -eq 'localai-creative-studio' -and $record.schema_version -eq 1 -and $savedRoot -ieq $root) {
            foreach ($relative in @('VERSION.txt','Launch-LocalAI-Creative-Studio.vbs','scripts\LAUNCH-DESKTOP.ps1','scripts\STOP-STUDIO.ps1','studio\server.py')) {
                if (-not (Test-LocalAIPlainRelativeFile -Root $root -Relative $relative)) { return $false }
            }
            $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw -ErrorAction Stop).Trim()
            $parsedVersion = [version]::MinValue
            return [version]::TryParse($version, [ref]$parsedVersion)
        }
        return $false
    } catch { return $false }
}

function Test-LocalAILegacyInstall {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        if (-not (Test-LocalAIPlainRoot $Path)) { return $false }
        $root = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        if (-not (Test-LocalAIPlainRelativeFile -Root $root -Relative 'MANIFEST-SHA256.txt')) { return $false }
        $hashes = @{}
        foreach ($line in (Get-Content -LiteralPath (Join-Path $root 'MANIFEST-SHA256.txt') -ErrorAction Stop)) {
            if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') { return $false }
            $key = $Matches[2].Replace('\','/').ToLowerInvariant()
            if ($hashes.ContainsKey($key)) { return $false }
            $hashes[$key] = $Matches[1].ToLowerInvariant()
        }
        $critical = @('VERSION.txt','Launch-LocalAI-Creative-Studio.vbs','scripts/INSTALL-DESKTOP-APP.ps1','scripts/LAUNCH-DESKTOP.ps1','studio/server.py')
        foreach ($relative in $critical) {
            $key = $relative.ToLowerInvariant()
            if (-not $hashes.ContainsKey($key)) { return $false }
            $nativeRelative = $relative.Replace('/','\')
            if (-not (Test-LocalAIPlainRelativeFile -Root $root -Relative $nativeRelative)) { return $false }
            $file = Join-Path $root $nativeRelative
            $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($actual -ne $hashes[$key]) { return $false }
        }
        $version = (Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw -ErrorAction Stop).Trim()
        $parsedVersion = [version]::MinValue
        return [version]::TryParse($version, [ref]$parsedVersion)
    } catch { return $false }
}

function Get-VerifiedLocalAIInstallRoot {
    param([Parameter(Mandatory=$true)][string]$FallbackRoot)

    $fallback = [System.IO.Path]::GetFullPath($FallbackRoot).TrimEnd('\')
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { return $fallback }

    $programs = [System.IO.Path]::GetFullPath((Join-Path $localAppData 'Programs')).TrimEnd('\')
    if (-not (Test-LocalAIPlainRoot $programs)) { return $fallback }

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add((Join-Path $programs 'LocalAI Creative Studio'))
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
