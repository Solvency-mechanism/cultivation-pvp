# COMBAT VISION

Date: 2026-09-10
Scope: `starter-game` combat loop as currently implemented in:
`src/shared/Config.luau`, `src/shared/Combat.luau`, `src/shared/ImpactSpec.luau`, `src/server/CombatService.luau`, `src/client/init.client.luau`, `src/client/Vfx.luau`, `src/client/Impact.luau`.
Round 6 (movement techniques and aura farming, see (d)) also touches `src/shared/Progression.luau`, `src/shared/AuraNodes.luau`, `src/server/CultivationService.luau`, `src/server/PersistenceService.luau`, and `src/server/NodeService.luau`.

Constraints locked by user:
1) No universal defense system (no dodge button, no block, no parry, no i-frames, no universal forced-movement defense). A slot-costing, madra-costing, cooldown-gated, opponent-visible movement commitment -- e.g. Swiftstep, defined in (d) -- is exactly the kind of deliberate defense the design calls for; what is disallowed is any defensive movement that is free, unlimited, or not a committed choice.
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

So yes, with this fixed-point and travel-only reaction model, a bolt fired at short range cannot be *sprint*-dodged: the defender cannot cover their own hitbox width in the flight time available using ordinary movement. That fact does not change under the ruling below -- what changes is what the design does with it.

**Round 6 update:** ordinary movement still can't do it, but this is no longer the whole picture -- a defender holding a ready, aura-unlocked strider technique (round 6's new fifth kind) can sometimes cover the needed distance instantly instead of by walking, which is a different inequality with a different answer depending on range, latency, and which technique. That full rework, with the arithmetic, lives in (d); the walking-only analysis below still stands as the floor case (no committed defensive resource in hand).

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

**Round 6 update on why this holds:** the reasoning above leans on close range being undodgeable, stated as settled fact. It no longer is, unconditionally -- see (d). Falloff's real justification was never actually about dodgeability, though; restated honestly in (d), it survives this round untouched and, if anything, matters more now that strider-based defense is conditional and falloff is not.

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

- `anchor` (new, round 6) -- backfills the slot swiftstep leaves; low magnitude, longest uptime, the third posture completing surge/bulwark's spread rather than a damage option. Full writeup in (d): `mitigation` **0.15**, `buffDuration` **8.0**, `cooldown` **10.0**, `windup` **0.1**, `madraCost` **26**.

`swiftstep` no longer belongs to enforcer as of round 6 -- it migrates to the new `strider` kind, unchanged in its own numbers, with its full writeup in (d). Enforcer stays at exactly three, now `surge`/`bulwark`/`anchor`, and collapses cleanly into pure defensive posture the way ruling 1 asked for.

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

## c) Aura affinity model that fits the technique pool, not overrun the invariants

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

Aura assignment table (12 techniques, plus `anchor` added in round 6 -- see (d)):
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
- `anchor` => `ash` (round 6)

`lunge` and `windstride` (round 6, `strider` kind) are *not* in this table on purpose: their `auraType` gates loadout availability in (d), not combat affinity here -- neither has a mechanic the relation matrix below currently touches (no `landingRadius`, no `buffDuration`, no construct).

`swiftstep` is a real wrinkle the migration surfaces: it keeps its `auraType` (`ash`) below for farming-gate purposes, but the relation matrix's "Enforcer: buff duration +/-20%" line is keyed off `kind == "enforcer"`. Now that `swiftstep`'s kind is `strider`, that dispatch would silently stop applying to it, even though its trailing mitigation buff (`buffDuration`, `mitigation`) is mechanically identical to what the matrix already modulates for `surge`/`bulwark`/`anchor`. Recommended fix: key that line off *having* a `buffDuration`-bearing buff rather than off `kind == "enforcer"` specifically, so `swiftstep` keeps receiving it. Not implemented here -- flagged so it isn't lost when (i)/7 actually wires up affinity's buff-duration effect.

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

**Round 6 raises the stakes on this.** The aura-farming axis in (d) reuses this exact region-to-aura mapping, so an `open` node is now progression-dead for *two* subsystems, not one -- it contributes nothing to combat affinity and nothing to unlocking a strider technique. See (d) for what distribution this now argues for; it is a real change from the 40/20/20/20 below, not a small nudge.

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
- The `d_cross` shift introduced in this round is not an exception to that rule: it is a parameter of `Combat.rangeFalloff`, a separate pure function applied in `CombatService` at resolve time, never inside `Combat.outgoingDamage` (see (a) and (h)). `Combat.outgoingDamage(config, dummy, "lance", freshPower, "wellspring", 0)` calls neither affinity nor falloff, so `lanceWell == freshHit` is untouched by this ruling regardless of node aura or distance.

The spec is therefore intentionally constrained: affinity is the readable mechanic, not a covert power stat.

## d) Movement techniques and the aura-farming axis (round 6)

The human's directive: give aura farming a reason to matter outside a combat matchup by gating movement techniques behind it, spanning burst-versus-sustain genuinely rather than sampling it once, with several options that work as a default dodge. Three structural rulings came with it, held below rather than relitigated: movement is a fifth kind with its own slot (not an enforcer subcategory); movement techniques are sidegrades, never upgrades; aura farming is a new progression axis this doc has to spec, not wave at.

