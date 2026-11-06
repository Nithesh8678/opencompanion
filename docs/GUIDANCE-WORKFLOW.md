# Guidance workflow implementation

This checkpoint follows the user-supplied `MASTER-BUILD-PROMPT.txt` and `WORKFLOW-REPORT.txt`, read on 6 November 2026. They describe an independent reconstruction and separate recovered artifact behavior, vendor claims and proposed acceptance goals. They are not copied into this repository. Existing voice, capture, notebook, history and signing boundaries remain in use.

## Current implementation

- A versioned semantic workflow keeps the original goal, up to 15 offered actions, observed click/Continue events and bounded screen-check assessments. A click is never stored as proof of success.
- Up to 46 checks permit initial perception, two additional checks per action context, and final verification. These are authored resource limits, not recovered vendor constants. The native 15-second admission freshness, 45-second mark lifetime and 180-second active-request limit remain independent.
- Pause revokes runtime ownership and cancels current capture, response, speech and marks. Resume/Recheck creates a new request/check and uses fresh current-screen capture. Saved progress contains no screenshot, frame/candidate ID, PID, coordinates, generation, lease or usable deadline.
- Native Home and both Chat surfaces share a compact progress card. It exposes Pause, Resume, Recheck and Stop without opening Notebook or changing hover-only notch presentation. Model-reported completion is explicitly distinguished from independent verification.
- The optional bounded `guidanceStatus` unit distinguishes progress, unchanged, loading, uncertainty and model-reported completion. Existing target and text units remain supported. Loading can request bounded fresh checks while the same foreground/evidence/request still owns the task; it performs no input and never repeats an action automatically.
- Active-scene metadata invalidation now revokes old inference and marks after an app activation round trip, in-scope scrolling or display topology change, retaining semantic progress and preventing typed selected-scope widening. [Current source, verification and limits](GUIDANCE-SCENE-INVALIDATION.md).
- Selected typed guidance now obtains one fresh image and semantic context in the original display/window/region before provider input, with exact scope and publication ownership. This replaces recent selected-frame reuse; it does not establish selected-scope continuous multi-step acceptance. [Contract and verification](GUIDANCE-SELECTED-FRESHNESS.md).
- Supporting marks remain native and retained. An optional assessment from an old model-input frame cannot be relabeled as current after a target has been independently re-grounded. State/content validation precedes primary visual admission.
- SQLite v5 adds guidance tombstones. Dedicated insert-only creation and exact-record CAS updates prevent stale writers from resurrecting or overwriting a deleted guide. Restore reads the latest payload and leaves it paused; opening history never captures or rearms a saved target.

The planner receives a bounded semantic progress projection, rather than an unlimited transcript. Its contents remain reference material, not screen authority. A model assessment does not invoke the host-only independent-verification path.

## Physical evidence preserved before this checkpoint

Installed source `5f03d9b` produced two distinct later checks on the public in-memory fixture:

1. `yY70EL` admitted a manual field step, retained its mark through cursor return, accepted Continue once and captured the changed screen. Three native mark checkpoints passed. At 28,813.922 ms the combined fixture/display guard failed while the next model turn was pending. The user reported staying in the fixture on the same screen. The earlier diagnostic did not distinguish its three guard predicates, so no focus-stealing or pointer cause is claimed.
2. `SjmAUA` passed all five native mark checkpoints, including the next checkbox mark after cursor return. Continue and a target click were each observed once. The independent AX postcondition still found Protect data enabled, so the task failed with `checkboxNotOff`. This is retained as a failed task, not a completion. The helper performed no checkbox input.

A separate invisible native component probe found that the fixture's 240-point checkbox frame included non-trackable blank trailing space: the box and label were trackable, while the frame center and trailing area were not. No input was posted and no window displayed. The actual failed run did not record click coordinates, so this is a demonstrated geometry weakness, not a proven explanation for that click. The guidance prompt now asks for the visible checkbox/radio/switch indicator or label, using image bounds when an AX layout frame includes blank padding.

Private traces, own-view rasters and probe receipts remain outside the public repository. Native model-layer raster checks, WindowServer metadata, physical input and external-task completion are distinct evidence classes.

