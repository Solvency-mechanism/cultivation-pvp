# COMBAT VISION

Date: 2026-09-10
Scope: `starter-game` combat loop as currently implemented in:
`src/shared/Config.luau`, `src/shared/Combat.luau`, `src/shared/ImpactSpec.luau`, `src/server/CombatService.luau`, `src/client/init.client.luau`, `src/client/Vfx.luau`, `src/client/Impact.luau`.

Constraints locked by user:
1) No universal defense system (no dodge button, no block, no parry, no i-frames, no universal forced-movement defense). A slot-costing, madra-costing, cooldown-gated, opponent-visible movement commitment -- e.g. the enforcer-slot Swiftstep defined in (e) -- is exactly the kind of deliberate defense the design calls for; what is disallowed is any defensive movement that is free, unlimited, or not a committed choice.
2) Shared modules in `src/shared` remain pure and never require each other.
3) Server authoritative, client sends intent only.
4) Invariants: exact 18% intra-bracket TTK advantage, constant TTK across brackets, and flat health within stage.
5) Presentation is severity-driven through `ImpactSpec`; new mechanics must use existing channels.
6) No global terrain combat stat layers outside nodes.

Out of scope / explicitly rejected:
- No speed/toughness/strength attributes.
- No terrain modifiers outside node-local effects.
- Ruler terrain scaling (`regionScaled`) remains only one existing exception.

## a) Read-and-react sequence with proof

Current live flow for one striker exchange (per code):
1) Client sends `UseTechnique(slot, cameraLookVector)` in `src/client/init.client.luau`.
2) `CombatService.onUseTechnique` resolves slot, applies `Combat.use`, and enforces cost/cooldown/gcd.
3) `task.delay(tech.windup, resolveEffect)` is scheduled.
4) `resolveEffect` calls `resolveStriker`.
5) `resolveStriker` immediately raycasts from caster root for `Config.Combat.ranges.striker` and decides hit/miss right away.
6) Server sends `TechniqueFired` payload for VFX after resolve; VFX comment and code show no cast-time broadcast for opponents.

Travel model decision:
- Fixed point only (committed).
- The striker samples one destination at cast intent time and does not track target movement.
- Tracking is not allowed, or dodge collapses into a no-skill guessing game and read-and-react dies.

Reaction and latency model:
- Human reaction: `0.25s`.
- Opponent cast visibility: `+` network delay one-way `0.08..0.15s`.
- Committed movement half-width: `r = 2`.
- Walking speed used for proof: `v = 16 studs/sec`.
- Dodge condition:
  - `v * t_flight > landingRadius + 2`, where `t_flight = range / projectileSpeed`.
- `preflightBudget = max(0, windup - (0.25 + netDelay))`.
- For `lance` and `volley` the preflight budget is around zero with these windups.

Candidate projectile values for this draft:
- `lance`: windup `0.28`, speed `190`, landingRadius `2.4`, cooldown/madra/damage unchanged.
- `volley`: windup `0.50`, speed `165`, landingRadius `2.8`, cooldown/madra/damage unchanged.
- `pierce`: windup unchanged at `0.90`, speed `145`, landingRadius `3.4`, cooldown/madra/damage unchanged.

Flight-time table:

| Striker | 140 studs | 80 studs | 40 studs | 20 studs |
|---|---:|---:|---:|---:|
| lance | 140/190 = `0.737s` | 80/190 = `0.421s` | 40/190 = `0.211s` | 20/190 = `0.105s` |
| volley | 140/165 = `0.848s` | 80/165 = `0.485s` | 40/165 = `0.242s` | 20/165 = `0.121s` |
| pierce | 140/145 = `0.966s` | 80/145 = `0.552s` | 40/145 = `0.276s` | 20/145 = `0.138s` |

Flight-only dodge distance at 16 studs/sec (`d_flight = 16 * time`):
- `lance`: 11.79, 6.74, 3.38, 1.68
- `volley`: 13.57, 7.76, 3.87, 1.94
- `pierce`: 15.46, 8.83, 4.42, 2.21

At 20 studs, compare to dodge threshold `L + 2`:
- `lance`: `2.4 + 2 = 4.4`; max dodge `1.68` -> NO dodge.
- `volley`: `2.8 + 2 = 4.8`; max dodge `1.94` -> NO dodge.
- `pierce`: `3.4 + 2 = 5.4`; max dodge `2.21` -> NO dodge.