### Why a fifth kind

Putting movement in the enforcer slot would mean picking Bulwark leaves a player with no defensive movement at all -- that contradicts "a few to choose from that will function like a default dodge," which only means something if movement doesn't compete with posture for the same slot. It also fixes a wart already on record: Swiftstep was movement wearing mitigation as a disguise, the odd one out among three techniques that were otherwise pure defensive posture. Migrating it out lets enforcer collapse cleanly into posture, and gives the new kind its founding member for free.

### Naming: `strider`

`striker`/`enforcer`/`forger`/`ruler` is a deliberate register: one-word agent nouns in the `-er` pattern, naming a role rather than describing a mechanic. `strider` matches that pattern exactly and is a name, not a description -- unlike "movement" or "mobility," it doesn't commit to burst or sustain, which fits a kind meant to span both. The one caveat worth recording: it is one phoneme away from `striker`, an already-loaded word in this doc. In text they're unambiguous; said aloud in the heat of a callout they could be confused. Flagged, not fixed -- swap it for `vaulter` or `roamer` if that turns out to matter at the table, but `strider` is the better name on genre fit and register match, so it is what the rest of this doc uses.

`Config.Techniques.*.kind` gains `"strider"` as a fifth legal value alongside the existing four.

### Loadout, slot bar, and the combinatorics

- `Config.LoadoutSlots` becomes `{ "striker", "enforcer", "forger", "ruler", "strider" }`. The new kind is appended rather than inserted, so keys 1-4 keep meaning exactly what they already mean to a player with muscle memory; key 5 is the only new binding.
- `Config.DefaultLoadout` gains `strider = "swiftstep"` -- see below for why Swiftstep specifically has to be the one every fresh character starts with.
- `Config.Combat.ranges.strider = 0`, matching `enforcer`'s posture: these are self-targeted techniques, not something aimed at a range.
- The loadout space goes from `3^4 = 81` to `3^5 = 243`, as the human already worked out, because this draft keeps the pool at exactly three per kind (see the roster below) -- the existing `3^4 = 81` comment in `Config.luau` and the `eq("three options for {slot}", byKind[slot], 3)` assertion in `tests/combat.test.luau` both need to track the fifth kind once this ships.
- `src/client/init.client.luau`'s slot bar: `SLOT_W, SLOT_H, SLOT_GAP = 108, 76, 10` with `slotBarWidth = (SLOT_W * 4) + (SLOT_GAP * 3)` becomes five slots, `(SLOT_W * 5) + (SLOT_GAP * 4)` -- 580px instead of 468px at current sizing. The `for index = 1, 4 do` slot-widget loop becomes `for index = 1, 5 do`, and `SLOT_KEYS` gains `[Enum.KeyCode.Five] = Config.LoadoutSlots[5]`. Flagged, not resolved here: a 580px-wide fixed-offset bar is a bigger bite out of a phone-width screen than 468px was, and this doc has no phone-HUD budget on record to check it against -- playtest question.
- Every player already carries `Slot_<slot>` attributes (`CombatService.onPlayerAdded` loops `Config.LoadoutSlots` and sets one per slot); adding a fifth slot to that table is enough, no new plumbing.

### The roster

Three techniques, one aura each, reusing the same `auraType` field every technique already carries for the (c) affinity system -- not a new tag. That reuse is scoped deliberately: a strider technique's `auraType` gates whether it's a legal loadout choice at all (this section); it does **not** feed the (c) match/counter relation matrix, which stays scoped to striker/forger/enforcer exactly as it already is. Movement is not currently a combat-modulation surface.

**`swiftstep`** (`ash`, ungated) -- unchanged from round 5's numbers, kind changes from `enforcer` to `strider`:
- `windup` **0.05s**, `swiftstepWindow` **0.95s** (pre-move commitment), `swiftstepDistance` **5.0** studs, `swiftstepRecovery` **1.2s**, `cooldown` **7.0**, `madraCost` **22**, `mitigation` **0.18** for `buffDuration` **4.0s** after the pop, `damageBuff` **0**.
- Burst-to-sustain position: near the burst end, but a *telegraphed* burst -- the long `swiftstepWindow` is a real tell, not an instant.
- The one technique every character starts with, ungated by farming. See "Why Swiftstep stays ungated" below.
- Feel: a held breath, then a snap. You commit before you know if you'll need it.

**`lunge`** (`verdant`, gated) -- new:
- `windup` **0.06s**, `lungeDistance` **6.0** studs, `cooldown` **9.0**, `madraCost` **20**, `damage` **8** (on contact with anything occupying the swept path or landing point; see "On damage" below), `damageBuff` **0**, `mitigation` **0**, `buffDuration` **0**.
- Burst-to-sustain position: the extreme burst pole -- this is the human's "almost instantaneous flash… only a couple yards… a great juke but not very good for movement," built as spec'd. No commitment window, no trailing defense, a real cooldown so it can't be chained into ground-crossing.
- Feel: gone before the eye catches it. No warning given, none received back.

