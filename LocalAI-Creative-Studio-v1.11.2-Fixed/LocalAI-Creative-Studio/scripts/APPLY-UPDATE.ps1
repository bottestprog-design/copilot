param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$SourceRoot = Split-Path -Parent $PSScriptRoot
$DefaultInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\LocalAI Creative Studio'
$InstallParent = Join-Path $env:LOCALAPPDATA 'Programs'
if (Test-Path -LiteralPath $InstallParent -PathType Container) {
    $installParentItem = Get-Item -LiteralPath $InstallParent -Force
    if (($installParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a redirected per-user Programs directory: $InstallParent" }
}
$SystemPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $PSScriptRoot 'DATA-PATH.ps1')
. (Join-Path $PSScriptRoot 'INSTALL-ROOT.ps1')
if (-not (Test-Path -LiteralPath $SystemPowerShell -PathType Leaf)) { $SystemPowerShell = 'powershell.exe' }

# Resolve the product's verified installation wherever a prior safe install placed it.
# An unknown or occupied default folder is never treated as an upgrade target.
$InstallRoot = Get-VerifiedLocalAIInstallRoot -FallbackRoot $DefaultInstallRoot
if (-not (Test-LocalAIInstallOwnerMarker $InstallRoot) -and -not (Test-LocalAILegacyInstall $InstallRoot)) {
    $sourceCandidate = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    if (Test-LocalAIInstallOwnerMarker $sourceCandidate) {
        $InstallRoot = $sourceCandidate
    } else {
        # Do not mistake a coincidental launcher file in an unknown folder for an installation.
        $InstallRoot = Get-AvailableLocalAIInstallRoot -DefaultRoot $DefaultInstallRoot
    }
}
$InstallOwnershipMarker = Join-Path $InstallRoot '.localai-creative-studio-owner.json'

function Ensure-PlainDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A required update directory path is empty.' }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to use a file, junction or symbolic link as an update directory: $Path"
        }
        return
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Created update directory is not a plain directory: $Path"
    }
}

function Write-InstallOwnershipMarker {
    if (Test-Path -LiteralPath $InstallOwnershipMarker) {
        $markerItem = Get-Item -LiteralPath $InstallOwnershipMarker -Force
        if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to write through a reparse-point ownership marker.' }
    }
    $record = [ordered]@{
        product_id = 'localai-creative-studio'
        schema_version = 1
        install_root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
        updated_at = (Get-Date).ToString('o')
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $InstallOwnershipMarker -Encoding UTF8
}

function Test-LegacyManagedInstall {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { return $false }
    $rootItem = Get-Item -LiteralPath $InstallRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $manifestPath = Join-Path $InstallRoot 'MANIFEST-SHA256.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    $manifest = Read-Manifest $manifestPath
    $critical = @('VERSION.txt','Launch-LocalAI-Creative-Studio.vbs','scripts\INSTALL-DESKTOP-APP.ps1','scripts\LAUNCH-DESKTOP.ps1','studio\server.py')
    foreach ($relative in $critical) {
        if (-not $manifest.ContainsKey($relative)) { return $false }
        $path = Join-Path $InstallRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $manifest[$relative]) { return $false }
    }
    $version = (Get-Content -LiteralPath (Join-Path $InstallRoot 'VERSION.txt') -Raw).Trim()
    return ($version -match '^\d+\.\d+\.\d+$')
}

