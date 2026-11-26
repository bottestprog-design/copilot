# Resolve the installed LocalAI Creative Studio folder for diagnostics/stop tools.
# A folder is accepted only after its product marker and canonical path are verified.
function Get-VerifiedLocalAIInstallRoot {
    param([Parameter(Mandatory=$true)][string]$FallbackRoot)

    $fallback = [System.IO.Path]::GetFullPath($FallbackRoot).TrimEnd('\')
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { return $fallback }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $localAppData 'Programs\LocalAI Creative Studio')).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { return $fallback }

    try {
        $rootItem = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $fallback }

        $marker = Join-Path $candidate '.localai-creative-studio-owner.json'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $fallback }
        $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $fallback }

        $record = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $recordRoot = [System.IO.Path]::GetFullPath([string]$record.install_root).TrimEnd('\')
        if ($record.product_id -eq 'localai-creative-studio' -and
            $record.schema_version -eq 1 -and
            $recordRoot -ieq $candidate -and
            (Test-Path -LiteralPath (Join-Path $candidate 'scripts\LAUNCH-DESKTOP.ps1') -PathType Leaf)) {
            return $candidate
        }
    } catch {}
    return $fallback
}
