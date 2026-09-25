# Changelog

All names in this project are placeholders, including the title.

Versions are dated and describe what was **observed working**, not what was
written. Anything unverified is listed as unverified.

## dice-and-scales — 2026-09-25 (branch `feat/dice-scales`)

**Written and gated, not yet played.** Nothing below has been observed on a
live client; the first Studio session should amend this entry.

### What was added

- **A basic d6 on every cultivator.** `R` rolls; the server picks the face
  (`Random`), enforces the cooldown on its own clock and pays
  `face × scalesPerPip` scales. The client sends one word and can name no
  face, amount or time. Rolling is allowed at the refinement ceiling —
  scales are currency first, so a player waiting on a catalyst still banks.
- **Scales (forged mana)**, a new persisted field on `Progression.State`:
  in `newState`, `clone`, `toStore` and `sanitizeState`, so the closed-set
  check in `tests/wiring.test` covers it. A pre-dice save loads with zero.
  A death does not touch scales; `applyLoss` costs refinement, not the purse.
- **`C` refines** one batch (10) into `10 × 1.5` progress through
  `addProgress`, so rollover and the ceiling clamp are the same rule as
  cycling. Refuses at the ceiling and when short, with a sentence either way.
- **A HUD chip**, its own script (`DiceClient`) to keep `init.client` under
  the 200-local cap: die face with a tumble that lands on the server's roll,
  scale count, cooldown countdown. Bottom-left on desktop, upper-right on
  touch (thumbstick and jump own the bottom corners); the die is the tap
  target for rolling.
- `tests/dice.test`: fairness over 60,000 rolls, payout, cooldown, refine
  refusals, tier rollover, death, save round-trip and corrupt saves. Release
  pacing (~0.9 progress/s, below a common node) is asserted only under the
  release profile; development drops the cooldown to 1.5s for throughput.

### Unverified

- The chip's placement against the real HUD on desktop and phone.
- Whether `R`/`C` collide with anything a player has bound.
- Whether a 6s roll feels like a rhythm or a chore — the first pacing
  question this system has, and the one only a person can answer.

## bracket-and-npc build — 2026-09-12, early (deploy HEAD: the commit carrying this entry, on `13b1e2a`)

Built for two friends at different stages to be able to fight at all. Still
`Config.Profile = "development"`. **Not for players** beyond the playtest.

### Observed by the human on a live client (first gameplay feedback this project has had)

- **Neutral NPCs.** Three named patrols exist at boot with no command — Grove
  Walker on the Reach, Ash Sentinel on the Barrens rim, Pool Warden circling
  the Wellspring. *"They shoot back and they are properly neutral, not
  hostile"*: they do not react to a player walking into them and they fire
  back once hit. Excluded from kill banners and the leaderboard.
- **They teleported.** The server moved them continuously; an anchored part's
  rewritten CFrame replicates without client interpolation, so the human saw
  steps where every server-side check saw a glide. Fixed by driving the root
  through physics (`AlignPosition`/`AlignOrientation`), which also makes them
  face where they walk (`2ab6b86`). *Not yet seen by the human at the time of
  writing — they confirm it on the fresh session before publishing; if this
  line is not amended, they had not.*
- **"Slowly."** Patrol speed 6 on all routes, the human's number.
- **Frostbolt on a real client** — see the amended entry above.

### In the build; the human saw some of it

- **Cross-bracket combat, opened for testing with a notice instead of a
  refusal** — *and the human confirmed both lines on dummies: "punching down and
  punching up warnings working properly."* Then asked for it quieter; it is. `Config.Combat.crossBracket` is `"notice"` in development and
  `"refuse"` in release; the bracket design is unchanged where it ships. A hit
  across brackets now lands and says so — *"You are punching up. They have more
  health and hit harder — this is not a fair fight. (Placeholder copy.)"* and
  its counterpart — once per opponent. Before this, twenty-one of twenty-six
  techniques failed a cross-bracket hit **silently**; only the lock path had a
  message. The human's own cross-bracket Frostbolt landed under this flag.