## Installed workflow attempts

Three fresh public-fixture attempts used installed `e1a915b`; the first two reached actual `gpt-6.1-terra` at low effort:

- `v4pT1n` passed permission/foreground/full-coverage preflight and accepted one production capture. Its first model target was an ungrounded-for-this-task click instead of the required waiting typing field. The strict verifier refused at 6,348.240 ms before any manual continuation, native mark checkpoint or task input. No specific model/capture cause is established.
- `7Qhr23` admitted the correct manual field step and passed its initial and after-cursor-return native mark checkpoints. CUA entered the public test value, but no native Continue event was recorded. The original 45-second mark lease expired; the unchanged 120-second helper deadline ended with `continue-or-next-target-timeout` at 120,010.926 ms. No second capture or checkbox action was observed, and task completion remains false. The user then confirmed they had not clicked Continue; this run is not evidence of a failed Continue click.

- `UfR7xQ`, after resetting the public field, waited for the fixture to become foreground. It then refused the unchanged full-display coverage predicate at 21,894.305 ms, before capture, provider, AX-state verification or task input. Its precise coverage failure cause is unestablished.

The optional WindowServer sampler failed independently: the first attempt was denied a process-inspection operation in the sandbox; the second refused its stricter process-identity gate. Neither supplies WindowServer visibility evidence, and neither controls the guidance verifier. Later private probe changes are not retroactive evidence for these runs. The third attempt's metadata sampler stopped on the fixture foreground guard; a later observation refused the already-exited process. None supplies new window-visibility evidence. No repeated identical attempt is treated as acceptance.

## Validation and remaining requirements

Final-source local validation passed **817 Swift tests**: 724 app tests across 85 suites, 28 store tests across three suites and 65 core tests across five suites. Review added assessment-order, stale-assessment, restore/delete and AppModel integration regressions, including preservation of a newer active token when an old restore is stale or cancelled. Fresh assessments also require the captured foreground app to remain current. An initial full run found the intentionally changed guidance prompt snapshot; its expected hash was updated after confirming the previous prompt hash independently. The final full run exited 0. These tests use bounded fixtures and do not establish physical task completion, acoustic latency or reference parity. The native project was regenerated to register the two new application files, then clean source **`e1a915b0597451ff8aec20a8e25b2caf79280559`** was certificate-built and installed as the single canonical app. Independent checks passed strict deep signing, team `BPR2T4D656`, Info/build/install source agreement, executable SHA-256 **`ee28ff73258025d7c3978e9530e7de4b8fc4ead9f024bad3f397ddddc2ecdaef`**, no cleanup issues and no temporary app bundles. [Exact-source CI 42207651886](https://github.com/Nithesh8678/opencompanion/actions/runs/42207651886) passed native tests/build and protocol checks. The earlier packaging run had a dirty generated project; it was superseded by this exact clean installation.

This checkpoint does not complete the supplied specification. Remaining acceptance includes:

- A successful real-browser three-step walkthrough and native-app result, with fresh postconditions, wrong-click/no-effect recovery and slow loading.
- Hover-specific interaction/tooltip verification and the broader typed event envelope, sequence/deduplication and annotation vocabulary described in the supplied protocol.
- Native delivery of the new app-switch/scroll invalidation across mixed-scale displays and Spaces; same-PID window movement/switching, programmatic reflow/navigation remain unverified or unimplemented. The later selected-evidence refresh addresses old pixels before provider input, with native race and full-task acceptance still open.
- Guidance-specific speech-beat/mark alignment from actual playback callbacks, interruption and audio-route/device cases. Local draw timing is not acoustic evidence.
- At least 30 warm trials per declared profile, separate cold/failure cases, accuracy/success rate and release-to-useful-output P50/P95. The supplied latency values are goals; none is presented as a measured vendor promise or current result.
- Held-out cross-app acceptance, permission denial/recovery, first-word preservation and complete accessibility/keyboard alternatives.

All whole-product parity gates remain open. The source/build/runtime boundaries in this report must be updated from actual evidence rather than inferred from test names or a green build.
