# Refinement candidate — 2026-09-12

The user approved this verified refinement as the `main` baseline, conditional on final checks. Git refs and the packaged receipt establish promotion/build provenance. No live Roblox deployment is included. Implementation branch: `feature/volcano-art-refinement`, based on plan commit `331f6b7`. The protected original remains at `346f85e` on `feature/volcano-experience`. Development tuning is retained for this approved candidate; approval does not mark the broader art and performance ambition complete.

## Implemented

A fitted, explicitly owned dark cave and fractured basalt enclosure replace the oversized box and broad coordinate blackening. The complete control sculpture is rigidly reposed so dorsal plates no longer escape the rear mountain. A colliding audience boundary distinguishes the visitor area from the scenic floor behind the head. The 64-section spiral is rebuilt with visible stone floors and kerbs around the enclosure.

The user subsequently authorized sculpture expansion for fidelity and awe. The candidate adds a tapered muzzle, almond amber eyes with dark pupils, pointed teeth, cheek/crown planes and horn detailing. Original replaced pieces are retained but hidden, with comparison attributes; this is a visual variant, not a claim that the entire original remains visible. Lower replacement teeth share the jaw animation. Built-in sphere meshes give the eyes their intended non-uniform proportions.

Station props now have recognizable forms: anvil and tools, purification basin, offering dais and charcoal brazier. Exterior lava has cooler crust edges and restrained illumination. Sparse fracture planes, entrance ash, local grading and reduced bloom support the cave reveal. Lighting updates stop once adaptation settles. No imported third-party assets or new gameplay systems were added.

## Pass 2 source changes

Pass 2 is implemented in source: a wider facial silhouette, outward horns, a dark mouth and two rows of shark-like teeth. Twenty visible teeth occupy both upper and lower arches; lower teeth, lips and mouth bed share the jaw pivot. Hidden baseline controls retain their geometry and cannot join opacity animation. The upper cave recess accommodates the horns while its lower walls preserve the trial clearance. Cave, exterior fracture/crust and station dressing have been refined. QA photo mode now saves and disables ProximityPromptService along with the interface, then restores its prior enabled state when H is pressed again.

The full pass 2 source gate completed successfully: Selene, formatting, 31-file compilation, wiring, 105 progression assertions, 112 aura-node assertions, 497 combat assertions, 211 interface assertions, 65 volcano rules assertions, 33 integration assertions, 250,449 construction checks, Luau analysis and Rojo packaging. Construction checks include lower attachment tags, rest/three-degree-exhale mouth and tooth enclosure bounds, and actual hero-camera-to-horn OBB occlusion rays that include opaque query-disabled geometry. These checks do not establish engine physics or visual quality.

- Normal development artifact: `dist/cultivation-pvp-volcano-refinement-pass2.rbxlx`, 770 KB. SHA256: `A9D6DF234DF53FD1357CA722CC0D6C490CF5FB46BAE1B3EF9861F321FE38C7C6`.
- Build receipt: `dist/cultivation-pvp-volcano-refinement-pass2.txt`; built September 12, 2026 at 16:19:20 -07:00. That artifact was built before the promotion commit; `331f6b7` identifies its ancestry only, as the historical receipt states.
- Isolated QA artifact: `volcano-art-qa-6.rbxlx`. SHA256: `3B22660B2B5433D7C0BF764C4F5F58D478AAF9163B806CFEA05AB4AAE753207D`.
- Construction cost: 879 BaseParts, two mesh instances and 26 lights; 842 decoration and 98 ground descendants. The immediate earlier source snapshot had 750 decoration and 98 ground descendants, so pass 2 adds 92 decoration descendants. Counts are not frame-rate evidence.

QA5 passed 2,592 real-engine spatial checks, 16 service checks and all 87 automated walking waypoints (three disclosed setup relocations). The recorded QA5 Studio log is `0.738.0.7381393_20260912T231417Z_Studio_C1642_last.log`. Visual inspection nevertheless exposed an outer-horn presentation issue and an enclosure join slit. The current source corrects horn orientation and sockets and adds 14 opaque join pieces; those changes required the new QA6 artifact above.

