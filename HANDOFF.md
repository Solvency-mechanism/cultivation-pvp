# Handoff

State as of the "playable loop" commit. All names are placeholders.

## Machine setup

Everything needed is installed and on the persistent user PATH.

- **Roblox Studio** installed; the Rojo Studio plugin is in place as
  `%LOCALAPPDATA%\Roblox\Plugins\RojoManagedPlugin.rbxm`, matching CLI 7.7.0.
- **Rokit** at `~/.rokit/bin` manages rojo 7.7.0, wally 0.3.2, stylua 2.5.2,
  selene 0.31.0, luau-lsp 1.69.0, lune 0.10.5.
- **VS Code** has luau-lsp, vscode-rojo, stylua and selene-vscode.

> If `rojo` reports "not found", the terminal predates the PATH change. Open a
> new one. This is not a broken install.

## How to run it

```sh
rojo serve      # then Connect from the Rojo plugin in Studio, and press Play
```

Any Studio place works — `ArenaService` builds ground and a spawn if the place
does not already have them, and skips both if it does, so connecting to a
Baseplate place will not produce two floors.

**Controls:** `1-4` fire the four loadout slots (striker, enforcer, forger,
ruler). `B` attempts a breakthrough. Walk into a glowing sphere to cycle.

## The architectural rule that matters

Everything in `src/shared/` is **pure and contains zero internal requires**, and
takes `Config` as a parameter instead of requiring it.

That is not stylistic. Roblox requires by instance (`require(script.Parent.X)`)
and Lune requires by relative path (`require("./X")`), and the two are
incompatible. Dependency-free modules load unchanged under both, which is the
only reason the game rules are unit-testable outside Studio.

**Adding a require between two shared modules breaks every test.** If a shared
module needs something from another, pass it in as an argument.

Server modules require each other freely, one way only. `CombatService`,
`AwarenessService` and `PersistenceService` all read from `CultivationService`;
`CultivationService` knows about none of them. Anything that needs to react to a
cultivation change polls for it rather than being called back — which is why
`CombatService` rebuilds its actor by comparing stage index each tick.

## The loop, end to end

Every step below now exists in code. **None of it has been played.**

1. Spawn at Lowgold (testers skip the proving ground; Lowgold is the bracket
   that needs validating).
2. Sense nodes within your range — the right-hand panel lists them nearest
   first with distance, occupancy and a bearing arrow.
3. Stand in one to cycle. Refinement fills; tiers roll over.
4. At the refinement ceiling, the bar turns gold and the bar stops.
5. A Prime node spawns and **every player on the server is told**, regardless of
   range. Hold it until it drains to earn a catalyst.
6. Press `B` to break through. Refusals explain themselves rather than doing
   nothing.
7. Fight with `1-4`. Same-bracket only. Dying costs 35% of a tier and never a
   stage.
8. Progress saves on leave, on shutdown, and every 90 seconds.

## What exists and is verified

| Module | What it owns |
|---|---|
| `shared/Config` | All tuning: stages, refinement, node tiers, spawn weights, techniques, combat, persistence |
| `shared/Progression` | Stage and refinement math, catalyst gate, the ratchet, save sanitizing |
| `shared/AuraNodes` | Spawn rolls, occupancy, capacity, decay, cycle rates, contest detection, sensing, telegraph scope |
| `shared/Combat` | Resources, technique gating, buffs, mitigation, damage resolution, slot resolution |
| `server/ArenaService` | Ground and spawn, if the place lacks them |
| `server/NodeService` | Field lifecycle, node parts, spawn and drain hooks |
| `server/CultivationService` | Per-player state, cycling tick, catalyst grants, death loss, breakthrough |
| `server/CombatService` | Actors, UseTechnique, hit resolution, constructs, death, respawn |
| `server/AwarenessService` | Per-player sensed-node feed and telegraph announcements |
| `server/PersistenceService` | DataStore load and save, retries, autosave |
| `client/init.client` | Status, sense and notice panels; keys 1-4 and B |

**233 Lune assertions across three suites**, plus selene, stylua, `rojo build`
and `luau-lsp analyze` all clean.

The assertions worth not breaking:

- intra-bracket time-to-kill advantage is **exactly 18%**
- time-to-kill is **constant across brackets**
- **finding outpaces fighting** — the sense-range spread across refinement is
  strictly larger than the power spread, which is the pressure valve working
- spawn distribution matches configured weights over 20,000 samples
- a construct cannot kill from full over its whole duration, and is still worth
  stepping out of — these two bounds pin `constructTickSeconds`
- Prime announces to everyone regardless of range; common announces to nobody
- a sanitized save always survives the functions that assert on their input

## What has never been run

**Everything that touches Roblox.** The pure rules are tested; the entire binding
layer — six server modules and the client — has never executed. It builds and
typechecks, which is not the same thing.

Specific things worth watching on the first run, roughly in order of how likely
they are to be wrong:

1. **Does a technique fire at all**, and does the HUD move when it does?
2. **Striker aim.** The raycast runs from `HumanoidRootPart` along its
   LookVector, which is the character's facing, *not* the camera's. In
   shift-lock they agree; in free camera they do not. This probably needs the
   camera vector sent from the client and validated server-side against a sane
   angle — that is a design decision, not just a fix.
3. **Bearing arrows.** Taken against the camera's own forward and right vectors,
   so the handedness should be right, but nobody has looked at it.
4. **Node spawn heights.** Nodes are placed at `y = 4` on flat ground. On a place
   with terrain they will float or sink.
5. **Whether the 0.4s global cooldown reads as rhythm or as lag.**

DataStores do not work in an unpublished place, or in Studio without *Enable
Studio Access to API Services*. That is handled: the server warns once and runs
in memory. **Persistence itself is therefore untested** — it needs a published
place to exercise at all.

Not built at all: bracket-enforced matchmaking, the proving ground as a distinct
experience, contest resolution, and a loadout editor.

## What the last session added

Everything needed to complete the loop, on top of the combat binding:

- **`ArenaService`** — the project tree ships no Workspace geometry, so a place
  built from `rojo build` alone dropped the player into the void. Now it builds
  a 700-stud plate and a spawn pad when the place lacks them. No spawn
  forcefield: an invulnerability window at the one place everyone returns to
  would have made the spawn a safe grind.
- **`AwarenessService`** — sensing and telegraphs. `senseRange` had been a
  computed stat with no gameplay effect at all, which meant the "veterans
  out-*find* newcomers" valve was documented but absent. Filtering is
  server-side.
- **`PersistenceService`** — DataStore with retries. The rule that matters: **a
  failed load never overwrites a save.** A player whose data could not be read is
  marked unsaveable for the session rather than having their progress silently
  replaced by a fresh state.
- **Breakthrough is reachable.** `CultivationService.tryAdvance` had existed
  since the first commit with nothing calling it, so the core loop could not be
  completed. `B` now fires it, and every refusal reason has a sentence.
- **`Progression.sanitizeState`** — saves outlive the config that wrote them.

Two bugs found by re-reading rather than by running:

- `Humanoid.Died` was only connected when an actor already existed, so a player
  whose state was still loading when their character spawned would never have
  had a death handler. Death now resolves the stage at death time.
- The node spawn hook compared list lengths, but `AuraNodes.step` culls before it
  appends — so a tick that expired three nodes and spawned one would have
  announced nothing. It compares ids now.

## Deferred, on purpose

| Decision | Options | Current |
|---|---|---|
| `Config.ContestResolution` | `presence` / `clear` | `presence` |
| `Config.PrimeSpawnMode` | `random` / `scheduled` | `random` |

Themed combat paths and AI/encounters are deferred. When paths arrive they
should become a restricted, empowered subset of the existing technique pool.

Loadouts are server-held but not changeable: every player gets
`Config.DefaultLoadout`, published to `Slot_<slot>` attributes so the client can
label its keys.

## Open design questions

- **The first two minutes.** At Lowgold a tier is 9,000 progress and a stage is
  ten of them — roughly three hours at a rare node's rate. That is probably right
  for the endgame and certainly wrong for onboarding. The proving-ground stages
  exist to absorb this and have never been played or tuned.
- What does losing a node fight cost, beyond the death loss?
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
