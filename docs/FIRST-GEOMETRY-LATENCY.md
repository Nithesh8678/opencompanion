# First-geometry latency experiment

Updated 6 November 2026. This is an opt-in public-fixture benchmark and implementation contract. Two separate six-request rounds are recorded below; neither candidate was promoted. Normal app requests retain introduction-first NDJSON, existing routing and disabled extra latency measurements. No model, effort, service tier, authentication or account preference is changed by the flag.

## Candidate and unchanged controls

The explicit public helper accepts the no-value flag **`--geometry-first`**. Without it, `sceneStart` is `introductionFirst`; with it, `sceneStart` is `geometryFirst`. Duplicates, attached or positional values, malformed variants, and combinations with any structured-output mode reject before a provider request. The underlying candidate also requires a new explanation with no retained scene or image. The flag is not a new ordinary UI preference.

The candidate requests a small first scene containing actual geometry and its concise attached narration, instead of a standalone introductory text unit. It retains normal NDJSON, typed geometry, exact focus IDs, complete-line decoding, atomic admission, native budgets, cancellation and subsequent progressive construction. It does not admit a partial object, construct a guessed part locally, relax an oracle, or treat a placeholder as useful geometry.

All three existing public cases and their prompts remain unchanged: brushed DC motor, water molecule and static simple pendulum. Their complete schema, progressive-new-part, label, role, connection, cutaway and static-pose checks remain applicable. In addition, the candidate records unmet checks if its first admitted unit is not a scene or its first scene has no drawable typed mesh. A failure is recorded in the full result rather than hidden by an early success or retry.

## Receipt and timing boundaries

Each case and aggregate receipt adds `sceneStart` and `measureSceneLatency:true`. Both baseline and candidate opt into the same content-free transport measurements. Existing fields remain present; old receipts are not rewritten.

`firstAdmission` and `firstSceneAdmission` retain the admitted unit type and resulting node, group, typed-mesh and drawable-typed-mesh counts. These summaries are set only after successful admission and do not change after a later rejection. They contain no narration or IDs. A drawable count means valid typed geometry at time zero, positive composed opacity and nonzero effective literal material alpha. It does not establish camera visibility, native pixels, correct semantic focus or scientific accuracy.

`providerTimingEvents` is serialized from the Codable event array, preserving the existing `stage` and `elapsedMS` keys and any supplied additive measurement fields:

- `requestPayloadPrepared` reports `instructionUTF8Bytes`, `conversationUTF8Bytes` and `turnInputUTF8Bytes`. Instruction bytes are the actual base/developer instruction strings' UTF-8 sum. Conversation bytes count the prepared text, including any selected-context text when present. Turn-input bytes are the JSONEncoder encoding of `JSONValue.array(input)`, not the complete RPC parameters, framing or token count. These public cases supply no image, selected evidence or conversation history.
- `firstSceneLineDecoded` carries `lineStartMS`, `lineEndMS`, `lineUTF8Bytes` and `lineTermination` when available. These are adapter-observed line/framing times and bytes; they do not expose when the model internally planned or generated each byte.
- `firstSceneHandlerStarted`, `firstSceneHandlerCompleted` and `firstSceneHandlerFailed` distinguish host callback admission from line decoding. A completed callback does not prove rendered pixels or audio. A failed callback does not count as successful admission.

Missing optional measurements remain absent. The normal application's extra measurement switch defaults to false; the benchmark logs counts and times, never raw instruction, evidence, image or conversation content.

Compare request-to-first typed geometry, turn-acceptance-to-first-delta, first-line start/end, line-end-to-decode, handler duration and request-to-completion. `firstTypedGeometryMS` does not independently prove drawability; inspect the first-scene drawable count before describing it as drawable geometry. Decoder/wrapper times include any awaited timing observer before the next boundary; they do not isolate network receipt or pure handler CPU time. The benchmark uses the same bounded scalar collector for both arms. No event here distinguishes server queueing, prompt prefill, internal reasoning, generation or network buffering without additional evidence. Native scene release, visible cursor/caption frames and audible speech are separate clocks.

## Minimum matched run: six sequential requests

