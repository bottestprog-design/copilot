$ErrorActionPreference = 'Stop'
$Root = 'D:\LocalAI'
$Platform = Join-Path $Root 'Platform'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Manifest = Join-Path $PSScriptRoot 'MANIFEST-SHA256.txt'
$Verifier = Join-Path $PSScriptRoot 'VERIFY-PACKAGE.ps1'
$LogRoot = Join-Path $Root 'Logs'
$BackupRoot = Join-Path $Root ('Backups\Setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$Copied = New-Object System.Collections.ArrayList
$Existing = @{}

try {
    if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found: $PowerShellExe" }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 or later is required.' }
    New-Item -ItemType Directory -Force -Path $Root, $Platform, $LogRoot, (Join-Path $Root 'Backups') | Out-Null
    Write-Host 'STEP 1/4 - Verify the extracted release package' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $Verifier -PathType Leaf)) { throw 'VERIFY-PACKAGE.ps1 is missing. Extract the complete ZIP first.' }
    & $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Verifier
    if ([int]$LASTEXITCODE -ne 0) { throw 'The release package failed its integrity or PowerShell syntax checks. No installed project files were changed.' }

    Write-Host 'STEP 2/4 - Refresh only package-managed application files' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { throw 'MANIFEST-SHA256.txt is missing from the release package.' }
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    $manifestLines = @(Get-Content -LiteralPath $Manifest -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') })
    if ($manifestLines.Count -lt 10) { throw 'The release manifest is incomplete.' }
    $sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
    $sourceRoot = $sourceRoot.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $sourcePrefix = $sourceRoot + [IO.Path]::DirectorySeparatorChar
    $targetRoot = [IO.Path]::GetFullPath($Platform)
    $targetRoot = $targetRoot.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    $targetPrefix = $targetRoot + [IO.Path]::DirectorySeparatorChar
    foreach ($line in $manifestLines) {
        if ($line -notmatch '^([0-9A-Fa-f]{64})\s+(.+)$') { throw "Invalid manifest line: $line" }
        $expected = $matches[1].ToLowerInvariant()
        $relative = $matches[2].Trim()
        if ($relative.StartsWith('*')) { $relative = $relative.Substring(1) }
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative -match '^[A-Za-z]:') { throw "Unsafe package path: $relative" }
        $localRelative = $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $localRelative))
        $target = [IO.Path]::GetFullPath((Join-Path $targetRoot $localRelative))
        if (-not $source.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Source path escapes the release folder: $relative" }
        if (-not $target.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Target path escapes the installed platform folder: $relative" }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release file is missing: $relative" }
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHash -ne $expected) { throw "Release file hash mismatch: $relative" }
        $samePath = $source.Equals($target, [StringComparison]::OrdinalIgnoreCase)
        if ($samePath) { continue }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($targetHash -eq $expected) { continue }
            $backup = Join-Path $BackupRoot $localRelative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
            Copy-Item -LiteralPath $target -Destination $backup -Force -ErrorAction Stop
            $Existing[$localRelative] = $true
        }
        $null = $Copied.Add($localRelative)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($targetHash -ne $expected) { throw "Installed copy failed SHA-256 verification: $relative" }
    }
    # The manifest is not listed inside itself, so copy it separately after all verified payload files.
    $manifestTarget = Join-Path $Platform 'MANIFEST-SHA256.txt'
    $manifestSourceFull = [IO.Path]::GetFullPath($Manifest)
    $manifestTargetFull = [IO.Path]::GetFullPath($manifestTarget)
    if (-not $manifestSourceFull.Equals($manifestTargetFull, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $manifestTarget -PathType Leaf) {
            $savedManifest = Join-Path $BackupRoot 'MANIFEST-SHA256.txt'
            Copy-Item -LiteralPath $manifestTarget -Destination $savedManifest -Force
            $Existing['MANIFEST-SHA256.txt'] = $true
        }
        $null = $Copied.Add('MANIFEST-SHA256.txt')
        Copy-Item -LiteralPath $Manifest -Destination $manifestTarget -Force
    }
    & $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Platform 'VERIFY-PACKAGE.ps1') -InstalledPlatform
    if ([int]$LASTEXITCODE -ne 0) { throw 'Installed-platform verification failed after copying the release.' }
    @("Created: $(Get-Date -Format o)", "Source: $sourceRoot", "Target: $Platform", "Files copied: $($Copied.Count)", "Previous files backed up: $($Existing.Count)", 'Ollama, Qwen model blobs, Open WebUI Data, chat database, secrets and user files were not package targets.') | Set-Content -LiteralPath (Join-Path $BackupRoot 'SETUP-SUMMARY.txt') -Encoding UTF8
    Write-Host "[OK] Package-managed files are installed. Backup: $BackupRoot" -ForegroundColor Green
} catch {
    Write-Host "SETUP COPY FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $BackupRoot -PathType Container) {
        foreach ($relative in $Copied) {
            $target = Join-Path $Platform $relative
            if ($Existing.ContainsKey($relative)) {
                $saved = Join-Path $BackupRoot $relative
                if (Test-Path -LiteralPath $saved -PathType Leaf) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                    Copy-Item -LiteralPath $saved -Destination $target -Force
                }
            } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force
            }
        }
        $savedManifest = Join-Path $BackupRoot 'MANIFEST-SHA256.txt'
        $manifestTarget = Join-Path $Platform 'MANIFEST-SHA256.txt'
        if (Test-Path -LiteralPath $savedManifest -PathType Leaf) { Copy-Item -LiteralPath $savedManifest -Destination $manifestTarget -Force }
        Write-Host "[ROLLBACK] Package file copy was rolled back. Backup retained at $BackupRoot" -ForegroundColor Yellow
    }
    exit 1
}

Write-Host 'STEP 3/4 - Repair/refresh the platform and run its regression checks' -ForegroundColor Cyan
$repairScript = Join-Path $Platform 'REPAIR-AND-RESUME.ps1'
& $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $repairScript
$repairExit = [int]$LASTEXITCODE
if ($repairExit -ne 0) {
    Write-Host "[FAIL] Platform repair exited with code $repairExit. Restoring the previously installed package files." -ForegroundColor Red
    foreach ($relative in $Copied) {
        $target = Join-Path $Platform $relative
        if ($Existing.ContainsKey($relative)) {
            $saved = Join-Path $BackupRoot $relative
            if (Test-Path -LiteralPath $saved -PathType Leaf) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Copy-Item -LiteralPath $saved -Destination $target -Force
            }
        } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    throw "Platform repair failed (exit $repairExit). Previous package files were restored; see logs under $LogRoot."
}
Write-Host 'STEP 4/4 - Create/update the desktop icon and open the app window' -ForegroundColor Cyan
& $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File (Join-Path $Platform 'LAUNCH-LOCALAI-APP.ps1') -CreateShortcutOnly
if ([int]$LASTEXITCODE -ne 0) { throw 'Could not create the LocalAI Studio desktop shortcut.' }
& $PowerShellExe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File (Join-Path $Platform 'LAUNCH-LOCALAI-APP.ps1')
$launchExit = [int]$LASTEXITCODE
if ($launchExit -ne 0) { throw "LocalAI Studio launcher exited with code $launchExit. See logs under $LogRoot." }
Write-Host '[SUCCESS] LocalAI Studio is ready. Use the LocalAI Studio desktop icon for future starts and this same SETUP file for future updates.' -ForegroundColor Green
exit 0
