# Cursor pointing inside generated explanations

Updated 6 November 2026. This is the implementation contract for a narrated cursor visit to a generated scene part. Combined native verification and its limits are recorded below. All 21 end-to-end gates in [the public-feature ledger](HEYCLICKY-PUBLIC-FEATURES.md) remain open.

## Model identity, native coordinates

Normal NDJSON scene units may pair their existing `narration` with optional `focusID`, the exact stable ID of a retained part introduced in that unit or an earlier unit. The model supplies no screenshot coordinate, cursor destination, renderer code or new desktop-action capability.

```json
{"type":"scene","nodes":[{"id":"part","kind":"mesh","fill":"#667788","spatial3D":{"geometry":{"type":"sphere","radius":0.5}}}],"narration":"This is the solid ball.","focusID":"part"}
```

The host first admits the complete atomic scene transaction, then validates the focus reference against that resulting document before canonical publication. A missing focus field adds no pointing behavior. A supplied blank, oversized, missing, group or syntactically hidden/unsupported target is rejected; a semantic label is never converted into a guessed part ID. Identifiers use the existing 256-UTF-8-byte bound. Parent traversal obeys `SceneLimits` and a hard 32-parent bound, with duplicate/missing/cyclic references rejected.

The focus ID travels with the immutable presentation beat. It is released only for that beat's active narration, after the own surface successfully submits the corresponding scene. Separate text units cannot retroactively identify a part. A scene with no narration does not acquire a cursor visit merely by retaining focus metadata. Existing-notebook editor updates do not become queued floating explanation visits.

## Native surface grounding

`RetainedCanvasView` supplies a `SceneFocusProjection`: target and actual surface IDs, document ID/revision, presentation generation, successful-render serial and global AppKit point. The point comes from the mounted own view/window transforms. Backing pixels, model-authored screen coordinates and external desktop evidence are not substituted for that transform.

For a typed 3D mesh, the renderer can reuse a current independently surface-verified label attachment for that same target. Otherwise it performs one bounded focus search: one requested-point ray plus at most 32 analytic surface candidates, **at most 33 focus rays**. Labels receive the remainder of the existing **512-ray per-layout shared budget**. Focus work does not add an unbounded second ray budget. Cached scene/camera/visibility context avoids searches for unchanged text prefixes or pointer movement; a changed native scene/camera revalidates the point.

The nearest actual visible triangle is checked against the requested target; a bounding-box intersection or target-only ray cannot establish visibility through an occluder. An unresolved/occluded point declines the visit while preserving valid geometry and narration. No name-based surface repair occurs.

The initial native projection supports **typed 3D meshes** and **filled 2D rectangles/ellipses** on an eligible 2D-only canvas. Ordinary explanatory text and open paths can be valid scene/focus references at the pure admission layer, but their native pointing projection is currently unsupported and returns no point. The scene remains valid and narration continues. Legacy inferred meshes and anchored 3D text are unsupported focus roles; assembly groups are not fallback targets. Broader role coverage must add a real native visibility implementation rather than guess a center from text or a name.

## Presentation authority and motion

`SceneFocusAuthority` binds:

- The exact floating presentation lease.
- Task generation and narration/beat UUID.
- Document ID and revision.
- Focus node ID plus exact retained target and ordered ancestor snapshots, including material/render properties.

This rejects a same-ID/same-revision replacement, changed ancestry, stale lease, old beat or interrupted generation. Authority is distinct from `ScreenEvidence`: no fabricated screen frame, capture timestamp or freshness TTL is created for an own-scene point. Native occlusion remains a separate current-scene check, including unrelated possible occluders.

The cursor begins its local flight from its last painted pose, then follows subsequent verified native projection callbacks. The model does not stream positions per frame. Reduce Motion uses the current destination directly. Retargeting starts from the current local flight position; it does not jump back to the old origin.

