# Handoff

State as of the CombatService commit. All names are placeholders.

## Machine setup

Everything needed is installed and on the persistent user PATH.

- **Roblox Studio** installed; the Rojo Studio plugin is in place as
  `%LOCALAPPDATA%\Roblox\Plugins\RojoManagedPlugin.rbxm`, matching CLI 7.7.0.
- **Rokit** at `~/.rokit/bin` manages rojo 7.7.0, wally 0.3.2, stylua 2.5.2,
  selene 0.31.0, luau-lsp 1.69.0, lune 0.10.5.
- **VS Code** has luau-lsp, vscode-rojo, stylua and selene-vscode.

> If `rojo` reports "not found", the terminal predates the PATH change. Open a
> new one. This is not a broken install.

## The architectural rule that matters

Everything in `src/shared/` is **pure and contains zero internal requires**, and
takes `Config` as a parameter instead of requiring it.

That is not stylistic. Roblox requires by instance (`require(script.Parent.X)`)
and Lune requires by relative path (`require("./X")`), and the two are
incompatible. Dependency-free modules load unchanged under both, which is the
only reason the game rules are unit-testable outside Studio.

**Adding a require between two shared modules breaks every test.** If a shared
module needs something from another, pass it in as an argument. `Combat` takes
effective power as a number rather than requiring `Progression`, and
`Combat.deathLoss` returns an amount for the caller to hand to
`Progression.applyLoss`, precisely to hold this line.

Server modules are free to require each other and the shared ones. The
dependency runs one way: `CombatService` reads cultivation state and routes
death loss back through `CultivationService`, and `CultivationService` does not
know `CombatService` exists.

## What exists and is verified

| Module | What it owns |
|---|---|
| `shared/Config` | All tuning: stages, refinement, node tiers, spawn weights, techniques, combat constants |
| `shared/Progression` | Stage and refinement math, catalyst gate, the ratchet |
| `shared/AuraNodes` | Spawn rolls, occupancy, capacity, decay, cycle rates, contest detection |
| `shared/Combat` | Resources, technique gating, buffs, mitigation, damage resolution, slot resolution |
| `server/NodeService` | Field lifecycle and the node parts in Workspace |
| `server/CultivationService` | Per-player state, cycling tick, catalyst grants, death loss |
| `server/CombatService` | Actors, the UseTechnique remote, hit resolution, constructs, death, respawn |
| `client/init.client` | HUD mirroring player attributes; keys 1-4 fire the remote |

**193 Lune assertions across three suites**, plus selene, stylua, `rojo build`
and `luau-lsp analyze` all clean.

The assertions worth not breaking:

- intra-bracket time-to-kill advantage is **exactly 18%**
- time-to-kill is **constant across brackets**
- spawn distribution matches configured weights over 20,000 samples
- a construct cannot kill from full over its whole duration, and is still worth
  stepping out of — these two bounds are what pin `constructTickSeconds`
- within a kind, a harder-hitting technique telegraphs longer

## What has never been run

Still the headline. The pure logic is tested and the **Roblox binding layer has
never executed** — it builds and typechecks, but no one has stood in a node and
watched the bar move, and now no one has thrown a technique either. There is
more untested binding than there was before, not less. Expect the first Studio
session to surface bugs that nothing above would catch.

Two things to know before that first run:

- **The project tree has no ground and no spawn.** `Workspace` in
  `default.project.json` sets only gravity. Use `rojo serve` and connect from a
  Studio place that already has a Baseplate and a SpawnLocation; a place built
  from `rojo build` alone will drop the player into the void.
- The node field places nodes within a 220-stud radius of the origin at `y = 4`,
  so the ground needs to reach that far.

Not built at all: DataStore persistence (state is in-memory and dies with the
server), bracket-enforced matchmaking, the proving ground, telegraph
announcements, and contest resolution.

## What the last session added

`server/CombatService`, wiring the finished combat rules to the engine:

- An actor per player, sized from their stage index and rebuilt on breakthrough.
  The actor is authoritative; the Humanoid is a readout mirrored from it, and the
  only thing read back is `Humanoid.Died`, so falling off the map costs the same
  refinement a lost fight does.
- `UseTechnique` carries a **slot name only**. `Combat.resolveSlot` — a new
  function in the pure module, so the trust boundary is unit-tested — refuses
  unknown slots, non-strings, empty slots and kind mismatches before anything
  else runs.
- Striker raycasts, Ruler sphere-queries with the caster's region applied, and
  Enforcer resolves as the self-buff `Combat.use` already applied.
- Cross-bracket damage refused via `Combat.canEngage` per target.
- Death routes `Combat.deathLoss` through the new
  `CultivationService.applyDeathLoss`, so cultivation state keeps one owner.
  Respawn uses `Players.RespawnTime`.

Three judgment calls worth knowing about, each reversible:

1. **Forger constructs were built rather than deferred.** Leaving them out would
   have left two of three forger options dead and made the first playtest of the
   loadout misleading. They are per-tick damage volumes with the damage
   snapshotted at cast; `Config.Combat.constructTickSeconds` is new, and the two
   test bounds above are what justify its value.
2. **Windup is implemented** via `task.delay` between cast and effect. Cost and
   cooldown are paid at cast; the effect is dropped if the caster dies during the
   telegraph. Ignoring windup would have invalidated tempest's 1.8s telegraph,
   which is load-bearing for its 140 damage.
3. **Aura node parts are now `CanQuery = false`.** They are neon readouts, and
   leaving them queryable let a common node body-block every Striker shot.

## Next task: first Studio run

Not more code. `rojo serve`, connect, and play it. Specifically worth watching:

- Does a technique fire at all, and does the HUD move when it does?
- Striker raycasts from `HumanoidRootPart` along its LookVector — does that
  actually point where the camera does, or does it need the camera vector sent
  from the client (which would then need validating against the character)?
- Do constructs look like anything useful at an 18-stud radius?
- Does the 0.4s global cooldown feel like a rhythm or like lag?

Then, in likely order: DataStore persistence (the highest-risk unbuilt system),
contest resolution, telegraph announcements.

## Deferred, on purpose

| Decision | Options | Current |
|---|---|---|
| `Config.ContestResolution` | `presence` / `clear` | `presence` |
| `Config.PrimeSpawnMode` | `random` / `scheduled` | `random` |

Themed combat paths and AI/encounters are deferred. When paths arrive they
should become a restricted, empowered subset of the existing technique pool —
the pool was shaped to make that a metadata layer rather than a rewrite.

Loadouts are server-held but not yet changeable: every player gets
`Config.DefaultLoadout`, published to `Slot_<slot>` attributes so the client can
label its keys. A loadout editor is the obvious next thing the remote needs.

## Open design questions

- What does losing a node fight actually cost, beyond the death loss?
- Does the Remnant mechanic (a kill dropping absorbable material) go in?
- What absorbs passive cycling at the Truegold cap, where most playtime lives?
- Should a breakthrough restore health and madra? It currently does, as a side
  effect of rebuilding the actor on stage change.

## Commands

```sh
lune run tests/progression.test
lune run tests/auranodes.test
lune run tests/combat.test
selene src tests
stylua src tests
rojo serve
```

Typecheck:

```sh
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau --base-luaurc=.luaurc src
```

`globalTypes.d.luau` is fetched from the luau-lsp repo and is gitignored; refetch
it if missing.

> Note for agents working in Git Bash here: backticks inside a `<<'EOF'` heredoc
> get command-substituted, which silently mangles Luau string interpolation.
> Write `.luau` files with an editor tool, not a heredoc.
