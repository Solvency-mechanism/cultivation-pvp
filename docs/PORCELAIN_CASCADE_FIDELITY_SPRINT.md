# Porcelain Cascade fidelity sprint

Status: bounded implementation and QA9 gameplay/visual verification completed. The user approved committing this verified refinement and making it the main baseline. Git refs and the clean packaged receipt establish promotion/build provenance. No live Roblox publication is included. The completed MVP remains the baseline, with its screenshots, runtime evidence and bounded performance sample preserved in `PORCELAIN_CASCADE_MVP.md` and `docs/evidence`.

## Concrete target

Shape the existing seven-tier landmark into irregular mineral terraces, with deposited skirts and banks that meet the surrounding ground. Keep the established solid beds, pool access spurs and west/east route geometry authoritative. Break the repeated shelf outlines with restrained asymmetry and layered mineral detail rather than extending the region.

Raise a distinctive, asymmetric porcelain source crown approximately 15–22 studs above the source bed. Give the summit a readable silhouette and a visible origin for the water. Drape the existing shaded alcove with mineral folds and water, maintaining its usable entry, headroom and node-placement exclusion. Add fine wet plants around selected contact points and pool edges.

Develop layered falls, limited spray and moving highlights. Keep the water shallow and readable above real solid beds. Scope quieter node boundaries to the Cascade, with the existing actual capture radius preserved; avoid replacing a truthful gameplay boundary with a smaller decorative one.

## Bounds and budgets

- Preserve all seven pools, 38-point expanded controller route, Pool Warden patrol and existing passive Lumen cultivation; introduce no new resource economy.
- Preserve the volcano and its regression suite, other biome node presentation and gameplay radii.
- Aim for roughly 800–950 static Cascade parts, with a ceiling around 1,100. Counts are construction budgets, not frame-rate evidence.
- Limit added client effects to at most 40 particles per second and 24 local animated decoration objects. Cull distant effects and clean up streamed/removed objects and connections.
- Retain the existing compact region footprint. New crown and mineral dressing must not obstruct standing areas or create misleading node placement surfaces.

## Implementation and review

The world implementation owns static mineral shaping, crown, plants and integrated banks. The client implementation owns local water motion, spray and scoped node-boundary presentation. QA independently reviews their final changes for route obstruction, support, headroom, water depth, region containment, actual radius accuracy, client cleanup and distant-effect culling.

Keep existing construction tests against the real builder. Add or revise checks only for intentional geometry contracts and budgets; do not inflate test totals by repeating implementation trivia. Preserve the full volcano suite. Review the final source before the single full package gate, then build a versioned development package and an isolated uniquely named QA place from the same source. Do not overwrite an open prior artifact.

## Acceptance evidence

Run the final place in Studio: actual spatial probes; 38-point normal-speed walking with one entry setup relocation and all pool spurs; Warden support/movement; natural published Lumen change when capacity permits. Keep all observations read-only except the authorized character setup/walking, with no grants or duplicate gameplay ticks.

Capture matched approach, alcove and source views, recording viewport and quality. Compare them with the retained MVP screenshots for silhouette, irregular mineral layering, source height, water readability and reduced node clutter. Source tests and part counts cannot substitute for this visual review.

If collecting a bounded performance sample, retain the same approach camera, explicit Studio quality and stable viewport; record frame percentiles and available render CPU/GPU values. The MVP's single 48-second sample is limited evidence, not a certified performance baseline. Do not infer sustained 60 FPS from a mean near the cap or from a source gate.

## Current candidate and source gate

Implementation, independent source review and QA9 Studio gameplay/visual verification are complete. The current world uses broad overlapping mineral curtains, ivory foundations and a joined source hood. Static cost is 790 BaseParts plus 345 Sphere meshes. The hood reaches Y63.09, approximately 22.09 studs above the source bed. A continuous rear mineral core reaches from ground to Y41 beneath the hood feet; checkpoint torso positions remain clear of opaque mineral dressing under geometric probes.

The client owns at most 24 local decoration parts and four emitters at rate 6 each (24 particles/second), with one 20 Hz nearby worker and 1 Hz distance checks. Distant effects stop animating and are hidden/cleared. Source/root removal destroys owned objects; script removal disconnects listeners. Independent review found no blocking cleanup issue. All Wellspring-region nodes use the compact presentation while the Cascade exists, including nodes on original ground; other regions are unchanged. Their boundaries use 32 static fine chords whose endpoints use the unchanged actual capture radius, with transparent interiors and preserved tier colors. These source properties do not certify rendered appearance or performance.

The full fidelity4 gate passed: lint/format, 34 compiled sources, wiring, actual Roblox-aware Luau typechecking, all prior rule suites, 47 node-visual cases, 3,916 Cascade construction checks with 232 route samples and 250,449 volcano construction checks. The tests include an explicit renderer contract: tagged ellipsoids must use Block parents with size-scaled Sphere meshes, plus static budget, crown height, grounded rear support and checkpoint clearance checks.