QA6 was opened fresh in Studio and verified after those corrections. It passed 2,592 spatial checks, 16 service checks and all 87 automated walking waypoints. The saved log contains 87 individual grounded-arrival records and three setup relocations; the aggregate report says Passed. No speed changes, forced jumps or rescue teleports were used. This is automated controller-contact evidence, not human or physical-device acceptance.

The final Studio visual review confirmed that both outer horns are visible in hero and lateral views, the dark mouth and tooth rows read clearly, the lateral sky gap is closed and the rear enclosure joins the mountain. Evidence: [hero](evidence/refinement-pass2-dragon.png), [lateral](evidence/refinement-pass2-lateral.png), [rear](evidence/refinement-pass2-rear.png), and [QA6 runtime extract](evidence/refinement-pass2-runtime.txt). The exact source log is `0.738.0.7381393_20260912T231941Z_Studio_399EA_last.log`.

QA6 performance remains below target. The uncontrolled Studio log records approximately 39.22 mean FPS / 39.73 ms p95 for a 15.3-second audience sample, 32.03 FPS / 48.71 ms p95 for lateral and 33.79 FPS / 43.79 ms p95 for rear. A later 45.01-second audience sample measured 29.46 FPS / 50.08 ms p95. Automatic graphics, 1094x490 viewport, Studio client wall intervals; machine and variant fields were not recorded in the harness. These are not matched baseline comparisons or GPU timings, and no performance improvement is claimed.

## Earlier candidate evidence

- Full source gate: lint, formatting, compilation, wiring, unit/integration/construction checks, Luau analysis and Rojo build. Build receipt in `dist` records the exact artifact SHA256 and explicitly identifies dirty working-tree provenance.
- Studio: 2,592 spatial checks passed, covering the 64 spiral pieces, six crater stairs, visitor area and exterior enclosure rays.
- Studio: 16 real-service smoke checks passed, including the corrected duplicate-brazier-light case.
- Studio: all 87 automated Humanoid walking waypoints passed across spiral/crater, crater ascent and sanctuary trial. Three disclosed setup relocations, one per route; normal WalkSpeed16; no forced jumps or rescue teleportation between points. This is controller-contact evidence, not an unfamiliar person's playtest.
- [Dragon candidate](evidence/refinement-dragon-candidate.png), [rear exterior](evidence/refinement-rear-exterior.png), and [runtime records](evidence/refinement-final-runtime.txt). Final iris/socket correction was visually applied in Studio, mirrored in source and rebuilt; it is noncolliding cosmetic geometry.

## Gates still open

The full ambition is not achieved. Custom sculpted environment meshes, authored material maps, a broader sound pass, matched gameplay reference captures and the three-reviewer comparison remain. Native geometry improves the candidate but still reads as a procedural prototype in several views.

Performance target remains unmet: representative earlier-candidate Studio audience samples measured approximately35–44meanFPS with p95 frame intervals approximately37–48ms, versus the provisional60FPS/16.7ms target. Machine: Windows, AMD Radeon integrated graphics, driver32.0.21037.3009; automatic graphics; viewport about1094x490; Studio editor and other application workload present. These are client wall intervals, not GPU timings. Runs were not a controlled baseline A/B, so no causal performance improvement claim follows from them. No physical mobile testing or long-session memory gate has been completed.

Fresh/returning multiplayer acceptance, actual human discovery/readability feedback and physical-device performance remain open. The user has approved this visual baseline; the broader reference-comparison and quality gates remain open. Preserve the baseline and continue asset/look development before calling this sprint complete.

## Try the candidate

Open `dist/cultivation-pvp-volcano-refinement-pass2.rbxlx` in Roblox Studio, then F5. It uses the existing development tuning profile. QA is a separate build: `powershell -ExecutionPolicy Bypass -File qa/build.ps1 -Output volcano-art-qa-6.rbxlx`. QA seeds isolated test data and automatically runs service and controller tests; do not confuse it with normal play. In QA,1–8 select camera views,0 cycles, H hides/restores interface and proximity prompts. The isolated build can alter the character for testing; all QA scripts are excluded from the normal place.
