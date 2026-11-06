# Terra runtime and bounded model discovery

Checkpoint: 6 November 2026. Current local signed app source is `c331b85292e6c1a000105a90e5ceeb8272347484`; actual executable SHA-256 is `cb4bff0c7669b4b698dee714470004d507aad891686dada1a2f92498ce9a2eda`. All 21 whole-product gates remain open. This report separates the external CLI upgrade, model requests on the earlier frozen app, current native execution and authored image guidance.

## Runtime discovery

The installed standalone CLI was `0.151.0`. A read-only `model/list` probe returned one page containing only `gpt-5.6-sol`, `gpt-5.6-terra` and `gpt-5.6-luna`. The app did not hardcode 5.6 Terra: its existing numeric-family selector already chooses the newest eligible visible image-capable Terra. The old catalog, not pagination, explains the observed selection in those requests.

The [official model documentation](https://learn.chatgpt.com/docs/models) requires Codex CLI 0.159.0 or later for 6.1 Terra. The supported [CLI updater](https://learn.chatgpt.com/docs/cli/reference#codex-update), invoked through the existing standalone installation, installed `0.167.0`. No managed credentials were read/copied and no API key or new sign-in was requested. The existing `/Users/nithesh/.local/bin/codex` path now resolves to that official release; its executable SHA-256 is `030316ecfbb41f4e7946e584b0063ef333b7a36cd312ba349f2f6869e39b62cc`.

A second catalog-only probe returned one page with eight models, including visible `gpt-6.1-terra` with text/image inputs and low effort as its advertised default. The existing automatic Terra preference selects it without hardcoding a new version. Explicit conversation/visual model settings and the separate guidance preference were not changed. Completed requests below verify access for those requests; a catalog entry alone does not establish entitlement, future availability or reliability. The conversation default also follows the returned catalog unless explicitly configured; no separate new conversation smoke test is claimed.

Before/after public catalog metadata is retained at `/tmp/OpenCompanion-Catalog-Before-CLI-Update-2026-11-06.json` and `/tmp/OpenCompanion-Catalog-After-CLI-Update-2026-11-06.json`. These probes started no model turn. The CLI update is an external runtime change, separate from the app source checkpoint.

## General catalog correction

Inspection and request routing formerly read one 100-entry page and ignored `nextCursor`. They now share bounded pagination: at most four pages, 100 entries each and 400 total. Opaque cursor identities compare exact UTF-8 bytes, with a 4,096-byte limit. Invalid/repeated cursors, oversized/malformed pages and an unfinished fourth-page chain fail before model selection or thread creation. Missing/null terminal cursors retain older app-server compatibility. No partial catalog silently selects an older model.

Visible-model, image modality, alias, duplicate ambiguity, explicit setting and supported-fast-effort rules remain intact. This implements the returned-values guidance in the [official app-server model contract](https://learn.chatgpt.com/docs/app-server#models). Neither observed real catalog needed a second page; deterministic stdio fixtures verify that path, not these live requests.

The focused run passed 31 tests in two suites. The full suite passed **734 tests**: 662 app across 79 suites, 21 store across two and 51 core across four. New subprocess fixtures cover a newer visible Terra on page two in both orders, inspection, exact page/cursor bounds, Unicode-distinct opaque cursors, aliases, cross-page duplicates and failures before provider turns. Generation prompts, scene validators and independent geometry oracles are unchanged.

## Same-app requests after the CLI update

The three original public prompts ran once each on the unchanged signed `a5cdbd5` app (SHA-256 `546fd1984a84d43ac31f3bb78c8f90d1add9a818e83e06c1270efc00b2c2883c`), after updating only its external CLI. Default NDJSON, introduction-first and 12,277 UTF-8 instruction bytes were retained. Actual routing was `gpt-6.1-terra`, low effort, `terraVisual`, without an explicit model flag, screen or audio payload.

Artifacts: `/tmp/OpenCompanion-Terra-CLI-Update-2026-11-06-a5cdbd5/`, including the frozen manifest, receipts, exit codes, logs, public scenes and summary. The earlier 5.6 trials remain separately retained in [the delivery report](NDJSON-DELIVERY.md).

| Public case | Quality / exit | Meshes / labels | Scenes | First typed geometry (s) | Provider finish (s) |
| --- | --- | --- | --- | --- | --- |
| Brushed DC motor | Failed: `motor-camera-facing-cutaway` / 1 | 9 / 7 | 5 | 10.732 | 31.249 |
| Water molecule | Passed / 0 | 5 / 3 | 3 | 7.383 | 15.998 |
| Static pendulum | Passed / 0 | 3 / 3 | 3 | 7.256 | 13.194 |

All three provider/delivery audits completed with one started final-answer item, equal streamed/completed byte lengths and matching SHA-256: motor 4,699 bytes / seven wire units; water 2,244 / four; pendulum 1,934 / four. All missing-suffix, completed-only, duplicate and ignored-scope counts were zero. These are complete deliveries, not guarantees of useful geometry.

Water used two endpoint recipes for its bonds; pendulum used one for the rod. Both passed the unchanged independent illustrative-geometry checks. Motor passed the former coaxial-axis checks but still failed its camera-facing cutaway. Its 120-degree opening is wide enough; after the parent's 90-degree X rotation, the camera's housing-local azimuth is 331.39 degrees, outside the required 10–110-degree margin. No geometry was inferred/repaired and no threshold was lowered.

First geometry in the earlier 5.6 requests took 21.089 / 14.226 / 33.479 seconds for motor/water/pendulum; the new requests took 10.732 / 7.383 / 7.256. This is not a controlled model benchmark: the CLI and selected model changed together, outputs differ in length/structure and each row has one request. The observations are promising, but neither latency distribution nor a quality-preserving speedup across arbitrary tasks is established. Remote queue/reasoning/network phases were not separately measured.

## Exact-installed image guidance

After installing `c331b85`, the unchanged authored public-image helper ran all 13 existing scenarios once using actual `gpt-6.1-terra`, low effort and `terraGuidance`. All passed their existing oracles: ten click targets, one manual screen-question target and two clarification envelopes. Each row's timing begins before provider startup and model discovery; it ends at callback/oracle receipt or offscreen native final-model rendering. It is not displayed animation, physical response time or FPS.

| Case | Evidence route | Expected outcome | First oracle-valid target (s) | Provider finish (s) |
| --- | --- | --- | --- | --- |
| `01-icon-only-compose` | authored-accessibility-candidates | click | 5.656 | 5.665 |
| `02-collapsed-sidebar` | authored-accessibility-candidates | click | 5.426 | 5.433 |
| `03-fresh-revealed-sidebar` | authored-accessibility-candidates | click | 4.363 | 4.367 |
| `04-generic-new-note` | authored-accessibility-candidates | click | 4.029 | 4.036 |
| `05-pixel-only-sidebar` | image-only | click | 5.183 | 5.190 |
| `06-heldout-profile` | image-only | click | 7.841 | 7.846 |
| `07-heldout-appearance` | image-only | click | 6.616 | 6.618 |
| `08-heldout-export` | image-only | click | 4.337 | 4.349 |
| `09-heldout-next-page` | image-only | click | 6.038 | 6.054 |
| `10-heldout-custom-canvas` | image-only | click | 4.042 | 4.047 |
| `11-heldout-screen-question` | image-only | manual | 4.184 | 4.192 |
| `12-ambiguous-selection` | image-only | clarification | — | 4.381 |
| `13-incompatible-foreground` | image-only | clarification | — | 6.461 |

Receipts, authored JPEG inputs, native annotation PNGs and summary are retained at `/tmp/OpenCompanion-Terra-Final-c331b85/guidance/`. The first four cases supplied authored accessibility candidates with empty titles; the remaining nine supplied image-only evidence without candidate geometry. Expected answer/control IDs were not sent to the model. Click-advancing marks use the existing ellipse styling; manual/explanatory marks retain their supported supplied shape. Raw/resolved/native shapes remain separately recorded. The profile PNG was inspected and circles the avatar, with a nearby Account menu label.

These checks validate target geometry and response envelopes on synthetic public screens, including the user's exact profile question. Target instructions were checked for nonempty content, not semantically judged; the two clarification results establish only their safety envelopes, not helpful wording. The helper neither captured a real screen nor harvested actual AX, clicked a control, exercised AppModel admission, mutated a Notebook, recorded audio or measured displayed motion. The expanded-sidebar transition is authored, not an observed user click. Actual capture, unknown-app physical continuation, hotkey/microphone and 100+ cold/warm latency acceptance remain open.

## Native generated scenes and narration

The final installed native overlay helper separately loaded each passing new public 6.1 document. Water and pendulum both passed three complete visible labels with zero overlap, all three requested leader surfaces independently verified against full-scene closest target triangles before/after programmatic camera motion, unchanged canonical anchors, passive foreground, Clear/teardown and separate synthetic own-view orbit. Composite sampling matched **47/47** for water and **128/128** for pendulum. Their own-view PNGs were inspected: connected bent atoms and bonds; connected support/rod/bob. Artifacts are `/tmp/OpenCompanion-Terra-Final-c331b85/native-water/` and `native-pendulum/`. These runs used no provider, desktop capture, audio, physical orbit/Clear click or FPS measurement; they do not retroactively become renders by the earlier executable that generated the documents.

The opt-in authored narration helper now adds at most 12 finite-safe pointer diagnostic checkpoints, including the original AppKit baseline, unposted Quartz read/conversion, display geometry, elapsed times and the first mismatch if any. It retains exactly the original baseline, 0.01-point guard, deadlines and pass/fail assertions. No pointer is moved/rebased, no observer is installed and no normal conversation collects these coordinates. The paired API reads are sequential, not atomic motion measurements. Keep raw receipts local rather than publishing pointer positions.

The current installed narration run passed both stages at `/tmp/OpenCompanion-Terra-Final-c331b85/narration/explanation-narration-acceptance.json`. Eight checkpoints stayed at zero baseline displacement, with matching AppKit/converted Quartz readings. Both native surface targets were reached; submitted-layer tip errors were approximately 0.500 / 0.783 logical points, with caption/body gaps 8.485 points. Scene-before-enqueue, native speech start/range/finish, stage-two recovery after unavailable host bounds, unchanged pointer/foreground and stale post-Stop rejection passed. Its cursor PNG was inspected and captures only the initial caption prefix The beside a red glow. This is authored native execution, not a trace-correlated provider-to-acoustic/user workflow, desktop composition or FPS proof.

The two earlier `a5cdbd5` narration failures remain failures. The current pass neither identifies their movement source nor proves the diagnostics fixed a product defect; no cause was established and no guard was relaxed.

## Installation and release state

The existing certificate identity and Team `BPR2T4D656` were reused. Strict deep verification, build/install receipts, Info.plist source and actual executable hash agreed. Only `/Applications/OpenCompanion.app` is installed, cleanup issues are empty, and temporary build/staging app bundles were removed. [Exact-source CI 42171106406](https://github.com/Nithesh8678/opencompanion/actions/runs/42171106406) passed. This is the local signed arm64 app, not a newly notarized distribution.

A Settings live-connection smoke test was not performed: the native UI tool exposed only the cursor window after invoking Settings. No error or working secondary-window interaction was established from that observation. Model access evidence above comes from completed public adapter requests, not that unexecuted Settings test. CUA quit the temporary Settings session and reopened the canonical app. Accessibility then exposed only `org.opencompanion.cursor` and menus, without Dashboard or Notebook. All 21 whole-product gates remain open.