So yes, with this fixed-point and travel-only reaction model, a bolt fired at short range cannot be sprint-dodged: the defender cannot cover their own hitbox width in the flight time available. That fact does not change under the ruling below -- what changes is what the design does with it.

The exact dodge-to-read boundary is:

`d_cross = projectileSpeed * (landingRadius + 2) / 16`.

- `lance`: `190 * (2.4 + 2) / 16 = 52.25` studs
- `volley`: `165 * (2.8 + 2) / 16 = 49.50` studs
- `pierce`: `145 * (3.4 + 2) / 16 = 48.94` studs

**Ruling (round 5, delegated to the human and judged on fun): the dead zone is rejected. `armingMin` is removed entirely.** The prior draft used `d_cross` as a floor below which a bolt would not connect at all (`armingMin`), producing a band up to ~50 studs deep where the striker simply did nothing. That is rejected, for five reasons:

1. A dead zone turns a button off. In an action game that reads as a bug, not as design. Lance is bound to key 1 and is the most-pressed input in the game; "my ability silently did nothing" is one of the worst feel-moments available, and no player infers "spacing is the skill" from it -- they infer the ability is broken.
2. Fifty studs is not close range. A Roblox character is about 5 studs. A 0-to-50-stud dead zone is ten body-lengths deep -- most of the fight, not an edge case.
3. The alternative of leaving close range undodgeable at full damage inverts the whole design: if a point-blank bolt always lands for full, the optimal play is to close distance and spam striker, and the read-and-react duel never happens.
4. Damage falloff gets everything the dead zone was reaching for and pays none of the cost. The striker still fires at any range; close-quarters play passes to enforcer, forger and ruler by incentive rather than by prohibition. The duel band at and beyond `d_cross` is untouched -- that is where the read-and-react game was always going to live.
5. It matches this project's own stated philosophy. README.md says PvP is mandatory "by economics, not by rule -- there is no safe grind, and none had to be forbidden." This is the identical move one layer down: close-range striker use is made unattractive rather than forbidden. This codebase already knows how it likes to solve this class of problem, and a hard arming distance was out of voice with it.

`d_cross` survives the ruling, but its meaning changes: it is no longer an arming floor, it is the **full-damage crossover**. At and beyond `d_cross` a striker deals full damage and the duel plays out exactly as the flight-time and dodge math above describe. Below `d_cross`, damage falls off with distance instead of the bolt refusing to land.

Falloff shape (shared by all three strikers):
- `1.0` at and beyond `d_cross`.
- A floor of `0.45` at contact range (`d = 0`) -- enough that a desperate point-blank shot still does something, low enough that it is visibly the wrong tool.
- Smoothstep interpolation between the two, not linear, so there is no sharp edge a player would feel as a cliff and no single exact distance where damage jumps:
  - `t = clamp(d / d_cross, 0, 1)`
  - `falloff = 0.45 + 0.55 * (3*t^2 - 2*t^3)`

| `t = d / d_cross` | falloff |
|---|---:|
| 0.00 (contact) | 0.450 |
| 0.25 | 0.536 |
| 0.50 | 0.725 |
| 0.75 | 0.914 |
| 1.00 (`d_cross` and beyond) | 1.000 |

Node combat at radius `14` sits at roughly `t ~= 0.27` against these `d_cross` values, i.e. a striker fired inside a contested node lands for roughly **55% damage** -- a real but weak tool, not a disabled one. That is the shape this design wants: the striker stays legal and functional at any range, but it is visibly the wrong tool up close, and enforcer/forger/ruler win that space on their own merits rather than because the striker was switched off there.

Flagged concerns (not changed here -- playtest questions, recorded so they are not lost):
- **`v = 16 studs/sec` is the root cause of the ~50-stud crossover**, and it is Roblox's default walk speed, not a number this design chose. It is slow relative to any plausible projectile, which is what forces `d_cross` out to ~50 studs in the first place. A single global combat movement constant raised to 20-24 studs/sec pulls the crossover to roughly 33-41 studs and lets the whole design breathe. This is explicitly **not** the rejected speed/toughness/strength attribute layer -- it is one number, identical for every player, with no build diversity and no per-player stat attached. It is the highest-leverage untried knob in this spec and a first-order playtest question.
- **The 140-stud striker range is suspect for telegraph legibility.** A windup VFX at 140 studs is a handful of pixels on screen, and a duel fought at that distance may be unreadable regardless of how correct the flight math is. Playtest question; nothing changes here.

