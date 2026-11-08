# Native 3D visual quality

The generator should build a recognisable explanation of the requested topic: a coherent silhouette, useful proportions, physically meaningful connections, and short labels on the actual parts. More primitives or a larger JSON response do not establish better quality. This guideline accompanies the bounded native geometry extension; it is a design and admission contract, not a claim that arbitrary generated models are accurate or match HeyClicky.

## Design the explanation

Choose a small set of parts that explains the requested relationship. Identify its main axis, characteristic outer outline, and the points where parts meet. A rounded body, taper, curved turned housing or L-shaped bracket should use a suitable supported shape. Repeated cylinders and boxes remain useful for rods and blocks; the selection follows the physical form rather than a fixed template.

For organic subjects, preserve the features that make the subject recognisable before adding decoration: major body regions, segmentation, paired appendages and distinctive curved or lobed outlines. A small mesh count is not a goal. A capsule alone cannot explain a caterpillar's form, and a pair of generic ovals loses a butterfly's forewing/hindwing distinction. Concentrate detail where it remains visible in the compact tray.

For processes and lifecycles, keep the appropriate states as distinct spatial assemblies and show their order. Use balanced stage scale and separation, short numbered labels and supported directional geometry where helpful; a cycle also needs an explicit return cue. The host has no semantic-arrow primitive: a cylindrical rod alone is not directional. Use ordinary native stems/cone heads, without inventing geometry or fields. The generic instruction does not force every topic to have the same number of states or prescribe a butterfly template.

Use consistent relative proportions. Keep related coaxial parts on one axis through a shared group transform, and use native endpoint connectors for static rods or bonds where the selected format supports them. Connections should enter the attached solids, with visible clearance where a mechanism requires it. A connector compiles supplied endpoints; it does not infer joints, solve collisions or simulate motion.

A cutaway may reveal a hidden mechanism. An exploded arrangement may separate obscuring parts. Explain the opening or separation and preserve the solid or hollow nature of unrelated parts. Orient the assembly so the relevant relationship is visible from the native camera. Avoid decorative bases, unrelated detail and labels that attempt to conceal incorrect geometry.

Use two to four colors with stable meaning: neutral structure, an accent for the active mechanism or phenomenon, and another accent only for a distinct concept. White labels should usually contain one to three words. Anchor them to distinct real parts and keep narration focused on the relationship introduced in that stage. The renderer resolves visible surfaces and projects leaders; model-written label coordinates are not evidence of surface ownership.

## Use the bounded geometry vocabulary

The existing world-space convention remains right-handed, +Y up. Local transforms compose `T * Rz * Ry * Rx * S`. The renderer owns camera fit and projection; there are no model-supplied shaders, executable geometry, URLs or downloaded assets.

| Shape | Useful physical form | Important semantics |
|---|---|---|
| Box | Block, plate or support | Optional bounded chamfer; solid volume. |
| Sphere | Ball or atom | Solid round body. |
| Cylinder | Rod, shaft or disk | Local +Y axis; solid volume. |
| Torus | Closed ring | Ring around local +Y, in the XZ plane. |
| Tube | Hollow shell or explained cutaway | Explicit inner/outer radii and bounded angular sweep. |
| Cone | Pointed or truncated taper | Local +Y axis, centered height; nonnegative top/bottom radii, with at least one at least 0.001. |
| Capsule | Rounded rod or body | Local +Y axis; height includes both rounded ends and is at least twice the radius. |
| Lathe | Turned axial outline or explicitly traced vessel | Revolves 2–32 `{radius,y}` contour points through 360 degrees around +Y; supplied Y coordinates remain unchanged. Endpoints close to the axis; equal-Y endpoints close directly as an annular cap. An open vessel needs an explicit outer-wall/rim/inner-wall contour; hollowing is not automatic. |
| Extrusion | Bracket, plate or other planar outline | Fills a simple 3–32 point XY polygon, implicitly closes last to first, and extends from `-depth/2` to `+depth/2` on Z. No holes or 3D bevel field. Optional `cornerRounding` in 0–0.25 rounds XY outline corners with bounded native quadratic samples; zero or omission preserves the exact linear outline. |

