<#
    Build the place that is about to be published, and prove what is in it.

    This exists because of a near-miss. The artifact at starter-game.rbxlx was
    found to be a place SAVED OUT OF STUDIO rather than built by rojo -- and it
    contained none of that day's geography work while containing the previous
    commit's HUD fix. Publishing it would have shipped current-looking scripts
    with an entire subsystem silently absent. Nothing about its size, its
    timestamp or its filename said so.

    The general form: a Studio-saved artifact is CODE OF UNKNOWN VINTAGE WEARING
    THE RIGHT FILENAME. Opening a place in Studio is a normal thing to do, Studio
    writes to it without being asked, and the result is indistinguishable from a
    good build until somebody parses it.

    So this does not inspect the artifact. It DELETES it and builds a new one,
    which makes the question unaskable rather than merely answered, and then
    proves the result is a clean rojo build.

    Usage:  .\publish-build.ps1
#>

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$env:PATH += ";$env:USERPROFILE\.rokit\bin"

$place = "starter-game.rbxlx"

if (Test-Path $place) {
    Write-Output "removing existing $place (provenance unknown by design)"
    Remove-Item $place -Force
}

Write-Output "--- build"
rojo build default.project.json --output $place
if ($LASTEXITCODE -ne 0) { throw "rojo build failed" }

<#
    Studio stamps UniqueId and HistoryId onto instances it writes; rojo emits
    neither. Their presence is a positive, structural signal that Studio has
    touched the file -- unlike a name grep, which cannot tell a baked instance
    from the source line that would create one, because a .rbxlx carries the Lua
    source of every script inside it.
#>
$text = Get-Content $place -Raw
$uniqueId = ([regex]::Matches($text, 'UniqueId')).Count
$historyId = ([regex]::Matches($text, 'HistoryId')).Count
if ($uniqueId -ne 0 -or $historyId -ne 0) {
    throw "$place carries Studio metadata (UniqueId $uniqueId, HistoryId $historyId) -- this is not a clean rojo build"
}

$hash = (Get-FileHash $place -Algorithm SHA256).Hash
$size = [math]::Round((Get-Item $place).Length / 1KB)
$commit = (git rev-parse --short HEAD)
$dirty = (git status --porcelain)

$profileLine = (Select-String -Path "src/shared/Config.luau" -Pattern '^Config\.Profile\s*=\s*"([a-z]+)"' | Select-Object -First 1)
$profile = if ($profileLine) { $profileLine.Matches[0].Groups[1].Value } else { "unknown" }

Write-Output ""
Write-Output "  place:   $place"
Write-Output "  commit:  $commit"
Write-Output "  size:    $size KB"
Write-Output "  sha256:  $hash"
Write-Output "  profile: $profile"
Write-Output "  studio:  none (UniqueId 0, HistoryId 0)"

if ($dirty) {
    Write-Output ""
    Write-Output "  !! WORKING TREE IS DIRTY -- this build contains uncommitted changes."
    Write-Output "  !! Whatever you publish will not correspond to any commit."
}
if ($profile -ne "release") {
    Write-Output ""
    Write-Output "  !! PROFILE: $($profile.ToUpper()) -- tuning is deliberately wrong for balance."
    Write-Output "  !! NOT FOR PLAYERS. Set Config.Profile = `"release`" to ship."
}

Write-Output ""
Write-Output "Now: open THIS file in Studio, let it load, and check the document gate"
Write-Output "before publishing --"
Write-Output "  which code  : boot log reads [cultivation] build check, and the HUD has"
Write-Output "                no numeric refinement caption and does have a centre reticle"
Write-Output "  which world : this build is seconds old and Studio has not saved over it"
Write-Output ""
Write-Output "If Studio writes to $place, throw it away and run this again."