The `Vfx.charge` vs `Vfx.play` mismatch is still true: local caster sees pre-impact charge, non-local cast telegraph is not currently seen. This is a required server-event extension to preserve the loop.

## b) 12 technique-by-technique changes for read-and-react

Per-entry values for this draft; unchanged fields are inherited from current `Config.Techniques`.

Striker:
- `lance`
  - windup: **0.28** (from 0.15)
  - projectileSpeed: **190** (new)
  - landingRadius: **2.4** (new)
  - range/cooldown/damage/madraCost unchanged (140, 1.2, 42, 18)

- `volley`
  - windup: **0.50** (from 0.35)
  - projectileSpeed: **165** (new)
  - landingRadius: **2.8** (new)
  - dart count in this spec: **4 darts** (new sequencing field)
  - range/cooldown/damage/madraCost unchanged (140, 2.6, 66, 30)

- `pierce`
  - projectileSpeed: **145** (new)
  - landingRadius: **3.4** (new)
  - windup/cooldown/damage/madraCost unchanged (0.90, 5.00, 128, 44) -- corrected from an earlier draft of this doc, which misstated windup as 1.00; `Config.Techniques.pierce.windup` is 0.9

- Range falloff (shared, all three strikers; see (a) for the ruling and the curve): no `armingMin` field. Each technique's `d_cross` is still `projectileSpeed * (landingRadius + 2) / 16` (lance 52.25, volley 49.50, pierce 48.94 studs), now used only as the full-damage crossover for `Combat.rangeFalloff`. The `0.45` floor and the smoothstep shape between contact and `d_cross` are shared constants, not per-technique fields.

Enforcer:
- `surge`
  - damageBuff: **0.00** (from 0.35)
  - mitigation: **0.25** (from 0.00)
  - cooldown/buffDuration/windup/damage/madraCost unchanged (9.0, 5.0, 0.1, 0, 32)
  - pick it when: you expect sustained incoming pressure and want a 5s mitigation window instead of movement.

- `bulwark`
  - mitigation: **0.50** (from 0.40)
  - cooldown/buffDuration/windup/damage/madraCost unchanged (11.0, 6.0, 0.1, 0, 28)
  - pick it when: you need hard mitigation against one big spike and can afford the longer cooldown.

- `swiftstep` (defensive mobility commitment)
  - damageBuff: **0.00** (from 0.15)
  - mitigation: **0.18** (from 0.10)
  - swiftstepDistance: **5.0** studs (new)
  - swiftstepWindow: **0.95** sec (new)
  - swiftstepRecovery: **1.2** sec (new)
  - cooldown/windup/madraCost unchanged (7.0, 0.05, 22), buffDuration stays 4.0
  - pick it when: you need a dodgeable dodge at close range and are willing to spend slot/time on a single movement commitment.

Forger:
- `barrier`
  - all combat fields unchanged (damage/mitigation/windup/cooldown/buffDuration/madra as current, i.e., 0, 0.55, 0.4, 12.0, 8.0, 40).
- `caltrops`
  - all combat fields unchanged (damage 30, windup 0.5, cooldown 10.0, madra 45).
