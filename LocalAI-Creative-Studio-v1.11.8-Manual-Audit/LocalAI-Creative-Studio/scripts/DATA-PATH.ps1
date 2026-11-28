# Shared, strict resolver for this application's persistent data directory.
# This file intentionally defines a function only; it has no side effects when dot-sourced.
function Get-LocalAIDataRoot {
    param([switch]$RecoverLegacyStatus)

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'Windows did not provide LocalAppData; cannot safely resolve the Studio data directory.' }

    $localAiHome = Join-Path $localAppData 'LocalAI'
    $localData = Join-Path $localAiHome 'CreativeStudioData'
    $driveHome = 'D:\LocalAI'
    $driveData = Join-Path $driveHome 'CreativeStudioData'
    $marker = Join-Path $localAiHome 'CreativeStudioDataRoot.txt'
    $allowed = @(
        [System.IO.Path]::GetFullPath($driveData).TrimEnd('\'),
        [System.IO.Path]::GetFullPath($localData).TrimEnd('\')
    )

    # Refuse reparse-point parents: otherwise a marker or a data folder could redirect
    # writes away from the two directories this application owns.
    foreach ($parent in @($localAiHome)) {
        if (Test-Path -LiteralPath $parent -PathType Container) {
            $parentItem = Get-Item -LiteralPath $parent -Force
            if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a redirected LocalAI data parent: $parent"
            }
        }
    }

    $selected = $null
    if (Test-Path -LiteralPath $marker) {
        $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'The Studio data marker is not a regular file. No data or application files were changed.'
        }
        $saved = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim()
        if (-not $saved -or -not [System.IO.Path]::IsPathRooted($saved)) {
            throw 'The saved Studio data path marker is invalid. No data or application files were changed.'
        }
        $normalized = [System.IO.Path]::GetFullPath($saved).TrimEnd('\')
        foreach ($candidate in $allowed) {
            if ($candidate -ieq $normalized) { $selected = $candidate; break }
        }
        if (-not $selected) {
            throw 'The saved Studio data path is outside the two supported CreativeStudioData locations. No cleanup or update was performed.'
        }
    } elseif ($RecoverLegacyStatus) {
        # Preserve the exact data location recorded by older Studio installers.
        foreach ($candidate in $allowed) {
            $status = Join-Path $candidate 'DESKTOP-APP-STATUS.txt'
            if (Test-Path -LiteralPath $status -PathType Leaf) {
                $statusItem = Get-Item -LiteralPath $status -Force
                if (($statusItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing a redirected legacy Studio status file: $status"
                }
                $statusText = Get-Content -LiteralPath $status -Raw -ErrorAction Stop
                if ($statusText -match '(?im)^DATA:\s*(.+?)\s*$') {
                    $statusPath = [System.IO.Path]::GetFullPath($Matches[1].Trim()).TrimEnd('\')
                    if ($candidate -ieq $statusPath) { $selected = $candidate; break }
                    throw 'The legacy Studio status file points outside the two supported data locations. No data was changed.'
                }
            }
        }
    }

    if (-not $selected) {
        $selected = if (Test-Path -LiteralPath $driveHome -PathType Container) {
            [System.IO.Path]::GetFullPath($driveData).TrimEnd('\')
        } else {
            [System.IO.Path]::GetFullPath($localData).TrimEnd('\')
        }
    }

    if ($selected -ieq [System.IO.Path]::GetFullPath($driveData).TrimEnd('\')) {
        if (Test-Path -LiteralPath $driveHome -PathType Container) {
            $driveItem = Get-Item -LiteralPath $driveHome -Force
            if (($driveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a redirected data directory parent: $driveHome" }
        }
    } else {
        if (-not (Test-Path -LiteralPath $localAiHome -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $localAiHome | Out-Null
        }
        $localHomeItem = Get-Item -LiteralPath $localAiHome -Force
        if (($localHomeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a redirected data directory parent: $localAiHome" }
    }

    if (Test-Path -LiteralPath $selected -PathType Container) {
        $dataItem = Get-Item -LiteralPath $selected -Force
        if (($dataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to use a redirected Studio data folder: $selected" }
    } else {
        New-Item -ItemType Directory -Force -Path $selected | Out-Null
        $dataItem = Get-Item -LiteralPath $selected -Force
        if (($dataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Created Studio data folder is unexpectedly redirected: $selected" }
    }

    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $localAiHome -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $localAiHome | Out-Null
        }
        if (Test-Path -LiteralPath $marker) {
            $markerItem = Get-Item -LiteralPath $marker -Force
            if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw 'Refusing to create or update a redirected Studio data marker.'
            }
        }
        Set-Content -LiteralPath $marker -Value $selected -Encoding UTF8
    }
    return $selected
}
