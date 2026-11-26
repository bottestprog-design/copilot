$ErrorActionPreference = 'Stop'
$Platform = 'D:\LocalAI\Platform'
$Python = Join-Path $Platform '.venv\Scripts\python.exe'
$Backup = Join-Path $Platform 'Backups\OpenWebUI\custom.css.original'
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "Open WebUI Python is missing: $Python" }
$code = 'import importlib.util,pathlib; s=importlib.util.find_spec("open_webui"); print(str(pathlib.Path(s.origin).parent/"static"/"custom.css") if s and s.origin else "")'
$out = @(& $Python -c $code 2>&1); $rc=[int]$LASTEXITCODE
if($rc -ne 0 -or $out.Count -eq 0){throw "Could not locate Open WebUI custom.css: $($out -join ' ')"}
$target=([string]($out|Select-Object -Last 1)).Trim()
if(-not $target){throw 'Open WebUI custom.css path is empty.'}
if(-not(Test-Path -LiteralPath $Backup -PathType Leaf)){throw "Original stylesheet backup is missing: $Backup"}
Copy-Item -LiteralPath $Backup -Destination $target -Force
Write-Host '[OK] Original Open WebUI stylesheet restored. No user data or models were changed.' -ForegroundColor Green