**`windstride`** (`lumen`, gated) -- new:
- `windup` **0.1s**, `moveSpeedBuff` **+0.40** (walk speed ×1.4, i.e. 16 -> 22.4 studs/sec) for `buffDuration` **6.0s**, `cooldown` **16.0**, `madraCost` **24**, `damage` **0**, `damageBuff` **0**, `mitigation` **0**.
- Burst-to-sustain position: the extreme sustain pole -- no instant displacement at all, just faster feet for six seconds. See "Sustain speed cannot solve the close-range dodge problem" below for why this is a deliberate, not an accidental, weakness in a fight.
- Feel: the ground opens up. Not useful in the two seconds a duel actually turns on, invaluable in the twenty it takes to get there, or away.

No dominance between the three (ruling 2, held explicitly): Swiftstep beats Lunge on cooldown frequency (7.0s vs 9.0s) and carries a trailing defensive buff Lunge lacks entirely; Lunge beats Swiftstep on stealth (no telegraph), reach (6.0 studs clears every current bolt's landing tolerance; Swiftstep's 5.0 does not -- see the arithmetic below), damage, and madra cost. Windstride is incomparable to both on the same axes -- it moves the *most total distance* of the three (22.4 studs/sec × 6s = 134.4 studs of bonus travel across its window, against Lunge's one-time 6 studs), and it is the only one of the three with zero standalone value in an active exchange. Each is a genuine tradeoff a player has reason to prefer situationally; none is strictly better.

**Why Swiftstep stays ungated.** All three techniques gated behind farming would leave a brand-new character with an empty strider slot -- `Combat.validateLoadout` requires exactly one technique per slot, and `CultivationService`'s starting state has farmed nothing. One technique has to be free. Swiftstep is the natural pick: it already existed, every player already had access to it (via the enforcer slot, pre-round-6), and "the founding member" language in the ruling that created this kind already treats it as the inherited default rather than something newly earned. This also gives the onboarding curve a shape that matches the rest of the game: one working option from minute one (matching `newPlayerState`, which starts players mid-ladder at Lowgold with a full striker/enforcer/forger/ruler kit already), growing to "a few to choose from" once a player has farmed even one more aura, and to all three once they've farmed both. The interesting choice -- which aura to farm first -- only exists because there's already something to compare it against.

### On damage: Lunge arrives violently, it does not fight

The human's own caveat: a damaging dash must never be efficient damage, or it quietly becomes a striker replacement with legs. The numbers have to make that literally true, not just gesture at it.

Compare Lunge's `8` damage against Lance, the technique explicitly designed as this game's baseline cheap-and-fast striker:

| | damage | madraCost | dmg/madra | cooldown+windup | dmg/sec-equivalent |
|---|---:|---:|---:|---:|---:|
| Lance | 42 | 18 | 2.33 | 1.48s | 28.4 |
| Lunge | 8 | 20 | 0.40 | 9.06s | 0.88 |

Lunge deals 17% of Lance's damage per madra spent and about 3% of Lance's damage-per-second if both were spammed on cooldown. Nobody picks the strider slot for that ratio; the damage exists so that dashing into someone's face reads as a hit rather than a teleport, not so that Lunge competes on a striker's own terms. That asymmetry is the whole point and should stay wide if this ever gets retuned -- closing the gap even to "10% as efficient as Lance" would start making Lunge a legitimate second striker, and the loadout math (3 strider options, each meant to be a sidegrade of the *other two striders*, not of the *striker kind*) does not want that.

### The dodge inequality changes -- reworking (a)

(a) proves a bolt is undodgeable below roughly 50 studs because a *walking* defender at 16 studs/sec cannot clear `landingRadius + 2` before flight time runs out. That proof assumed the defender's only tool was ordinary movement. It no longer is: a defender holding a ready, aura-unlocked, off-cooldown strider technique can cover `techDistance` studs effectively instantly (bounded by the technique's own commit time, not by flight time), at any range. Close range stops being a zone where the defender is helpless by construction and becomes one where they're helpless *unless* they have paid for, unlocked, and held in reserve a specific committed resource -- exactly the shape ruling 1 in the round-6 directive asked for.

The arithmetic, not an assurance. Define the defender's reactive budget once the required cast-telegraph-at-intent-time extension exists (still not built -- see (h)):

`techBudget(d) = windup_bolt + d / projectileSpeed_bolt - (0.25 + netDelay)`

That's the full time-to-impact (windup plus flight, per the flight-time table already in (a)) minus the reaction-and-perception overhead already established there. A strider technique with its own commit time `techCommit` (windup alone for Lunge; `windup + swiftstepWindow` for Swiftstep, since the pop only happens at the end of that window) reactively beats the bolt if and only if both hold:

- `techBudget(d) >= techCommit`
- `techDistance > landingRadius_bolt + 2`

Worked using `netDelay`'s stated range (`0.08s` best case, `0.15s` worst case):

