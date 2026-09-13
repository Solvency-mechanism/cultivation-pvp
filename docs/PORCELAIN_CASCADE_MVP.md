# Porcelain Cascade MVP

Historical baseline: bounded MVP implementation, source gate and QA5 Studio gameplay checks completed before the later fidelity refinement. See `PORCELAIN_CASCADE_FIDELITY_SPRINT.md` for the user-approved main baseline and Git promotion provenance. The compact landmark replaces the northern Wellspring landmark while retaining existing Lumen cultivation mechanics. Volcano behavior and its regression suite are preserved.

## Implemented scope

Seven offset mineral terraces hold shallow opaque water 0.45 studs above solid beds. West/east walking banks and pool spurs lead to the source; a shaded alcove sits behind a water veil. Its queryable, noncolliding roof intentionally rejects node placement beneath it. The Pool Warden follows a lower-pool loop. Compact node visuals apply only to actual Cascade walkable support; other field node visuals and gameplay radii remain unchanged. Wellspring road lamp/flame cleanup is scoped to this approach.

## Final source gate and artifacts

The full package gate passed: lint/format, 34 compiled source files, wiring and actual Luau typechecking with Roblox definitions; progression 105, aura 112, combat 497, interface 211, volcano 65, integration 33, scoped node visuals 35, volcano construction 250,449 and Cascade construction 1,701 checks. Cascade construction includes 232 interpolated route samples. These tests execute the actual builder with Roblox datatypes and establish geometric invariants, not engine collision or human playability.

- Ordinary development package: `dist/cultivation-pvp-porcelain-cascade-mvp3.rbxlx`, 791 KB, SHA256 `C0AA1413231619E0CDDD6F9C39C836D0968F88308DB76ED02CCE2D406B2B43E5`.
- Final isolated QA place: `Cascade-qa5.rbxlx`, SHA256 `FD8AF9A53E462B407D62736B62448C9843C10A193ABF298752F766EB3B0DC42B`.

Both historical artifacts contain the then-uncommitted working changes; ancestry is `0c05a1f37a9bed11838fefc5e3d138fd69754219`. The development profile is not a player release. Earlier artifacts are intermediate snapshots, not the current verification target.

## Repeating the QA

`./qa/Cascade-build.ps1 -Output Cascade-qa5.rbxlx` derives the isolated mapping from `default.project.json`, adds only Cascade QA and a separate DataStore, and includes no volcano smoke or traversal script. Do not overwrite an open Studio file; select a new output name for a changed candidate.

After F5, use the **server** command bar to run checks independently:

```lua
local q = require(game.ServerScriptService.CascadeQA)
q.spatial()
```

```lua
require(game.ServerScriptService.CascadeQA).walk(game.Players:GetPlayers()[1], true)
```

```lua
require(game.ServerScriptService.CascadeQA).warden()
```

```lua
require(game.ServerScriptService.CascadeQA).observe(game.Players:GetPlayers()[1])
```

The expanded walk uses one disclosed entry relocation, then real `Humanoid:MoveTo` through west-bank ascent, seven pool spurs out-and-back and east-bank descent. It requires normal WalkSpeed 16, never forces jumps, and stops at the first eight-second waypoint timeout, death or cancellation. Set `workspace:SetAttribute("CascadeWalkCancel", true)` to cancel. Omit the second argument to repeat only the shorter main-bank route. Avoid photo-camera inputs during walking.

Spatial checks query actual `ArenaService.regionAt` and `groundYAt`, floor support and standing headroom. Rejected node placements beneath scenery are allowed; accepted placements require their own walkable support and headroom, including upper terraces above an overhang. Warden checks sample the actual NPC's support and movement for 12 seconds.

Natural cultivation observations read existing published integer `Vessel_ash/verdant/lumen/neutral` balances and `VesselCapacity`, without grants or duplicate service ticks. Cycling is always active in the existing server tick; there is no toggle key. A full vessel can prevent accumulation, and missing attributes are reported unavailable. Earlier QA4 direct command-bar service-state reads returned nil, so its zero-delta output is unavailable evidence; QA5 corrects that observation without altering gameplay.

Photo-only client keys **1 / 2 / 3** select approach, overhang and source cameras at FOV 65; **0** restores the prior camera. Cameras never move the character. `qa/CascadePerformanceDiagnostic.luau` is a separate, unmapped Studio-client command-bar sample: one approach view for approximately 48 seconds after settling, frame percentiles and readable Stats CPU/GPU values, followed by camera restoration and callback cleanup. It is not a three-view benchmark or 60 FPS certification; explicitly set/read Studio quality and restore it afterward.

## Final QA5 Studio results

[Actual runtime log extract](evidence/cascade-final-runtime.txt) records 126 spatial checks with no failures. The Pool Warden had 24 supported samples over 12 seconds, zero unsupported samples and 11.925 studs displacement. The expanded controller walk passed all 38 points with zero failures at normal WalkSpeed 16, using one entry relocation and visiting all seven pool spurs. No waypoint teleport or forced jump was used.

The natural eight-second observation after that walk measured Lumen 293 to 608 (+315), total published vessel balance 509 to 843, capacity 1200. This was ordinary server cycling, with no resource grant or duplicate service tick. It establishes accumulation on the final Wellspring route; it is not a long-term economy or balance acceptance test.

The operator inspected and saved unedited [approach](evidence/cascade-approach.png), [alcove](evidence/cascade-alcove.png) and [source](evidence/cascade-source.png) screenshots. Gameplay checks and photographs used Studio Automatic quality; Level10 from an earlier Studio process did not persist. Any separate fixed-quality performance sample retains its own explicit setting evidence and cannot treat these photos as a controlled performance comparison.

This is automated Studio controller and service evidence, not unfamiliar-player usability or physical-device acceptance. At this historical MVP snapshot the feature was uncommitted and unpromoted; broader art ambitions and 60 FPS acceptance are not certified by these checks.

## Bounded performance observation

[Performance evidence](evidence/cascade-performance.txt) retains both attempts: the first is discarded from controlled results because editing the command bar resized its viewport. The repeated approach sample used a stable 1094x492 viewport, FOV 65, explicitly verified Studio Level10 and one Studio process. It recorded 2,895 frames, mean 59.67 FPS, frame p95 23.83 ms, p99 28.75 ms, and 0.24% of frames over 33 ms. The 48 readable Stats samples averaged render CPU 4.34 ms and GPU 13.65 ms. Camera restoration and callback cleanup were confirmed.

This is one approximately 48-second Studio view, without a matched before/after baseline. It does not establish a performance improvement, whole-region frame rate or physical-device acceptance. In particular, p95 exceeds 16.7 ms, so it does not certify a sustained 60 FPS target.

Studio rendering quality was restored to Automatic at 02:08:32 UTC, confirmed in the evidence log; the operator also restored the player camera. No commit, promotion or live publishing occurred during this historical MVP verification. Later Git promotion is documented with the fidelity sprint.