- **The target frame lied under it** — it kept the "different bracket" refusal
  line from when out-of-bracket meant refused. The human noticed: *"likely
  stale helper text."* Fixed (`13b1e2a`): one reader for the line, the reticle,
  the reach pip and the sweep; an NPC target gets no bracket line at all.
- **The first PvE kill was silent.** No bracket line (NPCs have no bracket) and
  no kill banner (NPCs are excluded) composed into nothing at all. An NPC's
  death now acknowledges itself in its own register (`214d6c5`, `13b1e2a`):
  a neutral-toned line, never the PvP banner. The plate reads
  *NEUTRAL — will not start it.*
- **Four family techniques**, data-only on server paths that already work:
  ash `scorch` and `wildfire`, verdant `thornlash` and `ironroot`. Every
  technique now carries `unlockRequirement = { kind = "always" }` — the gating
  contract, unread by anything yet.

### Not in this build, on purpose

The eight lock/effect techniques of the three families (they wait on a
status-effect ticker; a lock never lands before the thing that makes it real).
The remnant drop. The field-saturation retune. **The player-frame /
target-frame pair** the human asked for from first principles — *"two separate
panels but they are really the same panel modified based on the current
target"* — is the register this HUD was briefed on and never landed; it is an
hour-plus of relayout and rides the next deploy rather than going in unseen.

### Found and fixed on the way

- **A finished server module landed unwired — the second time.** `NpcService`
  was complete and never required by `init.server`; no NPC could exist. Wired,
  and `tests/wiring.test` now fails on any server module with a `start` that
  `init.server` never wires.
- **The Studio play-server log file does not capture runtime Lua output.**
  Established when eight minutes of `[field]` logging produced nothing while a
  rare node was visibly in the world. Boot-time output is trustworthy; every
  after-boot warn in the codebase never reached a file. Recorded as a property
  of the tool.

## frostbolt build — 2026-09-11, night (commit `e96bfa3`)

The first channelled, lock-and-cast technique, built as the generic skeleton
every later charged, channelled or homing ability reuses: a technique
declares `targeting = "aim" | "lock"`, `castTime`, `interruptible`, and
optionally `projectile` and `slow`, all as data in `Config.Techniques`; the
server dispatches on those fields the way it already dispatched on `kind`.
Still `Config.Profile = "development"` — tuning is deliberately wrong for
balance. **Not for players.**

### Observed on a gated build of this exact commit

Every commit on the way here was built by rojo from a proven-clean tree and
gated on a byte-identical copy Studio never saved over: boot fingerprint in
the server log, HUD on the first frame, no errors from our scripts.

- **`/dummy` works in the test loop for the first time.** Every local session
  before tonight ran `LegacyChatService` because the project never declared a
  chat service, while the published place runs `TextChatService`, under which
  alone a `TextChatCommand` fires. Declared in the project; a local build
  produced a Dummies folder for the first time. The dummy stands at (-20, 3, -60),
  in view walking down the ramp.
- **The lock.** T with the reticle on a dummy: target frame with a warm border,
  amber **LOCKED**, name, stage, health, and the bracket-refusal line. The
  refusal caption was found clipped by 3px on this first live sighting — the
  frame had never held a real target before — and the frame height is now
  summed from its rows and asserted in a test.
- **`/dummy … ahead` and the post.** A dummy placed on the caller's own line
  five studs out, as a ground-anchored ten-stud post, so a fresh spawn has it
  under the reticle with no camera input.
- **The HUD came back.** See "found and fixed" below.

### Verified by reading at the time; since seen by a human

*Amended 2026-09-12: on a live client the human reported "the targeted frostbolt
that I did on a test dummy out of my tier was successful" — lock acquired,
channel completed, bolt resolved, on their screen. The cast is **observed**. The
slow, the chip and the mid-channel snap remain reported only by reading.*

As written at `e96bfa3`:

The whole Frostbolt cast — 3-second bar, no refusal, trailed bolt curving to a
moving target, **SLOWED ×0.5** on its plate with the patrol visibly dragging,
the chip beside the caster's vitals, and a mid-channel hit snapping the bar
red — is **unverified on screen**. Not for want of trying: the test loop's
synthetic input reaches the keyboard and chat but never the mouse, and a
lock needs the camera pointed by a hand. The code path was read end to end by
three people and the tests; the one real bug in it was found that way (below).
A human at a real client runs it in three chat lines.

### Found and fixed on the way

- **The client stopped compiling at `74f3c2b` and nothing noticed.** Luau caps a
  function at 200 locals; the client's top-level chunk crossed it (188 → 203)
  and the whole script never became a function — no HUD at all, while
  four suites and three linters stayed green, because none of them compiles a
  Roblox script. Fixed by scoping each UI section (`eabdc6c`, 155 locals, soft
  ceiling 175 asserted). **`tests/compile.test` now compiles every file under
  `src/` with Lune's own compiler and runs first in the gate.**
- **The lock was never sent.** The client held the locked target and cast
  with two arguments; the server read a third and refused `no_target` before
  the channel started. Every Frostbolt press would have been refused with the
  LOCKED frame showing. Found by reading both files (`c3ead69`). The contract
  file had specified every server→client event and no client→server one; it
  now carries both directions and says so.
- **The moving dummy could not show a slow** — it patrols by CFrame lerp with
  no Humanoid. It now scales its step by the slow, and `SlowMultiplier` is
  published beside Health so a dummy's slow is as visible as a player's.
- **Lighting migrated on every open.** `Lighting` was declared with no
  properties; Studio rewrote the document to Voxel each time and the modal
  blocked input. `Technology = Voxel` is now declared — what production
  already ran.

### Unchanged from the playtest build

Persistence, breakthrough, the picker on L, the five-slot bar with Shift+slot
cycling, dummies at the row. Reticle–hitmarker concentricity and the lunge
burst at real latency still await a human hand, as before.

## playtest build — 2026-09-10, afternoon

Built for the first external session: four players who are not us. Carries a
**playtest-only override block at the bottom of `Config.luau`** — delete that
block to revert every tuning number in it. Tonight's saves go to their own
DataStore for the same reason.

**This is the build on which two people were in a server for the first time.**

### Verified with more than one client

Observed directly, on a session confirmed to be running current code:

- **Two players see each other.** Characters render; nameplates draw over other
  players at distance with stage-coloured text.
- **Damage between two real players is exact.** Client 1 fired Siphon; client 2's
  HUD went 400/400 to 345/400. That is 55 — Siphon's configured damage, times
  region 1.0, times power 100/100, with tier 1 granting no bonus.
- **`Combat.canEngage` permits same-bracket, proven rather than inferred.**
  `damagePlayer` early-returns and deals nothing when it fails. Health moved,
  therefore it returned true for two real `Player` objects.
- **Impact feedback reaches the defender**: damage number, red vignette,
  nameplate health bar, and the attacker's Ruler dome drawn for another player's cast.
- **Four clients run concurrently** on one machine alongside the editor.
- **The Prime telegraph reaches a second client at server scope**, reading "A Prime
  node has surfaced in the Verdant Reach" — the region name rendering as a
  signpost rather than a raw key.
- **The pacing override is live and applies, not merely displays.** A character on
  bare ground rolled to tier 2 in about six minutes, which is `perTierProgress`
  350 at the 1.0/sec bare-ground rate; `power` read 102, i.e. 100 base times one
  2% refinement step.
- Per-slot madra costs read 18/32/40/50, matching `Config.Techniques`.

### Shipped this round

Five silent failures closed — the pattern was that this codebase decides things
well and rarely tells the player what it decided, and **none of it was visible
with one player**:

- Onboarding: a first-run card and a persistent guidance line. There was none.
- Loadout selection. `loadouts` was cloned from `DefaultLoadout` at join and never
  written again, so eight of the twelve techniques were unreachable by any means.
- Kills and deaths produce output. `handleDeath` did not even receive the killer,
  and the victim was charged refinement without being told.
