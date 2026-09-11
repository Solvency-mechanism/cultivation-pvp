# starter-game

Xianxia-inspired PvP cultivation game for Roblox. All names are placeholders.

## Design shape

- **Stages are PvP brackets.** Foundation → Copper → Iron → Jade is a fast,
  protected proving ground. Lowgold → Highgold → Truegold is the actual game.
  Capping at Truegold keeps veterans pooled in one undivided endgame bracket
  instead of scattered up an infinite ladder.
- **Refinement is the continuous axis inside a stage** (10 tiers). Power spread
  within a bracket is capped at 18% so skill still decides fights; sense range
  scales faster than power, so veterans out-*find* newcomers more than they
  out-fight them.
- **Advancement ratchets.** Losses can drain the refinement bar but can never
  demote a stage. Non-negotiable when PvP is mandatory.
- **PvP is mandatory by economics, not by rule.** Cycling fills refinement →
  refinement caps at the stage ceiling → breaking the ceiling needs a catalyst
  → catalysts drop only from Prime nodes → Prime nodes are announced
  server-wide. There is no safe grind, and none had to be forbidden.
- **The spawner is the content pipeline.** With AI and encounters deferred,
  node spawn logic does the job level and encounter design do elsewhere.
- **Two node layers.** Static aura geography (permanent terrain richness) under
  a dynamic field (ephemeral, decaying, telegraphed by tier). Both layers are
  live: a node's region is derived from where it actually lands via
  `ArenaService.regionAt`, placement is weighted toward real landmark anchors,
  and cycling and Ruler damage both read the ground you are standing on. For a
  long time this was the one claim on this page that was false -- region was
  rolled from a literal table unrelated to position, so a node labelled
  `wellspring` routinely sat on the visible Ember Barrens.
- **Capacity caps are the anti-zerg valve.** A node feeds three; a ten-player
  clan gains nothing from bringing ten.
- **Prime nodes must be held to the drain** to yield their catalyst, which
  turns a Prime spawn into a timed defence fight rather than a tap-and-leave.

## Deferred, parked as config flags

| Flag | Options | Current |
|---|---|---|
| `Config.ContestResolution` | `presence` / `clear` | `presence` |
| `Config.PrimeSpawnMode` | `random` / `scheduled` | `random` |

Themed combat paths and AI/encounters are deferred. The technique system should
be built as a **shared pool with a limited loadout** so Paths can later become a
restricted, empowered subset rather than a rewrite.

## Layout

```
src/shared/    Config, Progression, AuraNodes, Combat  -- pure, no requires,
                                                        Lune-testable
src/server/    Arena, Node, Cultivation, Combat,        -- thin bindings to
               Awareness, Persistence                      Roblox APIs
src/client/    HUD panels and input
tests/         Lune test suites
```

Shared modules take config as a parameter and contain **zero internal requires**,
so the same files load in Roblox (`require(script.Parent.X)`) and under Lune
(`require("./X")`). That is what makes the game rules unit-testable outside Studio.

## Packaging a build

```powershell
.\package.ps1 -Version v0.1.0
```

Runs the full gate and refuses to package if any part fails, then writes the
place plus a receipt (commit, size, SHA-256) into `dist/`. `dist/` is gitignored:
the artifact is reproducible from the tag, so the tag is what is worth keeping.

`.github/workflows/gate.yml` runs the same checks on every push. It proves the
rules and the build. It cannot prove the game is fun -- only a person playing it
can do that.

See `CHANGELOG.md` for what each build was actually observed doing, as opposed
to what was written.

## Commands

```sh
lune run tests/progression.test     # 58 assertions
lune run tests/auranodes.test       # 88 assertions
lune run tests/combat.test          # 119 assertions
lune run tests/interface.test       # 97 assertions -- HUD geometry, no Studio needed
selene src tests                    # lint
stylua src tests                    # format
rojo build default.project.json --output starter-game.rbxlx
rojo serve                          # then Connect from the Rojo plugin in Studio
```

Typecheck:

```sh
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau --base-luaurc=.luaurc src
```

`globalTypes.d.luau` is fetched from the luau-lsp repo and is gitignored.

## Testing in Studio

Players spawn straight into **Lowgold** — the bracket that needs validating.
Glowing spheres are aura nodes: blue common, purple rare, gold prime. Stand
inside one to cycle. Live state is published to player attributes (`Stage`,
`Tier`, `Progress`, `Catalysts`, `Power`, `SenseRange`, `AtCeiling`, `Health`,
`Madra`).

Keys **1-4** fire the four loadout slots (striker, enforcer, forger, ruler). The
client sends only the slot name; the server resolves it against the loadout it
holds and owns every cost, cooldown and damage decision.

**Hold Shift and a slot key** (or right-click the slot) to swap that slot to a
different technique of the same kind. Without it every character is identical
and eight of the twelve techniques are unreachable, which is how it shipped to
the first playtest group.

**Combat dummies**, for testing anything without a second player:

```
/dummy stationary|moving|caster [stage] [techId]
/dummy clear
```

They go through the same combatant resolution and damage path as players --
deliberately, because a dummy that has its own path stops being a measuring
instrument and becomes a second thing to debug. A `caster` dummy loops a
telegraphed technique, which is the only way to watch a cast bar from the
defending side; a staged dummy is the cheapest way to exercise bracket
refusal.

`ArenaService` builds ground and a spawn pad when the place lacks them, so any
Studio place works and a Baseplate place will not end up with two floors. Nodes
are placed from its landmark anchors rather than scattered over a disc, so they
appear at the places worth walking to.

**Before publishing, run `.\publish-build.ps1`.** It deletes the place file and
rebuilds it, rather than inspecting the one that is there. A place saved out of
Studio is code of unknown vintage wearing the right filename -- neither its size
nor its timestamp tells you which commit is inside it -- and this has already
nearly shipped a build with an entire subsystem silently absent.

Press **B** at the refinement ceiling to break through. Progress saves on leave,
on shutdown and every 90 seconds — but DataStores are unavailable in an
unpublished place, where the server warns once and runs in memory.