- `sentry`
  - all combat fields unchanged (damage 24, windup 0.7, cooldown 16.0, madra 55) -- corrected from an earlier draft of this doc, which misstated cooldown as 12.0 (that is `sentry`'s `buffDuration`, not its cooldown); `Config.Techniques.sentry.cooldown` is 16.0.
Ruler:
- `upheaval`
  - all fields unchanged (windup 1.4, damage 95, cooldown 14.0, madra 70)
- `siphon`
  - all fields unchanged (windup 0.8, damage 55, cooldown 11.0, madra 50)
- `tempest`
  - all fields unchanged (windup 1.8, damage 140, cooldown 20.0, madra 85)

Cross-constraints:
- No other techniques receive `regionScaled` true.
- The draft keeps damage scalars in place unless explicitly changed above.

## c) Aura affinity model that fits 12 techniques, not overrun the invariants

Region keys are confirmed in code:
- `Config.StaticRegionMultipliers` keys: `open, barren, rich, wellspring`.

Aura types mapped to those keys:
- `open` => `inactive` for affinity (node-local effects only; no match/counter evaluation),
- `barren` => `ash`
- `rich` => `verdant`
- `wellspring` => `lumen`

Decision and option comparison:
- Option 1 (recommended): keep 4 auras, keep node-local gating, and treat `open` (including off-node fallback via `regionOf`) as `inactive`.
- Option 2 (rejected here): collapse to three auras by removing `neutral` from all techniques.
- Option 3 (rejected here): keep `neutral` as a true aura that never matches or counters anywhere, which is a strict no-op identity but is equivalent to Option 1 for all current technique assignments.

Recommendation:
- This is the cleanest fit for three constraints at once:
  - `regionOf` is `open` when no node exists,
  - only node occupants should get combat modulation,
  - and only four nodes are modeled in the map pipeline today.

This means neutral is not “always-on on open ground”; it is “always-on nowhere for match/counter”.

Decision: aura is kind-spanning rather than kind-locked.
That means no Path can lock a player into one play pattern by slot kind alone; each loadout can still compose cross-role counters.

Aura assignment table (12 techniques):
- `lance` => `neutral`
- `volley` => `ash`
- `pierce` => `verdant`
- `surge` => `lumen`
- `bulwark` => `neutral`
- `swiftstep` => `ash`
- `barrier` => `verdant`
- `caltrops` => `lumen`
- `sentry` => `neutral`
- `upheaval` => `ash`
- `siphon` => `verdant`
- `tempest` => `lumen`

Node source of aura:
- `NodeService.nodeAt(position)` returns the nearest node or `nil`.
- `AuraNodes.create(..., region, now)` stores `region` on the node record.
- `CombatService.regionOf` reads `node.region` each cast, and uses `"open"` when no node is present.
- Therefore current code requires affinity logic to check `node` existence and `region ~= "open"` before applying any affinity channel. The off-node `"open"` fallback is an inactive state, not a neutral-region match.

Aura reachability from current code:
- `AuraNodes.step(config, nodes, now, rng, nextId, placer)` does not know geography; it asks the injected `placer(tierId)` for both position and region.
- `NodeService.placer` currently chooses position randomly inside a 220-stud disc, then draws region from `{ "open", "open", "rich", "barren", "wellspring" }` (verified directly in `src/server/NodeService.luau`, lines 106-117).
- Therefore current region distribution is a fixed table draw, not geography sampling:
  - `open`: 2/5 = 40% of spawned nodes, affinity inactive.
  - `barren`: 1/5 = 20% of spawned nodes, `ash`.
  - `rich`: 1/5 = 20% of spawned nodes, `verdant`.
  - `wellspring`: 1/5 = 20% of spawned nodes, `lumen`.
- `AuraNodes.rollTier` separately draws node tier from `Config.Field.spawnWeights` (`common` 70, `rare` 25, `prime` 5); tier does not change region or aura in current code.

**What the 40% `open` draw means for the affinity model:**
- The active aura distribution is not badly skewed among `ash`, `verdant`, and `lumen`: each appears on 20% of all nodes and one third of affinity-active nodes.
- The real skew is that 40% of current nodes are `open` and therefore affinity-inactive. With the current 3/3/3/3 technique assignment, `neutral` techniques never match, and each colored technique matches on 20% of all nodes, counters on 20%, is ordinary neutral on 20%, and is inactive on the 40% `open` nodes -- so on two-fifths of all node fights, the entire affinity axis (one of the three build-diversity axes this spec is built around) contributes nothing, regardless of loadout.
- The model only survives this if open nodes are intentionally meant to be baseline, affinity-free fights. If affinity is meant to be present in most node fights, this 40% has to come down.

**This looks like a placeholder distribution, not a designed one.** The source comment directly above `placer` in `src/server/NodeService.luau` (line 104) says so itself: "Placeholder placement. Real maps should seed this from tagged spawn anchors so static aura geography actually means something." The `{ "open", "open", "rich", "barren", "wellspring" }` table reads as scaffolding written to unblock testing (nodes need *some* region), not as a tuned ratio -- there is no reasoning in the code or in this spec for why `open` should be exactly twice as common as each colored region. Before affinity ships, this table should be replaced by a distribution someone actually decided on (or by real map anchors), not carried forward as-is.

This is not a raw damage model. Node-local combat uses this contract:
Relation matrix for technique aura -> node aura (ordered pairs):

- Match = same aura.
- Counter = strict disadvantage.
- Neutral = otherwise.

| Technique aura \\ Node aura | neutral | ash | verdant | lumen |
|---|---|---:|---:|---:|
| neutral | neutral | neutral | neutral | neutral |
| ash | neutral | match | counter | neutral |
| verdant | neutral | neutral | match | counter |
| lumen | neutral | counter | neutral | match |

This is a 3-node cycle:
- `ash` matches `ash`, is countered by `verdant`, and is neutral into `lumen`.
- `verdant` matches `verdant`, is countered by `lumen`, and is neutral into `ash`.
- `lumen` matches `lumen`, is countered by `ash`, and is neutral into `verdant`.
- `neutral` never matches and never counters; it is neutral into every node aura.

- Match:
  - Striker: `landingRadius +1.4`, `d_cross -4` studs.
  - Forger: construct radius +25%, construct duration +20%.
  - Enforcer: buff duration +20%.
- Counter:
  - Striker: `landingRadius -0.8`, `d_cross +6` studs.
  - Forger: construct radius -15%, one fewer pulse window.
  - Enforcer: buff duration -20%.
- Neutral: no affinity delta.

**Where the removed `armingMin` delta goes, now that (a) has rejected the dead zone:** it moves to `d_cross`, not to `landingRadius`. Two options were on the table:

1) Fold the old `armingMin` delta into `landingRadius` instead, and let `d_cross` move only as a side effect of `landingRadius` changing (`d_cross` is already a function of `landingRadius`).
2) Keep `landingRadius`'s existing match/counter deltas exactly as they were (a hit-geometry effect only), and apply the old `armingMin` magnitudes directly to `d_cross`, the falloff crossover, as a separate lever.

