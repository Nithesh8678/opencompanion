# Guidance scene invalidation

This source checkpoint adds active-task metadata invalidation to the [guidance workflow](GUIDANCE-WORKFLOW.md). It addresses foreground-app changes and in-scope scrolling during preparation, inference and waiting for user action. It does not establish complete screen freshness, native event delivery or reference parity.

## Current behavior

- `GuidanceSceneObserver` is armed only for an explicit screen-guidance turn. Its ephemeral scope contains a fresh lease ID, task generation, foreground PID and global logical source rectangle. These values are not saved as resumable workflow authority.
- Observation is armed **before** asynchronous focus preparation or capture. Automatic guidance chooses its source display and rectangle before that first suspension; moving the pointer afterward cannot silently move the request to another display. Deliberately selected window/region evidence retains its original scope during preparation and any permitted late-target recapture.
- App activation uses the PID recorded in the notification, rather than a later foreground sample. An observed A → B → A transition therefore revokes A's original lease even if A becomes foreground again before a model result arrives. Same-PID notifications do not invalidate the lease.
- Scroll observation accepts only finite, nonzero deltas with an event location inside the armed source rectangle and the expected foreground PID. It excludes local events belonging to an assistant window. Missing locations, unrelated PIDs, out-of-scope points and nonfinite metadata do not authorize a change. A relevant scroll event is a conservative invalidation signal, not proof of how far content moved.
- Revocation removes monitors and clears the old observer scope **before** invoking the host. Queued callbacks retain their installed lease ID and cannot invalidate a replacement lease. Rearming inside a callback preserves the new owner.

The observer reads event metadata. It does not capture screenshots, inspect Accessibility content, call a model, simulate input or forward events. Ordinary key presses, caret changes and field-value changes are not observed, so typing alone does not revoke a waiting manual field step. Failure to install the required native monitors refuses the guidance observation instead of reporting it as installed.

## Host ownership and capture scope

AppModel accepts an invalidation only when the observer's lease and generation still match its active screen-guidance scope. It then cancels the active turn and loading task, advances cancellation/publication authority, removes old evidence and marks, and pauses saved semantic progress. Coordinator and cursor ownership are revoked through the existing cancellation path. A late model response or capture completion cannot restore the invalidated frame.

Selected capture publication also checks the actual `CapturePublicationGate` token and task cancellation before assigning evidence or manual-selection provenance. A stale capture cannot restore that provenance or clear a newer invalidation.

When a manually selected screen context becomes invalid, typed guidance refuses to fall back silently to a fresh full-display capture. The UI asks the user to recapture the chosen window/region or remove screen context before requesting current-screen guidance. Removing context or successfully publishing a newly selected capture clears that refusal. This is a widening refusal, not automatic reconstruction of an invalid crop or a promise to preserve arbitrary old drawing coordinates. Saved workflow progress remains semantic; it supplies no screenshot, candidate ID or live target lease.

Stop, failure and new-turn cancellation disarm observation. A completed provider response with no accepted target also disarms it unless bounded loading checks still own the task. Observation has a deadline no later than the existing **180-second active-request limit**; expiry revokes the scope and requests a fresh check. Existing mark deadlines remain separate and are not extended. Display-arrangement changes use the same revocation path. The older general workspace activation callback now handles its recorded event on the main queue, avoiding a deferred old callback clearing a newer guide.

The observer itself performs no retry or recapture. Existing deliberate Continue/click continuation and bounded loading-check behavior remain separate. The voice protocol, no-Notebook route and prohibition on automatic desktop input are unchanged.

## Evidence at this checkpoint

| Check | Scope and status |
|---|---|
| Initial focused run | **60 tests passed**, including direct metadata reducer and AppModel ownership/publication fixtures. |
| Earlier full run | **834 tests passed before** the final display-change and ordered-workspace-callback refinements. This is not a final-source full-suite result. |
| Final full suite | **834 tests passed**: 741 application tests across 87 suites, 28 store tests and 65 core tests. The run includes the display-change and ordered-workspace-callback refinements and exited 0. |
| New signed build and canonical installation | Pending at this write. Earlier installed workflow evidence is documented separately. |
| Native OS event delivery and physical workflow | Pending; tests with `observeSystemEvents: false` do not prove installed monitor delivery. |

The scoped tests cover one-shot A → B → A invalidation, same-PID stability, scroll filtering, negative display origins, disarm/rearm, stale queued leases, callback reentrancy and malformed geometry. Host tests exercise cancellation and publication authority using authored data. They do not establish a successful external task, acoustic timing, WindowServer visibility or a latency distribution.

## Remaining limits

- Same-PID window switches, movement/resize, navigation and programmatic reflow are not detected by this observer. It does not yet implement a native focused-window/layout observer.
- Changes to a selected frame **before observation is armed** can remain undetected while the frame is still inside the existing 15-second admission window. A recent timestamp alone is not proof of unchanged content.
- A future window observer must preserve the intended target mouse-down → menu/window transition → mouse-up sequence without admitting stale geometry or losing a legitimate fresh-capture continuation. This checkpoint does not solve that ordering problem by inferring success.
- Native monitor availability, actual event ordering, permission changes, mixed-scale displays, Spaces and physical interactions still need installed acceptance. A source rectangle and event filter do not prove all app content changes were observed.
- Full multi-step task completion, wrong-click/no-effect recovery, general unfamiliar-app success, low latency and HeyClicky parity remain unproven.

All **21 whole-product parity gates remain open**. The priority remains a correct closed loop with fresh evidence and a verified external result; this metadata safeguard does not close that workflow gate by itself.
