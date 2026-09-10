# Handoff

State as of commit `b67a1e2`. All names are placeholders.

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

## What exists and is verified

| Module | What it owns |
|---|---|
| `shared/Config` | All tuning: stages, refinement, node tiers, spawn weights, techniques, combat constants |
| `shared/Progression` | Stage and refinement math, catalyst gate, the ratchet |
| `shared/AuraNodes` | Spawn rolls, occupancy, capacity, decay, cycle rates, contest detection |
| `shared/Combat` | Resources, technique gating, buffs, mitigation, damage resolution |
| `server/NodeService` | Field lifecycle and the node parts in Workspace |
| `server/CultivationService` | Per-player state, cycling tick, catalyst grants |
| `client/init.client` | HUD mirroring player attributes |

**164 Lune assertions across three suites**, plus selene, stylua, `rojo build`
and `luau-lsp analyze` all clean.

The three assertions worth not breaking:

- intra-bracket time-to-kill advantage is **exactly 18%**
- time-to-kill is **constant across brackets**
- spawn distribution matches configured weights over 20,000 samples

## What has never been run

The pure logic is tested. The **Roblox binding layer has never executed** — it
builds and typechecks, but no one has stood in a node and watched the bar move.
That is the first thing to do, and it is likelier to surface bugs than anything
in the tested modules.

Not built at all: PvP damage in-game, bracket-enforced matchmaking, DataStore
persistence (state is in-memory and dies with the server), the proving ground,
telegraph announcements, and contest resolution.

## Next task: `server/CombatService`

The combat *rules* are done; the *binding* is not. Config already carries
`Config.Combat.ranges` and `Config.Combat.respawnSeconds`, added for this step
and **currently unreferenced** — that is staged, not dead code.

What it needs to do:

1. Own a `Combat.Actor` per player, created on spawn from their stage index.
2. Accept a `UseTechnique` RemoteEvent carrying a **slot name**, never a damage
   value. Resolve the slot against the player loadout server-side.
3. Gate every use through `Combat.canUse`, then `Combat.use`. Never trust the
   client for cost, cooldown or damage.
4. Resolve hits by kind:
   - `striker` — raycast forward to `ranges.striker`
   - `ruler` — sphere query at `ranges.ruler`, and pass the **caster region**
     into `Combat.outgoingDamage` so terrain scaling applies
   - `enforcer` — self only, buff already applied by `Combat.use`
   - `forger` — `barrier` is a self-buff; `caltrops` and `sentry` need a
     persistent damaging construct that does not exist yet
5. Refuse cross-bracket damage via `Combat.canEngage`.
6. On death: apply `Combat.deathLoss` through `Progression.applyLoss`, then
   respawn after `respawnSeconds`.
7. Drive `Combat.regen` from the existing heartbeat in `server/init.server`.

Client side needs keys 1–4 bound to the four slots firing that remote.

Note that `CultivationService` currently keeps its state table private. It will
need to expose stage index and effective power to `CombatService`, or the two
should share a single player-state module.

## Deferred, on purpose

| Decision | Options | Current |
|---|---|---|
| `Config.ContestResolution` | `presence` / `clear` | `presence` |
| `Config.PrimeSpawnMode` | `random` / `scheduled` | `random` |

Themed combat paths and AI/encounters are deferred. When paths arrive they
should become a restricted, empowered subset of the existing technique pool —
the pool was shaped to make that a metadata layer rather than a rewrite.

## Open design questions

- What does losing a node fight actually cost, beyond the death loss?
- Does the Remnant mechanic (a kill dropping absorbable material) go in?
- What absorbs passive cycling at the Truegold cap, where most playtime lives?

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
