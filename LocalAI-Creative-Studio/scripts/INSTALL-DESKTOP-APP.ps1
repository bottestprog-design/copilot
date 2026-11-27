param([switch]$Installed, [switch]$NoLaunch, [switch]$SkipPackageVerification)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$SourceRoot = Split-Path -Parent $PSScriptRoot
$DefaultInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\LocalAI Creative Studio'
$SystemPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $PSScriptRoot 'DATA-PATH.ps1')
. (Join-Path $PSScriptRoot 'INSTALL-ROOT.ps1')

# Prefer an existing, verified LocalAI installation wherever this product has
# previously placed it. Never claim or modify an unrelated folder at the default path.
$InstallRoot = Get-VerifiedLocalAIInstallRoot -FallbackRoot $DefaultInstallRoot
if (-not (Test-LocalAIInstallOwnerMarker $InstallRoot) -and -not (Test-LocalAILegacyInstall $InstallRoot)) {
    $sourceCandidate = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    if ((Test-LocalAIInstallOwnerMarker $sourceCandidate) -or (Test-LocalAILegacyInstall $sourceCandidate)) {
        $InstallRoot = $sourceCandidate
    } elseif (-not $Installed) {
        $InstallRoot = Get-AvailableLocalAIInstallRoot -DefaultRoot $DefaultInstallRoot
    }
}
$InstallOwnershipMarker = Join-Path $InstallRoot '.localai-creative-studio-owner.json'

