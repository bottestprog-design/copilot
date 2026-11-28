param([switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'DATA-PATH.ps1')
$Python = Join-Path $Root '.venv\Scripts\python.exe'
$Url = 'http://127.0.0.1:7865'
$DataRoot = Get-LocalAIDataRoot -RecoverLegacyStatus
$LogRoot = Join-Path $DataRoot 'logs'
$BrowserProfile = Join-Path $DataRoot 'browser-profile'
function Ensure-PlainDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing a redirected or non-directory Studio runtime folder: $Path"
        }
    } else {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Created Studio runtime path is not a plain directory: $Path"
        }
    }
}
function Assert-PlainFileOrMissing([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Refusing to write through a redirected or non-file Studio runtime path: $Path"
        }
    }
}
Ensure-PlainDirectory $DataRoot
Ensure-PlainDirectory $LogRoot
Ensure-PlainDirectory $BrowserProfile
$LogFile = Join-Path $LogRoot ('desktop-launch-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
$StdOut = Join-Path $LogRoot 'studio-server.stdout.log'
$StdErr = Join-Path $LogRoot 'studio-server.stderr.log'
$PidFile = Join-Path $DataRoot 'studio-server.pid'
Assert-PlainFileOrMissing $LogFile
Assert-PlainFileOrMissing $StdOut
Assert-PlainFileOrMissing $StdErr
Assert-PlainFileOrMissing $PidFile
$env:LOCALAI_STUDIO_DATA = $DataRoot

function Write-Log([string]$Text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}
function Show-Error([string]$Text) {
    Write-Log "ERROR: $Text"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("LocalAI Creative Studio could not start.`r`n`r`n$Text`r`n`r`nLog: $LogFile", 'LocalAI Creative Studio', 'OK', 'Error') | Out-Null
    } catch {}
}
function Test-StudioReady {
    try {
        $response = Invoke-RestMethod -Uri "$Url/api/ready" -TimeoutSec 2
        return ($response.app -eq 'LocalAI Creative Studio')
    } catch { return $false }
}
function Quote-Argument([string]$Value) { return '"' + $Value.Replace('"','\"') + '"' }

try {
    Write-Log 'Desktop launcher started.'
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw 'The Studio environment is not installed. Run APPLY-UPDATE.bat from a new release package, or SETUP-AND-START.bat for a first installation.' }

    if (-not (Test-StudioReady)) {
        $listener = @(Get-NetTCPConnection -LocalPort 7865 -State Listen -ErrorAction SilentlyContinue)
        if ($listener.Count -gt 0) {
            # A second desktop click can arrive while the first launcher has bound
            # the local port but the ASGI app is still completing startup. Wait only
            # when the listener process is our exact private Python/uvicorn command.
            $ourStartupProcess = $false
            foreach ($connection in $listener) {
                $owner = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$connection.OwningProcess) -ErrorAction SilentlyContinue
                if ($owner -and $owner.ExecutablePath -and
                    [System.IO.Path]::GetFullPath($owner.ExecutablePath) -ieq [System.IO.Path]::GetFullPath($Python) -and
                    $owner.CommandLine -match '(?i)uvicorn\s+studio\.server:app' -and
                    $owner.CommandLine -match '(?i)--port\s+7865') {
                    $ourStartupProcess = $true
                    break
                }
            }
            if (-not $ourStartupProcess) {
                throw 'Local port 7865 is already used by an application that is not this LocalAI Studio service. No process was stopped or replaced.'
            }
            Write-Log 'The LocalAI service is already starting. Waiting for its ready endpoint instead of starting a duplicate.'
            $ready = $false
            for ($i = 0; $i -lt 60; $i++) {
                Start-Sleep -Seconds 1
                if (Test-StudioReady) { $ready = $true; break }
            }
            if (-not $ready) { throw 'The existing LocalAI Studio process owns port 7865 but did not become ready within 60 seconds. Inspect the Studio server logs.' }
            Write-Log 'The existing LocalAI Studio service is ready.'
        } else {
            Write-Log 'Starting local Studio API in the background.'
            $arguments = '-m uvicorn studio.server:app --host 127.0.0.1 --port 7865 --log-level warning'
            $server = Start-Process -FilePath $Python -ArgumentList $arguments -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $StdOut -RedirectStandardError $StdErr
            Set-Content -LiteralPath $PidFile -Value $server.Id -Encoding ASCII

            $ready = $false
            for ($i = 0; $i -lt 60; $i++) {
                Start-Sleep -Seconds 1
                if (Test-StudioReady) { $ready = $true; break }
                $server.Refresh()
                if ($server.HasExited) { break }
            }
            if (-not $ready) {
                $details = ''
                if (Test-Path -LiteralPath $StdErr) { $details = (Get-Content -LiteralPath $StdErr -Tail 30 -ErrorAction SilentlyContinue) -join "`r`n" }
                throw "The local service did not become ready. $details"
            }
            Write-Log "Studio server is ready (PID $($server.Id))."
        }
    } else { Write-Log 'Studio server is already running.' }

    if ($NoBrowser) {
        Write-Log 'Browser launch was skipped by request; the local service is ready.'
    } else {
        $browserCandidates = @(
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        )
        $browserCommand = Get-Command 'msedge.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $browserCommand) { $browserCommand = Get-Command 'chrome.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 }
        $Browser = if ($browserCommand) { $browserCommand.Source } else { $browserCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1 }
    
        if ($Browser) {
            Write-Log "Opening app window using $Browser"
            $appArgs = @(
                (Quote-Argument "--app=$Url"),
                (Quote-Argument "--user-data-dir=$BrowserProfile"),
                '--no-first-run',
                '--no-default-browser-check',
                '--disable-translate'
            ) -join ' '
            Start-Process -FilePath $Browser -ArgumentList $appArgs -WorkingDirectory $Root | Out-Null
        } else {
            Write-Log 'No Edge/Chrome executable was found; using the default browser as a fallback.'
            Start-Process -FilePath $Url | Out-Null
        }
        Write-Log 'Desktop window launch request completed.'
    }
}
catch { Show-Error $_.Exception.Message; exit 1 }