function Assert-ManagedInstall {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { return $false }
    $rootItem = Get-Item -LiteralPath $InstallRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to update through an application-folder junction or symbolic link: $InstallRoot"
    }
    if (Test-Path -LiteralPath $InstallOwnershipMarker) {
        $markerItem = Get-Item -LiteralPath $InstallOwnershipMarker -Force
        if (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to trust a reparse-point ownership marker.' }
        try {
            $record = Get-Content -LiteralPath $InstallOwnershipMarker -Raw | ConvertFrom-Json -ErrorAction Stop
            $savedRoot = [System.IO.Path]::GetFullPath([string]$record.install_root).TrimEnd('\')
            $expectedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
            if ($record.product_id -eq 'localai-creative-studio' -and $record.schema_version -eq 1 -and $savedRoot -ieq $expectedRoot) { return $true }
        } catch {}
    }
    if (Test-LegacyManagedInstall) {
        Write-UpdateLog 'Verified the legacy installation using its own signed-by-hash package manifest; creating the ownership marker.' 'Green'
        Write-InstallOwnershipMarker
        return $true
    }
    throw "Safety stop: '$InstallRoot' exists but is not a verified LocalAI Creative Studio installation. No application files or Desktop shortcuts were changed."
}

function Read-Manifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    $map = @{}
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $lineNumber++
        if ($line -notmatch '^([0-9a-fA-F]{64})\s{2}(.+)$') { throw "Invalid manifest record at line $lineNumber in $Path" }
        $hash = $Matches[1].ToLowerInvariant()
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
        if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '[:*?<>|"\x00]' -or
            $relative.StartsWith('\\') -or $relative -match '\\$' -or $relative -ne $relative.Trim() -or $unsafeSegment) {
            throw "Unsafe path in package manifest: $relative"
        }
        if ($map.ContainsKey($relative)) { throw "Duplicate path in package manifest: $relative" }
        $map[$relative] = $hash
    }
    if ($map.Count -eq 0) { throw "Manifest has no usable SHA-256 entries: $Path" }
    return $map
}
function Get-SafeTarget([string]$Base, [string]$Relative) {
    if (Test-Path -LiteralPath $Base -PathType Container) {
        $baseItem = Get-Item -LiteralPath $Base -Force
        if (($baseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to traverse a reparse-point base directory: $Base" }
    }
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $target = [System.IO.Path]::GetFullPath((Join-Path $Base $Relative))
    if (-not $target.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Manifest path escapes the selected directory: $Relative" }
    $parent = [System.IO.Path]::GetDirectoryName($target)
    while ($parent -and $parent.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $parent) {
            $item = Get-Item -LiteralPath $parent -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to update through a reparse point: $parent" }
        }
        if ($parent.TrimEnd('\') -ieq $Base.TrimEnd('\')) { break }
        $parent = [System.IO.Path]::GetDirectoryName($parent)
    }
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        if ($item.PSIsContainer) { throw "A directory conflicts with an application file path; it was not replaced: $target" }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing to replace a reparse-point file: $target" }
    }
    return $target
}
function Write-UpdateLog([string]$Message, [string]$Color = 'Gray') {
    Write-Host $Message -ForegroundColor $Color
    Add-Content -LiteralPath $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}
function Write-OwnedUpdateFolderMarker([string]$Folder, [string]$Kind) {
    Ensure-PlainDirectory $Folder
    $marker = Join-Path $Folder '.localai-update-owner.json'
    if (Test-Path -LiteralPath $marker) {
        $item = Get-Item -LiteralPath $marker -Force
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing a redirected update ownership marker: $marker"
        }
        throw "An update staging folder already exists and will not be overwritten: $Folder"
    }
    $record = [ordered]@{
        product_id = 'localai-creative-studio'
        schema_version = 1
        update_run_id = $UpdateRunId
        kind = $Kind
        folder_path = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\')
        created_at = (Get-Date).ToString('o')
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $marker -Encoding UTF8
}
function Test-OwnedUpdateFolder([string]$Folder) {
    try {
        $rootItem = Get-Item -LiteralPath $Folder -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $name = Split-Path -Leaf $Folder
        if ($name -notmatch '^(stage|backup)-\d{8}-\d{6}-[0-9a-f]{32}$') { return $false }
        $marker = Join-Path $Folder '.localai-update-owner.json'
        $markerItem = Get-Item -LiteralPath $marker -Force -ErrorAction Stop
        if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $record = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $expectedPath = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\')
        $expectedKind = if ($name.StartsWith('stage-', [System.StringComparison]::OrdinalIgnoreCase)) { 'stage' } else { 'backup' }
        return ($record.product_id -eq 'localai-creative-studio' -and $record.schema_version -eq 1 -and
            $record.update_run_id -match '^[0-9a-f]{32}$' -and $name.EndsWith([string]$record.update_run_id, [System.StringComparison]::OrdinalIgnoreCase) -and
            $record.kind -eq $expectedKind -and [string]$record.folder_path -ieq $expectedPath)
    } catch { return $false }
}
function Test-PlainUpdateTree([string]$Folder) {
    try {
        $rootItem = Get-Item -LiteralPath $Folder -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        foreach ($child in (Get-ChildItem -LiteralPath $Folder -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($child.PSIsContainer -and -not (Test-PlainUpdateTree $child.FullName)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Remove-OwnedUpdateFolder([string]$Folder) {
    if (-not (Test-OwnedUpdateFolder $Folder)) { return $false }
    if (-not (Test-PlainUpdateTree $Folder)) {
        Write-UpdateLog "Kept an owned update folder because it contains a redirected/reparse-point child: $Folder" 'Yellow'
        return $false
    }
    Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop
    return $true
}

function Test-ManifestFiles([string]$Base, [hashtable]$Manifest) {
    foreach ($relative in $Manifest.Keys) {
        $target = Get-SafeTarget $Base $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Package file is missing: $relative" }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Manifest[$relative]) { throw "SHA-256 mismatch: $relative" }
    }
}
function Restore-Update([string]$BackupRoot, [hashtable]$BackupMap, [System.Collections.Generic.List[string]]$Created, [hashtable]$NewManifest) {
    Write-UpdateLog 'An update stage failed. Restoring the previous application files...' 'Yellow'
    foreach ($relative in $BackupMap.Keys) {
        try {
            $expectedBackupHash = [string]$BackupMap[$relative]
            if ($expectedBackupHash -notmatch '^[0-9a-f]{64}$') { throw "Rollback has no valid recorded backup hash for $relative." }
            $backup = Get-SafeTarget $BackupRoot $relative
            $target = Get-SafeTarget $InstallRoot $relative
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "Rollback backup is missing for $relative." }
            $backupItem = Get-Item -LiteralPath $backup -Force -ErrorAction Stop
            if ($backupItem.PSIsContainer -or (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Rollback backup is not a plain file for $relative." }
            $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($backupHash -ne $expectedBackupHash) { throw "Rollback backup SHA-256 mismatch for $relative; refusing to restore an unverified file." }
            $directory = [System.IO.Path]::GetDirectoryName($target)
            New-Item -ItemType Directory -Force -Path $directory | Out-Null
            Copy-Item -LiteralPath $backup -Destination $target -Force
            $restoredHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($restoredHash -ne $expectedBackupHash) { throw "Restored file SHA-256 mismatch for $relative." }
        } catch { Write-UpdateLog "ROLLBACK WARNING for $relative : $($_.Exception.Message)" 'Red' }
    }
    foreach ($relative in $Created) {
        if ($BackupMap.ContainsKey($relative)) { continue }
        try {
            $target = Get-SafeTarget $InstallRoot $relative
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($NewManifest.ContainsKey($relative) -and $actual -eq $NewManifest[$relative]) {
                    Remove-Item -LiteralPath $target -Force
                }
            }
        } catch { Write-UpdateLog "ROLLBACK CLEANUP WARNING for $relative : $($_.Exception.Message)" 'Red' }
    }
}

$DataRoot = Get-LocalAIDataRoot -RecoverLegacyStatus
$UpdateRoot = Join-Path $DataRoot 'updates'
$LogRoot = Join-Path $DataRoot 'logs'
Ensure-PlainDirectory $DataRoot
Ensure-PlainDirectory $LogRoot
Ensure-PlainDirectory $UpdateRoot
$LogFile = Join-Path $LogRoot ('desktop-update-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$UpdateRunId = [guid]::NewGuid().ToString('N')
$StageRoot = Join-Path $UpdateRoot ('stage-' + $Stamp + '-' + $UpdateRunId)
$BackupRoot = Join-Path $UpdateRoot ('backup-' + $Stamp + '-' + $UpdateRunId)
$BackupMap = @{}
$CreatedFiles = New-Object 'System.Collections.Generic.List[string]'
$NewManifest = @{}
$UpdateStarted = $false
$StudioWasRunning = $false
try {
    $expectedStudioPython = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot '.venv\Scripts\python.exe'))
    $studioProcesses = @(Get-CimInstance Win32_Process -Filter "name='python.exe' OR name='pythonw.exe'" -ErrorAction SilentlyContinue | Where-Object {
        if (-not $_.ExecutablePath -or -not $_.CommandLine) { return $false }
        try {
            [System.IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expectedStudioPython -and
            $_.CommandLine -match '(?i)uvicorn\s+studio\.server:app' -and
            $_.CommandLine -match '(?i)--port\s+7865'
        } catch { $false }
    })
    $StudioWasRunning = ($studioProcesses.Count -gt 0)
} catch { $StudioWasRunning = $false }

try {
    Write-UpdateLog 'LOCALAI CREATIVE STUDIO - TRANSACTIONAL DESKTOP UPDATE' 'Cyan'
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'scripts\VERIFY-PACKAGE.ps1') -PathType Leaf)) { throw 'Update package is incomplete. Extract the complete ZIP before running APPLY-UPDATE.bat.' }
    & $SystemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SourceRoot 'scripts\VERIFY-PACKAGE.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Update package integrity verification failed. No installed files were changed.' }

    $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $installFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if ($sourceFull -ieq $installFull) {
        if (-not (Assert-ManagedInstall)) { throw 'This folder is not an owned LocalAI Creative Studio installation.' }
        Write-UpdateLog 'The update files are already in the verified installed application folder. Refreshing only this application desktop integration.' 'Yellow'
        & $SystemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot 'scripts\INSTALL-DESKTOP-APP.ps1') -Installed -NoLaunch
        if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the desktop application.' }
        if (-not $NoLaunch) {
            $vbs = Join-Path $InstallRoot 'Launch-LocalAI-Creative-Studio.vbs'
            $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
            Start-Process -FilePath $wscript -ArgumentList ('//B //Nologo "' + $vbs + '"') -WindowStyle Hidden | Out-Null
        }
        exit 0
    }

    if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
        $existingLauncher = Join-Path $InstallRoot 'scripts\LAUNCH-DESKTOP.ps1'
        if (Test-Path -LiteralPath $existingLauncher -PathType Leaf) { Assert-ManagedInstall | Out-Null }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'scripts\LAUNCH-DESKTOP.ps1') -PathType Leaf)) {
        Write-UpdateLog 'No verified existing desktop installation was found. Starting the safe first-install flow instead.' 'Yellow'
        $setup = Join-Path $SourceRoot 'SETUP-AND-START.bat'
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',('"' + $setup + '"')) -Wait -PassThru -WindowStyle Normal
        if ($proc.ExitCode -ne 0) { throw 'The first-time installation did not complete successfully.' }
        exit 0
    }

    $NewManifest = Read-Manifest (Join-Path $SourceRoot 'MANIFEST-SHA256.txt')
    $oldManifest = Read-Manifest (Join-Path $InstallRoot 'MANIFEST-SHA256.txt')
    if ($NewManifest.Count -lt 10) { throw 'The new package manifest is unexpectedly small. No application files were changed.' }

    # Stage and hash-check every new file before stopping the running application.
    Write-UpdateLog 'Staging the complete update away from the live application...' 'Cyan'
    Ensure-PlainDirectory $StageRoot
    Ensure-PlainDirectory $BackupRoot
    Write-OwnedUpdateFolderMarker $StageRoot 'stage'
    Write-OwnedUpdateFolderMarker $BackupRoot 'backup'
    $stageArgs = @(
        $SourceRoot, $StageRoot, '/E', '/XJ', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
        '/XD', '.venv', '.venv.next', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', 'node_modules', '.git', '.idea', '.vscode',
        '/XF', '*.sqlite*', '*.db*', '*.log', '*.pyc', '*.pyo', '*.tmp', '*.bak'
    )
    & robocopy.exe @stageArgs
    $stageCode = $LASTEXITCODE
    if ($stageCode -ge 8) { throw "Could not stage update files (robocopy exit code $stageCode). The running installation has not been changed." }
    Test-ManifestFiles $StageRoot $NewManifest
    Write-UpdateLog ("Staging verified: {0} package files." -f $NewManifest.Count) 'Green'

    # Back up every package-owned file that will be replaced or retired.
    # If an unowned file collides with a new package path, stop rather than overwrite it.
    $pathsToProtect = @{}
    foreach ($relative in $NewManifest.Keys) { $pathsToProtect[$relative] = $true }
    foreach ($relative in $oldManifest.Keys) { if (-not $NewManifest.ContainsKey($relative)) { $pathsToProtect[$relative] = $true } }
    foreach ($relative in $pathsToProtect.Keys) {
        $target = Get-SafeTarget $InstallRoot $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $oldManifest.ContainsKey($relative) -and $NewManifest.ContainsKey($relative) -and $actual -ne $NewManifest[$relative]) {
            throw "An unowned local file conflicts with a new package file: $relative. It was not overwritten. Move or rename that file, then retry."
        }
        $backup = Get-SafeTarget $BackupRoot $relative
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($backup)) | Out-Null
        Copy-Item -LiteralPath $target -Destination $backup -Force
        $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($backupHash -ne $actual) { throw "The update backup did not match the original file: $relative. No application files were replaced." }
        $BackupMap[$relative] = $actual
        if ($oldManifest.ContainsKey($relative) -and $actual -ne $oldManifest[$relative]) {
            Write-UpdateLog "Preserved a backup of a locally modified package file before updating: $relative" 'Yellow'
        }
    }

    Write-UpdateLog 'Stopping only the LocalAI Creative Studio service...' 'Cyan'
    $stopScript = Join-Path $InstallRoot 'scripts\STOP-STUDIO.ps1'
    if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
        & $SystemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $stopScript
        if ($LASTEXITCODE -ne 0) { throw 'Could not safely stop the Studio service. Live application files were not changed.' }
    }
    $portReleased = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $listeners = @(Get-NetTCPConnection -LocalPort 7865 -State Listen -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 0) { $portReleased = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $portReleased) { throw 'Port 7865 is still listening after the Studio stop request. No live application files were replaced.' }

    $UpdateStarted = $true
    Write-UpdateLog 'Applying staged package files. The update can be rolled back if installation checks fail...' 'Cyan'
    foreach ($relative in $NewManifest.Keys) {
        $sourceFile = Get-SafeTarget $StageRoot $relative
        $targetFile = Get-SafeTarget $InstallRoot $relative
        if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) { $CreatedFiles.Add($relative) }
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($targetFile)) | Out-Null
        Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
        $installedHash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($installedHash -ne $NewManifest[$relative]) { throw "Installed file did not match the staged package: $relative" }
    }
    Test-ManifestFiles $InstallRoot $NewManifest
    Write-UpdateLog 'All staged application files were copied and verified.' 'Green'

    # Run setup in no-launch mode. It validates/builds Python, repairs dependencies,
    # tests the app, then refreshes the desktop shortcut and fingerprinted icon.
    Write-UpdateLog 'Validating Python, dependencies, app imports and desktop integration before finalizing the update...' 'Cyan'
    $installer = Join-Path $InstallRoot 'scripts\INSTALL-DESKTOP-APP.ps1'
    $installArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$installer,'-Installed','-SkipPackageVerification','-NoLaunch')
    & $SystemPowerShell @installArgs
    if ($LASTEXITCODE -ne 0) { throw 'The new application did not pass desktop setup and launch-readiness checks. The previous package files will be restored.' }

    Write-UpdateLog 'Removing obsolete package files only when they still match their previous recorded SHA-256...' 'Cyan'
    $removed = 0
    foreach ($relative in $oldManifest.Keys) {
        if ($NewManifest.ContainsKey($relative)) { continue }
        $target = Get-SafeTarget $InstallRoot $relative
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -eq $oldManifest[$relative]) {
            Remove-Item -LiteralPath $target -Force
            $removed++
        } else {
            Write-UpdateLog "Kept locally modified obsolete file: $relative" 'Yellow'
        }
    }

    Write-UpdateLog ("UPDATE FILES VERIFIED. Obsolete files removed: {0}. User data, .venv, logs, generated media, model files and locally modified obsolete files were preserved." -f $removed) 'Green'
    if (-not $NoLaunch) {
        $vbs = Join-Path $InstallRoot 'Launch-LocalAI-Creative-Studio.vbs'
        $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
        if (-not (Test-Path -LiteralPath $wscript -PathType Leaf)) { $wscript = 'wscript.exe' }
        Start-Process -FilePath $wscript -ArgumentList ('//B //Nologo "' + $vbs + '"') -WindowStyle Hidden | Out-Null
    }
    Write-UpdateLog 'UPDATE COMPLETED SUCCESSFULLY. Continue using the Desktop icon for daily launches.' 'Green'
    Write-Host "Update log: $LogFile" -ForegroundColor Cyan

    # Prune only folders carrying this product's exact ownership marker. Never delete
    # arbitrary user directories merely because their names start with stage-/backup-.
    $ownedHistory = @()
    foreach ($folder in (Get-ChildItem -LiteralPath $UpdateRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        if (Test-OwnedUpdateFolder $folder.FullName) { $ownedHistory += $folder }
    }
    $ownedHistory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 4 | ForEach-Object {
        try { if (Remove-OwnedUpdateFolder $_.FullName) { Write-UpdateLog "Removed an old verified LocalAI update staging/backup folder: $($_.Name)" 'Gray' } }
        catch { Write-UpdateLog "Could not safely prune owned update history '$($_.FullName)': $($_.Exception.Message)" 'Yellow' }
    }
}
catch {
    $message = $_.Exception.Message
    if ($UpdateStarted) {
        Restore-Update $BackupRoot $BackupMap $CreatedFiles $NewManifest
        # Best-effort refresh against the restored files; never launch on rollback.
        try {
            $oldInstaller = Join-Path $InstallRoot 'scripts\INSTALL-DESKTOP-APP.ps1'
            if (Test-Path -LiteralPath $oldInstaller -PathType Leaf) {
                & $SystemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $oldInstaller -Installed -SkipPackageVerification -NoLaunch
                if ($LASTEXITCODE -ne 0) { Write-UpdateLog 'WARNING: Desktop integration could not be refreshed after rollback. Run SETUP-AND-START.bat from the last known-good package.' 'Red' }
            }
        } catch { Write-UpdateLog "WARNING: rollback desktop refresh failed: $($_.Exception.Message)" 'Red' }
    }
    if ($StudioWasRunning) {
        try {
            $recoveryLauncher = Join-Path $InstallRoot 'scripts\LAUNCH-DESKTOP.ps1'
            if (Test-Path -LiteralPath $recoveryLauncher -PathType Leaf) {
                Write-UpdateLog 'The Studio was running before the update; restarting the restored application without opening a second browser window...' 'Cyan'
                & $SystemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $recoveryLauncher -NoBrowser
                if ($LASTEXITCODE -ne 0) { Write-UpdateLog 'WARNING: the restored Studio could not be restarted automatically. Use its existing Desktop shortcut after reviewing the update log.' 'Red' }
            }
        } catch { Write-UpdateLog "WARNING: restored Studio restart failed: $($_.Exception.Message)" 'Red' }
    }
    try { Write-UpdateLog "UPDATE FAILED: $message" 'Red' } catch { Write-Host "UPDATE FAILED: $message" -ForegroundColor Red }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("LocalAI Creative Studio update could not finish.`r`n`r`n$message`r`n`r`nLog: $LogFile", 'LocalAI Creative Studio Update', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
    exit 1
}