Option 2 is chosen. Routing the old delta through `landingRadius` (option 1) entangles two things a player would have to read as one: a bigger hitbox is not obviously "the same kind of better" as a shorter falloff ramp, and the sign is not even guaranteed to point the intuitive way once smoothstep and the floor are in the mix. Applying the delta straight to `d_cross` is legible on its own terms and reuses a magnitude that was already tuned for exactly this purpose: a match pulls the full-damage crossover 4 studs closer (more of the field is full-damage territory), a counter pushes it 6 studs further out (less of it is). `landingRadius`'s own match/counter deltas are untouched and keep doing only their original job -- hit geometry, not damage scaling.

Why this does not break invariant math:
- `tests/combat.test.luau` currently checks:
  - `ruler` scales with region and `lance` ignores region for damage.
  - low-to-high refinement TTK ratio exactly `1.18`.
  - TTK constant across brackets.
- If affinity only changes timing/shape and node-local geometry (as above), outgoing base damage for strikers stays unchanged and these assertions should remain stable.
- If affinity enters base `outgoingDamage` for non-rulers, it will fail the existing `lanceWell == freshHit` assertion.
- The `d_cross` shift introduced in this round is not an exception to that rule: it is a parameter of `Combat.rangeFalloff`, a separate pure function applied in `CombatService` at resolve time, never inside `Combat.outgoingDamage` (see (a) and (g)). `Combat.outgoingDamage(config, dummy, "lance", freshPower, "wellspring", 0)` calls neither affinity nor falloff, so `lanceWell == freshHit` is untouched by this ruling regardless of node aura or distance.

The spec is therefore intentionally constrained: affinity is the readable mechanic, not a covert power stat.

## d) Node-local combat effects + capacity/contest interaction

Node-local sources:
- `NodeService.nodeAt` determines if a fighter is inside node radius and which region applies.
- `AuraNodes.addOccupant` and `AuraNodes.occupantCount` drive all contest logic in this phase.
- Combat should consult occupancy directly and not apply modifiers outside a node.
- `open` is affinity-inactive whether it comes from the off-node `regionOf` fallback or from an actual open-region node spawned by the current placeholder table.

