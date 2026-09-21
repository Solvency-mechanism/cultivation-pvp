param([string]$Output="treasures-qa1.rbxlx")
$ErrorActionPreference="Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$env:PATH += ";$env:USERPROFILE\.rokit\bin"
$project=Get-Content default.project.json -Raw | ConvertFrom-Json
$project.name="treasures-qa"
foreach($taskName in @('TreasureQA','TreasureRoutesQA')) {
 if(Test-Path "qa/$taskName.luau"){$project.tree.ServerScriptService | Add-Member $taskName ([pscustomobject]@{'$path'="qa/$taskName.luau"})}
}
$project.tree.ServerScriptService | Add-Member TreasureBridge ([pscustomobject]@{'$path'='qa/TreasureBridge.server.luau'})
$project.tree.StarterPlayer.StarterPlayerScripts | Add-Member TreasureRelay ([pscustomobject]@{'$path'='qa/TreasureRelay.client.luau'})
$project.tree.ReplicatedStorage | Add-Member TreasureQAClient ([pscustomobject]@{'$className'='RemoteEvent'})
$config=(Get-Content src/shared/Config.luau -Raw).Replace('return Config','Config.Persistence.storeName = "Cultivation_TreasuresQA_v1"'+"`nreturn Config")
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'Config.luau'),$config)
$project.tree.ReplicatedStorage.Shared | Add-Member Config ([pscustomobject]@{'$path'='qa/Config.luau'})
$taskProject=Join-Path (Get-Location) '.treasures-qa.project.json'
try {
 $project | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $taskProject -Encoding UTF8
 rojo build $taskProject --output $Output
 if($LASTEXITCODE -ne 0){throw 'Treasure QA build failed'}
 Get-FileHash -LiteralPath $Output -Algorithm SHA256
} finally {Remove-Item -LiteralPath $taskProject}
