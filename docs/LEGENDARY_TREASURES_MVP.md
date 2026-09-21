# Legendary treasures

The implementation adds five authored discoveries, a persistent collection, and three universal equipment slots. Each owned treasure can occupy one slot; moving it removes its previous assignment. Equipment changes use the server's combat lock. No commit, main promotion, or live Roblox publishing is included in this working branch.

| Treasure | Implemented effect |
| --- | --- |
| Emberlung | Replaces V / the existing Vent touch button with a directed fire breath: 30 fire mana, 8-second cooldown, 30-stud cone. Damage uses the existing server combat rules. |
| Cascade Heart | Ten seconds of grounded, stationary cultivation charges the Heart. The next successful Swiftstep speed technique or Cinder Step physical dash heals the owner and same-team allies within 12 studs and clear sight for 20% maximum health. Movement or damage clears charge. |
| Wind Chime | +8% movement speed while equipped. |
| Iron Seed | +8% strength while equipped. |
| Stillwater Pearl | +8% cultivation while equipped. |

Discovery is server-authoritative: the player must be alive, within ten studs of the authored marker, and have clear line of sight. Repeated discoveries do not grant another copy. Treasures survive the normal progression serialization, advancement, and loss paths. The collection UI sends requests and renders server attributes; it does not grant items or predict successful equipment changes.

Press I or tap Treasures to open the collection, select one of three slots, then equip or move an owned treasure. A first discovery has a separate reveal. Heart readiness is visible on the closed collection button. Short viewports use compact controls and a scrolling collection. Opening a collection or reveal temporarily hides the Roblox player list and restores its prior state when closed. Chat is unchanged.

Accepted breath and healing events produce short local effects, culled beyond 130 studs and capped at 32 transient parts. Collection rendering is event-driven. Effects use tween/debris cleanup; script destruction disconnects owned listeners and destroys owned objects.

## Verified evidence

The normal `legendary-treasures3` build passed lint, formatting, full Luau types, compilation of 38 files, every existing suite, 79 treasure rule tests, and 125 treasure construction checks. Source ancestry is 8f7ff0e; these are uncommitted feature changes. The deployment candidate now uses the explicit `beta` profile: deliberately accelerated tester tuning with the loadout picker and a new isolated `Cultivation_beta_20260920` DataStore. It is for a restricted tester experience, not public balance measurement or final release.

QA2 passed 168 spatial checks and all 5 authored local walks with actual Humanoid movement, range, line of sight, and prompts. Each route uses one disclosed setup relocation. See [route log](evidence/treasures-routes-runtime.txt).

QA4 client UI was checked in Studio at the actual Heart route endpoint. The public ProximityPrompt InputHoldBegin/End methods were invoked from the client command bar, exercising the prompt and server discovery path rather than granting inventory directly. The first-discovery reveal, Open collection, clicking slot 3 and Equip 3, 100% Heart readiness, and closing/restoring PlayerList were observed. Unedited captures: [discovery](evidence/treasures-discovery.png), [equipped collection](evidence/treasures-equipped.png). This is desktop Studio evidence, not physical touch-device acceptance.

QA6 passed all 21 isolated service checks with zero failures. It verified near/far/blocked discovery, duplicate rejection, slot movement and modifiers, local serialization, breath cost/damage/cooldown/combat lock, normal cultivation charging, actual Cinder Step, recharge, and movement reset. The real dash changed authoritative health from 280 to 360 (+80, exactly 20% of 400 maximum), consuming charge to 0. See [service log](evidence/treasures-service-runtime.txt).

The healing oracle reads the published CombatService Health attribute; Humanoid values remain diagnostics because default regeneration can drift independently. Earlier QA-only character mutation and delayed Humanoid comparison were removed without relaxing production mechanics. This existing health-display drift remains separate from the demonstrated treasure-heal result.
| Artifact | SHA-256 |
| --- | --- |
| `dist/cultivation-pvp-legendary-treasures3.rbxlx` | `5F0896F04CCE0F2B900F34B27E846744240C6D609E2ABC93244D281CFECC0D54` |
| `treasures-qa6.rbxlx` | `047C40C0DC923FF8C18A3B5EF94F4E49DA8A91E27841057CB6EE99836995826C` |

QA6 contains the same production source as the passed normal build; subsequent changes only strengthen the isolated QA helper. Its embedded oracle was read back and verified after building.

## Reproduce

Use `./package.ps1 -Version legendary-treasures3-beta` for the normal restricted-beta artifact. Use `./qa/Treasure-build.ps1 -Output treasures-qa6.rbxlx` for the isolated Studio place. The latter derives from the normal project, uses `Cultivation_TreasuresQA_v1`, and adds manually invoked helpers only; none are mapped into production.

From the Studio server command bar, invoke `game.ServerScriptService.TreasureQACommand:Invoke(game.Players:GetPlayers()[1])`. The helper temporarily seeds state through its normal owner, creates a support/target lab, exercises real services and the normal Cinder RemoteEvent via a QA-only client relay, then restores state and position. The second argument `"spatial"` or `"walk"` selects authored route checks; an optional third treasure ID limits walking to one route. Route checks do not grant treasures.

Local serialization roundtrips do not prove backend persistence. The single-player lab does not verify multiplayer team healing or adversarial player behavior. Physical touch layouts, backend persistence, and multiplayer acceptance remain separate from this Studio evidence. Immediately after restricted publication, verify one real beta-store round trip (discover/equip, leave, rejoin) before treating persistence as accepted.
