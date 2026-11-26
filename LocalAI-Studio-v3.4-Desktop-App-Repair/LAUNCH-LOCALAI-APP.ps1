[CmdletBinding()]
param([switch]$CreateShortcutOnly)
$ErrorActionPreference = 'Stop'
$Root = 'D:\LocalAI'
$Platform = Join-Path $Root 'Platform'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$LauncherPath = Join-Path $Platform 'LAUNCH-LOCALAI-APP.ps1'
$IconPath = Join-Path $Platform 'Assets\LocalAI-Studio.ico'
$WebUrl = 'http://127.0.0.1:8080'
$Logs = Join-Path $Root 'Logs'
$Data = Join-Path $Platform 'Data'

function Update-LocalAIShortcuts {
    if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found: $PowerShellExe" }
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) { throw "Installed launcher is missing: $LauncherPath. Run SETUP-LOCALAI.bat from the extracted release." }
    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) { throw "Application icon is missing: $IconPath. Run SETUP-LOCALAI.bat again." }
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [string]$shell.SpecialFolders('Desktop')
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $desktop, $programs | Out-Null
    $targets = @((Join-Path $desktop 'LocalAI Studio.lnk'), (Join-Path $programs 'LocalAI Studio.lnk'))
    foreach ($shortcutPath in $targets) {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $PowerShellExe
        $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $LauncherPath + '"'
        $shortcut.WorkingDirectory = $Platform
        $shortcut.IconLocation = $IconPath + ',0'
        $shortcut.Description = 'LocalAI Studio - private local chat application'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    $iconRefresh = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
    if (Test-Path -LiteralPath $iconRefresh -PathType Leaf) { try { Start-Process -FilePath $iconRefresh -ArgumentList '-show' -WindowStyle Hidden | Out-Null } catch {} }
    Write-Host '[OK] Desktop and Start Menu shortcuts updated with the current LocalAI Studio icon.' -ForegroundColor Green
}

if ($CreateShortcutOnly) { Update-LocalAIShortcuts; exit 0 }

$form = $null
$label = $null
try {
    $currentRoot = [IO.Path]::GetFullPath($PSScriptRoot)
    $expectedRoot = [IO.Path]::GetFullPath($Platform)
    if (-not $currentRoot.Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'This launcher must run from D:\LocalAI\Platform. Extract the ZIP and run SETUP-LOCALAI.bat first.'
    }
    Update-LocalAIShortcuts
    New-Item -ItemType Directory -Force -Path $Logs, $Data, (Join-Path $Data 'Temp') | Out-Null
    $env:TEMP = Join-Path $Data 'Temp'
    $env:TMP = $env:TEMP
    $env:TMPDIR = $env:TEMP
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'LocalAI Studio'
    $form.Size = [System.Drawing.Size]::new(430, 154)
    try { $form.Icon = [System.Drawing.Icon]::new($IconPath) } catch {}
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Text = 'LocalAI Studio is starting...'
    $form.Controls.Add($label)
    $form.Show()
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    function Set-LaunchStatus([string]$Message) {
        $label.Text = $Message
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
    function Invoke-LocalPowerShellScript([string]$ScriptPath, [string]$Title, [int]$TimeoutSeconds = 10800) {
        if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Required script is missing: $ScriptPath" }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $stdout = Join-Path $Logs ('desktop-' + $stamp + '.stdout.log')
        $stderr = Join-Path $Logs ('desktop-' + $stamp + '.stderr.log')
        $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
        Set-LaunchStatus $Title
        $process = Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 350
            $process.Refresh()
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                try { $process.Kill(); [void]$process.WaitForExit(5000) } catch {}
                throw "$Title timed out after $TimeoutSeconds seconds. See $stdout and $stderr."
            }
        }
        $process.WaitForExit()
        if ([int]$process.ExitCode -ne 0) {
            $errTail = if (Test-Path -LiteralPath $stderr) { (Get-Content -LiteralPath $stderr -Tail 25 -ErrorAction SilentlyContinue) -join ' ' } else { '' }
            $outTail = if (Test-Path -LiteralPath $stdout) { (Get-Content -LiteralPath $stdout -Tail 25 -ErrorAction SilentlyContinue) -join ' ' } else { '' }
            throw "$Title failed (exit $($process.ExitCode)). $errTail $outTail Logs: $stdout | $stderr"
        }
        return [pscustomobject]@{ StdOut = $stdout; StdErr = $stderr }
    }

    Set-LaunchStatus 'Checking the existing Ollama service...'
    try { $null = Invoke-RestMethod 'http://127.0.0.1:11434/api/version' -TimeoutSec 8 -ErrorAction Stop }
    catch { throw 'Ollama is not running at 127.0.0.1:11434. Start Ollama, then click the LocalAI Studio icon again. This app will not restart or reinstall Ollama.' }

    $python = Join-Path $Platform '.venv\Scripts\python.exe'
    $openWebUI = Join-Path $Platform '.venv\Scripts\open-webui.exe'
    $secret = Join-Path $Platform 'Secrets\webui_secret_key.txt'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or -not (Test-Path -LiteralPath $openWebUI -PathType Leaf) -or -not (Test-Path -LiteralPath $secret -PathType Leaf)) {
        $repair = Join-Path $Platform 'REPAIR-AND-RESUME.ps1'
        $null = Invoke-LocalPowerShellScript $repair 'Preparing the LocalAI Studio environment (first run only)...' 10800
    }
    $startScript = Join-Path $Platform 'START-CHAT.ps1'
    $null = Invoke-LocalPowerShellScript $startScript 'Starting the local chat service...' 600
    $ready = $false
    try { $null = Invoke-RestMethod ($WebUrl + '/ready') -TimeoutSec 8 -ErrorAction Stop; $ready = $true } catch {}
    if (-not $ready) { throw 'The local chat service did not report ready after startup. Review the newest logs in D:\LocalAI\Logs.' }

    Set-LaunchStatus 'Opening the LocalAI Studio app window...'
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $browserCandidates = @()
    if ($programFilesX86) {
        $browserCandidates += Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'
        $browserCandidates += Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe'
    }
    if ($env:ProgramFiles) {
        $browserCandidates += Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'
        $browserCandidates += Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
    }
    if ($env:LOCALAPPDATA) {
        $browserCandidates += Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'
        $browserCandidates += Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
    }
    $browser = $browserCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if ($browser) {
        Start-Process -FilePath $browser -ArgumentList @('--app=' + $WebUrl, '--no-first-run') | Out-Null
    } else {
        Start-Process $WebUrl | Out-Null
    }
    if ($form) { $form.Close(); $form.Dispose(); $form = $null }
    exit 0
} catch {
    $message = $_.Exception.Message
    if ($form) { try { $form.Close(); $form.Dispose() } catch {} }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("LocalAI Studio could not start.`r`n`r`n$message", 'LocalAI Studio', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { Write-Host $message -ForegroundColor Red }
    exit 1
}
