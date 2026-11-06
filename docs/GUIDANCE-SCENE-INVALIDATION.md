# Guidance scene invalidation

This source checkpoint adds active-task metadata invalidation to the [guidance workflow](GUIDANCE-WORKFLOW.md). It addresses foreground-app changes and in-scope scrolling during preparation, inference and waiting for user action. It does not establish complete screen freshness or reference parity. One bounded native foreground-event delivery check is recorded below.

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
| New signed build and canonical installation | Clean signed source `544c518d667f98ebb8a37234d9ce14ad7a29f6c8` is installed at the single canonical `/Applications/OpenCompanion.app`. Independent source/hash/strict deep signature/team/cleanup checks passed. |
| Exact-source CI | [42211131014](https://github.com/Nithesh8678/opencompanion/actions/runs/42211131014) passed native tests/build and protocol checks. |
| Native OS event delivery | One real foreground activation reached the exact observer source in an isolated native component check. Scope, generation and lease matched; monitors were installed and the foreground changed from the public fixture. This is not an installed AppModel/full-workflow run. |
| Full physical guidance workflow | Pending. The metadata fixtures and the component check do not prove an external task completed. |

The scoped tests cover one-shot A → B → A invalidation, same-PID stability, scroll filtering, negative display origins, disarm/rearm, stale queued leases, callback reentrancy and malformed geometry. Host tests exercise cancellation and publication authority using authored data. They do not establish a successful external task, acoustic timing, WindowServer visibility or a latency distribution.

## Installation and native component boundary

The exact installed executable SHA-256 is `feef7c9198f1e2e51608be827ab3daca58b9e55554b45d5755f8b356ca677bd1`. Build/install receipts and Info.plist agree on source `544c518`; strict deep certificate verification and retained team `BPR2T4D656` pass. Temporary build/staging app bundles are absent, and the installer reports no cleanup issues. The repository is public and the installed-source commit is pushed.

The standalone check compiled the unchanged production `GuidanceSceneObserver.swift` (SHA-256 `bf00b4858a9b4970a46b75e3dfa1733324e02a621062f50cb15eed5b7152299a`) plus a dependency shim copying the existing coordinate conversion. It created no windows and stayed prohibited from activation. It scoped observation to the public Guidance Fixture, read native notification/event metadata and wrote bounded private receipts. It captured no screenshot, called no model, used no audio and posted no input. CUA performed the deliberate fixture-close UI action.

The first wrapper refused at its activation-policy initialization before arming. The corrected wrapper confirmed its already-prohibited policy and installed all monitors, but its first 20-second run timed out while the Mac was locked before the UI trigger. Those results are preserved separately. After the user unlocked, a fresh run received `foregroundChanged` with matching lease/generation/source and a changed foreground. Its 7,089.477 ms elapsed time includes time waiting for the CUA fixture-close action; it is **not** notification latency or a guidance latency benchmark.

This validates one real notification through the exact observer class outside the app bundle. AppModel cancellation/publication remains covered by the authored integration tests. Their combination does not establish native scroll delivery, all installed-host event ordering, menu transitions, the complete task or HeyClicky parity.

## Remaining limits

- Same-PID window switches, movement/resize, navigation and programmatic reflow are not detected by this observer. It does not yet implement a native focused-window/layout observer.
- At this historical observer checkpoint, changes before observation was armed could remain undetected within the 15-second admission window. The later [selected-evidence refresh](GUIDANCE-SELECTED-FRESHNESS.md) replaces selected pixels in exactly the original scope before provider input. Changes during inference/waiting, same-PID layout changes and native metadata/capture races remain open; a recent timestamp alone is not proof of unchanged content.
- A future window observer must preserve the intended target mouse-down → menu/window transition → mouse-up sequence without admitting stale geometry or losing a legitimate fresh-capture continuation. This checkpoint does not solve that ordering problem by inferring success.
- Broader native monitor availability, actual scroll delivery, installed-host event ordering, permission changes, mixed-scale displays, Spaces and physical interactions still need acceptance. A source rectangle and event filter do not prove all app content changes were observed.
- Full multi-step task completion, wrong-click/no-effect recovery, general unfamiliar-app success, low latency and HeyClicky parity remain unproven.

All **21 whole-product parity gates remain open**. The priority remains a correct closed loop with fresh evidence and a verified external result; this metadata safeguard does not close that workflow gate by itself.
