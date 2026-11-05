# Explicit Option orbit: implementation and evidence

Updated 5 November 2026. Latest source implements Option-only interaction with a floating typed-3D explanation and passes **556 local Swift tests** (494 app across 63 suites, 21 store, 41 core). The debug native helper also passed. A signed build, canonical replacement and rerun on that signed artifact are pending. The installed `ac38f823`/533-test release remains the earlier passive-overlay checkpoint.

This is an authored interaction choice. The reference recording shows a hand pointer and changing viewpoints, but does not establish its modifier or exact gesture. No exact reference-gesture, FPS, speech-synchronization or physical-input parity is claimed.

## Interaction contract

1. With an explanation visible, hold **Option only** over an actual visible typed mesh. Ordinary pointer use leaves the window passive.
2. The source provides the system open-hand cursor and a small black **⌥ Drag to rotate** cue when armed. A left-button drag uses the native camera controller; the cursor becomes a closed hand and the cue reads **Rotating · release ⌥**.
3. Release the mouse to end the gesture, then release Option to return to the wholly click-through state. Camera inertia is disabled. Orbit changes presentation, not the canonical scene document, transcript or keyboard focus.
4. **Control+Option has voice priority.** It disarms/cancels orbit rather than sharing that gesture. Command, Shift, Function or other active modifiers also prevent Option-only admission. Caps Lock and numeric-pad state do not change that policy.

Arming explicitly reserves the compact **whole native panel**, bounded by the layout's 620 × 420 point maximum. It does **not** promise that clicks through transparent pixels reach another application while armed. A native closest-triangle query decides whether a gesture may begin on visible geometry; an `NSView` hit test is not treated as a cross-application mouse hole. No events are swallowed globally, modified, replayed or reposted. The nonactivating panel cannot become key, and the camera view does not request first-responder status.

The existing Notebook remains the deliberate editing, saving/export and camera-control path. This interaction adds neither object selection/follow-up semantics nor scientific simulation.

## Observation, ownership and cleanup

Production observes modifier flags with a listen-only event tap using existing listen-event/Input Monitoring authorization or already available system trust; it does not prompt for a new grant. If observation is unavailable, authorization is revoked or the tap is lost, orbit stays or becomes passive. Health checks and each fresh native mouse-down recheck existing permission as well as tap availability. Global/local mouse observation supplies current pointer/button state. It does not capture the desktop, harvest AX content or send a model request. Only the app's retained scene is hit-tested.

Authority binds the presentation lease, scene identity, task generation and display. A fresh own mouse-down rechecks actual event modifiers and a visible triangle before beginning. A drag that started under a passive panel cannot be acquired later. Once admitted, the drag can leave the mesh, but current modifiers, authority and availability still govern it. End-of-drag rechecks current geometry; queued events after cancellation cannot continue moving the camera.

Stop/generation changes, document replacement, Clear, sleep/session inactivity, display changes and shutdown revoke ownership, end the native gesture and stop inertia. An old controller cannot arm a renewed presentation. Progressive geometry can refit the camera while preserving an already orbited viewing direction; a new document/generation resets ownership. The bounded Clear control retains its independent presentation lease.

## Verified checkpoint and limits

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| 556 local Swift tests | Pure admission/priority policy, native camera/hit tests, event ordering, cancellation and existing regressions pass. | Signed installation, actual external modifier delivery or human input. |
| Debug own-window helper | Authored down/drag/up calls changed the native camera: one accepted drag, one end, zero cancellations, no inertia, unchanged document and foreground. | WindowServer-delivered dragging; the helper calls its own view directly. |
| Separate authored box/label render | One requested leader passed independent full-scene closest-surface checks before/after that synthetic drag, with glyph/alpha pixels; the rotated box and white label/dot/leader were visually inspected. | Arbitrary scene accuracy or physical drag feel. |
| Lifecycle checks | Synthetic Control+Option/queued-event and generation cancellation, simulated sleep/display change, Clear teardown and closed-controller rejection passed. | Actual sleep, display removal or a physical Clear click. |
| Main loaded-document check | Water's three labels/leaders passed the existing programmatic-camera and native-composite checks. | A real user orbit of that lesson. |

The synthetic helper disables ambient observation. Its tap-enabled state is false and modifier/Option-edge counts are zero by design; these are not permission failures or live-input proof. Receipts explicitly identify authored own-view events, no global input posting, no WindowServer input, no external modifier verification and no human physical input. No provider, desktop capture or audio is used.

The opt-in live helper, `--explanation-orbit-live-acceptance OUTPUT`, waits at most 90 seconds over a public authored box. It requires an external foreground baseline, an available live tap, Option press/release edges, native begin/drag/end counts, camera movement, actual Option/mouse release, passive ownership and unchanged foreground/document. It posts no input. **This live path has not passed an external interaction check.** The CUA documentation did not explicitly authorize overlapping a duration-held modifier and drag, so unsupported overlapping calls were not attempted.

## Remaining manual acceptance

Use a public practice application as the foreground app. Place the pointer over the explanation, hold Option, drag a short distance, release the mouse and then Option. Check the cue/cursor, actual viewpoint and leader movement, unchanged foreground/keyboard focus, absence of inertia and return to passive click-through. Then check Control+Option priority, Stop during a drag, replacement/Clear, and actual sleep/display/Spaces behavior separately. The helper's native event/edge receipts must corroborate an external event test; command invocation alone is insufficient.

CUA-delivered events, if later supported and tested, remain distinct from human physical input. Exact reference feel, arbitrary concepts, part selection/follow-up, parameter editing, speech alignment, latency distributions and full product parity remain open. The P1 interactive-object gate in the [public feature ledger](HEYCLICKY-PUBLIC-FEATURES.md) stays unchecked. See [explanation evidence](EXPLANATION-OVERLAY.md) and [feature status](FEATURE-STATUS.md).
