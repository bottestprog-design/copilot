$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'INSTALL-ROOT.ps1')

$defaultRoot = Join-Path $env:LOCALAPPDATA 'Programs\LocalAI Creative Studio'
$resolvedRoot = Get-VerifiedLocalAIInstallRoot -FallbackRoot $defaultRoot
if ((Test-LocalAIInstallOwnerMarker $resolvedRoot) -or (Test-LocalAILegacyInstall $resolvedRoot)) {
    Write-Output $resolvedRoot
}