| Defender tech (commit time) | vs `lance` (0.28w / 190spd, threshold 4.4) | vs `volley` (0.50w / 165spd, threshold 4.8) | vs `pierce` (0.90w / 145spd, threshold 5.4) |
|---|---|---|---|
| Lunge (0.06s, reach 6.0) | reacts from ~21 studs (best case) to ~34 studs (worst case) out; below that, no | reacts at **any range**, both bounds | reacts at **any range**, both bounds |
| Swiftstep (1.00s, reach 5.0) | **never** -- max budget at lance's own 140-stud range is 0.69s, still under 1.00s | only a thin sliver near volley's own 140-stud max, and only at best-case latency | budget crosses 1.00s from ~62 studs (best case) to ~73 studs (worst case) out -- **but its 5.0-stud pop falls short of pierce's 5.4-stud threshold**, so the distance check fails even where the timing check passes |

That last line is a correction, not a restatement: the previous draft of this doc justified Swiftstep with "beats one close lance-speed dodge gap (`5.0 > 4.4`)" -- a pure distance comparison that never checked whether Swiftstep's own 1.00s of commitment fits inside any striker's actual time-to-impact. It doesn't, against any of the three, at any range either of them can be fired from. Swiftstep, as currently tuned, **does not reactively beat any bolt in this kit.** That is not a reason to cut it -- see "Why Swiftstep stays ungated" above, and its trailing mitigation still matters as a hedge -- but its actual value is proactive positioning and residual defense, not "I saw the cast and I dodged it." A `swiftstepDistance` bump to roughly 5.5 studs would close the pierce gap specifically and give it one real reactive matchup; noted as a candidate tweak, not made here.

Lunge is the honest reactive answer, and even then only conditionally: it beats volley and pierce at any range their own generous windups make possible, but against lance -- this game's fastest, cheapest, most-pressed button -- there remains a genuine blind spot inside roughly 21-34 studs where not even the fastest possible response wins. That floor is real and this doc is not pretending otherwise. Lance stays the technique where facehugging is closest to a guaranteed hit even after this round.

### Sustain speed cannot solve the close-range dodge problem

Worth stating plainly, because it's the cleanest argument for why Windstride is allowed to be combat-useless: even a large, sustained speed multiplier doesn't touch the inequality above, because it's bounded by flight time, not by the defender's speed. Recomputing (a)'s flight-only dodge distance at Windstride's boosted `22.4` studs/sec instead of `16` for lance at 20 studs: `d_flight = 22.4 * 0.105 = 2.35` studs, still under the `4.4`-stud threshold. A 40% speed boost is a 40% improvement on a number that was already an order of magnitude short. Only an *instant* displacement sidesteps flight-time-boundedness; no amount of sustained speed does, which is exactly why Windstride is "not great for combat" by construction rather than by accident, and why it's allowed to have no cooldown-vs-magnitude cleverness hiding a dodge in it.

### Why falloff survives, and why its old justification didn't tell the whole truth

Round 5's range falloff is unchanged in shape -- floor `0.45` at contact, `1.0` at `d_cross`, smoothstep between. But (a)'s supporting argument leaned on "close range is undodgeable," and round 6 shows that was never the complete picture even before this round: it was only ever true against a defender with no answer, and now some defenders sometimes have one.

Restated honestly: falloff was never really about whether the target *can* escape. It's about whether firing a striker from point-blank is ever the *right tool*, independent of what the target does about it. A player with no strider slot filled, or an off-cooldown one, or the wrong aura farmed, is still just as unable to escape a close lance as they were in round 5 -- but even against a target who genuinely cannot move, falloff still makes that shot the wrong choice, because enforcer/forger/ruler simply do more in that space. Dodgeability was a convenient fact used to motivate the number, not the actual design target. The actual target is role separation by range, and round 6 leaves that untouched -- if anything it matters more now, because falloff is the one thing in this kit that discourages facehugging *unconditionally*, while strider-based defense is conditional on aura, cooldown, and loadout choice.

### This puts real pressure on the placeholder region distribution -- extending (c)

(c) already flags that `NodeService.placer`'s `{ "open", "open", "rich", "barren", "wellspring" }` table makes 40% of nodes affinity-inactive. Under this round those same nodes now also farm no aura at all -- an `open` node is progression-dead for two subsystems, not one. That may still be an acceptable cost (it gives players a reason to leave open ground for a reason beyond combat now, which strengthens rather than dilutes the point), but the cost doubled and the placer is still explicitly scaffolding, not a designed distribution.

What this subsystem actually wants, stated plainly: `open` at roughly 15% or less, with the remaining ~85% split close to evenly across `barren`/`rich`/`wellspring` (~28% each) so farming any one of the three auras is comparably available. That is a real change from the current 40/20/20/20 placeholder, not a small nudge -- and it is a recommendation for whoever designs the real map anchors, not a code change made here.

### Presentation is a problem here too

`ImpactSpec.Cast.byKind` currently has four entries (`striker`/`enforcer`/`forger`/`ruler`); it needs a fifth, `strider`, or a strider cast falls silent by construction (`ImpactSpec.castSound` returns `""` for an unmapped kind, and `Impact.cast` correctly treats that as "play nothing" -- safe default, wrong outcome here). `Vfx`'s `PALETTE` table needs `lunge` and `windstride` entries; `swiftstep`'s existing one carries over since only its `kind` moved.

