# Speech and visual presentation timing

Scene-pointing checkpoint, **6 November 2026**: narrated visits to native generated-scene parts and attached captions are implemented. Recovery from temporarily unavailable host bounds is still under verification; no new installed pass is claimed here. See the [scene-pointing contract, artifact-scoped results and current recovery boundary](SCENE-CURSOR-POINTING.md). All 21 whole-product acceptance gates remain open.

Timing implementation recorded 5 November 2026; scene-pointing cross-reference updated 6 November. This slice coordinates accepted explanation scenes with native synthesis notifications or an explicit text fallback. It does not establish acoustic synchronization, exact HeyClicky timing, frame rate or full feature parity. All 21 end-to-end gates in [the public-feature acceptance ledger](HEYCLICKY-PUBLIC-FEATURES.md) remain open.

## Protocol and retained state

The normal NDJSON protocol supports optional `scene.narration`, limited to **32,000 UTF-8 bytes**. A scene's native transaction is validated and committed before its immutable presentation snapshot enters the queue. Its attached narration becomes canonical assistant history; it is not a model-authored clock or executable event. The ordinary Terra routing and default NDJSON output mode remain in place.

```json
{"type":"scene","nodes":[{"id":"part","kind":"mesh","fill":"#667788","spatial3D":{"geometry":{"type":"sphere","radius":0.5}}}],"removeIDs":[],"narration":"This step introduces a solid sphere."}
```

Existing separate text and scene units remain supported in their received order. A text unit cannot retrospectively acquire a scene association: producers should attach a step's explanation to that scene's `narration` field. Short standalone introductions and conclusions remain text units.

`ExplanationPlayback` retains at most **64 pending beats**, **8,192 node references across its snapshots**, and **128 KiB of pending narration**, with the 32,000-byte paragraph limit. Capacity is checked before canonical publication and checked again when enqueuing. Exhausting a limit fails visibly; it does not silently discard a pending beat or replay a transaction.

Canonical history and document revisions can advance ahead of presentation. Saving, validation and later edits use the accepted canonical document. The floating surface uses only its current released snapshot, so a future accepted scene does not appear simply because its bytes arrived. Opening the explicit Notebook editor cancels staged presentation and exposes the retained canonical document. Existing-notebook edits continue through the ordinary immediate editor path; this queue applies to new standalone explanations.

## Separate completion clocks

1. **Native transaction admission:** scene structure, references, transforms and budgets pass the existing atomic native boundary. This does not mean the scene was rendered or narrated.
2. **Presentation release:** one generation and beat ID select an immutable document/revision for the floating surface.
3. **Native render submission:** the exact snapshot successfully completes `RetainedCanvasView.render` on a mounted visible own surface. The overlay acknowledges only a successful return. Failed runtime pose validation cannot release narration merely because the view's document field changed. Empty assembly-only snapshots need no visible render acknowledgement. A renderable step that cannot be acknowledged has a bounded five-second failure path.
4. **Synthesis admission and delegate events:** `VoiceService` reports actual enqueue, start, text-range, finish or cancellation for the owned utterance. Native finish releases the next beat. None of these observations verifies GPU completion, physical display scanout, speaker/headphone output or audibility.
5. **Explicit text fallback:** when speech is disabled, deduplicated, rejected by the bounded speech queue, or unexpectedly cancelled by the engine, local caption pacing provides its own completion path. It does not emit synthetic speech-start/finish events.

Native speech captions initially contain no future paragraph. They advance from reported UTF-16 ranges, floored to complete Swift `Character` boundaries, with bounds/overflow checks and monotonic progress. Finish settles the remaining canonical text. A range observed before start is retained until start; repeated or stale updates cannot rewind the caption. The delegate's reported range is not an acoustic word timestamp.

The text fallback uses authored **0.22-second word-group intervals**, bounded long/unspaced groups and punctuation rests. It reveals at most one group per display advance. Its last submitted word retains the **0.14-second native word fade** before the completion callback releases the next beat. Reduce Motion can bypass pacing/fade remainder. Hidden or unavailable caption presentation releases the local gate explicitly, so a preference change or pointer exclusion does not deadlock playback. These constants are authored presentation choices, not measured reference-product constants.

## Ownership and cancellation

`VoiceNarrationContext` carries the immutable task generation and narration/beat UUID. Each admitted utterance also has a fresh opaque token, independent of the native object's address. The existing bounded token registry rejects delayed callbacks after Stop or address reuse. Only immutable identity, numeric range and observation-time values cross from nonisolated delegate callbacks to MainActor; native speech objects stay on their owning side.

