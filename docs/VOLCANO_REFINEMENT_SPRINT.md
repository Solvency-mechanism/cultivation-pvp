# Sleeping Furnace — volcano refinement sprint

Status: proposed sprint, not dispatched. Branch: `feature/volcano-art-refinement`. Protected baseline: `346f85e` on `feature/volcano-experience`. Duration: ten working days, with a review at each gate; revise estimates after the asset and performance audit. No refinement implementation has started.

## Goal and creative direction

Make a compact volcano expedition with exceptional art direction, material detail, atmosphere and physical credibility. The user's ambition is to exceed the polish of mainstream Roblox experiences. We will assess that ambition with matched in-engine evidence and a selected reference panel, not assert superiority over every game.

A living mountain shelters something vastly larger than the visitor. Outside: fractured, weathered basalt, ash deposits and restrained molten seams. Inside: scale, silence, an irregular cave mouth, and the complete red dragon head suspended against unreadable darkness. Warm light has a source and a purpose. Detail rewards approach rather than making every surface equally busy.

The approved head is the immutable control asset. Preserve every part, shape, relative pose, proportion, color and material in this sprint's production candidate. Refine its presentation through light, framing, breathing and sound. Any proposed remesh or anatomical revision belongs in a separate comparison variant and requires visual approval before replacing it. The cave must enclose the head rather than crop it. Preserve darkness on either side and behind it; do not reveal box walls or place stone across the face.

## Approach choice

| Approach | Benefit | Cost or risk |
| --- | --- | --- |
| Polish existing procedural primitives | Fastest, easiest to maintain | Repeated blocks and material uniformity limit the ceiling |
| Entirely custom sculpted environment | Maximum control of silhouette and surface detail | Large asset workload, iteration and collision cost |
| Authored hero assets plus reusable procedural assembly — recommended | Strong focal spaces with manageable asset and runtime budgets | Requires a disciplined seam, scale and material system |

Use custom modular rock, cave threshold and landmark props where the player looks closely. Keep assembly, interactions and distant structure code driven. Preserve the original dragon. Do not expand the playable map or introduce new progression systems during the art sprint.

## Days 1–2: references, scene surgery and composition

Deliverables: a licensed/reference-only visual board; three selected current Roblox reference experiences with dates and comparable screenshots; a camera sheet; measured performance baseline; a cleaned greybox candidate. References are for composition and quality comparison, never copied assets.

Inspect the entire scene, including its rear exterior. Current blackout geometry reaches local Z 137 beyond the original radius-80 shell. Coordinate-based blackening affects existing rivers and ramp dressing. Remove that fragile coupling: give the cave explicit ownership, fit or conceal the enclosure within a deliberate mountain silhouette, and reroute the existing climb around it with continuous floors and camera clearance. No invisible walking surfaces or exterior black patches.

Author five beats: distant volcano silhouette; compressed entrance; first glimpse of the dragon; full audience reveal; elevated exit and crater vista. Preserve forge, purification, secrets and trial access. Determine avatar-scale clearances in Studio before creating final meshes.

Gate A: uninterrupted avatar walk from approach through cave, trial and crater; side and rear views contain no exposed box, gaps or intersecting climb. Approve matched greybox views before detailed asset work.

## Days 3–4: geology and material craft

Build a small coherent basalt kit: large fractured masses, two medium fracture families, irregular cave lip segments, ledges, rubble clusters, stalactites and ash deposits. Use large and medium shapes first; add small detail only where it reinforces erosion, heat or traversal. Break straight brow and shoulder edges without making the cave a pile of disconnected rocks.

Create a consistent material palette with believable scale: cooled basalt, fresh fracture, soot, ash and molten crust. Use authored texture maps and meshes where they improve close views; share materials, atlas small props and provide collision proxies and distance variants. Audit UV stretching, tiling, seams, floating rocks and thin edges at every hero camera. Record asset source and licensing.

Gate B: unlit geometry still reads as a volcanic cave integrated into the mountain. No obvious repeated block rhythm at the entrance; material scale holds from avatar distance and from the crater. The original head comparison test remains green.

## Days 5–6: darkness, dragon presentation and atmosphere

