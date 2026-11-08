# Native 3D visual quality

The generator should build a recognisable explanation of the requested topic: a coherent silhouette, useful proportions, physically meaningful connections, and short labels on the actual parts. More primitives or a larger JSON response do not establish better quality. This guideline accompanies the bounded native geometry extension; it is a design and admission contract, not a claim that arbitrary generated models are accurate or match HeyClicky.

## Design the explanation

Choose a small set of parts that explains the requested relationship. Identify its main axis, characteristic outer outline, and the points where parts meet. A rounded body, taper, curved turned housing or L-shaped bracket should use a suitable supported shape. Repeated cylinders and boxes remain useful for rods and blocks; the selection follows the physical form rather than a fixed template.

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
| Extrusion | Bracket, plate or other planar outline | Fills a simple 3–32 point XY polygon, implicitly closes last to first, and extends from `-depth/2` to `+depth/2` on Z. No holes or bevel field in this slice. |

Profiles must be finite, simple and nondegenerate. No self-crossing or self-touching outline, repeated closing vertex or unsupported path commands are permitted. Radii are nonnegative; dimensions, coordinate magnitude, tessellation and total native allocation remain bounded by core admission. Prefer 16–32 radial segments and only enough profile points to preserve the silhouette. The prompt preference of at most 48 physical parts and 12 labels is a design target; it does not replace the renderer's aggregate limits.

The wire examples live in [Provider.swift](../Sources/OpenCompanion/Provider.swift). Prompt tests decode every documented primitive example through the native `Geometry3D` decoder and allocation admission. A valid primitive or transaction proves bounded representability, not correct topic geometry.

## Host presentation

The host presentation choices for this slice are an opaque `#101114` tray, a compact 44-point header, native system-medium labels in `#F2F4F8`, and `#CFD5DF` leaders, without a white border. Geometry uses four retained camera-relative lights and physically based materials with roughness 0.42 and metalness 0.08. The renderer configures HDR without automatic exposure, 4× antialiasing, and screen-space ambient occlusion at intensity 0.35, without shadow maps. These are host configuration choices, rather than model-controlled material fields or a claim of photorealism.

The additional lighting, antialiasing and occlusion cost is unmeasured until actual native checks run. Render quality, first geometry latency, CPU/GPU use, frame time and energy need separate verification on the target hardware. A prettier source configuration does not establish smoother rendering or lower model latency.

## Keep the explanation progressive

The default NDJSON path still starts with a brief introduction, then one small useful physical part. Subsequent atomic scene units add one to three parts with their narration and anchored labels. Generate the complete requested lesson in the same response without waiting for playback. Avoid a large design plan before the first geometry.

The opt-in geometry-first and structured formats retain their own startup and envelope rules. They share the visual-design guidance without promoting experimental defaults. Stable IDs, parent/reference validation, document revisions and current-generation cancellation remain authoritative. The host presents each admitted snapshot before its narration, follows actual native speech receipts when available, and uses explicit local text fallback otherwise. The model must not promise acoustic synchronization or physical simulation.

## What establishes improvement

Use unrelated held-out topics that require different silhouettes and connections. Check the requested parts and relationships before judging color or lighting. Independently inspect native geometry and rendered output for proportions, shape, joins, visible labels, occlusion and camera fit; reject unsupported or disconnected assemblies rather than renaming parts to pass. Keep the existing motor, molecule and pendulum checks unchanged where their original contracts apply.

Two additional fixed-public helper cases exercise the new representation. Select `--spatial-scene-case rounded-flask` for a genuinely hollow, bulbous lathe vessel with a fitted torus rim and separate tapered stopper, or `--spatial-scene-case swept-impeller` for four shaped extruded blades joined to a cylindrical hub and distributed around its axis. Their bounded content checks reject solid or thin-lidded vessel impostors, detached rims/blades, coincident blades and rectangles padded with collinear points; their static request requires no animation. These are illustrative geometry tests, not manufacturing or fluid-dynamics validation. The helper still writes the accepted document for an independent native render check. No live result for either new case is claimed here.

Measure first admitted useful geometry and complete-response time separately, with the actual model, effort and output mode recorded. Larger geometry vocabulary and clearer instructions alone establish no latency improvement. A complete protocol response, a rendered image, an illustrative explanation, scientific correctness, physical interaction and measured frame rate are separate outcomes. No new live, installed, accuracy, performance or reference-parity result is claimed by this document.


## Source checkpoint — 8 November 2026

The source passes **950 Swift tests**: 852 app tests across 100 suites, 28 store tests and 70 core tests. Native tests include actual procedural triangle winding/allocation, an open-vessel bore/floor/inner/outer wall, concave profile area under both windings, strict geometry schemas, local two-finger input admission/cancellation and retained renderer identity. One initial full run crashed in Apple's AXSpeech/TextToSpeech worker; an unchanged-source rerun passed 947 tests. Native speech allocation was then made lazy, including complete isolation for injected speech drivers. The resulting 949-test suite passed, followed by the final 950-test suite after the compact-start contract. The crash's precise cause was not established.

Two development public-prompt requests through the actual default NDJSON `gpt-6.1-terra`/low path passed their independent content checks. The flask used lathe/cone/torus with an open narrow neck, fitted rim and separated tapered stopper; the impeller used four shaped extrusions joined to its hub. Before compact-start tuning, first geometry/complete response took 12.934/19.763 seconds and 9.462/23.517 seconds respectively. These samples do **not** establish low cloud latency or an accuracy rate. The compact-start change reduces the requested first payload without changing the model, output mode, transaction validation or later completeness requirements; new timings must be measured separately.

Each generated document also passed a separate native own-window render/label/leader/camera/Clear check. The flask's 120 authored local orbit submissions measured 0.357 ms median and 0.484 ms p95 CPU time. This excludes GPU completion, physical trackpad dispatch, display refresh and the model. Both own-view PNGs were inspected for the new dark tray, legible labels and recognisable shapes. No screenshot of another app or microphone input was used. Clean signed installation, final compact-start provider results and physical two-finger acceptance are recorded separately when verified.


## Compact-start follow-up

The initial signed source `e9c24e6` passed its [exact-source CI](https://github.com/Nithesh8678/opencompanion/actions/runs/42478839479) and independent canonical source/hash/signature/team/cleanup checks. Its installed compact-start flask request passed, with one mesh/no group/no label in the first scene, a729-byte first scene versus1,034 bytes in the earlier development sample, and11.501s first geometry/18.642s completion. Its separate native check passed49/49 sampled geometry matches, three complete labels and all requested leader surfaces, Clear/teardown and authored camera/gesture tests. Across120 authored local camera submissions, median/p95 CPU costs were0.092/0.124ms; these remain distinct from displayed FPS or physical input latency.

Its next installed impeller request failed after retaining a valid first hub at7.231s: the model emitted `rotationDegrees:{x:90}` in the second unit. This invalid partial vector was rejected; the protocol/schema was not weakened and missing coordinates were not guessed. The prompt now distinguishes omission of a whole optional identity vector from a present vector, which must include all of `x,y,z`, and supplies a native-decodable example. It also requests a stable overall lesson title. A regression decodes the actual documented example and confirms partial vectors still fail native decoding. The resulting **951-test suite passes** (853 app across100 suites,28 store,70 core). The corrected development impeller request passed the unchanged content/protocol checks. Final follow-up installation and exact-source checks are recorded below when available.
