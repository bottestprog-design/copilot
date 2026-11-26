$ErrorActionPreference = 'Stop'
$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found: $powerShellExe" }
$root = Join-Path $env:TEMP ('LocalAI process launch test with spaces ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$childScript = Join-Path $root 'child script path with spaces.ps1'
$expectedPath = Join-Path $root 'argument path with spaces.txt'
$markerPath = Join-Path $root 'launch result marker.txt'
$specialArgument = 'quoted "value" with trailing' + [char]92
$specialExpected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($specialArgument))
$child = @'
param([string]$ExpectedPath,[string]$ExpectedSpecialBase64,[string]$MarkerPath,[string]$SpecialArgument)
if (-not (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) { throw "Child received a corrupted path: $ExpectedPath" }
$actualSpecial = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SpecialArgument))
if ($actualSpecial -cne $ExpectedSpecialBase64) { throw "Special argument was corrupted: $actualSpecial" }
[IO.File]::WriteAllText($MarkerPath,([IO.Path]::GetFullPath($ExpectedPath)+[Environment]::NewLine+$actualSpecial))
Write-Output 'PROCESS_ARGUMENTS_OK'
exit 0
'@
[IO.File]::WriteAllText($childScript,$child,[System.Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($expectedPath,'argument sentinel',[System.Text.UTF8Encoding]::new($false))
try {
    $repairPath=Join-Path $PSScriptRoot 'REPAIR-AND-RESUME.ps1';$tokens=$null;$parseErrors=$null
    $repairAst=[System.Management.Automation.Language.Parser]::ParseFile($repairPath,[ref]$tokens,[ref]$parseErrors)
    if(@($parseErrors).Count -gt 0){throw 'REPAIR-AND-RESUME.ps1 has PowerShell syntax errors.'}
    foreach($functionName in @('Quote-ProcessArgument','Invoke-CapturedProcess')){
        $node=$repairAst.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)
        if(-not $node){throw "Repair script is missing $functionName"}
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $probe=Invoke-CapturedProcess -Executable $powerShellExe -Arguments @('-NoLogo','-NoProfile','-Command',"[Console]::Error.WriteLine('NATIVE_STDERR_SENTINEL'); exit 0") -TimeoutSeconds 20
    if($probe.ExitCode -ne 0 -or $probe.StdErr -notmatch 'NATIVE_STDERR_SENTINEL'){throw "stderr capture test failed: $($probe.StdErr)"}
    Write-Host '[PASS] Native stderr is captured without converting it into a terminating PowerShell error.' -ForegroundColor Green
    $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$childScript,$expectedPath,$specialExpected,$markerPath,$specialArgument)
    $argumentLine=($args|ForEach-Object{Quote-ProcessArgument ([string]$_)}) -join ' '
    $p=Start-Process -FilePath $powerShellExe -ArgumentList $argumentLine -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput (Join-Path $root 'child.stdout') -RedirectStandardError (Join-Path $root 'child.stderr')
    if([int]$p.ExitCode -ne 0){$err=Get-Content (Join-Path $root 'child.stderr') -Raw -ErrorAction SilentlyContinue;throw "Child exited $($p.ExitCode): $err"}
    if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf)){throw 'Child process did not create its marker.'}
    $lines=[IO.File]::ReadAllLines($markerPath)
    if($lines.Count -lt 2 -or [IO.Path]::GetFullPath($lines[0]) -ne [IO.Path]::GetFullPath($expectedPath) -or $lines[1] -cne $specialExpected){throw 'Path or embedded quote/trailing-backslash round-trip mismatch.'}
    Write-Host '[PASS] Paths with spaces, embedded quotes, and trailing backslashes round-trip through Windows PowerShell 5.1.' -ForegroundColor Green
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
