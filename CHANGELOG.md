# Changelog

All names in this project are placeholders, including the title.

Versions are dated and describe what was **observed working**, not what was
written. Anything unverified is listed as unverified.

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