Profiles must be finite, simple and nondegenerate. No self-crossing or self-touching outline, repeated closing vertex or unsupported path commands are permitted. Radii are nonnegative; dimensions, coordinate magnitude, tessellation and total native allocation remain bounded by core admission. Prefer 16–32 radial segments and only enough profile points to preserve the silhouette. The prompt preference of at most 48 physical parts and 12 labels is a design target; it does not replace the renderer's aggregate limits.

The wire examples live in [Provider.swift](../Sources/OpenCompanion/Provider.swift). Prompt tests decode every documented primitive example through the native `Geometry3D` decoder and allocation admission. A valid primitive or transaction proves bounded representability, not correct topic geometry.

## Host presentation

The host presentation choices for this slice are an opaque `#101114` tray, a compact 44-point header, native system-medium labels in `#F2F4F8`, and `#CFD5DF` leaders, without a white border. Geometry uses four retained camera-relative lights and physically based materials with roughness 0.42 and metalness 0.08. The renderer configures HDR without automatic exposure, 4× antialiasing, and screen-space ambient occlusion at intensity 0.35, without shadow maps. These are host configuration choices, rather than model-controlled material fields or a claim of photorealism.

The additional lighting, antialiasing and occlusion cost is unmeasured until actual native checks run. Render quality, first geometry latency, CPU/GPU use, frame time and energy need separate verification on the target hardware. A prettier source configuration does not establish smoother rendering or lower model latency.

## Keep the explanation progressive

The default NDJSON path still starts with a brief introduction, then one small useful physical part. Subsequent atomic scene units introduce one coherent feature, including up to eight related new meshes when repeated anatomy needs them, with concise narration and anchored labels. This avoids narrating every repeated segment as a separate step while retaining native aggregate limits. Generate the complete requested lesson in the same response without waiting for playback. Avoid a large design plan before the first geometry.

The opt-in geometry-first and structured formats retain their own startup and envelope rules. They share the visual-design guidance without promoting experimental defaults. Stable IDs, parent/reference validation, document revisions and current-generation cancellation remain authoritative. The host presents each admitted snapshot before its narration, follows actual native speech receipts when available, and uses explicit local text fallback otherwise. The model must not promise acoustic synchronization or physical simulation.

## What establishes improvement

Use unrelated held-out topics that require different silhouettes and connections. Check the requested parts and relationships before judging color or lighting. Independently inspect native geometry and rendered output for proportions, shape, joins, visible labels, occlusion and camera fit; reject unsupported or disconnected assemblies rather than renaming parts to pass. Keep the existing motor, molecule and pendulum checks unchanged where their original contracts apply.

Two additional fixed-public helper cases exercise the new representation. Select `--spatial-scene-case rounded-flask` for a genuinely hollow, bulbous lathe vessel with a fitted torus rim and separate tapered stopper, or `--spatial-scene-case swept-impeller` for four shaped extruded blades joined to a cylindrical hub and distributed around its axis. Their bounded content checks reject solid or thin-lidded vessel impostors, detached rims/blades, coincident blades and rectangles padded with collinear points; their static request requires no animation. These are illustrative geometry tests, not manufacturing or fluid-dynamics validation. The helper still writes the accepted document for an independent native render check. These case definitions are separate from the dated live results below.

Measure first admitted useful geometry and complete-response time separately, with the actual model, effort and output mode recorded. Larger geometry vocabulary and clearer instructions alone establish no latency improvement. A complete protocol response, a rendered image, an illustrative explanation, scientific correctness, physical interaction and measured frame rate are separate outcomes. Dated checks below retain their own source and scope; no general accuracy, performance or reference-parity claim follows.


## Source checkpoint — 8 November 2026

The source passes **950 Swift tests**: 852 app tests across 100 suites, 28 store tests and 70 core tests. Native tests include actual procedural triangle winding/allocation, an open-vessel bore/floor/inner/outer wall, concave profile area under both windings, strict geometry schemas, local two-finger input admission/cancellation and retained renderer identity. One initial full run crashed in Apple's AXSpeech/TextToSpeech worker; an unchanged-source rerun passed 947 tests. Native speech allocation was then made lazy, including complete isolation for injected speech drivers. The resulting 949-test suite passed, followed by the final 950-test suite after the compact-start contract. The crash's precise cause was not established.

