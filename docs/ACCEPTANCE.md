# Acceptance evidence

3 November 2026, Apple Silicon, macOS26.6.2, Swift6.4.2 / Xcode27.2. These are observed boundaries, not performance guarantees.

## Local automated checks

- 25 core tests: bounded event framing/ordering/cancellation, coordinate inverses/negative displays, atomic revisions, reference/cycle/expression budgets, current/force conventions for the55-node motor, unrelated lessons, long playback, grouped transforms/hit tests, beat clocks and signed directional geometry.
- 15 storage/file tests: migrations/reopen/search/export, scope/symlink boundaries/hash freshness, leases, unknown outcomes/reconciliation, retry budgets, cancellation, missed-run semantics and safe memory edits.
- 9 runtime tests: actual executor results/cancellation, scheduler replacement, MCP JSON/SSE/session negotiation/pagination/schema validation/expiry/cancellation/deadlines.
- 5 context-binding tests: immutable frame/source identity, notebook identity and revisions, cancellation publication and scoped AX exclusion.
- 2 Codex transport tests: short pipe responses stream before EOF; cancellation does not accept late output.
- 6 provider-boundary tests: direct create/patch and legacy node updates share atomic validation; signed arrows, alternate point representations, omitted fields and failed updates are covered.
- 7 shell capture tests: only fresh matching frames complete an invocation; Stop and superseding captures invalidate late results.
- 5 shortcut tests: safe modifiers, duplicate actions, corrupted preferences and persistence.
- 1 capture-sampler test: JPEG color conversion, negative display origins, retained fixtures and invalid controls.
- 5 notch layout/hover tests: exact cutout footprint, negative display origins, notchless fallback, physical top-edge boundaries, pointer exit, pinned conversation and hover rearming. A separate run-loop test verifies pointer polling without mouse-event delivery, using an injected location source.
- 11 voice input tests: permission/start/release/Stop ordering, final/deadline races, cancellation after release, old tails after a new hold and typed-draft preservation.
- 6 background-callback tests: Speech authorization completion from a real background queue, recognition value snapshots and TTS event delivery onto MainActor, stale utterance-token rejection and bounded token storage. No microphone recording or acoustic claim.
- 9 modifier-voice tests: Control+Option edges, repeats, extra keys/modifiers, lock-bit policy, cancellation and preference migration.
- 29 isolated installer/signing tests: verified replacement and rollback, running-app and process-lock refusal, recoverable cleanup, unchanged saved-data fixtures, strict Launch Services errors and local signing configuration.
- 5 native host tests;6 selfhost relay integration tests;4 browser protocol/scope tests.
- 10 real Chromium DOM assertions, including shadow DOM, stale document refs, protected/covered controls and fresh post-action evidence. Extension messaging was fixture-driven; this is not installed MV3/native-host pairing.
- Real Swift browser bridge↔Unix socket↔Python host↔framed-message round trip.

## Live model evidence

A native app command-line acceptance run used the production Codex adapter with managed ChatGPT auth and default catalog selection. It completed:

1. Simplified brushed DC motor:12 validated retained nodes.
2. Photosynthesis:12 different validated retained nodes.
3. Follow-up recolor: stable IDs, unchanged unrelated nodes, requested color accepted.

No tokens were read/copied; external capabilities were disabled for the ephemeral teaching thread. These completed requests establish access for those requests. They do not establish all model entitlements, a latency percentile, or general scientific correctness.

## Native application evidence

The app-bundle Keychain acceptance probe saved/read/deleted a unique temporary public fixture successfully. No real credential was read or copied.

The real signed-to-run-locally bundle launched with **only its collapsed notch panel**, with no normal workspace window. Accessibility inspection found its Expand control; clicking expanded it and focused its message field. Native safe geometry reported display1512×982, safe top32pt, collapsed panel96×48pt.

The corrected notch implementation replaces that earlier floating idle chip: the current display reports a185×32pt cutout at(663,950), and idle matches it exactly. A real panel diagnostic drove synthetic pointer positions through two hover/tuck passes, preserved an unsent fixture draft and the foreground application, and rendered the compact peek and explicit full conversation. Synthetic interaction acceptance explicitly disables mouse monitors and pointer polling with `observePointer: false`; normal app shells observe the actual pointer. This exercises the real window/layout path independently of the polling transport; physical pointer and voice-key delivery still need installed human acceptance.

A live question submitted through the expanded notch UI completed with a provider answer, returning the panel to Ready. This verifies the actual UI→provider→UI path.

The user's subsequent physical check failed for both hover and Control+Option. Inspection of that normally launched GUI found Input Monitoring unavailable. The hover target also excluded the display's exact top edge and relied solely on mouse-event delivery. Closed-edge hit testing and a permission-free pointer timer now address hover; the compact HUD exposes voice setup. The user later confirmed physical hover reveals the corrected black panel. Synthetic geometry tests alone did not establish that result.

After the user enabled Input Monitoring and reopened the certificate-signed app, normal-process diagnostics confirmed an enabled event tap and two real Control+Option press/release pairs. Speech authorization then exposed a Swift actor-isolation trap in its background callback, confirmed by the matching own-app crash report. Authorization, recognition, audio-tap and TTS callbacks now have explicit thread boundaries; background regression tests cover the crash path and stale TTS delivery. In installed app revision `f4e3bd2`, the user confirmed both physical notch hover and held voice input followed by a spoken answer. The normal GUI log verified Input Monitoring and an installed/enabled event tap after the signed update, demonstrating that the existing grant survived this update. This is a human-confirmed end-to-end check on the current Mac and audio route; it does not establish latency, recognition accuracy across utterances, every route or interruption scenario.

The earlier utility-window test opened/paused/saved the motor notebook and verified its record in Library. Own-window PNG renders of the notch and notebooks were inspected, exposing/fixing the initial dark-appearance contrast issue. These are local view renders, not displayed-FPS or acoustic measurements.

After the user enabled Screen Recording, the updated installed bundle completed a real display capture. A distinctive own-app checker panel was visible in the included control and absent from the production filtered capture; the resident notch was also absent. Both local JPEGs were visually inspected. No screen image or OCR was submitted to a provider or committed. This verifies this fixture on the current display, rather than every display/Space configuration.

## Remaining installed/release acceptance

Screen capture/exclusion was inspected under an earlier installed identity. The later ad-hoc GUI showed Screen Recording and Input Monitoring unavailable. The canonical certificate-signed app now has user-granted Input Monitoring, retained through a subsequent update. Screen Recording and Accessibility under the new identity have not been revalidated; installed desktop action acceptance remains pending.

Voice input and a spoken answer are user-confirmed on the current route. Route changes, denied/revoked permissions, interruption coverage, physical multi-display/fullscreen/Spaces/StageManager, unfamiliar-app three-step tutorials, installed browser pairing, live MCP account, live selfhost upstream, minimum OS/Intel, long sessions and100+ cold/warm latency trials remain unverified. Default distribution builds use an ad-hoc signature; the ignored local signing configuration can reuse an existing development certificate. Developer ID/notarization/stapling/signed updates remain release gates.

See FEATURE-STATUS.md for implementation gaps as well as external acceptance gates. This alpha does not satisfy every row in the full research specification.