Capacity interaction:
- `Config.NodeTiers.common.capacity` is 3 and is already enforced.
- Node effects apply only to:
  - occupants of the node,
  - not to non-occupants.

Contest interaction:
- `Config.ContestResolution` currently `presence`.
- Do not dampen contested nodes.
- There are no factions in current combat/data models.
- Contested means `#occupants > 1` (which is equivalent to contested in current code, because `factionOf` defaults to `userId` in `AuraNodes`).
- Derived occupancy levels for node locality:
- `densityIndex = clamp(occupantCount - 1, 0, 2)` (capacity 3 implies max 2 extra occupants)
  - `hasContest = (occupantCount > 1)` from `AuraNodes.isContested(node, _factionOf)`.
- New node-local multipliers target non-damage channels only:
  - `densityFactor = 1 + 0.10 * densityIndex`.
  - applied only to flight/shape channels (`landingRadius`, construct geometry, buff duration), never to `Combat.outgoingDamage`. `armingMin` no longer exists to modulate (see (a), round 5); this list was not otherwise revisited by that ruling.

For `clear` resolution mode (deferred), branch can switch to zero bonus while contested.

Why this helps:
- Node fights become stronger for being on-node together.
- Open ground remains neutral.
- Capacity rules stay unchanged and still matter.

## e) Enforcer is the only deliberate defense

Hard rule remains: only the enforcer slot is a deliberate, committed defense.
No extra universal dodge button, no global stamina layer, no universal block or guard.

Current three enforcers in draft:
- `surge`: mitigation-gated sustain.
- `bulwark`: max-mitigation burst.
- `swiftstep`: instant commitment burst-move.

Concrete `swiftstep` commitment (single explicit mechanic):
- Player enters a **0.95s pre-move commitment** (`swiftstepWindow`) so opponents see read signal.
- At commit end, player displaces up to `5.0` studs in a chosen dodge direction (instantly).
- For the next `1.2s` (`swiftstepRecovery`), the commitment cannot be retriggered.
- This is intentionally tuned to beat one close `lance`-speed dodge gap (`5.0 > 4.4`), and it remains a deliberate, visible commitment because it requires cast-up and leaves a recovery hole.

## f) Path seam for future implementation (no rewrite)

Current base requirement says techniques are currently shared and should not be rewritten.
Path model should be a constrained view, not a replacement:
- Add `Config.Paths` with path->allowed technique IDs per slot.
- Add a pure shared selector helper that filters the shared pool to one allowed subset per path.
- Keep every shared technique in place.
- `CombatService` loadout assignment uses selected path list then validates kind and slot.
- This preserves a drop-in switch once paths unlock.

## g) Conflict map with hard constraints and invariants

Known collision points:
- `src/shared` purity:
  - no new `require` among shared modules.
- Balance invariants:
  - `tests/combat.test.luau` asserts:
    - intra-bracket TTK advantage exactly 18%
    - TTK constant Lowgold vs Highgold
    - TTK constant Lowgold vs Truegold
    - striker ignores terrain while ruler scales with region.
  - Base damage for non-ruler techniques must remain unchanged unless assertions are updated.
  - Range falloff (round 5 ruling, see (a)) must not touch these. It is kept out of `Combat.outgoingDamage` entirely and applied only in `CombatService` at resolve time, so none of the four assertions above ever exercise it -- `tests/combat.test.luau` calls `Combat.outgoingDamage` directly and never supplies a distance.
  - Falloff is also symmetric across refinement tiers even where it *is* eventually applied, so it cannot widen the intra-bracket spread on its own: `hitsFreshToKillMaxed / hitsMaxedToKillFresh` in the 18% test reduces to `maxedHit / freshHit` (the `hp /` on both sides cancels). If a caller later multiplied both `freshHit` and `maxedHit` by the *same* `falloff(distance)` -- which is all falloff can be, since it is a function of distance only, never of power -- that factor cancels out of the ratio identically: `(maxedHit*f) / (freshHit*f) = maxedHit/freshHit`. The 18% ratio is unaffected at any fixed distance. Verified against the actual assertion at `tests/combat.test.luau:47-65`, not assumed.