The deeper issue: even once the pending cast-telegraph-at-intent-time extension ships (still required, still not built -- (a) and (h) both already flag this), it helps unevenly here. Swiftstep's `swiftstepWindow` is a genuine 0.95s telegraph an opponent could learn to read once cast events broadcast at intent time. Lunge's `0.06s` windup is close enough to zero that a cast-time broadcast and its resolution would land in almost the same frame -- there is no meaningful "opponent sees the Lunge coming" moment to build, network fix or not. That may be fine: unlike a bolt, the opponent doesn't need to counter the cast itself, only react to where the caster ends up, and Lunge is a repositioning tool, not an attack aimed at them. But it does mean Lunge's *arrival* needs a clear, fast visual beat of its own -- a bright, brief snap using the existing muzzle/ring vocabulary at a smaller scale and shorter duration than a striker impact, not a new channel -- so a Lunge into someone's face reads as a hit landing rather than as rubber-banding or a desync.

Worth naming directly: Lunge is not an i-frame. There is no window where the caster is present and untargetable -- the server resolves a position change, same as any other technique resolution, with no invulnerability attached. Anything else that can hit the caster during or after a Lunge still can.

### Enforcer's third slot: `anchor`

Ruling 1's consequence: enforcer needs a third member to stay at three, and it has to be posture, not a damage option. `surge` is medium magnitude / medium window, `bulwark` is high magnitude / short window with a long cooldown; `anchor` completes the triangle as low magnitude / long window:

- `id` `anchor`, `kind` `enforcer`, `auraType` `ash` (chosen to keep the aura distribution close to even once swiftstep's kind changes -- see (j)).
- `windup` **0.1**, `cooldown` **10.0**, `buffDuration` **8.0**, `mitigation` **0.15**, `madraCost` **26**, `damage`/`damageBuff` **0**.
- `buffDuration / cooldown = 0.80` -- the highest uptime fraction of the three enforcers (surge 0.556, bulwark 0.545), paired with the lowest single-hit magnitude (0.15 vs 0.25 and 0.50). No dominance: bulwark still answers one big spike better than anything Anchor offers, surge sits in between on both axes.
- Pick it when: you expect a long grinding exchange rather than one spike, and you'd rather have *some* mitigation active almost all the time than a lot of it some of the time.

### The aura-farming axis

Nothing in the game currently accumulates aura; nodes carry a region, and cycling accrues refinement. This section is the missing half.

**Where it lives.** `Progression.State` gains `auraProgress: { ash: number, verdant: number, lumen: number }` (three counters; `open`/`neutral` stays non-farmable, matching its affinity-inactive status everywhere else in this doc). `Progression.newState()` initializes it to all zeros.

**Accrual.** `CultivationService.tick` already computes `region` once per player per tick, in the same loop that calls `Progression.addProgress` -- the same value already feeds refinement cycling. This reuses it: map `region` to an aura with the exact table already defined in (c) (`barren -> ash`, `rich -> verdant`, `wellspring -> lumen`, `open -> inactive`), and when the mapped aura is farmable, add progress via a new pure function, `Progression.addAuraProgress(config, state, aura, amount)`, mirroring `addProgress`'s shape but touching a distinct field and never rolling into `stageIndex`/`tier`.

Deliberately **not** multiplied by `Config.StaticRegionMultipliers` (`barren 0.5`, `open 1.0`, `rich 1.8`, `wellspring 2.6`). That multiplier was tuned to make richer ground worth more *refinement* -- reusing it here would make farming `ash` (barren, `0.5x`) intrinsically half as fast as farming `lumen` (wellspring, `2.6x`), a five-fold spread that has nothing to do with which aura a player is actually trying to unlock. Reused instead: `Config.NodeTiers.*.cycleMultiplier` (`common 3`, `rare 8`, `prime 20`), the same tier scaling refinement already uses, since rewarding a rarer node is a shape worth keeping; a new `Config.AuraFarming.baseRate = 1.0` gives effective rates of `3.0`/`8.0`/`20.0` progress per second at common/rare/prime. Sharing occupancy doesn't divide this any more than it divides refinement cycling -- `AuraNodes` gates who can *join* a node, never how fast an already-joined occupant earns.

**Threshold.** `Config.AuraFarming.unlockThreshold = 600`, one shared value for both gated techniques (first-pass simplification; nothing yet demands per-technique numbers). That's `200s` (~3.3 min) of continuous occupancy at a common node, `75s` at rare, `30s` at prime -- reachable inside a single node's own lifetime (`600s`/`420s`/`300s`) even without exclusive occupancy.

**Spent or merely reached: reached, permanently.** This follows from ruling 2 directly. A sidegrade has to remain a standing choice in the loadout screen, which means once unlocked it has to *stay* unlocked -- a spend-to-use model would turn "different options" back into "one option you paid for," which contradicts what "farming unlocks a technique" means in the human's own framing. Once `auraProgress.verdant >= 600`, `lunge` is a legal `strider` selection for that character forever, independent of what they farm afterward.

**Not touched by death.** `Progression.applyLoss`/`Combat.deathLoss` drain refinement on death -- a combat-performance ratchet. Aura farming measures breadth of exploration, not combat performance, and draining it on death would punish exactly the wrong thing: a player experimenting with a new region would be pushed straight back to the aura they already know. `applyLoss` must not touch `auraProgress`; recorded here as a rule, not an oversight.

**Persistence.** `PersistenceService.save` adds `auraProgress = state.auraProgress` next to `stageIndex`/`tier`/`progress`/`catalysts`. `Progression.sanitizeState` needs the same defensive treatment it already gives every other field: for each of `ash`/`verdant`/`lumen`, `tonumber` the stored value, reject it on a failed `NaN` self-equality check (`n == n`, the existing pattern), clamp to `>= 0`, default to `0` if missing. A save written before this system existed has no `auraProgress` table at all -- `type(raw.auraProgress) ~= "table"` catches that case and the whole block falls through to zeros, exactly the way a pre-existing save already falls through on `catalysts` today. No store migration, no `Config.Persistence.storeName` bump: an old save just loads as a returning player who hasn't farmed anything yet.

**The upside, stated plainly.** This is the first thing in the whole spec that gives the four aura types a reason to exist outside a combat matchup, and the first thing that gives a player a reason to specifically seek out a `barren`/`rich`/`wellspring` node rather than any node with a free slot. It turns the region map from "flavor on top of a shared cycling rate" into something with its own pull, which is exactly the kind of pressure the node economy was missing -- it strengthens that economy rather than sitting beside it, which is also why the region-distribution pressure noted above is worth taking seriously rather than shrugging off.

## e) Node-local combat effects + capacity/contest interaction

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

## f) Enforcer and strider are the only deliberate defenses

Hard rule, updated for round 6: deliberate, committed defense lives in exactly two slots now, enforcer and strider. No extra universal dodge button, no global stamina layer, no universal block or guard anywhere else. This is a change from round 5's "only the enforcer slot" framing -- ruling 1 put movement-flavored defense in its own kind specifically so it wouldn't have to compete with pure posture for one slot, and constraint 1 at the top of this doc already generalized to "a slot-costing, madra-costing, cooldown-gated, opponent-visible movement commitment," not to enforcer specifically.

Enforcer, three techniques, all pure posture, no movement:
- `surge`: mitigation-gated sustain.
- `bulwark`: max-mitigation burst.
- `anchor` (round 6): low magnitude, longest uptime -- see (b) and (d).

Strider, three techniques, full writeup and the reactive-dodge arithmetic in (d):
- `swiftstep`: telegraphed commitment dash with a trailing mitigation buff -- the closest thing to defense-flavored movement, though (d) shows it does not currently win a pure reaction race against any striker in the kit; its value is proactive positioning plus the residual buff, not a clean escape.
- `lunge`: near-instant repositioning with token arrival damage -- the actual reactive answer to a bolt already fired, where aura-unlocked and off cooldown.
- `windstride`: sustained speed, not defense-flavored at all -- useful between exchanges, not inside one.

## g) Path seam for future implementation (no rewrite)

Current base requirement says techniques are currently shared and should not be rewritten.
Path model should be a constrained view, not a replacement:
- Add `Config.Paths` with path->allowed technique IDs per slot.
- Add a pure shared selector helper that filters the shared pool to one allowed subset per path.
- Keep every shared technique in place.
- `CombatService` loadout assignment uses selected path list then validates kind and slot.
- This preserves a drop-in switch once paths unlock.

## h) Conflict map with hard constraints and invariants

Known collision points:
- `src/shared` purity:
  - no new `require` among shared modules.
  - round 6 adds `Progression.addAuraProgress` and extends `Progression.sanitizeState`; both stay pure, Config passed as a parameter, same as every existing function in that module.
- Balance invariants:
  - `tests/combat.test.luau` asserts:
    - intra-bracket TTK advantage exactly 18%
    - TTK constant Lowgold vs Highgold
    - TTK constant Lowgold vs Truegold
    - striker ignores terrain while ruler scales with region.
  - Base damage for non-ruler techniques must remain unchanged unless assertions are updated.
  - Range falloff (round 5 ruling, see (a)) must not touch these. It is kept out of `Combat.outgoingDamage` entirely and applied only in `CombatService` at resolve time, so none of the four assertions above ever exercise it -- `tests/combat.test.luau` calls `Combat.outgoingDamage` directly and never supplies a distance.
  - Falloff is also symmetric across refinement tiers even where it *is* eventually applied, so it cannot widen the intra-bracket spread on its own: `hitsFreshToKillMaxed / hitsMaxedToKillFresh` in the 18% test reduces to `maxedHit / freshHit` (the `hp /` on both sides cancels). If a caller later multiplied both `freshHit` and `maxedHit` by the *same* `falloff(distance)` -- which is all falloff can be, since it is a function of distance only, never of power -- that factor cancels out of the ratio identically: `(maxedHit*f) / (freshHit*f) = maxedHit/freshHit`. The 18% ratio is unaffected at any fixed distance. Verified against the actual assertion at `tests/combat.test.luau:47-65`, not assumed.
  - `lunge`'s damage (round 6, see (d)) is not an exception either: it scales by `power / referencePower` exactly like every other technique's `outgoingDamage` call, which is what makes the invariant technique-agnostic in the first place. Nothing about a fifth kind changes that.
- Terrain scale scope:
  - only ruler currently has `regionScaled=true`; keep it that way for damage.
- Presentation:
  - no new severity channel; use existing ImpactSpec contract.
  - round 6 needs a fifth `ImpactSpec.Cast.byKind` entry (`strider`) and two new `Vfx.PALETTE` rows (`lunge`, `windstride`) -- data additions to an existing table, not a new channel.
- PvP feedback:
  - opponent cast telegraph is not visible from code today; adding a cast event at intent time is required. Round 6 raises the stakes on this same gap and adds a second one on top: even once that extension exists, `lunge`'s `0.06s` windup is close enough to zero that a cast broadcast and its resolution land almost the same frame, so the fix helps `swiftstep` a great deal and `lunge` barely at all. See (d) for why that's judged acceptable (the opponent needs to react to where the caster lands, not to the cast itself) and what it still requires (a fast, legible arrival effect).
- Movement server authority (round 6, see (d)):
  - a strider displacement (`swiftstep`, `lunge`) has to be validated the same way a striker raycast already is -- swept against world geometry before the character is repositioned, so a dash can't be used to clip through a wall. `windstride`'s `WalkSpeed` change is server-set and client-visible by ordinary replication, no new remote needed; the client still only ever sends slot + aim, same as every other technique.

Potential hidden risk:
- If fixed-point vs tracking is reversed, dodgeability as designed collapses.
- If contest is damped rather than amplified, close-node fights lose intended readability.
- If a strider technique's own commit time (`windup`, or `windup + swiftstepWindow`) is ever shortened without redoing the arithmetic in (d), the reactive-dodge table there goes stale silently -- it is derived from specific numbers, not a rule the code enforces.

## i) Ordered implementation plan (smallest verifiable step first), with test checkpoints

1) Shared schema extension (smallest/isolated)
- Add in `Config.Techniques`:
  - `auraType`, `projectileSpeed`, `landingRadius`, and swiftstep fields (`swiftstepDistance`, `swiftstepWindow`, `swiftstepRecovery`). No `armingMin` field -- rejected in (a), round 5.
  - round 6: `"strider"` as a fifth legal `kind`; `lungeDistance`; `moveSpeedBuff` (shared shape with `damageBuff`/`mitigation`, only `windstride` sets it non-zero for now).
