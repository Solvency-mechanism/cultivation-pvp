$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$env:PATH += ";$env:USERPROFILE\.rokit\bin"
$config = Get-Content src/shared/Config.luau -Raw
$config = $config.Replace("return Config", 'Config.Persistence.storeName = "Cultivation_volcano_qa_20260912"' + "`nreturn Config")
[IO.File]::WriteAllText((Join-Path $PSScriptRoot "Config.luau"), $config)
rojo build qa.project.json --output volcano-qa.rbxlx
if ($LASTEXITCODE -ne 0) { throw "QA build failed" }