- Terrain scale scope:
  - only ruler currently has `regionScaled=true`; keep it that way for damage.
- Presentation:
  - no new severity channel; use existing ImpactSpec contract.
- PvP feedback:
  - opponent cast telegraph is not visible from code today; adding a cast event at intent time is required.

Potential hidden risk:
- If fixed-point vs tracking is reversed, dodgeability as designed collapses.
- If contest is damped rather than amplified, close-node fights lose intended readability.

## h) Ordered implementation plan (smallest verifiable step first), with test checkpoints

1) Shared schema extension (smallest/isolated)
- Add in `Config.Techniques`:
  - `auraType`, `projectileSpeed`, `landingRadius`, and enforcer swiftstep fields (`swiftstepDistance`, `swiftstepWindow`, `swiftstepRecovery`). No `armingMin` field -- rejected in (a), round 5.
- Add shared falloff constants (not per-technique) for `Combat.rangeFalloff`: floor `0.45`, smoothstep shape.
- Add/adjust `Config.Paths` placeholder schema.
- Tests:
  - every technique has `windup`, `kind`, `auraType` and required combat-sequencing fields.

2) Pure resolver helpers in shared combat layer
- In `src/shared/Combat.luau`, add deterministic helpers:
  - `projectedFlightTime(config, techId, range)`
  - `projectileDodgeThreshold(config, techId, nodeRegion)` -- computes `d_cross`, now read as the full-damage crossover rather than an arming floor.
  - `resolveAffinity(config, techId, nodeRegion)`
  - `rangeFalloff(config, techId, distance)` -- pure, config-parameterized, zero requires, per the round-5 ruling in (a)/(c). Returns `1.0` when `distance` is `nil`, so every pre-existing call to `Combat.outgoingDamage` (which never supplies one) is unaffected.
- Tests (round 5, falloff-specific; in addition to the existing numeric-bounds/fallback tests):
  - `rangeFalloff` returns exactly `1.0` at and beyond `d_cross`.
  - `rangeFalloff` is monotonic non-decreasing as distance increases.
  - `rangeFalloff` never drops below the `0.45` floor at any distance, including `0`.
  - `rangeFalloff` with no distance context returns `1.0`.
  - the existing 18%-TTK and constant-cross-bracket assertions still pass unchanged after `rangeFalloff` is added (they must, since `Combat.outgoingDamage` never calls it -- see (g)).

3) Server striker timing migration (must remain server-authoritative)
- In `CombatService.resolveStriker`, replace instant hit-check raycast logic with fixed-point scheduled impact resolution.
- Apply `Combat.rangeFalloff` at resolve time, as a multiplier on the result of `Combat.outgoingDamage` -- outside that function, never inside it, the same discipline the affinity model already follows (see (c), (g)).
- Keep server authority and collision permission checks.
- `tests/combat.test.luau` has no direct delayed-flight assertions:
  - it currently checks windup ordering and bracket/range scaling assertions.
  - existing assertions touching timing are:
    - `lance`/`volley`/`pierce` windup order among striker (`pool[i].windup > pool[i - 1].windup`),
    - `striker > ruler > forger` range ordering.
- Add new assertion tests:
  - miss if target leaves fixed landing point before impact.
  - a striker fired at contact range lands for `0.45x` the damage of the same cast at `d_cross` or beyond, all else equal.

4) Cast telegraph extension
- Emit a server-scope cast event at use-success time.
- In `Vfx`, support non-local charge telegraph on that cast event.
- Keep local `Vfx.charge` as fallback and anti-refusal UI signal.

5) Enforcer meaning pass
- Move enforcers to deliberate defense as defined above:
  - `swiftstep` commitment values,
  - `surge`/`bulwark` defensive-only.
- Add tests:
  - enforcers still one slot each, still only one slot kind each.

6) Aura model integration
- Hook affinity fields into node-local behavior only (timing/shape, not base `outgoingDamage`), including the match/counter `d_cross` shift from (c), which feeds `Combat.rangeFalloff` and stays outside `Combat.outgoingDamage` exactly like the rest of affinity.
- Ensure no region multiplier gets applied to non-ruler damage in `Combat.outgoingDamage`.
- Tests:
  - `lance` still ignores open/wellspring terrain damage scaling.
  - `siphon` still scales as ruler.
  - a matched node aura shrinks a striker's `d_cross` by 4 studs and a countered one grows it by 6, and neither changes the value `Combat.outgoingDamage` returns for that cast.

