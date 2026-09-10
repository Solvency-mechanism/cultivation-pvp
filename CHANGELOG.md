# Changelog

All names in this project are placeholders, including the title.

Versions are dated and describe what was **observed working**, not what was
written. Anything unverified is listed as unverified.

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