Two development public-prompt requests through the actual default NDJSON `gpt-6.1-terra`/low path passed their independent content checks. The flask used lathe/cone/torus with an open narrow neck, fitted rim and separated tapered stopper; the impeller used four shaped extrusions joined to its hub. Before compact-start tuning, first geometry/complete response took 12.934/19.763 seconds and 9.462/23.517 seconds respectively. These samples do **not** establish low cloud latency or an accuracy rate. The compact-start change reduces the requested first payload without changing the model, output mode, transaction validation or later completeness requirements; new timings must be measured separately.

Each generated document also passed a separate native own-window render/label/leader/camera/Clear check. The flask's 120 authored local orbit submissions measured 0.357 ms median and 0.484 ms p95 CPU time. This excludes GPU completion, physical trackpad dispatch, display refresh and the model. Both own-view PNGs were inspected for the new dark tray, legible labels and recognisable shapes. No screenshot of another app or microphone input was used. Clean signed installation, final compact-start provider results and physical two-finger acceptance are recorded separately when verified.


## Compact-start follow-up

The initial signed source `e9c24e6` passed its [exact-source CI](https://github.com/Nithesh8678/opencompanion/actions/runs/42478839479) and independent canonical source/hash/signature/team/cleanup checks. Its installed compact-start flask request passed, with one mesh/no group/no label in the first scene, a 729-byte first scene versus 1,034 bytes in the earlier development sample, and 11.501s first geometry/18.642s completion. Its separate native check passed 49/49 sampled geometry matches, three complete labels and all requested leader surfaces, Clear/teardown and authored camera/gesture tests. Across 120 authored local camera submissions, median/p95 CPU costs were 0.092/0.124 ms; these remain distinct from displayed FPS or physical input latency.

Its next installed impeller request failed after retaining a valid first hub at 7.231s: the model emitted `rotationDegrees:{x:90}` in the second unit. This invalid partial vector was rejected; the protocol/schema was not weakened and missing coordinates were not guessed. The prompt now distinguishes omission of a whole optional identity vector from a present vector, which must include all of `x,y,z`, and supplies a native-decodable example. It also requests a stable overall lesson title. A regression decodes the actual documented example and confirms partial vectors still fail native decoding. The resulting **951-test suite passes** (853 app across 100 suites, 28 store, 70 core). The corrected development impeller request passed the unchanged content/protocol checks. Final follow-up installation and exact-source checks are recorded below when available.


## Installed compact-vector results and cursor rounding follow-up

Signed source `8290ddc` passed [exact-source CI 42479610960](https://github.com/Nithesh8678/opencompanion/actions/runs/42479610960). Independent source/hash/deep-strict-signature/team/single-app/temporary-bundle-cleanup checks passed. The installed executable SHA-256 was `e4d35ac17f9678a0782fd4b54d2cbc463694779f4ff4f240c39079ec1111596b`; the existing local Apple Development identity/team was reused, without notarization.

Three default NDJSON `gpt-6.1-terra`/low public requests passed their unchanged protocol and independent illustrative-geometry checks:

| Public case | First admitted geometry | Provider completion | Result |
|---|---:|---:|---|
| Rounded open flask | 10.470 s | 17.408 s | Lathe vessel, fitted rim and separated stopper; three labels. |
| Four-blade swept impeller | 5.094 s | 19.668 s | Four shaped extrusions joined to a hub; two labels. |
| Water molecule | 6.817 s | 14.908 s | Five meshes, bent arrangement and three labels. |

Their separate native own-window checks passed complete visible labels, independent closest-target leader surfaces before/after camera motion, no label overlap, dark tray/header, bounded Clear, synthetic orbit and teardown. Captures of the generated flask, impeller and water scenes were inspected. Across 120 authored local camera submissions per scene, CPU p95 was 0.112/0.097/0.106 ms respectively; this excludes GPU completion, displayed FPS, physical dispatch and cloud time. These three samples do not establish arbitrary-topic quality or very low latency.

An older narration preflight still expected the former completely click-through canvas and refused before requesting speech; it now checks the actual bounded interactive tray. A development real-synthesis attempt then passed the first stage but exposed a 1.060-point second-stage cursor-tip miss against the existing one-point limit: AppKit had rounded a fractional window frame. Production placement now rebases local body/caption geometry against the accepted native frame and caches requested frames separately. Five pure/native test cases cover positive/negative coordinates, fractional/integral frames and invalid frames. The corrected full suite passes **954 tests** (856 app across 102 suites, 28 store, 70 core). A subsequent speech check refused when both AppKit and Quartz observed pointer movement; its source is unestablished. No full post-fix installed narration pass is claimed at this checkpoint, and the pointer/one-point guards are unchanged.

The user confirmed that the updated two-finger rotation works, but reported that the object was still too basic or inaccurate for “show me the lifecycle of a butterfly visually in 3D.” This confirms the reported gesture result for one interaction, not semantic quality or measured FPS. The butterfly lifecycle is the next quality regression; richer primitives alone did not resolve it.


## Butterfly lifecycle quality regression

The user's exact request, “Show me the lifecycle of a butterfly visually in 3D,” was reproduced through the same default Terra/low NDJSON path. The baseline completed the protocol in 21.396 seconds with first geometry at 7.529 seconds. It contained all four labeled states but only six meshes: an egg, one capsule for the entire caterpillar, a lathe chrysalis and an adult capsule with two flattened sphere wings. A native render confirmed the featureless larva, bow-tie silhouette and absent visible process direction. Readable labels and successful native geometry admission did not establish a good explanation. The first diagnostic reported `unknown-content-fixture` before the dedicated oracle was added; that run is not retroactively called a helper pass.

The shared quality guidance now asks for diagnostic organic anatomy and complete spatial process structure, using the existing bounded geometry. The first real mesh remains compact, no new model call or asset download is introduced, and the same model/effort/output mode is retained. The guidance grew by 790 UTF-8 bytes; this is a prompt-size change, not measured cloud speedup. Notebook prompt snapshots were deliberately updated; conversation and screen-guidance snapshots remain unchanged. Four-stage biology and the two wing pairs are checked against [Florida Museum's lifecycle resource](https://www.floridamuseum.ufl.edu/educators/resource/butterfly-life-cycle/) and [Illinois DNR's butterfly anatomy/life-history resource](https://dnr.illinois.gov/education/wildaboutpages/wildaboutinvertebrates/wildaboutbutterflies.html). The result remains an illustrative educational scene rather than a species-specific anatomical specimen.

The cursor-rounding source separately passed its full two-stage development narration check after the earlier pointer refusal: actual native speech enqueue/start/range/finish callbacks, render-before-speech order, both caption/focus stages, accepted native tip error of zero logical points at both targets, unchanged physical pointer/foreground and stale callback rejection. No microphone/audio recording, acoustic timing, external desktop capture or physical input was used. Installed follow-up results are recorded separately.


The first generic quality revision produced a clearer balanced loop with numbered stages, four native stem/cone arrows, a leaf and lobed extruded wings (16 meshes/four labels). Native label/leader/orbit/Clear checks passed, but visual inspection still found an unsegmented capsule-and-head larva and absent adult head/antennae. First geometry took 7.729 seconds and complete generation 40.538 seconds. The diagnostic preceded the dedicated content-oracle build and therefore reported `unknown-content-fixture`; it is not a lifecycle quality pass. More output increased completion time in this sample and did not itself solve anatomy.

The follow-up permits related repeated anatomy in the same atomic feature unit (up to eight new meshes), preserves the one-mesh startup, and explicitly rejects a featureless tube merely augmented with a head. A generic optional extrusion `cornerRounding` adds a bounded curved outline rather than requiring many model-written vertices or an external mesh-generation service. It rounds each XY corner with fixed quadratic samples, at most 160 outline points from 32 inputs. The resulting contour must remain valid; budgets, meshing and surface candidates use that same contour. Rounding changes attachment roots and clearances, does not add a 3D bevel, and is never applied automatically to old linear geometry. This capability is explicit native data, without organism names, code or remote asset loading. Validation and final model/render results follow separately.


The rounded/anatomy follow-up first failed before geometry: the model emitted one missing object-closing brace in its initial scene line. Strict parsing refused the invalid JSON, retained the valid introduction and published no geometry. This was not a successful scene request. One fresh request with unchanged prompt/model/effort then passed the independent lifecycle oracle: **24 meshes, four anchored stage labels, six progressive scene units**. It included actual repeated larval segments, a tapered lathe chrysalis, four shaped rounded wing extrusions, adult head/antennae and four directed native stem/cone arrows. First admitted geometry was **7.398 seconds**, completion **49.815 seconds**. This is an illustrative quality pass for that request, not a reliability rate or a low cloud-completion-latency claim.

Its separate native check passed four complete labels, all closest-target leader surfaces, zero overlap, 30/30 sampled geometry matches, camera/orbit and Clear/teardown. The final full-resolution PNG was inspected: all four labels are readable and the loop, larval segments, wing pairs and antennae are visible. Progressive prefix previews intentionally contain partial labels and are separate from the final render. The final-check harness is being strengthened to check native glyph layout/pixels for every label, rather than only the first label's pixels.

Independent review also found a small rounded-contour precision gap outside this model sample: a 0.01-unit concave L with 0.001 rounding had cap vertices discarded by the legacy absolute collinearity threshold. Pure arithmetic reproduced three missing vertices and four missing boundary edges. Rounded-only triangulation now preserves every boundary vertex with scale-aware orientation checks and retains nonzero tiny native triangles; original linear behavior remains unchanged. The corrected arithmetic has 30/30 vertices, 28 cap triangles, all outline edges covered and zero cap-area difference. New Core/native regressions and final source checks follow separately.


The final source passes **977 Swift tests**: 872 app across 104 suites, 28 store and 77 core. This includes both Core and actual native cap-boundary/area precision regressions, all 11 fixed-case lifecycle oracle tests (including hidden/padded/misassigned anatomy and misplaced number cues), rounded/unrounded schema compatibility, actual retained glyph complete/clipped cases, existing native orbit/narration/state tests and unchanged conversation/guidance prompt snapshots. The final helper checks complete CoreText-visible UTF-16 layout and native changed pixels for every final label; those diagnostics do not establish OCR or physical scanout. Signed installation, exact-source CI and installed acceptance follow this checkpoint.


## Native visibility-cache follow-up

The first final-source lifecycle render found one unresolved adult-body attachment despite all four resolving in the earlier run. A fresh identical-source retry passed every attachment and all four complete CoreText/pixel label checks. Source and receipts established an early-query cache hazard: initial overlay refresh occurs before ordering the window front, while terminal misses were keyed only by scene/camera state. In the failed receipt, window visibility changed from occluded to visible but the adult miss remained cached (one context, 56 total rays, no pending work).

Window identity, visibility, occlusion and native stage hidden state now participate in cache validation. A real visibility edge schedules one coalesced reconciliation on the existing native display frame, including under Reduce Motion. That frame discards only negative attachment entries before a fresh bounded native query; verified surfaces remain cached. Duplicate visibility notifications do not create repeated retries, and stop/unmount clears pending work. No timer, arbitrary wait, weakened closest-surface check or inferred target is introduced. An initial synchronous requery implementation exposed four assertions in two existing cursor-focus tests; the queued implementation passes them unchanged.

The complete corrected suite passes **980 tests** (875 app across 104 suites, 28 store, 77 core). Three new native component tests cover window binding, native stage hiding, and the same nonactivating window's show/hide transition, retaining exact occluder ownership and zero-ray settled caching. The corrected source's lifecycle native check passes all four verified labels/surfaces, 30/30 geometry samples, zero label overlap, Clear, lifecycle and orbit checks. Its 120 authored local orbit CPU submissions measured 0.599 ms median, 0.828 ms p95 and 1.327 ms maximum; GPU, physical input and displayed FPS remain unmeasured. A separate source narration attempt stopped on the unchanged physical-pointer guard, with the source of motion unestablished; it is not a narration pass. Final signed-source and installed results follow below.