Use one frozen executable and the same CLI/account/configuration for the entire run. Keep the configured model argument identical, record the actual model/effort/routing in every receipt, and make no concurrent provider request. Do not change prompts, model defaults or geometry oracles between arms.

| Order | Case | Arm | Output directory suffix |
| --- | --- | --- | --- |
| 1 | `brushed-dc-motor` | Baseline | `01-motor-baseline` |
| 2 | `brushed-dc-motor` | Geometry-first | `02-motor-candidate` |
| 3 | `water-molecule` | Baseline | `03-water-baseline` |
| 4 | `water-molecule` | Geometry-first | `04-water-candidate` |
| 5 | `simple-pendulum` | Baseline | `05-pendulum-baseline` |
| 6 | `simple-pendulum` | Geometry-first | `06-pendulum-candidate` |

The commands below are a template, not an executed trial. Use a new private output root and a distinct directory per request so failures and previous receipts remain intact.

```sh
"$trial_executable" \
  --spatial-scene-live-acceptance /tmp/OpenCompanion-FirstGeometry-RUN/01-motor-baseline \
  --spatial-scene-case brushed-dc-motor

"$trial_executable" \
  --spatial-scene-live-acceptance /tmp/OpenCompanion-FirstGeometry-RUN/02-motor-candidate \
  --spatial-scene-case brushed-dc-motor --geometry-first
```

Repeat that paired template for the other rows. Preserve every failure, rejection and partial-admission receipt; do not silently retry or drop a case. If another matched round is authorized, reverse the within-case arm order to inspect order/caching effects. Six calls provide one paired observation per case, not a latency distribution, reliability rate or causal estimate immune to changing provider load.

A candidate is eligible for further study only when every final quality gate still passes and every candidate begins with admitted drawable geometry. Report individual paired timing differences and failures together. No default promotion follows automatically, and faster invalid output is not a latency success.

The template requires `trial_executable` to name the newly frozen executable containing this helper. There is no helper model flag: both arms read the same configured model argument and must report matching actual model, effort and routing. Run each row even if an earlier quality check fails. Eligibility also permits new 2D explanations, but these three 3D cases do not validate path-only plots or justify a general 2D default change.

Before freezing the benchmark, **692 local Swift tests passed**: 620 application tests across 74 suites, 21 store tests across two suites and 51 core tests across four suites. The new checks cover unchanged default prompts, opt-in scope, framing/decoding boundaries, first-handler ownership, content-free counts, and cancellation during diagnostic observers. A stopped request cannot submit its turn or deliver its scene after those observers suspend. These are local regression checks, separate from real-provider quality and latency.

## Round 1: candidate revision 1 is not eligible for promotion

All six planned requests ran sequentially using the same frozen, certificate-signed executable from source **`a60b66fb9f1f98f56f553dfb24ec604e83c9036e`**, SHA-256 **`1f46dd1000c47db76ad448e9e3dd184ed5fd168df1d1cf0c477747d3b1d7464f`**. Every receipt reports normal NDJSON, `measureSceneLatency:true`, actual **`gpt-5.6-terra`**, **low** effort and **`terraVisual`** routing. The baseline/candidate instruction-string sizes were 11,096/11,538 UTF-8 bytes; conversation and serialized input bytes matched within each pair. No image, desktop capture or microphone was used. Separate benchmark requests did not overlap; unrelated account activity and remote load were not controlled.

| Order | Case / arm | Quality | First typed geometry (s) | Provider finish (s) |
| --- | --- | --- | ---: | ---: |
| 1 | Motor / baseline | Failed: camera-facing cutaway | 29.37375 | 48.92132 |
| 2 | Motor / candidate 1 | Failed: only one mesh/label; incomplete lesson | 20.06812 | 20.06854 |
| 3 | Water / baseline | Passed | 17.08059 | 32.65460 |
| 4 | Water / candidate 1 | Failed: only one mesh/label; incomplete lesson | 25.36446 | 25.36514 |
| 5 | Pendulum / baseline | Failed: rod does not connect both parts | 23.54354 | 35.13494 |
| 6 | Pendulum / candidate 1 | Passed | 18.57921 | 27.79127 |