The speech service accepts at most **24 pending utterances** and **32,000 UTF-8 bytes per utterance**. Both legacy and typed speech calls report admission. Deduplication is recorded only after successful enqueue, so a full queue cannot silently consume a future valid narration attempt.

Stop revokes playback generation/beat ownership and speech tokens before native cancellation. It emits a distinct host-stop terminal receipt rather than claiming that the delegate supplied a cancellation. Stop preserves the canonical document and last released snapshot; Clear hides the floating surface without deleting the retained document. User edits, explicit editor entry, sleep/session loss and display topology loss invalidate pending presentation and speech. Dismissed surfaces do not resume old queued beats after wake. Stale render acknowledgements and narration completions cannot advance a newer owner.

The renderer still owns independent part introduction and anchored-label reveals. Native cursor visits to narrated parts are now implemented in the separate [scene-pointing slice](SCENE-CURSOR-POINTING.md), whose current recovery verification remains pending. Neither slice establishes word-exact diagram marks or general semantic correspondence between narration and geometry. Native submission, synthesis notifications, caption submission and audible output remain separate claims.

## Historical timing development evidence

The historical guarded timing source, whose debug executable has SHA-256 **`194ad05c9209898381809465f4515d022c242f9d8a197b4d3a1fd2bfdb6f5afe`**, passed the full local Swift suite: **629 tests** — 557 app tests in 69 suites, 21 store tests in two suites, and 51 Core tests in four suites. Log: `/tmp/opencompanion-explanation-final-tests.log`. Relevant coverage includes playback queue/ownership/reentrancy, canonical-versus-presented scenes, speech receipts/Unicode ranges, fallback final-fade completion, surface loss, runtime render rejection and stale Stop receipts. That log is not attributed to the earlier debug executable below or to the later scene-pointing recovery source.

An earlier modified debug executable with SHA-256 **`0c52cfebd8605a944db2476ca78c0e9df2c4df585e26ea3fd175fa6d14fde63e`** passed the separate native authored helper at `/tmp/OpenCompanion-Narration-Debug-2026-11-05/explanation-narration-acceptance.json`. This executable preceded the final guard-only source corrections; its results are historical development evidence, not exact-final-binary acceptance. It admitted both public scenes canonically while initially presenting only stage one, requested real synthesis for two public paragraphs, observed start/range/finish for both, submitted matching native scene revisions before each enqueue, retained foreground and rejected stale completion/render receipts after Stop. The two saved own-render PNGs were visually inspected: a sphere first, then the added box.

Times below are single-run elapsed milliseconds from that helper's start. “Presentation release” is the host event, not the render-acknowledgement timestamp or physical scanout.

| Stage | Presentation release | Speech enqueue | Delegate start | Delegate finish |
| --- | ---: | ---: | ---: | ---: |
| 1 | 9.956 | 70.390 | 254.116 | 6,343.300 |
| 2 | 6,343.540 | 6,345.321 | 6,346.245 | 11,092.000 |

This native run used public authored content and real synthesis, with **no provider call, desktop capture, microphone capture, audio recording or physical input**. Its JSON explicitly marks acoustic output and frame-rate verification false. Own-render images are not desktop capture, and delegate finish is not a measured acoustic endpoint. The trial is not a latency distribution, interruption stress test or human assessment of synchronization.

A separate default-provider water trial passed at `/tmp/OpenCompanion-Narration-NDJSON-Default-Water-2026-11-05/water-molecule/result.json`, using that same debug executable and no explicit model argument: actual `gpt-5.6-terra`, low effort, routing reason `terraVisual`, normal NDJSON. It produced three scene units, three attached narration fields, four total narration/text units, five typed meshes, three anchored labels, and two connector units compiling two cylinders. The unchanged illustrative water-geometry checks passed; no rejected public unit was recorded. First accepted typed geometry took **20.05936 s** and provider completion took **36.09409 s** in that one trial.

The provider helper does not exercise AppModel staged presentation, native rendering or audio. Its success and the authored native synthesis check are distinct evidence; together they do not establish a live provider-to-audible-rendered explanation. Scientific accuracy beyond the illustrative oracle is unverified.

## Historical signed timing installation (`228d495`)

