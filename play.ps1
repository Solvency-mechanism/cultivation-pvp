# play.ps1 -- open the publishable build in Studio, and say whether it is publishable.
#
# Why this exists: the most expensive recurring failure on this project has been
# not knowing which build was loaded. Studio runs and publishes its IN-MEMORY
# document, a place file on disk can be any vintage, and the window title says
# nothing. An afternoon was lost to a session silently running a three-hour-old
# build, and a publish nearly shipped a place with an entire subsystem absent.
#
# So: one thing to click. It delegates the artifact to publish-build.ps1 -- the
# same script the deploy uses, with the same guarantees -- then opens THAT file
# and tells you, in one word, whether the window you are looking at is one you
# can publish from.
#
# The artifact is disposable by design. It is deleted and rebuilt on every click,
# so it can never be stale, and it does not matter if Studio writes to it after
# you publish.

$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
Set-Location $repo
$env:PATH += ";$env:USERPROFILE\.rokit\bin"

$place = Join-Path $repo "starter-game.rbxlx"
function Line { Write-Host "  ---------------------------------------------------------------" }

Write-Host ""; Line

# --- identity ---------------------------------------------------------------
$sha     = (git rev-parse --short HEAD 2>$null)
$full    = (git rev-parse HEAD 2>$null)
$subject = (git log -1 --pretty=%s 2>$null)
$dirty   = (git status --porcelain 2>$null)
if (-not $sha) { Write-Host "  NOT A GIT REPO -- cannot say what this is." -ForegroundColor Red; Read-Host "  Enter"; exit 1 }

# Is this commit on the remote? If not, the build is not recoverable by anyone else.
git rev-parse --verify --quiet "origin/combat-vision" *> $null
$pushed = $false
if ($LASTEXITCODE -eq 0) {
    git merge-base --is-ancestor $full (git rev-parse origin/combat-vision) *> $null
    $pushed = ($LASTEXITCODE -eq 0)
}

# --- never launch on top of a running Studio --------------------------------
$running = Get-Process RobloxStudioBeta -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "  STUDIO IS ALREADY RUNNING -- $($running.Count) process(es)." -ForegroundColor Yellow
    Write-Host "  Opening a file now can focus an existing window holding an OLDER"
    Write-Host "  document instead of loading this build. That is the trap."
    if ((Read-Host "  Close them all and continue? (y/N)") -ne "y") {
        Write-Host "  Stopped. Nothing opened." -ForegroundColor Yellow; Read-Host "  Enter"; exit 1
    }
    $running | Stop-Process -Force; Start-Sleep -Seconds 2
    Write-Host "  closed." -ForegroundColor Green
}

Get-ChildItem (Join-Path $repo "*.rbxlx.lock") -EA SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force; Write-Host "  cleared orphaned lock $($_.Name)"
}

# --- the artifact: same script the deploy uses ------------------------------
Write-Host "  building via publish-build.ps1 (deletes first, proves it is a clean rojo build)..."
& (Join-Path $repo "publish-build.ps1") *> $null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $place)) {
    Write-Host "  BUILD OR GATE FAILED -- nothing opened." -ForegroundColor Red
    Write-Host "  Run .\publish-build.ps1 directly to see why." -ForegroundColor Red
    Read-Host "  Enter"; exit 1
}

$profileLine = Select-String -Path "src/shared/Config.luau" -Pattern '^Config\.Profile\s*=\s*"([a-z]+)"' | Select-Object -First 1
$prof = if ($profileLine) { $profileLine.Matches[0].Groups[1].Value } else { "unknown" }
$hash = (Get-FileHash $place -Algorithm SHA256).Hash
$size = (Get-Item $place).Length

# --- the verdict ------------------------------------------------------------
$blockers = @()
if ($dirty)   { $blockers += "working tree has uncommitted changes -- this build matches NO commit" }
if (-not $pushed) { $blockers += "commit $sha is not on origin/combat-vision -- nobody else could rebuild it" }

Line
if ($blockers.Count -eq 0) {
    Write-Host "  PUBLISHABLE" -ForegroundColor Green
    Write-Host "  The Studio window about to open IS the one to publish from."
} else {
    Write-Host "  NOT PUBLISHABLE" -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host "    - $b" -ForegroundColor Red }
    Write-Host "  It will still open and play. Do not publish it."
}
Line
Write-Host "    commit   $sha  $subject"
Write-Host "    profile  $prof" -NoNewline
if ($prof -eq "development") { Write-Host "   (test tuning -- NOT what players get)" -ForegroundColor Yellow } else { Write-Host "" }
Write-Host "    sha256   $($hash.Substring(0,32))"
Write-Host "    size     $size bytes, built just now from HEAD"
Write-Host "    studio   none was running; this file was untouched by Studio"
Line
Write-Host ""
Write-Host "  To play:    press F5"
Write-Host "  To publish: File > Publish to Roblox  (update Xianxia Combat Simulator)"
Write-Host ""
Write-Host "  1-5 cast   5 movement   Shift+n swap   L picker   T lock   B breakthrough"
Write-Host "  /dummy stationary lowgold   /dummy caster ahead   /dummy clear"
Write-Host ""

$studio = Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions\*\RobloxStudioBeta.exe" -EA SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($studio) { Start-Process -FilePath $studio.FullName -ArgumentList $place } else { Start-Process $place }
Write-Host "  Studio launching..." -ForegroundColor Green
Start-Sleep -Seconds 4
