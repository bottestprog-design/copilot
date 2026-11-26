$ErrorActionPreference='Stop'
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"};Write-Host "[PASS] $Message" -ForegroundColor Green}
$installerPath=Join-Path $PSScriptRoot 'INSTALL-PLATFORM.ps1';$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($installerPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count -gt 0){throw 'INSTALL-PLATFORM.ps1 has syntax errors.'}
foreach($name in @('Backup-ManagedPlatformFiles','Restore-ManagedPlatformFiles')){
    $node=$ast.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw "Installer backup helper missing: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$testRoot=Join-Path $env:TEMP ('LocalAI platform backup tests '+[guid]::NewGuid().ToString('N'))
$Root=$testRoot;$Platform=Join-Path $testRoot 'Platform';$script:BackupRoot=$null;$script:BackupReady=$false;$script:ManagedFilesBeforeUpdate=@{};$script:ManagedRelativePaths=New-Object System.Collections.ArrayList
try{
    New-Item -ItemType Directory -Force -Path $Platform|Out-Null
    $existing=Join-Path $Platform 'existing.ps1';$newFile=Join-Path $Platform 'nested\new-managed.ps1';$userFile=Join-Path $Platform 'user-settings.json'
    Set-Content -LiteralPath $existing -Value 'before' -Encoding UTF8;Set-Content -LiteralPath $userFile -Value 'user-owned' -Encoding UTF8
    $hash=(Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash.ToLowerInvariant();$manifestLines=@("$hash  existing.ps1",(('0'*64)+'  nested/new-managed.ps1'))
    Backup-ManagedPlatformFiles
    Assert-Test ($script:BackupReady -and (Test-Path -LiteralPath (Join-Path $script:BackupRoot 'existing.ps1') -PathType Leaf)) 'Existing manifest-managed file was backed up'
    Set-Content -LiteralPath $existing -Value 'after update' -Encoding UTF8;New-Item -ItemType Directory -Force -Path (Split-Path -Parent $newFile)|Out-Null;Set-Content -LiteralPath $newFile -Value 'new file' -Encoding UTF8
    Restore-ManagedPlatformFiles
    Assert-Test ((Get-Content -LiteralPath $existing -Raw).Trim() -eq 'before') 'Rollback restores overwritten package-managed file'
    Assert-Test (-not(Test-Path -LiteralPath $newFile -PathType Leaf)) 'Rollback removes newly added package-managed file'
    Assert-Test ((Get-Content -LiteralPath $userFile -Raw).Trim() -eq 'user-owned') 'Rollback leaves non-manifest user data untouched'
    Assert-Test (Test-Path -LiteralPath (Join-Path $script:BackupRoot 'ROLLBACK-RESULT.txt') -PathType Leaf) 'Backup and rollback result are retained'
    Write-Host 'PLATFORM_BACKUP_TESTS: SUCCESS' -ForegroundColor Green
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