- Development package: `dist/cultivation-pvp-porcelain-cascade-fidelity4.rbxlx`, 798 KB, SHA256 `037F68A16646984543FC3C3BB0FB4CF14E6755F361A7B75F90A34A4213009088`.
- Current isolated candidate: `Cascade-qa9.rbxlx`, SHA256 `37EDCC718B0D13E76275245AF830FE9486D9A8EA30772310763F6C1D20D8F37F`.

These pre-promotion verification artifacts contain the then-uncommitted working changes; `0c05a1f37a9bed11838fefc5e3d138fd69754219` is ancestry only. The development package is not a player release. Baseline MVP artifacts and evidence remain unchanged.

## Intermediate visual findings

QA6 passed gameplay probes but [failed rendered-shape review](evidence/cascade-fidelity-qa6-rejected.png): engine Ball parts did not render the intended anisotropic sizes. The correction uses Sphere meshes; the [intermediate runtime evidence](evidence/cascade-fidelity-qa6-intermediate.txt) is not final art acceptance.

QA7 corrected mesh rendering but [failed composition review](evidence/cascade-fidelity-qa7-review.png): repeated separate egg forms exposed rectangular foundations, while the crown read as thin pickets. Its [gameplay probes](evidence/cascade-fidelity-qa7-intermediate.txt) passed independently. The current candidate replaces these with fewer broad overlapping curtains, ivory backing and a joined hood. Those earlier successful controller tests do not substitute for the final candidate's visual verification.

Human discovery, long-term balance, physical-device acceptance and sustained 60 FPS remain separate gates. Final QA9 evidence is recorded below.

The broadened node scope resolves the [QA8 approach obstruction](evidence/cascade-fidelity-qa8-node-obstruction.png), where an original-ground Prime still used a giant shaft. Capture radius, spawn positions and gameplay remain unchanged; the final runtime diagnostic verified both Wellspring and other-region node presentation.



## Final QA9 runtime and visual evidence

[Final runtime records](evidence/cascade-fidelity-final-runtime.txt) show 126 spatial checks with no failures, 24 supported Warden samples with zero unsupported samples and 11.01 studs displacement, and all 38 controller waypoints passed at normal WalkSpeed 16 with one entry relocation. The route visits every pool spur. Natural eight-second Lumen accumulation was 217 to 233 (+16), with published vessel total 562 to 598 and capacity 1200. No resource grant or duplicate service tick was used.

The client diagnostic verified 24 local parts, four emitters totaling 24 particles/second, 16 changed transforms, distant hiding/emitter disabling and nearby resumption. It observed two Wellspring nodes and five other-region nodes, with correct scoped styles in both groups. This is actual engine behavior evidence; it is not a performance measurement.

Unedited [approach](evidence/cascade-fidelity-approach.png), [alcove](evidence/cascade-fidelity-alcove.png) and [source](evidence/cascade-fidelity-source.png) captures use the original camera views at 1094x490, FOV 65, Studio Automatic. The separate [crown close view](evidence/cascade-fidelity-crown.png) uses eye (0,48,198), target (0,50,230), and Studio Level10; it is not a matched comparison to the earlier source camera.

The result is a bounded fidelity improvement: broader connected mineral forms, a readable source hood, quieter region nodes and verified water motion. Straight foundation faces and the regular tier rhythm remain visible. It is not described as a finished naturalistic landscape or an industry-quality benchmark. At the verification snapshot no commit or promotion had occurred; subsequent user approval covers Git promotion. No live publication is included.


## Bounded performance observation

[QA9 performance evidence](evidence/cascade-fidelity-performance.txt) records one approximately 48-second approach sample at explicitly verified Studio Level10, FOV 65 and stable 1094x490 viewport. It measured 2,811 frames, 57.98 mean FPS, p95 26.53 ms, p99 32.26 ms and 0.85% of frames over 33 ms. The 48 readable Stats samples averaged render CPU 4.94 ms and GPU 13.88 ms. Camera restoration and callback disconnection were confirmed.

The MVP sample used 1094x492, so these are not a matched viewport comparison and establish no causal performance gain or regression. This single Studio view does not certify the whole scene or a physical device. Its p95 exceeds 16.7 ms; sustained 60 FPS acceptance remains unmet.


Studio quality was restored to Automatic at 02:48:13 UTC, confirmed in the performance evidence; the operator restored the normal player camera. At verification closeout the artifact hash was reverified, git diff whitespace checks passed, and branch/main refs were unchanged. The user subsequently approved committing and promoting the verified source; final Git refs and the clean `porcelain-cascade-main` receipt establish that provenance. The performance limitation remains unchanged.