The destination identifies the **glyph tip**, with the shared native glyph defining a **7.5-point horizontal tip offset** from its body center at rest. The visit therefore settles its body at target minus that offset. Scene visits retain the exact anchor even when ordinary follower/glow layout would clamp a frame near a display edge. Caption placement may move outside the explanation panel only if its nearest gap to the 18-by-22-point glyph body stays within **24 logical points**. Otherwise the attached placement remains, even over the transparent host. This prevents a tiny caption from jumping to the far edge of a 620-by-420-point panel; it does not prove avoidance of every painted object or label. Insufficient room never justifies moving the tip away from its verified target.

The cursor stays click-through and cannot become key. Its window level is one level above the floating visual surface. This establishes intended native stacking; independent own-window captures alone do not prove WindowServer compositing or cross-application pixel-level visibility. The actual physical mouse pointer is not moved, clicked or replaced.

## Teardown and retained state

Narration completion, cancellation, Stop, user editing, a new turn, sleep/session loss, display loss and entering orbit revoke the owned visit. An ended visit returns the follower toward the current physical pointer using its local motion state. A stale scoped cancellation cannot remove a newer visit. Projection loss also releases the visit instead of pointing through hidden geometry.

When the cursor reports `hostBoundsUnavailable`, the overlay queues one coalesced reconciliation outside that bounds/render stack. It requires the same narrated focus, presentation lease, generation, beat and exact document authority, a visible own canvas and passive orbit state. End/dismiss cancels pending reconciliation. The canvas invalidates only its publication sentinel and uses the existing cached resolver and finite appearance clock, allowing an identical recovered valid point to be offered again. The cursor keeps no stale pointing pose while unavailable; permanently hidden/occluded targets remain unpointed. This recovery adds no screenshot, provider call, pointer control or unbounded timer polling.

Native speech still follows its typed utterance receipts; local text fallback keeps its own paced completion. Pointing does not become an audio clock. The canonical scene may already contain later accepted steps, but the target always belongs to the currently released immutable snapshot. Ending a visit does not delete that canonical document or mutate its model-authored label hints. See [speech/visual timing](SPEECH-VISUAL-TIMING.md).

## Verified development checkpoint

The pre-caption-fix debug executable has SHA-256 `8e98890bb9f2ca5a4ee8fa58efcf91e48cbf808170741f15565cd36a40204227`. Its full native suite passed **658 Swift tests: 586 app tests across 72 suites, 21 store tests across two suites, 51 core tests across four suites** (`/tmp/opencompanion-scene-focus-final-tests.log`). Focused native panel tests independently converted the generated global point back into the native scene and hit the actual intended triangle; they also exercised filled 2D shapes, occlusion, behind-camera rejection, hidden/zero-alpha targets, native lifecycle, cached reads, and the shared ray budget. These are public authored fixtures, not general model accuracy or physical-user acceptance.

The caption attachment fix at `e752b22119ac6c165cda25b4961c96bcb348f07b` passed **660 Swift tests: 588 app tests across 72 suites, 21 store tests across two suites, 51 core tests across four suites**, log `/tmp/opencompanion-scene-caption-final-tests.log`, debug SHA-256 `545a1fcccb106b1624fde3dd1d410e63d9d444dcf0c954a5a9f660c4e08ac06c`. The added regression cases distinguish a centered caption from a near-edge outside placement, preserve exact tip position, and keep a growing caption on its attached side.

The recovery source passed **665 Swift tests: 593 app tests across 72 suites, 21 store tests across two suites, 51 core tests across four suites**, log `/tmp/opencompanion-focus-recovery-serialized-final-tests.log`, debug SHA-256 `69a7c3aa0ba6c78d13ab50b2855ce978ef62334e771f32d4e7c69b77c79c4d20`. Five added native cases cover identical-point recovery without new focus rays, 100-request coalescing, reentrant recovery on a later native frame, permanent invisibility, Stop and stale generation/beat/lease ownership. All 11 focus-projection tests passed separately. The new async visible fixtures initially passed alone but failed different cases during two full-suite runs while sharing the same floating WindowServer region. Their suite now serializes ownership of that native resource; all assertions and two-second limits remain unchanged. No production tolerance was relaxed to obtain the full-suite pass.