- Add shared falloff constants (not per-technique) for `Combat.rangeFalloff`: floor `0.45`, smoothstep shape.
- Add/adjust `Config.Paths` placeholder schema.
- Round 6: `Config.LoadoutSlots` gains `"strider"`; `Config.DefaultLoadout` gains `strider = "swiftstep"`; `Config.Combat.ranges.strider = 0`; new `Config.AuraFarming = { baseRate = 1.0, unlockThreshold = 600 }`.
- Tests:
  - every technique has `windup`, `kind`, `auraType` and required combat-sequencing fields.
  - round 6: `byKind[slot] == 3` holds for all five slots including `strider` (extends the existing per-kind-count assertion rather than replacing it).
  - round 6: `ranges.strider == 0`, extending the existing `enforcer is self only` assertion the same way.

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
  - the existing 18%-TTK and constant-cross-bracket assertions still pass unchanged after `rangeFalloff` is added (they must, since `Combat.outgoingDamage` never calls it -- see (h)).

3) Server striker timing migration (must remain server-authoritative)
- In `CombatService.resolveStriker`, replace instant hit-check raycast logic with fixed-point scheduled impact resolution.
- Apply `Combat.rangeFalloff` at resolve time, as a multiplier on the result of `Combat.outgoingDamage` -- outside that function, never inside it, the same discipline the affinity model already follows (see (c), (h)).
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
  - `surge`/`bulwark`/`anchor` (round 6) all defensive-only, no movement, no damage.
- Add tests:
  - enforcers still one slot each, still only one slot kind each.

6) Movement kind and the aura-farming axis (round 6) -- see (d) for the full spec
- Migrate `swiftstep` from `enforcer` to `strider` in `Config.Techniques` (kind change only; its own numbers are untouched).
- Add `lunge` and `windstride` to the pool.
- In `CombatService.resolveEffect`, add a `kind == "strider"` branch: for `swiftstep`/`lunge`, validate and apply a server-side displacement (swept against world geometry, same collision discipline as the striker raycast); for `lunge`, also check the swept path for a struck player and apply its (small) damage through the existing `damagePlayer` path; for `windstride`, apply a `moveSpeedBuff` through the existing buff mechanism (`Combat.use` already handles arbitrary buff fields) and mirror it onto `Humanoid.WalkSpeed` the way `mirrorHumanoid` already mirrors `Health`.
- Add `Combat.moveSpeedBuffOf(actor, now)`, mirroring `Combat.damageBuffOf`'s shape, for the one new buff dimension.
- Add `Progression.addAuraProgress(config, state, aura, amount)` and extend `Progression.sanitizeState` to read/clamp/default `auraProgress` (see (d) for the exact defensive rules -- same posture as every other field it already sanitizes).
- Hook the accrual into `CultivationService.tick`'s existing per-tick region lookup (same loop that already calls `Progression.addProgress`).
- Extend `PersistenceService.save`'s record with `auraProgress`.
- Extend `src/client/init.client.luau`'s slot bar and `SLOT_KEYS` to five slots (see (d) for the exact width/key changes).
- Add `ImpactSpec.Cast.byKind.strider` and `Vfx.PALETTE` entries for `lunge`/`windstride`.
- Tests:
  - `rangeFalloff`-style purity tests for `Combat.moveSpeedBuffOf`: sums active `moveSpeedBuff` sources, prunes expired ones, matches `damageBuffOf`'s existing test shape.
  - `Progression.addAuraProgress` never decreases a counter, and never touches `stageIndex`/`tier`/`progress`.
  - `Progression.sanitizeState` on a raw table with no `auraProgress` key returns all-zero counters (the "save written before this existed" case).
  - `Progression.sanitizeState` rejects a `NaN` or negative stored counter the same way it already rejects one for `catalysts`.
  - `Progression.applyLoss` leaves `auraProgress` untouched (death does not drain farming progress).
  - `Combat.validateLoadout` accepts a loadout with a `strider` slot and rejects one missing it, extending the existing per-slot validation tests.
  - a fresh `Progression.newState()` can legally fill `strider` with `swiftstep` and nothing else (the ungated-default requirement from (d)).

