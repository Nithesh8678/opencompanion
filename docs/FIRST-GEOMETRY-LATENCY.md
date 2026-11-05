# First-geometry latency experiment

Prepared 6 November 2026. This is an opt-in public-fixture benchmark plan and implementation contract. No benchmark request was run while adding this helper. Normal app requests retain introduction-first NDJSON, existing routing and disabled extra latency measurements. No model, effort, service tier, authentication or account preference is changed by the flag.

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

Before freezing the benchmark, **692 local Swift tests passed**: 620 application tests across 74 suites, 21 store tests across two suites and 51 core tests across four suites. The new checks cover unchanged default prompts, opt-in scope, framing/decoding boundaries, first-handler ownership, content-free counts, and cancellation during diagnostic observers. A stopped request cannot submit its turn or deliver its scene after those observers suspend. These are local regression checks, separate from the pending real-provider comparisons.

## Earlier diagnostic context

The separately recorded normal-NDJSON Terra/low water and pendulum trials reached first geometry at **17.35022 s** and **21.38729 s**, completing at **33.06665 s** and **33.87206 s**. They spent less than one second before turn acceptance; substantial waits occurred afterward. These are historical diagnostic observations, not matched controls for a new candidate. They do not isolate queueing, prompt processing or generation. See the [scene-pointing report](SCENE-CURSOR-POINTING.md) for artifact identity, admission results and the separate native verification boundary. No six-second saving, acoustic improvement or general quality equivalence is promised.