Two separate real default-model requests used normal NDJSON and actual `gpt-5.6-terra`, low effort:

| Public case | Scene / attached narration / focused units | Geometry result | First geometry / provider finish |
| --- | --- | --- | --- |
| Water molecule, earlier debug `920e7ea5` | 3 / 3 / 3 | Passed unchanged independent water checks; two connector units compiled two bonds. | 17.35022 s / 33.06665 s |
| Simple pendulum, debug `8e98890b` | 3 / 3 / 3 | Passed unchanged independent connection/role/static-pose checks; one connector unit compiled one rod. | 21.38729 s / 33.87206 s |

The pendulum's public receipt retains its declared focus IDs `fixed-support`, `pendulum-rod`, `pivot-pin`; their corresponding narration describes those roles. The earlier water trial counted three admitted focus IDs before the later bounded target-ID evidence field existed; it does not retain which IDs were selected. The public results are `/tmp/OpenCompanion-Focus-NDJSON-Water-2026-11-05/water-molecule/result.json` and `/tmp/OpenCompanion-Focus-NDJSON-Pendulum-2026-11-05/simple-pendulum/result.json`. Those provider helpers do not render, play speech, capture a screen or exercise AppModel/physical hotkeys. Their successes are separate from native cursor motion. The trials are not controlled latency comparisons or a broad quality/reliability result.

## Exact signed recovery checkpoint

The single canonical app at `/Applications/OpenCompanion.app` contains clean source **`e8a7278006f87a82a31450ee1276a8bf82d3a533`**, executable SHA-256 **`98d19a294493514c3c1f7cae93af01f9618a12501fda1c58e7ea0cca9044d261`**. Build/install receipts, Info.plist and the independently hashed executable agree. The existing certificate/team `BPR2T4D656` is reused; deep strict signature verification and the designated requirement passed. This is a local arm64 build, not a notarized distribution. Installer cleanup issues are empty; no temporary build/staging app bundles or extra Companion app in Applications remained.

Both exact installed runs passed the unchanged combined authored native check:

| Run | Native submitted-layer tip error, stages 1 / 2 | Native caption/body gap, both stages | Evidence |
| --- | --- | --- | --- |
| 1 | 0.499886 / 0.783001 logical points | 8.485281 points | `/tmp/OpenCompanion-Focus-Recovery-Installed-Run1-2026-11-06/explanation-narration-acceptance.json` |
| 2 | 0.499886 / 0.783001 logical points | 8.485281 points | `/tmp/OpenCompanion-Focus-Recovery-Installed-Run2-2026-11-06/explanation-narration-acceptance.json` |

Errors and gaps remained within their limits both before and after own-window capture. Both runs observed two real synthesis starts/ranges/finishes, matching successful native revisions before speech enqueue, exact full-scene closest-triangle ownership, passive/nonkey stacking, unchanged foreground/physical pointer, retained canonical state and rejected late focus/completion/render replay after Stop. Run two actually recorded stage-two `hostBoundsUnavailable` under the current model owner, followed by successful native arrival and narration completion; this is a recovered observed interruption, not only a manufactured unit-test condition. The first scene finished before the second was released in both runs. These are two small static authored trials, not a reliability rate or acoustic measurement.

The own-view scene and own cursor-window PNGs were inspected: the added box and sphere retain their white labels/leaders, and the short pink caption is close to the red cursor halo rather than detached at the host-panel perimeter. These separate own-window images do not establish desktop compositing or pixel-level reference parity. Raw files remain outside the public repository.