Every first-scene admission summary recorded three nodes, including one group and one drawable typed mesh. Each baseline first admitted a standalone text unit; each candidate first admitted a scene. The two incomplete candidates reached a clean provider completion with no rejected scene or protocol failure: they ended after their starter part. Their first scene ended at EOF; the other four first scenes were newline-terminated. All failures remain in the receipts and table. The candidate's faster motor/pendulum timings therefore do **not** establish a valid quality-preserving latency improvement; its water geometry was also slower.

| Order | Turn accepted → first delta (s) | First scene line start → end (s) | Line end → decoded (ms) | First handler start → completed (ms) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 22.61120 | 4.62603 | 0.862 | 0.491 |
| 2 | 15.26222 | 4.66449 | 0.412 | 0.214 |
| 3 | 10.00071 | 6.40971 | 0.331 | 0.169 |
| 4 | 20.58558 | 4.02074 | 0.649 | 0.297 |
| 5 | 14.68081 | 7.03801 | 0.921 | 0.437 |
| 6 | 15.10364 | 3.33701 | 0.875 | 0.425 |

The observed host admission/decode work is far smaller than the earlier waits in these six samples. These client clocks cannot assign that waiting time to a specific remote mechanism. No displayed frame, acoustic onset, full native visibility or real user action was measured. The baseline quality failures also demonstrate that the current default is not a general geometry-quality guarantee.

Private retained artifacts: `/tmp/OpenCompanion-FirstGeometry-2026-11-06-Round1-a60b66f/manifest.json`, with the six named row directories above. Each contains its case's `result.json` and `public-scene.json`; aggregate receipts, exit codes and per-request logs are retained. Public prompts do not authorize publishing local raw output or unrelated user content.

Candidate revision 2 makes a bounded prompt correction: after the starter scene, complete the entire requested lesson in the same response, including every requested part and label in further complete units, without stopping or waiting for a follow-up. All default prompts and shared geometry rules stay unchanged. This is a new candidate, not a retry or a replacement for revision 1. Its next matched round reverses the within-case order; results must be reported separately rather than pooled as a repeat of the same treatment.

## Round 2: completion wording does not rescue the candidate

Six new sequential requests used frozen signed source **`4aa0f04c733c0fb957f9cfd3b140b3b4534b717e`**, SHA-256 **`7d4b982378fa5c529225e3ec9b67a2a91bd3439ba24e0c5a50b4dd85834779a7`**. This round reversed each within-case order and tested candidate revision 2. It is a different prompt treatment, not a replicated revision-1 round. All receipts again report normal NDJSON, explicit measurement, actual `gpt-5.6-terra`, low effort and `terraVisual`; the instruction-string sizes are 11,856 candidate / 11,096 baseline bytes. Conversation/input sizes match within pairs. The four focused prompt tests passed after the wording-only revision; the prior full native suite is scoped to the diagnostics checkpoint.

| Order | Case / arm | Quality | First typed geometry (s) | Provider finish (s) |
| --- | --- | --- | ---: | ---: |
| 1 | Motor / candidate 2 | Failed: only one mesh/label; incomplete lesson | 27.05719 | 27.05809 |
| 2 | Motor / baseline | Passed | 21.10637 | 52.66571 |
| 3 | Water / candidate 2 | Failed: only one mesh/label; incomplete lesson | 16.99704 | 16.99770 |
| 4 | Water / baseline | Failed: protocol rejection; partial scene retained | 14.67023 | 32.02593 |
| 5 | Pendulum / candidate 2 | Passed | 16.04128 | 24.67200 |
| 6 | Pendulum / baseline | Passed | 15.33252 | 25.44447 |

| Order | Turn accepted → first delta (s) | First scene line start → end (s) | Line end → decoded (ms) | First handler start → completed (ms) |
| --- | ---: | ---: | ---: | ---: |
| 1 | 19.99453 | 6.18915 | 0.828 | 0.517 |
| 2 | 14.88088 | 4.96557 | 0.366 | 0.138 |
| 3 | 11.19901 | 5.68702 | 0.577 | 0.321 |
| 4 | 10.65293 | 3.17446 | 0.706 | 0.472 |
| 5 | 11.91665 | 3.93652 | 0.531 | 0.266 |
| 6 | 12.06418 | 3.11659 | 0.642 | 0.461 |