function Write-InstallOwnershipMarker {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $InstallRoot -ErrorAction Stop | Out-Null
    }
    $installRootItem = Get-Item -LiteralPath $InstallRoot -Force -ErrorAction Stop
    if (-not $installRootItem.PSIsContainer -or (($installRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Refusing to claim an install directory that is a file, junction or symbolic link.'
    }
    if (Test-Path -LiteralPath $InstallOwnershipMarker) {
        $markerItem = Get-Item -LiteralPath $InstallOwnershipMarker -Force
        if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Refusing to write through a reparse-point ownership marker.' }
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

    $critical = @(
        'VERSION.txt',
        'Launch-LocalAI-Creative-Studio.vbs',
        'scripts/INSTALL-DESKTOP-APP.ps1',
        'scripts/LAUNCH-DESKTOP.ps1',
        'studio/server.py'
    )
    $hashes = @{}
    foreach ($line in Get-Content -LiteralPath $manifestPath -ErrorAction Stop) {
        if ($line -match '^([0-9a-fA-F]{64})  (.+)$') {
            $hashes[$Matches[2].Replace('/', '\').ToLowerInvariant()] = $Matches[1].ToLowerInvariant()
        }
    }
    foreach ($relative in $critical) {
        $key = $relative.Replace('/', '\').ToLowerInvariant()
        if (-not $hashes.ContainsKey($key)) { return $false }
        $path = Join-Path $InstallRoot $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $hashes[$key]) { return $false }
    }
    $version = (Get-Content -LiteralPath (Join-Path $InstallRoot 'VERSION.txt') -Raw).Trim()
    return ($version -match '^\d+\.\d+\.\d+$')
}

function Test-ManagedInstall {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { return $false }
    $rootItem = Get-Item -LiteralPath $InstallRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to use an installation directory that is a junction or symbolic link: $InstallRoot"
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
        # A damaged ownership marker may be recovered only by validating the old package manifest.
    }
    if (Test-LegacyManagedInstall) {
        Write-Host 'Verified a previous LocalAI Creative Studio installation; adopting it safely for updates.' -ForegroundColor Green
        Write-InstallOwnershipMarker
        return $true
    }
    $contents = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction Stop)
    return ($contents.Count -eq 0)
}

function Test-OwnedShortcut([string]$ShortcutPath, [string]$WScriptPath, [string]$VbsPath, $Shell) {
    $entry = Get-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue
    if (-not $entry -or $entry.PSIsContainer -or (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
    try {
        $existing = $Shell.CreateShortcut($ShortcutPath)
        $expectedTarget = [System.IO.Path]::GetFullPath($WScriptPath)
        $actualTarget = [System.IO.Path]::GetFullPath([string]$existing.TargetPath)
        $expectedVbs = [System.IO.Path]::GetFullPath($VbsPath)
        $existingArguments = [string]$existing.Arguments
        $containsExpectedVbs = ($existingArguments.IndexOf($expectedVbs, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        return ($actualTarget -ieq $expectedTarget -and $containsExpectedVbs -and
            [string]$existing.Description -like '*LocalAI Creative Studio*')
    } catch { return $false }
}

function Ensure-PlainDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A required Windows folder path is empty.' }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to write into a file, junction or symbolic link: $Path"
        }
        return
    }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "New Windows folder is not a plain directory: $Path"
    }
}

function Get-SafeShortcutPath([string]$Directory, [string]$BaseName, [string]$WScriptPath, [string]$VbsPath, $Shell) {
    $candidate = Join-Path $Directory ($BaseName + '.lnk')
    $entry = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    if (-not $entry) { return $candidate }
    if (Test-OwnedShortcut $candidate $WScriptPath $VbsPath $Shell) { return $candidate }
    # Never overwrite a same-named shortcut owned by another application or the user.
    for ($suffix = 2; $suffix -le 99; $suffix++) {
        $candidate = Join-Path $Directory ($BaseName + ' (' + $suffix + ').lnk')
        $entry = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if (-not $entry) { return $candidate }
        if (Test-OwnedShortcut $candidate $WScriptPath $VbsPath $Shell) { return $candidate }
    }
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $unique = [guid]::NewGuid().ToString('N').Substring(0,8)
        $candidate = Join-Path $Directory ($BaseName + ' (' + $unique + ').lnk')
        if (-not (Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue)) { return $candidate }
    }
    throw "Could not create a collision-free shortcut name for '$BaseName' in '$Directory'. No existing shortcut was changed."
}
function Write-SafeShortcut(
    [string]$ShortcutPath,
    [string]$TargetPath,
    [string]$Arguments,
    [string]$WorkingDirectory,
    [string]$Description,
    [string]$IconLocation,
    $Shell,
    [string]$WScriptPath,
    [string]$VbsPath
) {
    $directory = Split-Path -Parent $ShortcutPath
    Ensure-PlainDirectory $directory
    # Keep both temporary files beside the shortcut. File.Replace requires all
    # transaction paths to be on the same volume (Desktop may be redirected).
    $temporary = Join-Path $directory ('.localai-creative-studio-' + [guid]::NewGuid().ToString('N') + '.tmp.lnk')
    $backup = Join-Path $directory ('.localai-creative-studio-backup-' + [guid]::NewGuid().ToString('N') + '.tmp.lnk')
    try {
        $shortcut = $Shell.CreateShortcut($temporary)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.Description = $Description
        $shortcut.IconLocation = $IconLocation
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        $temporaryItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
        if ($temporaryItem.PSIsContainer -or (($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'The temporary application shortcut is not a regular file.'
        }

        if (Test-Path -LiteralPath $ShortcutPath) {
            # Re-check ownership at commit time. File.Replace is atomic and is allowed
            # only for a shortcut whose target, VBS script and description still match.
            if (-not (Test-OwnedShortcut $ShortcutPath $WScriptPath $VbsPath $Shell)) {
                throw "The shortcut name became occupied by another program or user during installation; it was not overwritten: $ShortcutPath"
            }
            [System.IO.File]::Replace($temporary, $ShortcutPath, $backup)
            if (Test-Path -LiteralPath $backup) {
                $backupItem = Get-Item -LiteralPath $backup -Force -ErrorAction Stop
                if ($backupItem.PSIsContainer -or (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw 'The shortcut transaction produced an unsafe backup file.'
                }
                # This hidden backup is created by this transaction in the same
                # directory and removed only after the owned shortcut is replaced.
                Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            }
        } else {
            # File.Move fails if another app creates the target after name selection;
            # unlike COM Save, it cannot silently replace a newly-created shortcut.
            [System.IO.File]::Move($temporary, $ShortcutPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            $temporaryItem = Get-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            if ($temporaryItem -and -not $temporaryItem.PSIsContainer -and (($temporaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

if (-not $Installed) {
    $installParent = Join-Path $env:LOCALAPPDATA 'Programs'
    if (Test-Path -LiteralPath $installParent -PathType Container) {
        $parentItem = Get-Item -LiteralPath $installParent -Force
        if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a redirected per-user Programs directory: $installParent" }
    } else {
        Ensure-PlainDirectory $installParent
    }
    # Re-check the resolved parent after creation. Never copy into a redirected path.
    Ensure-PlainDirectory $installParent
    Write-Host 'Preparing or updating the permanent per-user desktop application...' -ForegroundColor Cyan
    $sourceFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $installFull = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if (Test-Path -LiteralPath $InstallRoot) {
        if (-not (Test-ManagedInstall)) {
            throw "Safety stop: the selected LocalAI installation path is occupied by an unverified file or directory: '$InstallRoot'. No existing item was changed. Choose another per-user location and retry."
        }
        Write-InstallOwnershipMarker
    }
    if ($sourceFull -ieq $installFull) {
        if (-not (Test-ManagedInstall)) { throw 'The current directory is not a verified LocalAI Creative Studio installation.' }
        Write-InstallOwnershipMarker
    }
    if ($sourceFull -ine $installFull) {
        $sourceVerifier = Join-Path $SourceRoot 'scripts\VERIFY-PACKAGE.ps1'
        if (-not (Test-Path -LiteralPath $sourceVerifier -PathType Leaf)) { throw 'Source package verifier is missing. Extract the complete ZIP.' }
        $global:LASTEXITCODE = 0
        & $sourceVerifier
        if ($LASTEXITCODE -ne 0) { throw 'The source package did not pass integrity verification.' }

        # If a previous installation exists, use the non-destructive updater.
        # Running SETUP-AND-START.bat therefore also applies future releases in place.
        $sourceUpdater = Join-Path $SourceRoot 'scripts\APPLY-UPDATE.ps1'
        $installedLauncher = Join-Path $InstallRoot 'scripts\LAUNCH-DESKTOP.ps1'
        if ((Test-Path -LiteralPath $installedLauncher -PathType Leaf) -and (Test-Path -LiteralPath $sourceUpdater -PathType Leaf)) {
            if (-not (Test-Path -LiteralPath $SystemPowerShell -PathType Leaf)) { $SystemPowerShell = 'powershell.exe' }
            $updateArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$sourceUpdater)
            if ($NoLaunch) { $updateArgs += '-NoLaunch' }
            & $SystemPowerShell @updateArgs
            if ($LASTEXITCODE -ne 0) { throw 'The desktop update did not complete. Read the desktop-update log.' }
            exit 0
        }

        # First install: only write into a new or explicitly owned folder. Never mirror or wipe.
        # A pre-existing empty install folder is allowed after Test-ManagedInstall has
        # verified it is empty; do not try to create it a second time. If it appeared
        # after the earlier check, validate it again before claiming ownership.
        if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
            if (-not (Test-ManagedInstall)) {
                throw "Safety stop: the install folder appeared or changed during setup and is not an owned LocalAI folder: $InstallRoot"
            }
        } else {
            New-Item -ItemType Directory -Path $InstallRoot -ErrorAction Stop | Out-Null
        }
        Write-InstallOwnershipMarker
        $copyArgs = @($SourceRoot,$InstallRoot,'/E','/R:2','/W:2','/NFL','/NDL','/NJH','/NJS','/NP','/XD','.venv','.venv.next','__pycache__','.pytest_cache','.mypy_cache','.ruff_cache','node_modules','.git','.idea','.vscode','/XF','*.sqlite*','*.db*','*.log','*.pyc','*.pyo','*.tmp','*.bak')
        & robocopy.exe @copyArgs
        if ($LASTEXITCODE -ge 8) { throw "Could not copy application files into $InstallRoot (robocopy exit code $LASTEXITCODE)." }
        if (-not (Test-Path -LiteralPath $SystemPowerShell -PathType Leaf)) { $SystemPowerShell = 'powershell.exe' }
        $installedArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $InstallRoot 'scripts\INSTALL-DESKTOP-APP.ps1'),'-Installed','-SkipPackageVerification')
        if ($NoLaunch) { $installedArgs += '-NoLaunch' }
        & $SystemPowerShell @installedArgs
        if ($LASTEXITCODE -ne 0) { throw 'The installed application setup step failed. Run SETUP-AND-START.bat again and inspect its setup log.' }
        exit 0
    }
    $Installed = $true
}
$Root = Split-Path -Parent $PSScriptRoot
if ([System.IO.Path]::GetFullPath($Root).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')) {
    if (-not (Test-ManagedInstall)) { throw "Refusing to run setup from an unverified application directory: $Root" }
    Write-InstallOwnershipMarker
}
$Venv = Join-Path $Root '.venv'
$Python = Join-Path $Venv 'Scripts\python.exe'
$Requirements = Join-Path $Root 'requirements.txt'
$Verifier = Join-Path $PSScriptRoot 'VERIFY-PACKAGE.ps1'
$DataRoot = Get-LocalAIDataRoot -RecoverLegacyStatus
$LogRoot = Join-Path $DataRoot 'logs'
Ensure-PlainDirectory $DataRoot
Ensure-PlainDirectory $LogRoot
$LogFile = Join-Path $LogRoot ('desktop-setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
Start-Transcript -LiteralPath $LogFile -Force | Out-Null

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Fail([string]$Text) { throw $Text }
function Test-PythonRuntime([string]$Executable) {
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return $false }
    try {
        $pythonItem = Get-Item -LiteralPath $Executable -Force -ErrorAction Stop
        if ($pythonItem.PSIsContainer -or (($pythonItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $null = & $Executable -c 'import sys,struct; print(sys.version.split()[0]); raise SystemExit(0 if (sys.version_info >= (3,11) and sys.version_info < (3,15) and struct.calcsize("P") == 8) else 2)' 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
function Test-PythonBootstrapRuntime([string]$Executable) {
    if (-not (Test-PythonRuntime $Executable)) { return $false }
    try {
        & $Executable -c 'import pip,venv,ensurepip,ssl,sqlite3,ctypes; print("Python bootstrap components are available.")' *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
function Add-PythonCandidate([System.Collections.Generic.List[string]]$List, [string]$Candidate) {
    if ($Candidate -and (Test-Path -LiteralPath $Candidate -PathType Leaf) -and $Candidate -notmatch '(?i)\\WindowsApps\\') {
        if (-not $List.Contains($Candidate)) { $List.Add($Candidate) }
    }
}
function Find-UsablePython {
    $candidates = New-Object 'System.Collections.Generic.List[string]'

    # Read registered CPython locations first; do not rely on PATH or Store aliases.
    $registryRoots = @(
        'HKCU:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\Python\PythonCore',
        'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore'
    )
    foreach ($registryRoot in $registryRoots) {
        if (Test-Path -LiteralPath $registryRoot) {
            foreach ($versionKey in (Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending)) {
                $installKey = Join-Path $versionKey.PSPath 'InstallPath'
                try {
                    $install = (Get-Item -LiteralPath $installKey -ErrorAction Stop).GetValue('')
                    if ($install) { Add-PythonCandidate $candidates (Join-Path $install 'python.exe') }
                } catch {}
            }
        }
    }

    $knownPaths = @(
        (Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime\Python314-LocalAI\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime\Python314-LocalAI-fallback\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime\Python314\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime\Python314-fallback\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        'C:\Python314\python.exe',
        'C:\Python313\python.exe',
        (Join-Path $DataRoot 'runtime\Python314\python.exe'),
        (Join-Path $DataRoot 'runtime\Python314-fallback\python.exe'),
        (Join-Path $DataRoot 'runtime\Python313\python.exe'),
        (Join-Path $DataRoot 'runtime\Python313-fallback\python.exe'),
        (Join-Path $env:ProgramFiles 'Python314\python.exe'),
        (Join-Path $env:ProgramFiles 'Python313\python.exe'),
        (Join-Path $env:ProgramFiles 'Python312\python.exe'),
        (Join-Path $env:ProgramFiles 'Python311\python.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Python313\python.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Python312\python.exe')
    )
    foreach ($candidate in $knownPaths) { Add-PythonCandidate $candidates $candidate }

    foreach ($commandName in @('python.exe','python3.exe')) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source) { Add-PythonCandidate $candidates $command.Source }
    }

    $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($launcher -and $launcher.Source) {
        foreach ($version in @('3.14','3.13','3.12','3.11')) {
            try {
                $resolved = @(& $launcher.Source "-$version" -c 'import sys; print(sys.executable)' 2>$null)
                if ($LASTEXITCODE -eq 0 -and $resolved.Count -gt 0) { Add-PythonCandidate $candidates ([string]$resolved[-1]).Trim() }
            } catch {}
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-PythonBootstrapRuntime $candidate) { return $candidate }
    }
    return $null
}
function Install-OfficialPython([string]$DownloadRoot, [string]$InstallLogRoot) {
    # Pinned official security-maintenance CPython release; verify both SHA-256 and Authenticode.
    $pythonVersion = '3.14.10'
    $installerUrl = 'https://www.python.org/ftp/python/3.14.10/python-3.14.10-amd64.exe'
    $expectedSha256 = '92480239264744fe0386a1bd8275786fefa126e3129e56a68e22b52c73329965'
    # Content-addressed cache name: never overwrite/delete an unrelated file that happens
    # to use a generic installer filename in the user's data folder.
    $installerPath = Join-Path $DownloadRoot ('python-3.14.10-amd64-' + $expectedSha256.Substring(0,16) + '.exe')

    # A previous attempt may have completed Python installation before the Studio venv failed.
    $alreadyInstalled = Find-UsablePython
    if ($alreadyInstalled) {
        Write-Host "Reusing a compatible, fully verified Python runtime: $alreadyInstalled" -ForegroundColor Green
        return $alreadyInstalled
    }

    Ensure-PlainDirectory $DownloadRoot
    Ensure-PlainDirectory $InstallLogRoot
    $downloadTemp = Join-Path $DownloadRoot ('.python-download-' + [guid]::NewGuid().ToString('N') + '.tmp.exe')
    if (Test-Path -LiteralPath $installerPath) {
        $cachedItem = Get-Item -LiteralPath $installerPath -Force -ErrorAction Stop
        if ($cachedItem.PSIsContainer -or (($cachedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw 'The content-addressed Python installer cache path is not a regular file; it was not changed.'
        }
        $cachedHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cachedHash -ne $expectedSha256) {
            throw 'The content-addressed Python installer cache has an unexpected SHA-256 hash. It was not overwritten or deleted.'
        }
        Write-Host "Reusing verified official Python $pythonVersion installer cache." -ForegroundColor Green
    } else {
        Write-Host "Downloading official Python $pythonVersion x64 from python.org..." -ForegroundColor Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $downloadTemp -UseBasicParsing -TimeoutSec 900
        } catch {
            if (Test-Path -LiteralPath $downloadTemp -PathType Leaf) {
                $partialItem = Get-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue
                if ($partialItem -and -not $partialItem.PSIsContainer -and (($partialItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                    Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue
                }
            }
            throw "Could not download Python $pythonVersion from python.org. Check internet access or firewall. Download error: $($_.Exception.Message)"
        }
        if (-not (Test-Path -LiteralPath $downloadTemp -PathType Leaf) -or (Get-Item -LiteralPath $downloadTemp -Force).Length -lt 25000000) {
            if (Test-Path -LiteralPath $downloadTemp -PathType Leaf) { Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue }
            throw 'The official Python installer download is incomplete or unexpectedly small. It was not executed.'
        }
        $downloadHash = (Get-FileHash -LiteralPath $downloadTemp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($downloadHash -ne $expectedSha256) {
            Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue
            throw "The downloaded Python installer failed the pinned SHA-256 check. Expected $expectedSha256; received $downloadHash. It was not executed."
        }
        # Atomically publish only the exact verified download. File.Move fails on a race
        # rather than replacing a file created by another process.
        try {
            [System.IO.File]::Move($downloadTemp, $installerPath)
            $downloadTemp = $null
        } catch {
            $moveError = $_
            $cacheAppeared = Test-Path -LiteralPath $installerPath -PathType Leaf
            if ($cacheAppeared) {
                $racedHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($racedHash -ne $expectedSha256) {
                    if ($downloadTemp -and (Test-Path -LiteralPath $downloadTemp -PathType Leaf)) { Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue }
                    throw 'A different file appeared at the Python installer cache path. It was not overwritten.'
                }
                if ($downloadTemp -and (Test-Path -LiteralPath $downloadTemp -PathType Leaf)) { Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue }
                $downloadTemp = $null
            } else {
                if ($downloadTemp -and (Test-Path -LiteralPath $downloadTemp -PathType Leaf)) { Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue }
                throw $moveError
            }
        }
    }

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw 'The verified Python installer is missing from its cache location.' }
    $actualSha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "The cached Python installer failed the pinned SHA-256 check. Expected $expectedSha256; received $actualSha256. It was not executed."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { 'No signer certificate' }
    Write-Host "Python installer signature: $($signature.Status); signer: $signer"
    if ($signature.Status -ne 'Valid' -or $signer -notmatch '(?i)Python Software Foundation') {
        throw "The downloaded installer did not pass signature validation. Status: $($signature.Status); signer: $signer. It was not executed."
    }

    # Keep the runtime on the user's system drive first. D: may contain model storage or
    # have different ACLs; using LocalAppData avoids making the app's runtime depend on it.
    # The D:/data-root targets remain as compatibility fallbacks for older installations.
    $localRuntimeRoot = Join-Path $env:LOCALAPPDATA 'LocalAI\CreativeStudioRuntime'
    $attempts = @(
        [pscustomobject]@{ Path = (Join-Path $localRuntimeRoot 'Python314-LocalAI'); Name = 'localappdata-primary' },
        [pscustomobject]@{ Path = (Join-Path $localRuntimeRoot 'Python314-LocalAI-fallback'); Name = 'localappdata-fallback' },
        [pscustomobject]@{ Path = (Join-Path $localRuntimeRoot 'Python314'); Name = 'legacy-localappdata-primary' },
        [pscustomobject]@{ Path = (Join-Path $localRuntimeRoot 'Python314-fallback'); Name = 'legacy-localappdata-fallback' },
        [pscustomobject]@{ Path = (Join-Path $DataRoot 'runtime\Python314'); Name = 'legacy-data-primary' },
        [pscustomobject]@{ Path = (Join-Path $DataRoot 'runtime\Python314-fallback'); Name = 'legacy-data-fallback' }
    )
    $lastInstallLog = $null
    foreach ($attempt in $attempts) {
        $runtimeRecord = $null
        $targetDir = [System.IO.Path]::GetFullPath($attempt.Path).TrimEnd('\')
        $pythonInstallLog = Join-Path $InstallLogRoot ('python-runtime-' + $attempt.Name + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
        $lastInstallLog = $pythonInstallLog

        try {
            $targetParent = [System.IO.Path]::GetDirectoryName($targetDir)
            Ensure-PlainDirectory $targetParent
            if (Test-Path -LiteralPath $targetDir) {
                $targetItem = Get-Item -LiteralPath $targetDir -Force -ErrorAction Stop
                if (-not $targetItem.PSIsContainer -or (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                    throw "Refusing an invalid or redirected Python installation target: $targetDir"
                }
                $runtimeMarker = Join-Path $targetDir '.localai-python-runtime.json'
                if (Test-Path -LiteralPath $runtimeMarker) {
                    $markerItem = Get-Item -LiteralPath $runtimeMarker -Force -ErrorAction Stop
                    if ($markerItem.PSIsContainer -or (($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                        throw "Refusing a redirected Python runtime ownership marker: $runtimeMarker"
                    }
                    $runtimeRecord = Get-Content -LiteralPath $runtimeMarker -Raw | ConvertFrom-Json -ErrorAction Stop
                    $runtimeState = if ($runtimeRecord.PSObject.Properties.Name -contains 'state') { [string]$runtimeRecord.state } else { 'READY' }
                    if ($runtimeRecord.product_id -ne 'localai-creative-studio' -or $runtimeRecord.schema_version -ne 1 -or
                        [System.IO.Path]::GetFullPath([string]$runtimeRecord.runtime_path).TrimEnd('\') -ine $targetDir -or
                        $runtimeState -notin @('INSTALLING','READY')) {
                        throw "The existing Python target is not owned by LocalAI Creative Studio: $targetDir"
                    }
                } else {
                    $existingItems = @(Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction Stop | Select-Object -First 1)
                    if ($existingItems.Count -gt 0) {
                        throw "The Python target already contains files but has no verified LocalAI ownership marker. It was left untouched: $targetDir"
                    }
                    $runtimeRecord = $null
                }
            } else {
                New-Item -ItemType Directory -Path $targetDir -ErrorAction Stop | Out-Null
                $targetItem = Get-Item -LiteralPath $targetDir -Force -ErrorAction Stop
                if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Refusing a redirected Python installation target: $targetDir"
                }
            }
        } catch {
            Write-Host "Python target '$($attempt.Name)' is not safe or writable: $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }

        $runtimeMarker = Join-Path $targetDir '.localai-python-runtime.json'
        if (-not $runtimeRecord) {
            # The directory was empty and had no owner. Claim it before launching the
            # installer so an interrupted/partial install can be resumed next time.
            $runtimeMarkerRecord = [ordered]@{
                product_id = 'localai-creative-studio'
                schema_version = 1
                runtime_path = $targetDir
                python_exe = (Join-Path $targetDir 'python.exe')
                python_version = $pythonVersion
                state = 'INSTALLING'
                installer_sha256 = $expectedSha256
                verified_at = $null
            }
            $runtimeMarkerText = $runtimeMarkerRecord | ConvertTo-Json -Depth 3
            try {
                New-Item -ItemType File -Path $runtimeMarker -ErrorAction Stop | Out-Null
                Set-Content -LiteralPath $runtimeMarker -Value $runtimeMarkerText -Encoding UTF8 -ErrorAction Stop
            } catch {
                throw "Could not claim the empty Python runtime folder safely: $runtimeMarker. $($_.Exception.Message)"
            }
        } else {
            # Rebuild rather than mutate the object so markers from earlier releases
            # (which did not include state/installer_sha256) are upgraded safely.
            ([ordered]@{
                product_id = 'localai-creative-studio'
                schema_version = 1
                runtime_path = $targetDir
                python_exe = (Join-Path $targetDir 'python.exe')
                python_version = $pythonVersion
                state = 'INSTALLING'
                installer_sha256 = $expectedSha256
                verified_at = $null
            } | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $runtimeMarker -Encoding UTF8
        }

        Write-Host "Installing Python into this app-owned per-user runtime folder: $targetDir" -ForegroundColor Cyan
        # InstallAllUsers=0, Include_launcher=0 and PATH/association flags keep this isolated.
        # Use TargetDir explicitly and verify python.exe at that exact path after exit.
        $installArguments = '/passive InstallAllUsers=0 TargetDir="' + $targetDir + '" Include_dev=1 Include_exe=1 Include_lib=1 Include_pip=1 Include_tools=0 Include_launcher=0 Include_tcltk=0 Include_test=0 Include_doc=0 Shortcuts=0 PrependPath=0 AppendPath=0 AssociateFiles=0'
        $installArguments += ' /log "' + $pythonInstallLog + '"'
        try {
            $process = Start-Process -FilePath $installerPath -ArgumentList $installArguments -Wait -PassThru -ErrorAction Stop
        } catch {
            Write-Host "Python installation attempt '$($attempt.Name)' could not start: $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }
        Write-Host "Python installer exit code ($($attempt.Name)): $($process.ExitCode)"
        if ($process.ExitCode -notin @(0, 3010)) {
            $tail = if (Test-Path -LiteralPath $pythonInstallLog -PathType Leaf) { (Get-Content -LiteralPath $pythonInstallLog -Tail 24 -ErrorAction SilentlyContinue) -join ' | ' } else { 'Installer log was not created.' }
            Write-Host "Python installation attempt failed. $tail Log: $pythonInstallLog" -ForegroundColor Yellow
            continue
        }

        $directPython = Join-Path $targetDir 'python.exe'
        if (Test-PythonBootstrapRuntime $directPython) {
            $probeOutput = @(& $directPython -c 'import sys,struct,pip,venv,ensurepip,ssl,sqlite3,ctypes; print(sys.executable); print(sys.version); print("bits=" + str(struct.calcsize("P")*8))' 2>&1)
            Write-Host "Python runtime verified at explicit target: $directPython" -ForegroundColor Green
            Write-Host (($probeOutput | ForEach-Object { [string]$_ }) -join ' | ') -ForegroundColor Green
            $runtimeMarker = Join-Path $targetDir '.localai-python-runtime.json'
            $runtimeMarkerItem = Get-Item -LiteralPath $runtimeMarker -Force -ErrorAction Stop
            if ($runtimeMarkerItem.PSIsContainer -or (($runtimeMarkerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw "Refusing to replace an invalid Python runtime marker: $runtimeMarker"
            }
            ([ordered]@{ product_id = 'localai-creative-studio'; schema_version = 1; runtime_path = $targetDir; python_exe = $directPython; python_version = $pythonVersion; state = 'READY'; installer_sha256 = $expectedSha256; verified_at = (Get-Date).ToString('o') } | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $runtimeMarker -Encoding UTF8
            # Keep the content-addressed installer cache for a reliable retry/repair. It is
            # verified against the pinned hash and never overwrites any other file.
            return $directPython
        }
        Write-Host "Installer exit code was $($process.ExitCode), but python.exe did not pass the full 64-bit/pip/venv/SSL/SQLite probe at: $directPython" -ForegroundColor Yellow

        # Some installers finish in a registered per-user location despite TargetDir.
        # Rediscover all known CPython installs before downloading or installing again.
        $installedPython = Find-UsablePython
        if ($installedPython) {
            Write-Host "A compatible Python runtime was found after installation: $installedPython" -ForegroundColor Green
            # Keep the content-addressed official installer cache for deterministic repair.
            return $installedPython
        }

        $tail = if (Test-Path -LiteralPath $pythonInstallLog -PathType Leaf) {
            (Get-Content -LiteralPath $pythonInstallLog -Tail 24 -ErrorAction SilentlyContinue) -join ' | '
        } else { 'Installer log was not created.' }
        Write-Host "Python runtime was not found after '$($attempt.Name)'. $tail" -ForegroundColor Yellow
    }

    if ($downloadTemp -and (Test-Path -LiteralPath $downloadTemp -PathType Leaf)) {
        $tempItem = Get-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue
        if ($tempItem -and -not $tempItem.PSIsContainer -and (($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
            Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue
        }
    }
    $expectedPaths = @(
        (Join-Path $localRuntimeRoot 'Python314-LocalAI\python.exe'),
        (Join-Path $localRuntimeRoot 'Python314-LocalAI-fallback\python.exe'),
        (Join-Path $localRuntimeRoot 'Python314\python.exe'),
        (Join-Path $localRuntimeRoot 'Python314-fallback\python.exe'),
        (Join-Path $DataRoot 'runtime\Python314\python.exe'),
        (Join-Path $DataRoot 'runtime\Python314-fallback\python.exe')
    )
    $pathReport = $expectedPaths | ForEach-Object { "  $_ : $(Test-Path -LiteralPath $_ -PathType Leaf)" }
    $diagnostics = @(
        'Python 3.14.10 installer returned but no acceptable 64-bit runtime was verified.',
        'The installer log files are preserved under the Studio logs folder:',
        "  Last installer log: $lastInstallLog",
        'Expected runtime paths:',
        ($pathReport -join "`r`n")
    ) -join "`r`n"
    throw $diagnostics
}

try {
    Write-Host 'LOCALAI CREATIVE STUDIO - DESKTOP APP INSTALLER' -ForegroundColor Green
    Write-Host "First install or safe update. It creates or refreshes only this app's Desktop shortcut."
    Write-Host 'Other Desktop icons, shortcuts and applications are never removed or overwritten. Ollama, Qwen, Open WebUI and ComfyUI data are not changed.' -ForegroundColor Green

    Step 'Verify the complete package'
    if (-not (Test-Path -LiteralPath $Verifier -PathType Leaf)) { Fail 'Package verification script is missing. Extract the complete ZIP first.' }
    if (-not $SkipPackageVerification) { $global:LASTEXITCODE = 0; & $Verifier; if ($LASTEXITCODE -ne 0) { Fail 'Installed package integrity check failed.' } } else { Write-Host 'Package files were verified by the source-package updater.' -ForegroundColor Green }

    Step 'Check the built-in Windows PowerShell'
    if (-not (Test-Path -LiteralPath $SystemPowerShell -PathType Leaf)) { Fail 'Windows PowerShell was not found in its standard Windows location.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $SystemPowerShell
    Write-Host "Using Windows PowerShell: $SystemPowerShell"
    Write-Host "Windows PowerShell signature status: $($signature.Status)"
    if ($signature.Status -ne 'Valid') { Write-Warning 'Windows did not report a valid Authenticode signature for the built-in PowerShell executable. The setup will not download or replace PowerShell.' }

    Step 'Find or automatically prepare a private Python runtime'
    if (-not [Environment]::Is64BitOperatingSystem) { Fail 'This desktop edition requires 64-bit Windows.' }
    $basePython = Find-UsablePython
    if ($basePython) {
        Write-Host "Found a compatible 64-bit Python runtime: $basePython" -ForegroundColor Green
    } else {
        $downloadRoot = Join-Path $DataRoot 'downloads'
        $basePython = Install-OfficialPython -DownloadRoot $downloadRoot -InstallLogRoot $LogRoot
    }
    if (-not (Test-PythonRuntime $basePython)) { Fail "The selected Python runtime failed the final validation: $basePython" }
    Write-Host ((& $basePython --version 2>&1) -join ' ') -ForegroundColor Green

    function Test-StudioEnvironment([string]$PythonExe) {
        if (-not (Test-PythonRuntime $PythonExe)) { return $false }
        try {
            & $PythonExe -m pip --version *> $null
            if ($LASTEXITCODE -ne 0) { return $false }
            & $PythonExe -c 'import fastapi,httpx,psutil,uvicorn,multipart,pydantic; print("Studio dependencies imported successfully.")' *> $null
            if ($LASTEXITCODE -ne 0) { return $false }
            & $PythonExe -m pip check *> $null
            return ($LASTEXITCODE -eq 0)
        } catch { return $false }
    }
    function Test-StudioApplication([string]$PythonExe) {
        Push-Location $Root
        try {
            & $PythonExe -m compileall -q (Join-Path $Root 'studio') (Join-Path $Root 'tests')
            if ($LASTEXITCODE -ne 0) { return $false }
            & $PythonExe -c 'from studio.server import app; from fastapi import FastAPI; assert isinstance(app, FastAPI); print("Studio FastAPI app smoke test passed.")'
            if ($LASTEXITCODE -ne 0) { return $false }
            # Do not promote a dependency set or refresh the Desktop icon until the
            # entire shipped regression suite passes against the exact staged runtime.
            & $PythonExe -m unittest discover -s (Join-Path $Root 'tests') -q
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'The complete LocalAI regression suite failed. The previous .venv and Desktop integration were not promoted.' -ForegroundColor Red
                return $false
            }
            Write-Host 'The complete LocalAI regression suite passed in the staging environment.' -ForegroundColor Green
            return $true
        } finally { Pop-Location }
    }

    Step 'Prepare the isolated Studio Python environment'
    $env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
    $env:PYTHONUNBUFFERED = '1'
    $requirementsHash = (Get-FileHash -LiteralPath $Requirements -Algorithm SHA256).Hash.ToLowerInvariant()
    $dependencyState = Join-Path $DataRoot 'requirements.sha256'
    $priorRequirementsHash = if (Test-Path -LiteralPath $dependencyState -PathType Leaf) { (Get-Content -LiteralPath $dependencyState -Raw).Trim() } else { '' }
    $dependenciesReady = ($priorRequirementsHash -eq $requirementsHash) -and (Test-StudioEnvironment $Python)

    if (-not $dependenciesReady) {
        Write-Host 'Building or repairing the Studio environment in a temporary folder. The existing environment is kept until every dependency and application test succeeds...' -ForegroundColor Cyan
        $CandidateVenv = Join-Path $Root '.venv.next'
        $CandidatePython = Join-Path $CandidateVenv 'Scripts\python.exe'
        if (Test-Path -LiteralPath $CandidateVenv -PathType Container) {
            $candidateItem = Get-Item -LiteralPath $CandidateVenv -Force
            if (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to move a redirected .venv.next directory.' }
            $candidateBackup = "$CandidateVenv.incomplete-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            Move-Item -LiteralPath $CandidateVenv -Destination $candidateBackup
            Write-Host "Preserved an incomplete staging environment at: $candidateBackup" -ForegroundColor Yellow
        }

        & $basePython -m venv $CandidateVenv
        if ($LASTEXITCODE -ne 0 -or -not (Test-PythonRuntime $CandidatePython)) {
            throw 'Could not create a staging virtual environment using the selected Python runtime. The installed application environment was not changed.'
        }
        & $CandidatePython -m pip install --disable-pip-version-check --upgrade pip
        if ($LASTEXITCODE -ne 0) { throw 'Could not prepare pip in the staging environment. The previous .venv was left untouched.' }
        & $CandidatePython -m pip install --disable-pip-version-check --only-binary=:all: -r $Requirements
        if ($LASTEXITCODE -ne 0) { throw 'Studio dependency installation failed in the staging environment. The previous .venv was left untouched.' }
        & $CandidatePython -m pip check
        if ($LASTEXITCODE -ne 0) { throw 'The staging Python environment contains conflicting or incomplete packages. The previous .venv was left untouched.' }
        if (-not (Test-StudioEnvironment $CandidatePython)) { throw 'Staging environment import/pip validation failed. The previous .venv was left untouched.' }
        if (-not (Test-StudioApplication $CandidatePython)) { throw 'The Studio application smoke test failed in the staging environment. The previous .venv was left untouched.' }

        $venvBackup = $null
        if (Test-Path -LiteralPath $Venv -PathType Container) {
            $venvItem = Get-Item -LiteralPath $Venv -Force
            if (($venvItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to replace or move a redirected .venv directory.' }
            $venvBackup = Join-Path $Root ('.venv.previous-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
            Move-Item -LiteralPath $Venv -Destination $venvBackup
        }
        try {
            Move-Item -LiteralPath $CandidateVenv -Destination $Venv
            $Python = Join-Path $Venv 'Scripts\python.exe'
            if (-not (Test-StudioEnvironment $Python) -or -not (Test-StudioApplication $Python)) {
                throw 'The promoted Python environment did not pass its final post-swap validation.'
            }
            Set-Content -LiteralPath $dependencyState -Value $requirementsHash -Encoding ASCII
            Write-Host 'The new Python environment passed validation and was activated successfully.' -ForegroundColor Green
            if ($venvBackup) { Write-Host "The previous environment was preserved at: $venvBackup" -ForegroundColor Yellow }
        } catch {
            if (Test-Path -LiteralPath $Venv -PathType Container) {
                $failedVenv = Join-Path $Root ('.venv.failed-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Move-Item -LiteralPath $Venv -Destination $failedVenv -ErrorAction SilentlyContinue
            }
            if ($venvBackup -and (Test-Path -LiteralPath $venvBackup -PathType Container)) {
                Move-Item -LiteralPath $venvBackup -Destination $Venv -ErrorAction SilentlyContinue
            }
            throw
        }
    } else {
        Write-Host 'Studio dependencies are present, import correctly and pass pip check. No package download is required.' -ForegroundColor Green
        $Python = Join-Path $Venv 'Scripts\python.exe'
        if (-not (Test-StudioApplication $Python)) { Fail 'Studio application smoke test failed. The desktop shortcut was not refreshed.' }
    }
    Write-Host ((& $Python --version 2>&1) -join ' ') -ForegroundColor Green
    Step 'Prepare desktop launcher and shortcuts'
    $VbsPath = Join-Path $Root 'Launch-LocalAI-Creative-Studio.vbs'
    $LauncherScript = Join-Path $PSScriptRoot 'LAUNCH-DESKTOP.ps1'
    if (-not (Test-Path -LiteralPath $LauncherScript -PathType Leaf)) { Fail 'Desktop app launcher script is missing.' }
    if (-not (Test-Path -LiteralPath $VbsPath -PathType Leaf)) { Fail 'Desktop app VBS launcher is missing.' }

    $Desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if ([string]::IsNullOrWhiteSpace($Desktop)) { $Desktop = Join-Path $env:USERPROFILE 'Desktop' }
    Ensure-PlainDirectory $Desktop

    $StartMenuBase = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu'
    Ensure-PlainDirectory $env:APPDATA
    Ensure-PlainDirectory (Join-Path $env:APPDATA 'Microsoft')
    Ensure-PlainDirectory (Join-Path $env:APPDATA 'Microsoft\Windows')
    Ensure-PlainDirectory $StartMenuBase
    $StartMenu = Join-Path $StartMenuBase 'Programs'
    Ensure-PlainDirectory $StartMenu
    $IconSource = Join-Path $Root 'assets\localai-creative-studio.ico'
    if (-not (Test-Path -LiteralPath $IconSource -PathType Leaf)) { Fail 'The desktop icon asset is missing.' }
    $iconSourceItem = Get-Item -LiteralPath $IconSource -Force
    if (($iconSourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail 'The desktop icon source must be a regular package file.' }
    $IconHash = (Get-FileHash -LiteralPath $IconSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $IconDir = Join-Path $DataRoot 'desktop-icons'
    Ensure-PlainDirectory $IconDir
    $Icon = Join-Path $IconDir ('localai-creative-studio-' + $IconHash + '.ico')
    if (Test-Path -LiteralPath $Icon) {
        $iconItem = Get-Item -LiteralPath $Icon -Force
        if ($iconItem.PSIsContainer -or (($iconItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Fail 'A redirected or invalid icon-cache entry was found. It was not overwritten.' }
        $cachedHash = (Get-FileHash -LiteralPath $Icon -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cachedHash -ne $IconHash) { Fail 'The existing icon cache does not match its content-addressed filename. It was not overwritten.' }
    } else {
        # The full SHA-256 filename makes every icon release immutable; an old cached icon is never overwritten.
        Copy-Item -LiteralPath $IconSource -Destination $Icon -ErrorAction Stop
        $copiedHash = (Get-FileHash -LiteralPath $Icon -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($copiedHash -ne $IconHash) { Fail 'The new desktop icon did not pass its post-copy SHA-256 check.' }
    }
    $WScript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $WScript)) { $WScript = 'wscript.exe' }
    $shell = New-Object -ComObject WScript.Shell

    # Create a new shortcut or update only a shortcut that is provably ours.
    # A pre-existing same-name shortcut owned by another app/user is never replaced.
    $desktopShortcutPath = Get-SafeShortcutPath $Desktop 'LocalAI Creative Studio' $WScript $VbsPath $shell
    $startMenuShortcutPath = Get-SafeShortcutPath $StartMenu 'LocalAI Creative Studio' $WScript $VbsPath $shell
    foreach ($shortcutPath in @($desktopShortcutPath, $startMenuShortcutPath)) {
        Write-SafeShortcut $shortcutPath $WScript ('//B //Nologo "' + $VbsPath + '"') $Root `
            'Open LocalAI Creative Studio as a desktop app window' "$Icon,0" $shell $WScript $VbsPath
    }

    $stopVbs = Join-Path $Root 'Exit-LocalAI-Creative-Studio.vbs'
    $stopShortcutPath = Get-SafeShortcutPath $StartMenu 'Exit LocalAI Creative Studio' $WScript $stopVbs $shell
    Write-SafeShortcut $stopShortcutPath $WScript ('//B //Nologo "' + $stopVbs + '"') $Root `
        'Exit LocalAI Creative Studio only' "$Icon,0" $shell $WScript $stopVbs

    $versionFile = Join-Path $Root 'VERSION.txt'
    $appVersion = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { "unknown" }
    $statusLines = @(
        "STATUS: SUCCESS"
        ("DATE: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))
        "APP: LocalAI Creative Studio"
        ("VERSION: " + $appVersion)
        ("PYTHON VENV: " + $Python)
        ("PYTHON BASE RUNTIME: " + $basePython)
        ("DATA: " + $DataRoot)
        ("DESKTOP SHORTCUT: " + $desktopShortcutPath)
        ("START MENU SHORTCUT: " + $startMenuShortcutPath)
        ("EXIT SHORTCUT: " + $stopShortcutPath)
        ("INSTALL OWNERSHIP: " + $InstallOwnershipMarker)
        "WINDOW MODE: Microsoft Edge / Chrome application window (no browser tabs or address bar)"
        "OLLAMA: Preserved; not installed, restarted, stopped, or modified"
        "COMFYUI: External local service; not installed or modified"
    )
    $statusFile = Join-Path $DataRoot "DESKTOP-APP-STATUS.txt"
    Set-Content -LiteralPath $statusFile -Value $statusLines -Encoding UTF8

    Write-InstallOwnershipMarker
    Step "Launch the desktop application"
    if ($NoLaunch) {
        Write-Host "Desktop integration refreshed. App launch was skipped by request." -ForegroundColor Green
    } else {
        Write-Host "The desktop shortcut and icon have been refreshed. The Studio will now open in its own app window." -ForegroundColor Green
        $quotedVbsPath = [string][char]34 + $VbsPath + [string][char]34
        Start-Process -FilePath $WScript -ArgumentList @("//B","//Nologo",$quotedVbsPath) -WindowStyle Hidden | Out-Null
    }

    Write-Host "`nSETUP COMPLETED SUCCESSFULLY." -ForegroundColor Green
    Write-Host "Next time, double-click the LocalAI Creative Studio icon on your Desktop." -ForegroundColor Cyan
    Write-Host "The first installation may need internet access to prepare Python packages; model weights are separate." -ForegroundColor Yellow
    Write-Host "Setup log: $LogFile"
}
catch {
    $message = $_.Exception.Message
    Write-Host "`nSETUP FAILED: $message" -ForegroundColor Red
    Write-Host "Log: $LogFile" -ForegroundColor Yellow
    try { Add-Content -LiteralPath $LogFile -Value (($_ | Out-String)) -Encoding UTF8 } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $messageText = "LocalAI Creative Studio could not be installed.`r`n`r`n$message`r`n`r`nLog: $LogFile"
        $messageButtons = [System.Windows.Forms.MessageBoxButtons]::OK
        $messageIcon = [System.Windows.Forms.MessageBoxIcon]::Error
        [System.Windows.Forms.MessageBox]::Show($messageText, "LocalAI Creative Studio", $messageButtons, $messageIcon) | Out-Null
    } catch {}
    exit 1
}
finally { try { Stop-Transcript | Out-Null } catch {} }