After the helpers, CUA reopened the canonical app normally and initially observed only `org.opencompanion.cursor`, with no Dashboard or Notebook. The user then performed the real Control+Option request “Create a 3D explanation of a water molecule” and reported **“Cursor points at parts; captions stay close.”** This is attributed acceptance of that physical provider/presentation workflow and its visual feel. No prompt-free trace was correlated with that response, so its exact model identity, latency, acoustic alignment, scene semantics and FPS are not independently established. The earlier separate user confirmation that parts/captions follow speech remains in [the timing report](SPEECH-VISUAL-TIMING.md).

Exact-source [CI run 42089257408](https://github.com/Nithesh8678/opencompanion/actions/runs/42089257408) passed native tests, the native release build and protocol checks for installed source `e8a7278006f87a82a31450ee1276a8bf82d3a533`. The later evidence-only documentation commit does not replace that installed executable. No whole-product acceptance row closes from this checkpoint.

## Verification boundary

Focused pure visit-policy tests passed during implementation. Pure authority and visit tests cover exact identities, target/ancestor replacement, bounded input, stale scoped updates, retargeting, glyph-tip anchoring and edge placement. This is not an actual native cursor-arrival result or physical-input acceptance.

The opt-in `--explanation-narration-acceptance OUTPUT` helper uses two public authored scene/narration beats focused on `blue-sphere` and `amber-box`, and requests real synthesis. At each first real range it waits at most three seconds for matching focus authority and a cursor tip within one logical point of the current native surface point. It independently checks the whole-scene closest native triangle, passive/nonkey windows, cursor-above-visual levels, unchanged foreground/physical pointer and rejection of a late visit after Stop.

The exact signed source `0f4ab4ccaf39c147a774ef02d13df5ddefff0063`, installed executable SHA-256 `bc1a506e10b8105ebb19425262a9de690c0f423d3557d3988a78008f3270516a`, passed both stages. Receipt: `/tmp/OpenCompanion-Focus-Installed-Native-2026-11-05/explanation-narration-acceptance.json`. Both sampled layout-tip errors were zero logical points before and after capture; both full-scene triangle hits identified the exact intended part. Native starts/ranges/finishes, render-before-enqueue ordering, passive windows, preserved foreground/real pointer and late replay rejection passed. Exact-source [CI 42083301351](https://github.com/Nithesh8678/opencompanion/actions/runs/42083301351) passed. Visual inspection of its own cursor PNGs found that whole-panel avoidance detached the tiny caption; this led to the bounded caption fix rather than a claim of matching reference feel.

The first exact installed caption-fix run at `e752b22`, executable SHA-256 `aa6a8c74855d907f08b3493c21015f87d3371fc452b19dc36aa481692efd409d`, passed stage one with zero sampled tip error and caption/body gaps of 7.436/8.142 logical points before/after capture, then **failed the stage-two three-second arrival check**. Both visit admissions were observed. The failed receipt remains at `/tmp/OpenCompanion-Focus-Caption-Installed-Native-2026-11-06/explanation-narration-acceptance.json`; its exact-source [CI 42084981502](https://github.com/Nithesh8678/opencompanion/actions/runs/42084981502) passed. A later diagnostic debug run passed both stages without changing the arrival oracle; that pass does not erase the installed failure.

The stronger native-layer check at signed source `ca0759937f53c12d86143dca65be68097c58e08c`, executable SHA-256 `fd0b97912490f3a5a299a124634e76953898d4f509110d48044f4a2b766b268d`, reproduced the stage-two timeout at `/tmp/OpenCompanion-Native-Tip-Installed-Run1-2026-11-06`. Its first stage had **0.499886-point actual submitted-layer tip error** and **8.485281-point native caption/body gap**. At failure the second scene's projection was valid, but the visit had ended and the follower had returned to the physical pointer. A further public debug trace, `/tmp/OpenCompanion-Focus-End-Trace-Debug-2026-11-06`, identified `hostBoundsUnavailable` during stage two while the exact model focus remained current. The projection was briefly unavailable, then returned with the same value; publication equality suppression prevented a new visit. No coordinate or timeout tolerance was relaxed during diagnosis.

The native-layer oracle converts the actual submitted `CAShapeLayer` tip and body bounds through NSView and NSWindow to global AppKit coordinates. This is separate from the coordinator's planned layout position and accounts for native window/frame placement. It still measures model-layer submission, not physical scanout.

The repaired debug executable `69a7c3aa…` passed the combined native helper at `/tmp/OpenCompanion-Focus-Recovery-Debug-2026-11-06`. Its stage-two trace actually contains the same `hostBoundsUnavailable` cancellation followed by successful reoffering and completion under the same current model owner. Both exact visible native surfaces were checked; submitted-layer tip errors were **0.499886 / 0.783001 logical points**, and both native caption/body gaps were **8.485281 points**, before and after capture. Signed recovery-build verification remains separate from this development run.

The helper saves each own-render scene PNG and a ScreenCaptureKit **desktop-independent own cursor-window PNG**, with bounded snapshot waits, focus counts, actual surface IDs, tip errors and speech receipts. These are separate from desktop capture, microphone capture, audio recording, physical mouse input, GPU/scanout verification and acoustic timing. Window levels and passive flags do not prove WindowServer compositing or actual click delivery. The sampled static-target arrivals do not prove continuous tracking during orbit/occlusion; the late Stop replay runs after narration completion and does not establish interruption during an active flight. The first-range captures contain only the prefix “The”, not every rendered word. Model focus selection is tested separately from these authored native fixtures.

The semantic choice of `focusID` is still the model's responsibility. Correct projection of an incorrectly chosen part is not a correct explanation. This slice does not establish arbitrary-concept accuracy, exact HeyClicky choreography, word-exact marks, acoustic synchronization or FPS. It also does not reduce the separate 17–21-second first-geometry waits in the two current public provider trials.

Those receipts locate 0.875–0.939 seconds before turn acceptance, 10.368–13.582 seconds from acceptance to first transport delta, 0.694–1.000 seconds until the introductory unit is admitted, and another 5.349–5.930 seconds until geometry admission. They do not separate queueing, prompt processing, reasoning, network buffering, generation or local complete-line admission. A bounded next experiment is first-scene-first output for new 3D lessons, retaining Terra/low, the same schema/admission and independent quality oracles; the current default still requires an introductory text unit. No six-second saving or model-quality equivalence is promised.

## Source map

- [SceneFocus.swift](../Sources/OpenCompanion/SceneFocus.swift): pure reference validation and immutable presentation authority.
- [ProviderSceneBoundary.swift](../Sources/OpenCompanion/ProviderSceneBoundary.swift), [AppModel.swift](../Sources/OpenCompanion/AppModel.swift) and [ExplanationPlayback.swift](../Sources/OpenCompanion/ExplanationPlayback.swift): atomic admission, narrated beat ownership and canonical/presented separation.
- [SceneFocusProjection.swift](../Sources/OpenCompanion/SceneFocusProjection.swift), [SceneCanvas.swift](../Sources/OpenCompanion/SceneCanvas.swift) and [ExplanationOverlay.swift](../Sources/OpenCompanion/ExplanationOverlay.swift): native surface projection and lease-bound callbacks.
- [SceneCursorVisit.swift](../Sources/OpenCompanion/SceneCursorVisit.swift) and [CursorCompanionCoordinator.swift](../Sources/OpenCompanion/CursorCompanionCoordinator.swift): bounded local flight, exact tip anchoring, stacking and passive return.
- [ExplanationNarrationAcceptance.swift](../Sources/OpenCompanion/ExplanationNarrationAcceptance.swift): bounded combined authored native/synthesis verification and failure receipts.