Replace broad blackout overrides with a bounded, owned light enclosure. Preserve absolute visual darkness behind and alongside the head across supported settings. Shape a restrained facial light so teeth, brow, horns and snout read without lighting the enclosure. Reduce competing altar and path brightness; nine equally bright action markers should become distinct objects with different visual priority.

Retain complete sculpture geometry. Refine jaw and eye timing into a slow, coherent breath with subtle pauses. Keep teeth and tongue rigidly attached to the animated jaw. The eye response, ember activity, cavern rumble and local aura pulse should share one breath clock. Avoid a constantly blinking or bobbing head.

Layer positional rumble, distant stone movement and restrained ember sounds using verified usable assets. Add sparse localized ash and heat cues. No full-screen effects needed to make the scene attractive; essential navigation and danger cues must remain readable with effects reduced.

Gate C: audience and side views show the intact head against darkness at rest and peak exhale. No light leaks, visible backdrop planes, competing neon glare, camera clipping or excessive particles. Review silent footage first, then audio separately.

## Days 7–8: discovery detail and expedition continuity

Replace generic action plinths with readable silhouettes: a worked anvil with cooled slag, a quiet purification basin, an offering surface worn by repeated use. Keep server actions, ranges and resource costs intact. Place environmental clues for refuge and brazier discovery; reduce signage only when unfamiliar players can still find the action.

Add a few deliberate stories through props: abandoned tools, ash settled in sheltered places, worn pilgrimage stones and a route that turns toward the dragon. Avoid scatter that blocks paths or looks randomly distributed. Ensure every close-view object has intentional contact with its support surface.

Run a full fresh-state expedition, returning-player persistence check and two-client interaction check. Resolve the pending corrected handler smoke and engine route probe. Record real walking separately from teleported automated checks.

Gate D: unfamiliar players can find the entrance, read the dragon reveal, use the offering and navigate the trial without narration. Log confusion and fix repeated issues. No new combat/economy systems are added to conceal presentation problems.

## Days 9–10: performance, critique and release candidate

Capture identical camera positions, avatar scale, FOV, graphics settings and breath phases for baseline and candidate: approach, entrance, audience, lateral audience, trial, refuge, crater and rear exterior. Include a continuous gameplay-camera walk; beauty shots alone are insufficient.

Measure frame-time percentiles, memory, part/mesh and active light counts in the same test session. Day 1 names the actual desktop and physical mobile test devices. Provisional targets: desktop 60 fps with p95 frame time at or below 16.7 ms; selected mobile 30 fps with p95 at or below 33.3 ms. These are targets, not established capabilities. No sustained memory growth over a 15-minute repeat route. Budget lights, triangles, texture residency and particles from measured headroom; if targets fail, simplify effects and distant detail before compromising the hero composition. Reduced settings must preserve cave darkness and navigation.

Use three independent reviewers where available, viewing unlabeled baseline/candidate captures and the selected references. Score composition, geological coherence, materials, lighting, creature presence and atmospheric restraint from 1 to 5 with written reasons. Target candidate preference from all three, median at least 4 in every category, and zero unresolved geometry/light-leak defects. Reference comparisons must explain both strengths and deficits. This panel is evidence of quality, not a universal ranking.

Gate E: all code gates pass; original-head preservation checks pass; fresh and returning expedition, two-client and designated physical-device evidence are attached; performance targets pass or explicit exceptions are reviewed; user approves the final scene. Preserve the baseline branch for comparison and rollback. Merge/publish only when separately authorized.

## Ownership and dependencies

Environment artist owns rock kit, cave shell, paths and collision. Look-development owner owns materials, lighting and atmosphere. Gameplay/integration owner protects prompts, movement, resources and persistence. Reviewer owns matched captures and performance/acceptance evidence. Work can be parallel after Gate A, with separate asset/module boundaries and one shared placement contract. No concurrent edits to the central world assembly file without coordination.

The baseline is available locally now. Missing final assets, asset tooling, device availability and benchmark access are discovered on Day 1 and reflected in the schedule. If the full quality bar needs more than ten days, keep the gate open and report the remaining work rather than relabel the candidate as finished.

## Required handoff

A reproducible candidate build and source commit; asset manifest; exact baseline/candidate screenshots and walk video; named-device performance report; expedition acceptance record; remaining defects; and a short comparison explaining where the candidate meets or falls short of the selected references. A polished screenshot with a broken route does not pass.
