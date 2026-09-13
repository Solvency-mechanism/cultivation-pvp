param([string]$Output = "porcelain-cascade-qa.rbxlx")
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$env:PATH += ";$env:USERPROFILE\.rokit\bin"
$project=Get-Content default.project.json -Raw | ConvertFrom-Json
$project.name="porcelain-cascade-qa"
$project.tree.ServerScriptService | Add-Member CascadeQA ([pscustomobject]@{'$path'='qa/CascadeQA.luau'})
$project.tree.StarterPlayer.StarterPlayerScripts | Add-Member CascadeCamera ([pscustomobject]@{'$path'='qa/CascadeCamera.client.luau'})
$config=(Get-Content src/shared/Config.luau -Raw).Replace('return Config','Config.Persistence.storeName = "Cultivation_CascadeQA_v1"'+"`nreturn Config")
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'Config.luau'),$config)
$project.tree.ReplicatedStorage.Shared | Add-Member Config ([pscustomobject]@{'$path'='qa/Config.luau'})
$temporaryProject=Join-Path (Get-Location) '.cascade-qa.project.json'
try {
 $project | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporaryProject -Encoding UTF8
 rojo build $temporaryProject --output $Output
 if ($LASTEXITCODE -ne 0) {throw 'Cascade QA build failed'}
 Get-FileHash -LiteralPath $Output -Algorithm SHA256
} finally {Remove-Item -LiteralPath $temporaryProject}