7) Node effects and contest bonuses
- Apply node occupancy and contest formula from section d in resolve path.
- Add tests:
  - non-occupant and `open` users receive no node-local bonus.
  - contested bonus derives from `occupantCount` and `isContested(node, factionOf)` (or its equivalent), not hard-coded magic number.

8) Path seam
- Add path filter/validation in shared and server loadout assignment.
- Keep techniques unchanged.
- Test with path containing illegal IDs and slot-kind mismatch.

9) Two-client PvP gate (highest confidence check, must happen before final retune)
- Run 2 clients with:
  1) read clarity,
  2) cast telegraph visibility,
  3) defended movement in close range,
  4) duel timing 20-40 seconds at Lowgold,
  5) no untelegraphed surprise deaths.

Confidence note:
- Unverified in live two-client combat remains the largest blocker and is expected to force numerical retune, not structural rewrite.

## i) First-pass tuning numbers -- asserted, not derived

Every number in this table was chosen by this spec to hit a stated intent (e.g. "beat one close lance-speed dodge gap," or "visibly the wrong tool at contact range but not disabled"), or as a plausible first value -- none of them fall out of a formula the way `d_cross` or the 18% TTK ratio do. They are first-pass targets pending the two-client PvP gate in (h)/9, not verified balance. Anyone reading this doc later should not treat a number below as load-bearing until it has been played.

For contrast, `v = 16 studs/sec` (Roblox's default walk speed) and the `0.25s` human-reaction / `0.08-0.15s` net-delay figures in (a) are *not* in this table: they are external inputs this spec takes as given, not values it chose.

| Number | Value | Where |
|---|---|---|
| lance windup | 0.28s (from 0.15) | (b) |
| lance projectileSpeed | 190 studs/sec | (a), (b) |
| lance landingRadius | 2.4 studs | (a), (b) |
| volley windup | 0.50s (from 0.35) | (b) |
| volley projectileSpeed | 165 studs/sec | (a), (b) |
| volley landingRadius | 2.8 studs | (a), (b) |
| volley dart count | 4 darts | (b) |
| pierce projectileSpeed | 145 studs/sec | (a), (b) |
| pierce landingRadius | 3.4 studs | (a), (b) |
| striker range-falloff floor (contact, `d = 0`) | 0.45x damage | (a) |
| striker range-falloff shape | smoothstep between contact and `d_cross` | (a) |
| surge damageBuff | 0.00 (from 0.35) | (b) |
| surge mitigation | 0.25 (from 0.00) | (b) |
| bulwark mitigation | 0.50 (from 0.40) | (b) |
| swiftstep damageBuff | 0.00 (from 0.15) | (b) |
| swiftstep mitigation | 0.18 (from 0.10) | (b) |
| swiftstepDistance | 5.0 studs | (b), (e) |
| swiftstepWindow | 0.95s | (b), (e) |
| swiftstepRecovery | 1.2s | (b), (e) |
| affinity match: striker landingRadius | +1.4 studs | (c) |
| affinity match: striker `d_cross` shift | -4 studs | (c) |
| affinity match: forger construct radius | +25% | (c) |
| affinity match: forger construct duration | +20% | (c) |
| affinity match: enforcer buff duration | +20% | (c) |
| affinity counter: striker landingRadius | -0.8 studs | (c) |
| affinity counter: striker `d_cross` shift | +6 studs | (c) |
| affinity counter: forger construct radius | -15% | (c) |
| affinity counter: forger construct pulse window | -1 pulse | (c) |
| affinity counter: enforcer buff duration | -20% | (c) |
| densityFactor | `1 + 0.10 * densityIndex` | (d) |

Everything else in this spec that looks like a number -- `d_cross`, the flight-time table, the dodge-distance table, the 18% TTK ratio, `regen 6%/s`, and every unmodified `Config.Techniques` field carried forward as "unchanged" -- is either already live in the codebase (verified against `src/shared/Config.luau` and `tests/combat.test.luau`) or is derived in this doc from numbers that are. Only the table above is new and asserted.
