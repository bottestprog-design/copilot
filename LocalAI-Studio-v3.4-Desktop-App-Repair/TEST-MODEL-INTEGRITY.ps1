$ErrorActionPreference='Stop'
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERTION FAILED: $Message"};Write-Host "[PASS] $Message" -ForegroundColor Green}
$managerPath=Join-Path $PSScriptRoot 'ENSURE-MODELS.ps1';$tokens=$null;$parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($managerPath,[ref]$tokens,[ref]$parseErrors)
if(@($parseErrors).Count -gt 0){throw 'ENSURE-MODELS.ps1 has syntax errors; isolated model integrity tests were not started.'}
foreach($name in @('Get-ManifestModelTag','Test-OllamaManifest','Find-OllamaManifestByTag','Import-OllamaManifest')){
    $node=$ast.Find({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $node){throw "Model manager function not found: $name"}
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:ModelIntegrityFailures=New-Object System.Collections.Generic.List[string]
$root=Join-Path $env:TEMP ('LocalAI model integrity test '+[guid]::NewGuid().ToString('N'))
$source=Join-Path $root 'source-store';$active=Join-Path $root 'active-store';$relative='registry.ollama.ai/library/qwen3.5/9b'
$manifestPath=Join-Path (Join-Path $source 'manifests') $relative
$payloads=@('tiny-config-payload','tiny-model-layer-payload')
try{
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath),(Join-Path $source 'blobs')|Out-Null
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($payload in $payloads){
        $bytes=[Text.Encoding]::UTF8.GetBytes($payload);$sha=[Security.Cryptography.SHA256]::Create()
        try{$digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $name='sha256-'+$digest;[IO.File]::WriteAllBytes((Join-Path (Join-Path $source 'blobs') $name),$bytes)
        $entries.Add([pscustomobject]@{mediaType='application/vnd.ollama.image.model';digest=('sha256:'+$digest);size=[long]$bytes.Length})
    }
    $manifest=[ordered]@{schemaVersion=2;mediaType='application/vnd.docker.distribution.manifest.v2+json';config=$entries[0];layers=@($entries[1])}
    $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Assert-Test ((Get-ManifestModelTag -RelativePath $relative) -eq 'qwen3.5:9b') 'Ollama registry path maps to the expected model tag'
    $valid=Test-OllamaManifest -StoreRoot $source -ManifestFile $manifestPath -RelativePath $relative
    Assert-Test ($null -ne $valid -and $valid.Blobs.Count -eq 2) 'Valid synthetic manifest and source blobs are accepted'
    $found=Find-OllamaManifestByTag -Tag 'qwen3.5:9b' -StoreRoots @($source,$active)
    Assert-Test ($null -ne $found -and $found.StoreRoot -eq $source -and $found.ManifestFile -eq $manifestPath) 'Existing Ollama tag resolves to its local manifest for SHA-256 verification'
    Assert-Test ($null -eq (Find-OllamaManifestByTag -Tag 'qwen3.5:not-present' -StoreRoots @($source,$active))) 'Unknown tags do not match an unrelated local manifest'

    $sourceBlob=Join-Path (Join-Path $source 'blobs') $valid.Blobs[1].Name
    $damaged=[IO.File]::ReadAllBytes($sourceBlob);$damaged[0]=$damaged[0] -bxor 1;[IO.File]::WriteAllBytes($sourceBlob,$damaged)
    $bad=Test-OllamaManifest -StoreRoot $source -ManifestFile $manifestPath -RelativePath $relative
    Assert-Test ($null -eq $bad -and $script:ModelIntegrityFailures.Count -gt 0) 'Same-size source blob corruption is rejected by SHA-256'
    [IO.File]::WriteAllBytes($sourceBlob,[Text.Encoding]::UTF8.GetBytes($payloads[1]));$script:ModelIntegrityFailures.Clear()

    New-Item -ItemType Directory -Force -Path (Join-Path $active 'blobs')|Out-Null
    $activeTarget=Join-Path (Join-Path $active 'blobs') $valid.Blobs[1].Name
    $damaged=[IO.File]::ReadAllBytes($sourceBlob);$damaged[0]=$damaged[0] -bxor 2;[IO.File]::WriteAllBytes($activeTarget,$damaged)
    $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($activeTarget));$thrown=$false
    try{Import-OllamaManifest -ActiveRoot $active -VerifiedManifest $valid}catch{$thrown=$true}
    $after=[Convert]::ToBase64String([IO.File]::ReadAllBytes($activeTarget))
    Assert-Test ($thrown -and $before -ceq $after) 'Corrupt active blob is rejected and left untouched'

    $clean=Join-Path $root 'clean-store'
    Import-OllamaManifest -ActiveRoot $clean -VerifiedManifest $valid
    foreach($blob in $valid.Blobs){$target=Join-Path (Join-Path $clean 'blobs') $blob.Name;$hash=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();Assert-Test ($hash -eq $blob.Name.Substring(7)) 'Temporary import copy matches digest before promotion'}
    $temporary=@(Get-ChildItem -LiteralPath (Join-Path $clean 'blobs') -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
    Assert-Test ($temporary.Count -eq 0) 'Successful blob import leaves no partial temporary files'
    Assert-Test (Test-Path -LiteralPath (Join-Path (Join-Path $clean 'manifests') $relative) -PathType Leaf) 'Verified manifest is installed after its blobs'
    Write-Host 'MODEL_INTEGRITY_TESTS: SUCCESS' -ForegroundColor Green
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
