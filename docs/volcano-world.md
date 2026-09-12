# Sleeping Furnace world

`VolcanoWorld.build(kit, centre)` reuses Worldcraft's volcano, hollow chamber,
dragon, pools, spiral ramp, crater floor and stairs. It returns `{centre, root,
ground, frame}`. Nothing connects to a heartbeat or owns a prompt in this builder.
The service owns interactions, reward eligibility, resource spending and animation.
`VolcanoCave.build(root, ground, frame)` owns the fitted black interior, authored
rear basalt mass and replacement spiral. Parent integration may layer separate
prop/dragon-detail modules after this build returns.

The `VolcanoExperience` folder lives under `kit.decor`; `VolcanoWalkable` lives
under `kit.ground`. This preserves ArenaService's floor-placement distinction.
The caller must supply a supporting plate that covers the 105-stud approach and
88-stud side exit as well as the original 80-stud mountain footprint.

## Geometry and journey

Coordinates below are local to `frame = CFrame.lookAt(centre, centre + outward)`;
outward is Worldcraft's mouth bearing. Negative Z points toward the entrance;
positive Z points toward the dragon. Local +X is bearing mouth + pi/2.

* Approach road: Z -105 through -63, width 16, paired ember markers and the
  Sleeping Furnace inscription. Existing arch/tunnel continue toward the chamber.
* Entry brazier: (7, 3.5, -43), with a nearby instruction to offer a small breath.
  An ash seal at (11.6, 4.7, -43) hides a small recess, relic and carved clue.
* Sanctuary: 47 by 39 studs, top Y 2, centre (0, 1, -1). Dragon offering at
  (0, 4, 12), forge at (-13, 4, 4), purification at (14, 4, -4). The sanctuary
  is an authored dry floor; any combat exclusion must be enforced by gameplay.
* Side fissure: 10-stud floor from (20, 1.2, -10) to (88, 1.2, -10), lined by
  basalt ribs and ember threads. Low shell facets with local X > 45,
  abs(Z) < 19 and Y < 27 are removed so the exit is physically open. Cache at
  (58, 3.7, -10); lintel at X 70 with underside Y 11.
* Refuge: an eight-stud branch from the sanctuary leads around staggered visual
  screens to a 15 by 15 floor centred at (37, 1.2, 24). Three breath glyphs mark
  the screen; a bedroll and journal surround the cache at (38, 3.8, 25).
  Back and side walls plus a roof make it an actual concealed alcove.
* Trial: ten continuous eight-stud-wide treads rise 1.4 studs per segment from
  (-24, 1.2, -7) to (-29, 15.2, 21). The course can be walked without its reward.
  Finish marker is at (-29, 17.7, 21).
* Shortcut: a platform centred at (-29, 15.2, -5), with roughly 15 studs between
  platform edges, offers a use for directed movement. A sloping seven-stud-wide
  descent returns to (-16, 1.2, -14). Walking back down the trial is always available.
* Crater source: (16, 90.5, 0), on dry floor outside the central radius-11 pool.
  Existing spiral and crater stairs supply ordinary access and exit.
* Thermal vents: optional west-rim six-stud pads at (-16, 88.15, +/-9), outlined
  by bright borders. The east source and ordinary access remain clear.

All nine action marker parts are anchored and noncolliding. Decorative additions
are noncolliding except for the intentionally sealed ash recess; traversable
surfaces are colliding slate beneath `ground`.
This avoids a secret or reward becoming inaccessible behind a decorative rib.

## Visual refinement: fitted cave and rear mountain

The previous approved head-in-darkness composition is retained as the visual
goal, while its projecting rectangular enclosure is replaced. Every original
dragon part retains its size, relative transform, color and material. The whole
sculpture takes a rigid 12-degree raised-chin pose around chamber X, with head
centre local (0,22.6,28). This directs the intact neck down into the mountain:
translation alone left Plate2/Plate3 visibly outside the rear wall in Studio.
The regression checks every exposed dragon corner against the sloping rear
backing with 0.9 studs of margin. No original anatomy is deleted or remodeled.

