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
  a dynamic field (ephemeral, decaying, telegraphed by tier).
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
src/shared/    Config, Progression, AuraNodes  -- pure, no requires, Lune-testable
src/server/    NodeService, CultivationService -- thin bindings to Roblox APIs
tests/         Lune test suites
```

Shared modules take config as a parameter and contain **zero internal requires**,
so the same files load in Roblox (`require(script.Parent.X)`) and under Lune
(`require("./X")`). That is what makes the game rules unit-testable outside Studio.

## Commands

```sh
lune run tests/progression.test     # 31 assertions
lune run tests/auranodes.test       # 43 assertions
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
`Tier`, `Progress`, `Catalysts`, `Power`, `SenseRange`, `AtCeiling`).
