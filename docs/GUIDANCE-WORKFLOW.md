# Guidance workflow implementation

This checkpoint follows the user-supplied `MASTER-BUILD-PROMPT.txt` and `WORKFLOW-REPORT.txt`, read on 6 November 2026. They describe an independent reconstruction and separate recovered artifact behavior, vendor claims and proposed acceptance goals. They are not copied into this repository. Existing voice, capture, notebook, history and signing boundaries remain in use.

## Current implementation

- A versioned semantic workflow keeps the original goal, up to 15 offered actions, observed click/Continue events and bounded screen-check assessments. A click is never stored as proof of success.
- Up to 46 checks permit initial perception, two additional checks per action context, and final verification. These are authored resource limits, not recovered vendor constants. The native 15-second admission freshness, 45-second mark lifetime and 180-second active-request limit remain independent.
- Pause revokes runtime ownership and cancels current capture, response, speech and marks. Resume/Recheck creates a new request/check and uses fresh current-screen capture. Saved progress contains no screenshot, frame/candidate ID, PID, coordinates, generation, lease or usable deadline.
- Native Home and both Chat surfaces share a compact progress card. It exposes Pause, Resume, Recheck and Stop without opening Notebook or changing hover-only notch presentation. Model-reported completion is explicitly distinguished from independent verification.
- The optional bounded `guidanceStatus` unit distinguishes progress, unchanged, loading, uncertainty and model-reported completion. Existing target and text units remain supported. Loading can request bounded fresh checks while the same foreground/evidence/request still owns the task; it performs no input and never repeats an action automatically.
- Supporting marks remain native and retained. An optional assessment from an old model-input frame cannot be relabeled as current after a target has been independently re-grounded. State/content validation precedes primary visual admission.
- SQLite v5 adds guidance tombstones. Dedicated insert-only creation and exact-record CAS updates prevent stale writers from resurrecting or overwriting a deleted guide. Restore reads the latest payload and leaves it paused; opening history never captures or rearms a saved target.

The planner receives a bounded semantic progress projection, rather than an unlimited transcript. Its contents remain reference material, not screen authority. A model assessment does not invoke the host-only independent-verification path.

## Physical evidence preserved before this checkpoint

Installed source `5f03d9b` produced two distinct later checks on the public in-memory fixture:

1. `yY70EL` admitted a manual field step, retained its mark through cursor return, accepted Continue once and captured the changed screen. Three native mark checkpoints passed. At 28,813.922 ms the combined fixture/display guard failed while the next model turn was pending. The user reported staying in the fixture on the same screen. The earlier diagnostic did not distinguish its three guard predicates, so no focus-stealing or pointer cause is claimed.
2. `SjmAUA` passed all five native mark checkpoints, including the next checkbox mark after cursor return. Continue and a target click were each observed once. The independent AX postcondition still found Protect data enabled, so the task failed with `checkboxNotOff`. This is retained as a failed task, not a completion. The helper performed no checkbox input.

A separate invisible native component probe found that the fixture's 240-point checkbox frame included non-trackable blank trailing space: the box and label were trackable, while the frame center and trailing area were not. No input was posted and no window displayed. The actual failed run did not record click coordinates, so this is a demonstrated geometry weakness, not a proven explanation for that click. The guidance prompt now asks for the visible checkbox/radio/switch indicator or label, using image bounds when an AX layout frame includes blank padding.

Private traces, own-view rasters and probe receipts remain outside the public repository. Native model-layer raster checks, WindowServer metadata, physical input and external-task completion are distinct evidence classes.

## Validation and remaining requirements

Final-source local validation passed **817 Swift tests**: 724 app tests across 85 suites, 28 store tests across three suites and 65 core tests across five suites. Review added assessment-order, stale-assessment, restore/delete and AppModel integration regressions, including preservation of a newer active token when an old restore is stale or cancelled. Fresh assessments also require the captured foreground app to remain current. An initial full run found the intentionally changed guidance prompt snapshot; its expected hash was updated after confirming the previous prompt hash independently. The final full run exited 0. These tests use bounded fixtures and do not establish physical task completion, acoustic latency or reference parity. Signed installation and exact-source CI will be recorded after execution.

This checkpoint does not complete the supplied specification. Remaining acceptance includes:

- A successful real-browser three-step walkthrough and native-app result, with fresh postconditions, wrong-click/no-effect recovery and slow loading.
- Hover-specific interaction/tooltip verification and the broader typed event envelope, sequence/deduplication and annotation vocabulary described in the supplied protocol.
- Material scroll/navigation/window-layout invalidation during inference and while a mark waits, across mixed-scale displays and Spaces.
- Guidance-specific speech-beat/mark alignment from actual playback callbacks, interruption and audio-route/device cases. Local draw timing is not acoustic evidence.
- At least 30 warm trials per declared profile, separate cold/failure cases, accuracy/success rate and release-to-useful-output P50/P95. The supplied latency values are goals; none is presented as a measured vendor promise or current result.
- Held-out cross-app acceptance, permission denial/recovery, first-word preservation and complete accessibility/keyboard alternatives.

All whole-product parity gates remain open. The source/build/runtime boundaries in this report must be updated from actual evidence rather than inferred from test names or a green build.