`DragonCaveArchitecture/BlackInterior` contains eight sloping rear seal bands,
paired side bands and a roof. The rear recedes from local Z 75 at Y 0 to Z 57 at
Y 68; sides are X +/-24. Roof is Y 69 with underside 68, supporting additive horn
detail below that height. All eight corners of every black enclosure part are
checked within the original radius 80 footprint. Its floor is real collidable
geometry under `VolcanoWalkable`; darkness is never substituted for spiral floor.
The sculpture's backing floor carries `VolcanoScenicFloor` and a visitor extent
of local Z29. A visible colliding basalt barrier at Z31 spans X +/-24, reaches
Y5.5, and carries `VolcanoVisitorBoundary`. This separates the audience space
from the neck/scenic interior. It is a walking boundary, not an anti-jump barrier.

`DragonCaveArchitecture/BasaltEnvelope` supplies 112 staggered rear rock faces,
fractured threshold ribs and crown pieces. The rear mass tapers from radius 78
at ground to 66 at Y 68, then joins the original cone at Y 88. The opening frames
the complete head rather than covering it. Every architecture part carries
`VolcanoCaveOwned`; structural rock faces also carry `VolcanoRockFace`.

Replacement selection is explicit: named rear VolcanoFacet/VolcanoRiver parts
below Y 88, original ramp posts/flames, dragon pool and lava fall are removed.
No arbitrary nearby surfaces are painted black. The front original shell stays.

The 64 original ramp slabs are replaced with eight-stud-wide solid cobblestone
slabs outside the new rear buttress. Start and arrival bearings remain unchanged;
the outer offset eases from 7.5 back to 3.5 near the summit to meet existing crater
stairs. Low basalt kerbs mark exposed edges, with regular landing gaps. All ramp
names remain `VolcanoRamp1` through `VolcanoRamp64` for engine QA compatibility.

## Runtime seams

| Part | VolcanoAction |
| --- | --- |
| EmberBrazier | light_brazier |
| RefugeCache | refuge |
| FissureCache | fissure |
| DragonOffer | dragon |
| TrialStart | trial_start |
| TrialFinish | trial_finish |
| PurifyFont | purify |
| ForgeAnvil | forge |
| CraterSource | gather |

The root carries `Centre` (Vector3). The dragon model carries `VolcanoDragon`;
the jaw, tongue and six lower teeth carry `VolcanoJaw`, both eyes `VolcanoEye`.
The ash seal carries `VolcanoAshSeal`; vent pads carry `VolcanoHazard`.
Added emissive markers carry
`VolcanoBreath`; three glyphs also carry `VolcanoClue`. Existing pools, lava fall,
rivers and crater lake carry `VolcanoLava`. Pool beds are not lava. The legacy
dragon Speak prompt is destroyed after generation so the service is the sole
interaction owner.

`VolcanoCultivationRate` / `VolcanoCultivationRadius` are 6/14 on EmberBrazier,
8/18 on ForgeAnvil, and 18/12 on CraterSource. These are source metadata for the
runtime cultivation owner, not a separate reward timer in the world builder.

## Verification

* StyLua applied; Selene reports zero errors, warnings or parse errors.
* Existing compile gate: 25 source files compiled, zero failed at the time of
  the world change.
* `lune run tests/volcano-world.test.luau` executes the builders and performs
  over 244,000 construction checks, including marker support estimates, nine-point
  body clearance samples along all 64 spiral slabs and trial/fissure/shortcut geometry, dragon-facing
  direction, baseline dragon anatomy preservation, enclosure bounds, action
  uniqueness and metadata. The integrated harness also constructs the separate
  prop and dragon-detail modules before its assertions. The harness uses midpoint RNG,
  stub service lookup, removed the legacy prompt event hookup (Lune has no live
  Roblox signals), and replaced the Part Position read with CFrame.Position
  because Lune does not synthesize that derived property. It supplies the standard
  CFrame basis construction for lookAt because Lune 0.10.5 reverses the Z direction
  for this bearing. Ground support uses oriented bounding boxes (including disc
  bounding boxes), and cannot substitute for Roblox collision. This is construction
  evidence, not physics or visual acceptance.
* Studio walk-through, lighting readability, collision acceptance and multiplayer
  pacing remain runtime checks. No claim of in-client playtesting is made here.