At that timing checkpoint, the installed source was **`228d49502960a165c77fb8e60279ce7aa36f5ec2`**, executable SHA-256 **`7274e5ca874064463fa71bb5276feb50e84c3b26dab01eb3715083d1a8ec4f9d`**, at `/Applications/OpenCompanion.app`. Build/install receipts, Info.plist and independently hashed executable agree. It reuses the existing certificate/team, `BPR2T4D656`; normal macOS deep strict signature verification passed and the designated requirement is satisfied. The local arm64 app is not notarized. Only that canonical Companion app remains in Applications; temporary build/staging apps were removed and installer cleanup issues are empty.

The exact installed executable passed `--explanation-narration-acceptance` at `/tmp/OpenCompanion-Narration-Installed-2026-11-05`. Both actual native starts/ranges/finishes, exact rendered revisions before enqueue, canonical revision two ahead of presentation one, cursor prefixes, foreground/passivity and stale post-Stop rejection passed. Root inspected both own-view PNGs, showing a sphere first and then the added box. Single-run elapsed times:

| Stage | Presentation release | Speech enqueue | Delegate start | Delegate finish |
| --- | ---: | ---: | ---: | ---: |
| 1 | 11.372 ms | 74.434 ms | 90.141 ms | 5,864.077 ms |
| 2 | 5,864.638 ms | 5,868.333 ms | 5,870.060 ms | 10,612.303 ms |

Those are host/native-engine observations, not audible sample timestamps. This authored helper made no provider call, desktop/microphone capture, audio recording or physical input. It cannot establish an end-to-end model-to-audible-rendered turn.

**Separate user-reported real workflow at that checkpoint:** with the updated canonical app open, the user was asked to hold Control+Option and say “Create a 3D explanation of a water molecule.” They reported **“Parts and captions follow the speech smoothly.”** This adds attributed feedback for one physical hotkey/provider/presentation workflow and subjective speech/visual feel. No prompt-free trace or recording was correlated with that response, so its model identity, timings, acoustic word alignment, frame rate and audio route are not independently established. It does not rewrite the authored helper's physical-input/acoustic fields or close the broader conceptual-explanation gate.

A separate exact-installed native regression loaded the public water document from the earlier `0c52cfeb` default-model trial. At `/tmp/OpenCompanion-Narration-Installed-Water-Native-2026-11-05`, five meshes, all three complete labels and all three requested leaders passed independent full-scene closest-surface checks before/after programmatic camera movement. Canonical hints stayed unchanged, label overlap was zero, alpha/composite pixels and foreground/Clear teardown passed, and the separate authored-box synthetic own-view orbit/lifecycle checks passed. Its own-view PNG was inspected. That regression used no provider, speech, desktop capture or physical orbit.

After helpers, CUA reopened the canonical app normally and observed only `org.opencompanion.cursor`, with no Dashboard or Notebook. Exact-source [CI run 42078512787](https://github.com/Nithesh8678/opencompanion/actions/runs/42078512787) passed native tests, the native app build and protocol checks for the exact installed source. Physical listening quality, route/mute/headphone behavior, broader concepts and full HeyClicky interaction parity remain open.

## Implementation entry points

- [Provider.swift](../Sources/OpenCompanion/Provider.swift): optional attached narration and normal NDJSON instructions.
- [AppModel.swift](../Sources/OpenCompanion/AppModel.swift): canonical admission, per-turn ownership, speech/fallback selection and teardown.
- [ExplanationPlayback.swift](../Sources/OpenCompanion/ExplanationPlayback.swift): bounded immutable snapshot queue and beat acknowledgements.
- [ExplanationOverlay.swift](../Sources/OpenCompanion/ExplanationOverlay.swift) and [SceneCanvas.swift](../Sources/OpenCompanion/SceneCanvas.swift): mounted successful render submission and unavailable-surface revocation.
- [Voice.swift](../Sources/OpenCompanion/Voice.swift): bounded typed native receipts, token ownership and grapheme-safe UTF-16 progress.
- [CursorNarrationCaption.swift](../Sources/OpenCompanion/CursorNarrationCaption.swift) and [CursorCompanionCoordinator.swift](../Sources/OpenCompanion/CursorCompanionCoordinator.swift): native-range captions and explicit local completion.
- [ExplanationNarrationAcceptance.swift](../Sources/OpenCompanion/ExplanationNarrationAcceptance.swift): opt-in `--explanation-narration-acceptance OUTPUT` helper. It requests real speech; it is not run implicitly for ordinary app use.
