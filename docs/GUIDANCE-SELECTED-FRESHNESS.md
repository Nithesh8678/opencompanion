# Selected guidance evidence freshness

This source checkpoint changes how typed screen guidance uses an explicitly selected screenshot. The selection defines the permitted capture scope; its saved pixels are no longer treated as current model input, even when the selection is less than 15 seconds old. The final local suite passes 855 tests. Clean signed source `dae3fa586e0f6a868c88a4061f707391c996dbc7` is installed as the single canonical app. [Exact-source CI 42257186008](https://github.com/Nithesh8678/opencompanion/actions/runs/42257186008) passed native tests/build and protocol checks. Native selected-scope acceptance remains pending.

## Before the provider request

For the selected typed-guidance route, AppModel arms the active [scene observer](GUIDANCE-SCENE-INVALIDATION.md) before asynchronous focus preparation. The observer owns the original foreground PID and source rectangle. Generation, capture-publication token, exact selected evidence identity, observer lease and enabled preference must remain current across preparation and capture.

AppModel then requests **one fresh capture of the original scope**. The original display ID, optional window ID, global logical source rectangle and foreground PID must all be preserved. Moving the pointer does not select a different display. The foreground is checked before capture and again before publication. An unavailable or invalid selection produces an error; it cannot silently widen into a full-display capture, retry another source or fall back to the old image.

The new pixels may differ from the selected screenshot. This refresh happens before reasoning about the current screen, so pixel similarity with the discarded image is neither required nor used. A returned crop or source rectangle that differs from the original is refused rather than silently changing the selection's geometry. Window metadata lookup and native capture are not atomic; this does not detect every movement or layout change.

Only the fresh image, fresh semantic context and its fresh frame-scoped grounding candidates enter this guidance request. Old candidate IDs, selected file or memory content, and saved strokes are not carried into that payload. The normal conversation route retains its existing selected-snapshot behavior; this change applies to current-screen guidance.

## Validation and publication

`SelectedGuidanceEvidenceRefresh.capture` validates the handoff independently of AppModel's publication:

- Source metadata must have a positive PID/display ID, a valid optional window ID, finite capture time and finite, bounded, positive raw rectangle dimensions. Negative display origins are supported.
- The replacement must have a different frame ID, a strictly greater perception revision and a nondecreasing capture timestamp. Its PID, display, window and source rectangle must exactly match the original.
- The replacement must be less than 15 seconds old, without a future timestamp. The existing bounded JPEG header reader must report a supported orientation and positive dimensions matching the stored image dimensions. Malformed or truncated headers, oversized data, unsupported formats and metadata mismatches refuse. This does not fully decode or verify the JPEG pixel stream.
- Cancellation and ownership are checked before capture, after its suspension and after header validation. The old image is never decoded as a substitute. A thrown capture or rejected replacement consumes this one attempt; there is no fallback.

The helper returns evidence but does not publish it. AppModel repeats ownership and foreground checks, then uses the actual `CapturePublicationGate` before assigning the new evidence and manual-selection provenance. A cancelled or superseded result cannot restore old context, clear a newer invalidation or start the provider with stale pixels. Perception revisions remain separate from explanation-document revisions.

CaptureService also refuses a nonnil requested display that is no longer available; only an unspecified display may use the existing default selection. For a selected window, it verifies that the actual window owner matches the requested external PID before requesting pixels. These checks do not make window lookup and ScreenCaptureKit capture an atomic operation.

This intentionally replaces the earlier selected-guidance contract that could reuse a recent selected frame after focus preparation. The broader scene-invalidation safeguards and their historical evidence remain documented separately.

## Known selected-route continuation gap

The selected typed route still creates no active `ScreenGuidanceRequest` or workflow check token: `send` currently ties request creation to `requiresFreshGuidanceCapture`, which is false for an explicit selection. Its first refreshed target can reach native annotation, but cannot arm the coordinator's click or manual Continue lease. This is a source-confirmed missing continuation path, not merely an untested pass.

The next slice must separate guidance request ownership from capture choice and retain an ephemeral exact selected scope across click/Continue, voice continuation, loading checks and pause/resume. Simply enabling the request would be unsafe: current continuation sends use `voiceOnly: true` and choose the pointer display, silently broadening a selected region/window on step two. An unavailable selection or an out-of-scope next UI must refuse or request new scope authorization. Durable semantic workflow records must continue to exclude coordinates, PIDs, screenshots and live capture leases; restoring one cannot authorize a saved screen scope.

## Evidence and remaining work

The final full local suite passed **855 tests**: 762 application tests across 90 suites, 28 store tests and 65 core tests. The new coverage comprises thirteen helper methods, five AppModel handoff methods and three capture-source policy methods, including parameterized young-frame cases. They exercise changed pixels and semantic/candidate replacement, exact scope preservation, malformed metadata and image headers, one-attempt failure, ownership loss and cancellation around a suspended refresh. They use authored offscreen bitmaps and an injected refresh closure. They do not capture an actual screen, call a provider, display a window or post input. Host checks directly exercise the selected-evidence handoff with injected capture and foreground closures; they do not prove the actual provider payload or native capture path. The certificate build and canonical installation pass independent source, executable hash, strict deep signature, signing-team and cleanup checks. Exact-source CI passed native tests/build and protocol checks; the tests do not establish a native selected-scope workflow pass.

The installed source is `dae3fa586e0f6a868c88a4061f707391c996dbc7`; executable SHA-256 is `1469bebc3b94166189866ad78bc6df9953bbca345b0ddfe040a1dc4fa24a8698`. Info.plist, build and installation receipts agree. Strict deep signature and existing team `BPR2T4D656` pass. Only `/Applications/OpenCompanion.app` remains among the canonical and installer-managed copies; temporary bundles are absent and cleanup issues are empty. The app was reopened through native UI and remains tucked. The repository remains public, and this source is pushed.

Native acceptance still needs to cover ScreenCaptureKit races, movement between window lookup and capture, mixed displays/scales and Spaces. Same-PID window/layout changes during inference or waiting remain outside the metadata observer's coverage. Refreshing before the provider narrows the earlier selected-frame gap; it does not prove that the screen stays unchanged throughout inference or that every later target remains valid.

Selected typed continuous guidance remains unimplemented as described above; full external task completion and recovery still require end-to-end acceptance. No speed benchmark, latency improvement or HeyClicky parity follows from this change. All **21 whole-product parity gates remain open**.