7) Aura model integration
- Hook affinity fields into node-local behavior only (timing/shape, not base `outgoingDamage`), including the match/counter `d_cross` shift from (c), which feeds `Combat.rangeFalloff` and stays outside `Combat.outgoingDamage` exactly like the rest of affinity.
- Ensure no region multiplier gets applied to non-ruler damage in `Combat.outgoingDamage`.
- Tests:
  - `lance` still ignores open/wellspring terrain damage scaling.
  - `siphon` still scales as ruler.
  - a matched node aura shrinks a striker's `d_cross` by 4 studs and a countered one grows it by 6, and neither changes the value `Combat.outgoingDamage` returns for that cast.

8) Node effects and contest bonuses
- Apply node occupancy and contest formula from section e in resolve path.
- Add tests:
  - non-occupant and `open` users receive no node-local bonus.
  - contested bonus derives from `occupantCount` and `isContested(node, factionOf)` (or its equivalent), not hard-coded magic number.

9) Path seam
- Add path filter/validation in shared and server loadout assignment.
- Keep techniques unchanged.
- Test with path containing illegal IDs and slot-kind mismatch.

10) Two-client PvP gate (highest confidence check, must happen before final retune)
- Run 2 clients with:
  1) read clarity,
  2) cast telegraph visibility,
  3) defended movement in close range,
  4) duel timing 20-40 seconds at Lowgold,
  5) no untelegraphed surprise deaths,
  6) round 6: does `lunge` read as a hit-and-reposition rather than a teleport or a desync; does a fresh character's single `swiftstep` option feel adequate before any farming; does farming an aura toward `600` feel like a destination or a chore at the placeholder rate in (d).

Confidence note:
- Unverified in live two-client combat remains the largest blocker and is expected to force numerical retune, not structural rewrite.

## j) First-pass tuning numbers -- asserted, not derived

Every number in this table was chosen by this spec to hit a stated intent (e.g. "beat one close lance-speed dodge gap," or "visibly the wrong tool at contact range but not disabled"), or as a plausible first value -- none of them fall out of a formula the way `d_cross` or the 18% TTK ratio do. They are first-pass targets pending the two-client PvP gate in (i)/10, not verified balance. Anyone reading this doc later should not treat a number below as load-bearing until it has been played.

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
| swiftstepDistance | 5.0 studs | (d) |
| swiftstepWindow | 0.95s | (d) |
| swiftstepRecovery | 1.2s | (d) |
| swiftstep mitigation | 0.18 | (d) |
| anchor mitigation | 0.15 | (b), (d) |
| anchor buffDuration | 8.0s | (b), (d) |
| anchor cooldown | 10.0s | (b), (d) |
| anchor windup | 0.1s | (b), (d) |
| anchor madraCost | 26 | (b), (d) |
| lunge windup | 0.06s | (d) |
| lungeDistance | 6.0 studs | (d) |
| lunge cooldown | 9.0s | (d) |
| lunge madraCost | 20 | (d) |
| lunge damage | 8 | (d) |
| windstride windup | 0.1s | (d) |
| windstride moveSpeedBuff | +0.40 (16 -> 22.4 studs/sec) | (d) |
| windstride buffDuration | 6.0s | (d) |
| windstride cooldown | 16.0s | (d) |
| windstride madraCost | 24 | (d) |
| AuraFarming.baseRate | 1.0 progress/sec at common tier | (d) |
| AuraFarming.unlockThreshold | 600 progress (shared by `lunge`, `windstride`) | (d) |
| recommended region distribution (open / colored) | open <=15%, ~28% each of barren/rich/wellspring | (c), (d) |
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
| densityFactor | `1 + 0.10 * densityIndex` | (e) |

Everything else in this spec that looks like a number -- `d_cross`, the flight-time table, the dodge-distance table, the 18% TTK ratio, `regen 6%/s`, and every unmodified `Config.Techniques` field carried forward as "unchanged" -- is either already live in the codebase (verified against `src/shared/Config.luau` and `tests/combat.test.luau`) or is derived in this doc from numbers that are. Only the table above is new and asserted.