- Capacity refusal produces output. Capacity is 3; the refusal had never fired.
- A leaderboard, so four players share a frame of reference.

Also: the HUD rebuilt in a denser register, nameplates, a reticle, a soft-target
frame stating bracket refusal outright, cast telegraphs broadcast at intent time
(an opponent previously could not see a cast at all), Ruler techniques scaling off
the ground rather than only off a node, fault isolation on the tick loop and the
join handler, and a build fingerprint printed at boot.

### Not verified

- **Node capacity contest with four players**, and whether the refused fourth is told.
- Kill/death notices, loadout cycling and the defender-side cast bar, in practice.
- **Breakthrough.** Still never performed by anybody. Now reachable within a session.
- **The DataStore read/write path.** Still only the unavailable branch has run.
- Whether time-to-kill feels right. Deliberately untuned: the session exists to
  answer that, and pre-tuning it blind would destroy the measurement.

### Known

- **Studio silently ignores `-localProjectFile`** and runs its own cached document,
  with no error. Every test session for an afternoon ran a build six hours stale
  while the file on disk was current. Open the place in Studio and let it load
  *before* starting a session, and check the boot fingerprint line.
- Technique range is invisible and a refused cast is silent.
- Below a ~600px viewport the HUD keeps its absolute size and eats the frame; the
  scale function has a floor for legibility and no ceiling for footprint.
- Aura geography is still decorative for node placement: `NodeService.placer` rolls
  a region unrelated to where the node lands. `ArenaService.regionAt` exists and
  nothing calls it.

## v0.1.0 — 2026-09-10

First packaged build. The game is playable end to end by one player.

### The loop

Spawn at Lowgold → sense nodes within your range → stand in one to cycle →
refinement fills → hit the stage ceiling → hold a Prime node to its drain for a
catalyst → break through. Fight with four technique slots, same bracket only.
Dying costs 35% of a tier and can never cost a stage.

### Verified in Studio

Observed directly in a running session, not inferred from source:

- Arena builds ground, spawn, graded aura regions, landmarks and sky.
- Cultivation publishes correctly — Lowgold tier 1, power 100, sense 400, and
  combat pools of 400 health / 200 madra matching `Config` exactly.
- Cycling accrues while standing in a node; that node reports `1/3` occupancy
  and returns to `0/3` when the occupant leaves or dies.
- Aura sense lists nodes nearest-first with distance, occupancy and bearing.
- Telegraphs fire at both regional and server scope; a Prime spawn announces
  server-wide.
- Techniques fire and are charged server-side. Madra 200 → Lance → regen tick →
  Surge → regen tick → 174, exactly as the configured costs and 6%/s regen
  predict.
- Slot cooldowns display correctly: firing 1 and 4 dims those slots while 2 and
  3 stay ready.
- Death applies the refinement loss and floors it; **stage and tier hold** — the
  ratchet — and the character respawns with pools restored.
- Persistence degrades correctly in an unpublished place: it warns once, marks
  the player unsaveable, and runs in memory rather than writing over data it
  could not read.
- Zero Lua errors across the session.

### Not verified

- **PvP.** Everything about the design is about contested nodes and mandatory
  PvP, and no second player has ever been in a server. `Combat.canEngage`,
  bracket refusal, node capacity contest and striker aim against a real target
  are all untested.
- **The DataStore read/write path.** Only the unavailable branch has run. This
  needs a published place.
- **Breakthrough.** Reachable and wired, but never performed — it needs a full
  refinement bar, which is hours at current pacing.
- **Pacing.** A Lowgold tier is 9,000 progress and a stage is ten of them. That
  is likely right for the endgame and almost certainly wrong for onboarding.

### Known

- Audio uses client-shipped `rbxasset://sounds/` ids, each verified by loading
  it in Studio and checking for a non-zero `TimeLength`. No id is guessed.
- The proving-ground stages (Foundation through Jade) exist and have never been
  played or tuned; testers spawn straight into Lowgold.
