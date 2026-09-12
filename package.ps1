<#
    Package a release build.

    Runs the full gate first and refuses to package if any part of it fails,
    because a build that has not passed the gate is not a build worth keeping.
    Output goes to dist/ , which is gitignored -- the artifact is reproducible
    from the tag, so the tag is the thing worth storing, not the .rbxlx.

    Usage:  .\package.ps1 [-Version v0.1.0] [-SkipGate]
#>
param(
    [string]$Version = "",
    [switch]$SkipGate
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$env:PATH += ";$env:USERPROFILE\.rokit\bin"

if ($Version -eq "") {
    $Version = (git describe --tags --always --dirty)
}

Write-Output "packaging $Version"

if (-not $SkipGate) {
    Write-Output "--- lint"
    selene src tests
    if ($LASTEXITCODE -ne 0) { throw "selene failed" }

    Write-Output "--- format"
    stylua --check src tests
    if ($LASTEXITCODE -ne 0) { throw "stylua found unformatted files" }

    Write-Output "--- tests"
    foreach ($suite in @("compile", "wiring", "progression", "auranodes", "combat", "interface", "volcano", "volcano-integration", "volcano-world")) {
        lune run "tests/$suite.test"
        if ($LASTEXITCODE -ne 0) { throw "$suite suite failed" }
    }

    Write-Output "--- typecheck"
    rojo sourcemap default.project.json --output sourcemap.json | Out-Null
    if (-not (Test-Path "globalTypes.d.luau")) {
        Write-Output "    globalTypes.d.luau missing; skipping typecheck"
    } else {
        luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau --base-luaurc=.luaurc src
        if ($LASTEXITCODE -ne 0) { throw "luau-lsp reported type errors" }
    }

    # The shared modules must never require each other; that rule is the only
    # reason the game rules are testable outside Studio, and it breaks silently.
    $offenders = Select-String -Path "src/shared/*.luau" -Pattern "^\s*(local\s+\w+\s*=\s*)?require\(" -ErrorAction SilentlyContinue
    if ($offenders) {
        $offenders | ForEach-Object { Write-Output $_.Line }
        throw "a shared module gained a require; this breaks every Lune test"
    }
}

New-Item -ItemType Directory -Force -Path "dist" | Out-Null
$out = "dist/cultivation-pvp-$Version.rbxlx"
rojo build default.project.json --output $out
if ($LASTEXITCODE -ne 0) { throw "rojo build failed" }

# The tuning profile is part of the artifact's identity. A development build
# is a legitimate thing to package; one that ships to players by accident is
# not, so the receipt says which it is and the console says so loudly.
$profileLine = (Select-String -Path "src/shared/Config.luau" -Pattern '^Config\.Profile\s*=\s*"([a-z]+)"' | Select-Object -First 1)
$profile = if ($profileLine) { $profileLine.Matches[0].Groups[1].Value } else { "unknown" }
if ($profile -ne "release") {
    Write-Output ""
    Write-Output "  !! PROFILE: $($profile.ToUpper()) -- tuning is deliberately wrong for balance."
    Write-Output "  !! This artifact is NOT FOR PLAYERS. Set Config.Profile = `"release`" to ship."
}

$sourceState = if (git status --porcelain) { "working tree changes; commit is ancestry only" } else { "clean commit" }
$hash = (Get-FileHash $out -Algorithm SHA256).Hash
$size = [math]::Round((Get-Item $out).Length / 1KB)

@"
build:   $Version
commit:  $(git rev-parse HEAD)
source:  $sourceState
built:   $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")
file:    $(Split-Path $out -Leaf)
size:    $size KB
sha256:  $hash
profile: $profile$(if ($profile -ne "release") { "  -- NOT FOR PLAYERS" })
gate:    $(if ($SkipGate) { "SKIPPED -- not a release build" } else { "passed" })
"@ | Set-Content -Path "dist/$([System.IO.Path]::GetFileNameWithoutExtension($out)).txt" -Encoding utf8

Write-Output ""
Get-Content "dist/$([System.IO.Path]::GetFileNameWithoutExtension($out)).txt"
Write-Output ""
Write-Output "Open $out in Studio and press F5 to play."
