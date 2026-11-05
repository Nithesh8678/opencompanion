# Cursor pointing inside generated explanations

Updated 5 November 2026. This is the implementation contract for a narrated cursor visit to a generated scene part. The combined native acceptance run is pending. All 21 end-to-end gates in [the public-feature ledger](HEYCLICKY-PUBLIC-FEATURES.md) remain open.

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

Native speech still follows its typed utterance receipts; local text fallback keeps its own paced completion. Pointing does not become an audio clock. The canonical scene may already contain later accepted steps, but the target always belongs to the currently released immutable snapshot. Ending a visit does not delete that canonical document or mutate its model-authored label hints. See [speech/visual timing](SPEECH-VISUAL-TIMING.md).

## Verified development checkpoint

The frozen working-source debug executable has SHA-256 `8e98890bb9f2ca5a4ee8fa58efcf91e48cbf808170741f15565cd36a40204227`. The full native suite passed **658 Swift tests: 586 app tests across 72 suites, 21 store tests across two suites, 51 core tests across four suites** (`/tmp/opencompanion-scene-focus-final-tests.log`). Focused native panel tests independently converted the generated global point back into the native scene and hit the actual intended triangle; they also exercised filled 2D shapes, occlusion, behind-camera rejection, hidden/zero-alpha targets, native lifecycle, cached reads, and the shared ray budget. These are public authored fixtures, not general model accuracy or physical-user acceptance.

Two separate real default-model requests used normal NDJSON and actual `gpt-5.6-terra`, low effort:

| Public case | Scene / attached narration / focused units | Geometry result | First geometry / provider finish |
| --- | --- | --- | --- |
| Water molecule, earlier debug `920e7ea5` | 3 / 3 / 3 | Passed unchanged independent water checks; two connector units compiled two bonds. | 17.35022 s / 33.06665 s |
| Simple pendulum, debug `8e98890b` | 3 / 3 / 3 | Passed unchanged independent connection/role/static-pose checks; one connector unit compiled one rod. | 21.38729 s / 33.87206 s |

The pendulum's public receipt retains its declared focus IDs `fixed-support`, `pendulum-rod`, `pivot-pin`; their corresponding narration describes those roles. The earlier water trial counted three admitted focus IDs before the later bounded target-ID evidence field existed; it does not retain which IDs were selected. The public results are `/tmp/OpenCompanion-Focus-NDJSON-Water-2026-11-05/water-molecule/result.json` and `/tmp/OpenCompanion-Focus-NDJSON-Pendulum-2026-11-05/simple-pendulum/result.json`. Those provider helpers do not render, play speech, capture a screen or exercise AppModel/physical hotkeys. Their successes are separate from native cursor motion. The trials are not controlled latency comparisons or a broad quality/reliability result.

## Verification boundary

Focused pure visit-policy tests passed during implementation. Pure authority and visit tests cover exact identities, target/ancestor replacement, bounded input, stale scoped updates, retargeting, glyph-tip anchoring and edge placement. This is not an actual native cursor-arrival result or physical-input acceptance.

The extended opt-in `--explanation-narration-acceptance OUTPUT` helper is prepared for the combined native check. It uses two public authored scene/narration beats focused on `blue-sphere` and `amber-box`, and requests real synthesis. At each first real range it waits at most three seconds for matching focus authority and a cursor tip within one logical point of the current native surface point. It independently checks the whole-scene closest native triangle, passive/nonkey windows, cursor-above-visual levels, unchanged foreground/physical pointer and rejection of a late visit after Stop.

The helper will save each own-render scene PNG and a ScreenCaptureKit **desktop-independent own cursor-window PNG**, with bounded snapshot waits, focus counts, actual surface IDs, tip errors and speech receipts. These are separate from desktop capture, microphone capture, audio recording, physical mouse input, GPU/scanout verification and acoustic timing. Its result must remain pending until the actual native run and image inspection complete; no combined pass is claimed here.

The semantic choice of `focusID` is still the model's responsibility. Correct projection of an incorrectly chosen part is not a correct explanation. This slice does not establish arbitrary-concept accuracy, exact HeyClicky choreography, word-exact marks, acoustic synchronization or FPS. It also does not reduce the separate roughly 20-second first-geometry wait observed in an earlier default-provider trial.

## Source map

- [SceneFocus.swift](../Sources/OpenCompanion/SceneFocus.swift): pure reference validation and immutable presentation authority.
- [ProviderSceneBoundary.swift](../Sources/OpenCompanion/ProviderSceneBoundary.swift), [AppModel.swift](../Sources/OpenCompanion/AppModel.swift) and [ExplanationPlayback.swift](../Sources/OpenCompanion/ExplanationPlayback.swift): atomic admission, narrated beat ownership and canonical/presented separation.
- [SceneFocusProjection.swift](../Sources/OpenCompanion/SceneFocusProjection.swift), [SceneCanvas.swift](../Sources/OpenCompanion/SceneCanvas.swift) and [ExplanationOverlay.swift](../Sources/OpenCompanion/ExplanationOverlay.swift): native surface projection and lease-bound callbacks.
- [SceneCursorVisit.swift](../Sources/OpenCompanion/SceneCursorVisit.swift) and [CursorCompanionCoordinator.swift](../Sources/OpenCompanion/CursorCompanionCoordinator.swift): bounded local flight, exact tip anchoring, stacking and passive return.
- [ExplanationNarrationAcceptance.swift](../Sources/OpenCompanion/ExplanationNarrationAcceptance.swift): pending combined authored native/synthesis verification.