All first-scene summaries again recorded three nodes, one group and one drawable typed mesh. Candidate 2 again returned only one admitted mesh/label for motor and water, with clean provider completion and EOF framing. Its pendulum passed all existing checks, but its first typed geometry arrived **later** than the paired passing baseline. No candidate 2 case establishes a quality-preserving improvement in first-geometry latency.

The water baseline retained two earlier scene units and three atom meshes before rejecting its next unit. The retained public rejected line is valid JSON but incorrectly mixes a text-label object into the `connectors` array; typed protocol decoding correctly refuses it. The independent final checks also detect missing bonds. No coercion, hidden retry, local guessed geometry or oracle weakening was introduced.

Private retained root: `/tmp/OpenCompanion-FirstGeometry-2026-11-06-Round2-4aa0f04/`, with `manifest.json`, all six row/case receipts and scenes, per-request logs, and the water baseline's `public-rejected-unit.txt`. All 12 round-one/round-two outcomes remain recorded. **Both candidate revisions remain opt-in; default NDJSON prompts, model/effort selection, normal measurement settings and ordinary UI behavior remain unchanged.** These samples do not establish a general reliability rate, acoustic/display latency, FPS or HeyClicky parity. Next work must establish complete valid scene delivery before promoting a startup optimization.

## Installed native verification and a diagnosed sampling failure

The canonical `/Applications/OpenCompanion.app` was replaced with signed source `4aa0f04`, retaining team `BPR2T4D656` and the existing designated requirement. Its actual executable, build/install receipts and Info.plist agree on source/hash; strict deep signature verification passed. The installer reported `cleanupIssues:[]` and removed both temporary build/staging app bundles. No additional installed copy or user-data reset was introduced. Both exact-source CI runs passed: [diagnostics revision a60b66f](https://github.com/Nithesh8678/opencompanion/actions/runs/42093413404) and [completion wording revision 4aa0f04](https://github.com/Nithesh8678/opencompanion/actions/runs/42094528359).

The exact installed `4aa0f04` authored narration check passed at `/tmp/OpenCompanion-FirstGeometry-Final-Narration-4aa0f04/explanation-narration-acceptance.json`. Both stages reached their actual native surface targets, with submitted-layer tip errors **0.499886 / 0.783001 logical points** and nearest caption/body gap **8.485281 logical points**. The second stage recovered after `hostBoundsUnavailable`. Native synthesis start/range/finish callbacks, scene-before-speech-enqueue ordering, stale post-Stop rejection, unchanged physical pointer and unchanged foreground passed. Own cursor-window PNGs were inspected; each captured only the initial caption prefix “The”. This is authored native execution with actual synthesis requested, not microphone, provider, acoustic recording, whole-desktop compositing or FPS evidence. The earlier physical user confirmation belongs to the separately recorded `e8a7278` workflow, not a new physical test of `4aa0f04`.

A separate exact-installed native overlay check of round-two's passing public pendulum scene failed at its combined final-composite assertion. The failure and own-view PNG remain at `/tmp/OpenCompanion-FirstGeometry-Final-Pendulum-4aa0f04/`. The image shows the complete support/rod/bob lesson; all three requested leaders separately passed canonical-anchor preservation and whole-scene closest-triangle target checks. Visual inspection alone does not override that failed assertion.

A diagnostic-only build then retained the same predicates/sampler and wrote bounded scalar metrics before the assertion. At `/tmp/OpenCompanion-FirstGeometry-Pendulum-Predicate-Diagnostic/final-composite-metrics.json`, **15 geometry samples all matched**; only the minimum-20-samples predicate failed. Label/leader changed-pixel counts were **1,178 / 132**, final visible/transparent counts **26,268 / 930,413**, with all remaining pixel predicates true. This establishes undersampling of a thin object by the original viewport grid for that run. No sample-count or 65% match threshold was lowered. A coverage correction and a fresh exact-installed verification are required before claiming this native pendulum check passes.

The coverage correction subsequently passed **701 local Swift tests** (629 application across 75 suites, 21 store across two suites, 51 core across four suites). Nine new synthetic checks include thin off-grid geometry, displaced/wrong-color/empty images, insufficient genuine opaque pixels, backing-scale/offset mapping, preservation of existing sufficiently populated passes and failures, work bounds, unavailable colors and invalid/off-canvas mappings. The helper retains an original grid result with at least 20 samples. Otherwise a format-checked, bounded fallback selects up to 128 opaque-pixel rank quantiles with constant storage, at most two passes over eight million pixels and at most 128 color-converted pairs. It preserves the original coordinate mapping and alpha/color tolerances.

The corrected diagnostic native pendulum run passed every original assertion at `/tmp/OpenCompanion-FirstGeometry-Pendulum-Coverage-Diagnostic/explanation-acceptance.json`. Its metrics retain the original **15/15** grid result and report **128/128** fallback matches, 21,864 eligible opaque pixels and 1,043,566 raw alpha visits. This is area-weighted sampled composite consistency; very small components or periodic corruption can escape finite quantile sampling. All-target native surface/leader checks remain separate. A clean signed installation check follows this diagnostic result; it is not retroactively assigned to the earlier failed installed binary.

## Final signed installation and native result

The final installed source is **`c7a504fe5fe5cb7455b51f681f2b17876520d28e`**, actual executable SHA-256 **`25068bf8f2d8687e39d590e732120a82f2806e27dd31d67c6d835c7ee8ebf800`**. Build/install receipts and Info.plist agree with that executable. Strict deep signature verification, signing team `BPR2T4D656` and the unchanged designated requirement passed. The canonical path remains `/Applications/OpenCompanion.app`; the installer reported no cleanup issues, and both temporary app bundles were removed. The signed app is a local arm64 build, not a notarized release. Exact-source [CI run 42097695325](https://github.com/Nithesh8678/opencompanion/actions/runs/42097695325) passed native tests, the app build and protocol checks.

The exact installed pendulum check passed at `/tmp/OpenCompanion-Final-Installed-Pendulum-c7a504f/explanation-acceptance.json`, with **128/128** fallback matches and the retained original **15/15** grid result. All three requested leaders passed full-scene closest-triangle ownership before and after programmatic camera movement; all labels were complete, in bounds and non-overlapping. Native label-clock settling, passive foreground behavior, stale/current Clear and synthetic own-view orbit/teardown passed. This was a separate render of the retained public scene, without a provider call, desktop capture, audio, physical drag/Clear click or FPS measurement.

The original failed installed check, unchanged-predicate diagnostic, corrected diagnostic and final installed check produced the **same PNG bytes**, SHA-256 **`9bc6c1d6650d3a0dfa62da9a9c8ae3ba1aa195fc5674bdb2c0258b5b94f4b3dd`**. The correction repairs test coverage for thin geometry; it does not change the displayed pendulum or establish that every pixel/part is sampled. Historical failed artifacts remain intact.

The final installed authored narration check also passed at `/tmp/OpenCompanion-Final-Installed-Narration-c7a504f/explanation-narration-acceptance.json`: both native focus targets, close captions, actual synthesis callbacks, scene-before-enqueue ordering, recovery after unavailable host bounds, stale post-Stop rejection and unchanged pointer/foreground. Submitted-layer tip errors were **0.499886 / 0.783001 logical points**; nearest caption/body gap was **8.485281 logical points**. Its own cursor-window captures were inspected and show only the initial caption prefix “The”. Acoustic timing, whole-desktop composition, displayed FPS and a new physical microphone/shortcut test remain outside this check.

CUA reopened the normal final canonical app after the helpers ended. Its exposed state contained only `org.opencompanion.cursor` and the app menus, with no Dashboard or Notebook open. The geometry-first experiments stay opt-in, default prompts/model routing remain unchanged, and very low latency/general scene-quality acceptance remain unmet. All 21 whole-product gates remain open.

## Earlier diagnostic context

The separately recorded normal-NDJSON Terra/low water and pendulum trials reached first geometry at **17.35022 s** and **21.38729 s**, completing at **33.06665 s** and **33.87206 s**. They spent less than one second before turn acceptance; substantial waits occurred afterward. These are historical diagnostic observations, not matched controls for a new candidate. They do not isolate queueing, prompt processing or generation. See the [scene-pointing report](SCENE-CURSOR-POINTING.md) for artifact identity, admission results and the separate native verification boundary. No six-second saving, acoustic improvement or general quality equivalence is promised.
