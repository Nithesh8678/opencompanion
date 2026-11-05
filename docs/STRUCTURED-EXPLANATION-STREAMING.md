# Structured explanation streaming: experimental checkpoint

**Source checkpoint, 5 November 2026.** The new opt-in `--structured-spatial-steps` path is implemented and the full local suite passes **533 Swift tests** (471 app across 60 suites, 21 store, 41 core). Its signed build, real-model trial, native output check and clean installation are pending. Neither this source result nor the earlier schema experiments promotes an output format or changes the model default.

The current installed source remains `96180a1d07a6f28a7601fc8889cf6be519e5f9ea`, which passed **498 local Swift tests**, a signed build and exact-source [CI run `42052198287`](https://github.com/Nithesh8678/opencompanion/actions/runs/42052198287), including native tests/build and protocol checks. Its executable SHA-256 is `1ba5094a3e38aa22f9bf856cd96af4696e63f8c482301075857d724124acc787`; receipt/Info.plist/hash agree, the existing certificate's deep strict signature and designated requirement are valid, and cleanup reported no issues. Reopening through CUA checked only cursor Accessibility state, without Dashboard/Notebook. A separate normal NDJSON/Terra water control and native render passed on that binary; no physical input or audio check is inferred. Older native motor evidence remains tied to `6e55f75`; see [feature status](FEATURE-STATUS.md).

Historical original-schema trials failed explanation quality or native admission; unified Terra completed with no scene units, while unified Luna retained three atoms before a later scene was rejected. Neither produced an accepted complete lesson. The new scene-required path has no real-model result yet. Defaults and native quality gates remain unchanged.

Normal production output remains **NDJSON**, with the existing **Terra** selection policy unchanged. Passing a schema or pipe fixture does not establish useful geometry, scientific accuracy, native rendering, speech alignment or lower answer latency.

## Scope and wire format

The explicit structured modes add a raw JSON Schema to `turn/start.outputSchema` and request one final object. The original `CodexOutputMode.structuredScene` and alternate `structuredUnifiedScene` use this units envelope; the new `structuredSpatialSteps` uses the separate steps format below:

```json
{"units":[{"type":"text","text":"A short explanation."},{"type":"scene","title":"Public lesson","nodes":[],"removeIDs":[],"animations":[]}]}
```

This example shows framing only; an empty scene does not pass the lesson-quality gate. Complete text and scene units retain the existing `ProviderUnit` meaning. The prototype supports bounded typed 3D groups, meshes and anchored labels, plus a restricted set of 2D nodes and animations. Geometry variants have exact keys; foreign primitive keys are not added as null placeholders. Genuine nullable fields retain native default semantics.

The adapter rejects these modes **before process startup** unless the immutable response policy authorizes a new standalone notebook explanation, without a retained notebook, supplied scene or image. Conversation, screen guidance and existing-document editing remain outside the experiment. The requested schemas exclude parameters, bindings, expressions, operations, arbitrary assets and renderer code. The older units formats retain the local nested-conformance gap below; the new steps format validates its bundled subset locally. No normal preference is changed.

The existing fresh ephemeral teaching thread remains tool-disabled: read-only sandbox, no approvals, empty dynamic tools, disabled inherited MCP/plugin entries, web search and execution features. The schema grants no external-action capability and does not replace the independent tool-attempt rejection.

The original `StructuredSceneOutputSchema.value` is preserved. The alternate `unifiedValue` replaces the eight-way node union with one node object using nullable unused fields, while requesting the same restricted capabilities and retaining native admission rules. Reducing overlapping node alternatives is a hypothesis about grammar/model selection, not an established fix. The first real unified Terra trial returned text only, so this alternative is neither implicitly selected nor promoted to production.

## Streaming and authority

The client scopes events to the exact thread, active turn and message item. Unrelated thread/turn events are ignored. Current-identity deltas without a started item, duplicate starts, item-type changes, multiple final answer IDs and inconsistent authoritative completions fail.

| Message state | Admission behavior |
|---|---|
| Explicit `final_answer` at item start | Complete unit objects can be delivered progressively from deltas. |
| `commentary` | Does not feed the explanation decoder. |
| Unknown phase, then completed as `final_answer` | Buffer first; decode once when the authoritative completed item identifies it as final. |
| Phase remains unknown | Wait for a successful turn completion; require exactly one completed unknown candidate and no selected final. This compatibility fallback is **not progressive delivery**. |
| Completed-only final item | Decode the authoritative text once, without requiring prior deltas. |

For streamed messages, `item/completed` text must exactly match accumulated deltas. An exact duplicate completion with the same ID, text and completion phase is idempotent; it does not replay units. A changed completion fails. Successful `turn/completed` and an authoritative completed final item are required; interruption, failure, missing completion or a truncated envelope cannot become success.

`StructuredSceneStreamDecoder` is a stateful UTF-8 framing parser. It tracks strings, escapes and nested containers and decodes only complete unit objects. It rejects foreign/duplicate root or unit fields, mixed text/scene fields, unsupported types and trailing content. It does not execute incomplete JSON. Text previews in this mode are emitted for complete text units, rather than partial strings.

Each awaited `onUnit` callback retains native semantic admission, atomic scene transactions, stable IDs, document revisions and current-generation cancellation. The envelope does not make the entire response one transaction. If later framing, completion reconciliation or cancellation fails, earlier accepted atomic units remain retained as partial content; they are not replayed or represented as a completed lesson.

## Bounds and diagnostics

| Boundary | Limit |
|---|---:|
| Aggregate delta text / aggregate authoritative completed text | 2,000,000 UTF-8 bytes each |
| One unit or spatial step | 262,144 UTF-8 bytes |
| One decoded narration unit | 32,000 UTF-8 bytes |
| Envelope units | 96 |
| Spatial steps / physical parts per step | 48 / 1–3 |
| Parser container depth | 32 |
| Message items per turn | 16 |
| Turn/item identifier | 256 UTF-8 bytes |

The supplied schema has its own closed-object, variant and range constraints. Native scene/node/geometry/triangle budgets still apply before allocation; schema adherence does not prove references, connected geometry, label meaning or a useful explanation.

**Server schema, client framing and native admission are distinct.** The adapter supplies a schema for remote generation. The older units formats enforce bounded framing and allowed root/unit fields, then native decoders and transactions enforce supported scene semantics and budgets. Those formats do not fully validate the supplied schema locally: excluded nested bindings or unknown nested fields can reach an existing bounded native decoder or be ignored. This grants no tools or arbitrary execution, but full local enforcement remains their promotion gate. The new spatial-stage compiler validates its immutable bundled subset, including nested closed objects and duplicate keys; it does not replace native graph/transaction admission. Never accept a model-supplied schema as authority.

The explicit public-prompt helper maps `--structured-scene-output` to `structuredScene`, `--structured-unified-output` to `structuredUnifiedScene`, and `--structured-spatial-steps` to `structuredSpatialSteps`. With none it uses NDJSON. Repeated, conflicting or value-bearing format flags reject before output-directory/provider work; no format is an automatic fallback. `--spatial-scene-case water-molecule` or `brushed-dc-motor` selects one existing case. Missing, unknown, repeated or malformed case arguments reject before any provider turn. Results record output mode, selected cases, actual model/effort, unmet quality checks and content-free timing stages.

Only this opt-in public helper stores `narrationPreview`: at most **16,384 UTF-8 bytes total and 64 entries**, truncated at a Unicode-scalar boundary. Recording stops after an omitted suffix; subsequent paragraphs cannot replace it. Byte count and truncation are explicit. This diagnostic is not normal production persistence. The helper supplies public authored prompts, no desktop image, microphone or private notebook; no credentials are written to results.

On a native scene-transaction error, the helper also records `lastRejectedScene`: the bounded error, complete proposal node/mesh counts and at most 128 identity/reference rows (`id`, `kind`, `parentID`, label `targetID`). Identifiers are capped at 256 UTF-8 bytes, errors at 2,048 bytes, with an explicit truncation flag. It contains no node text, geometry, materials or raw response. This summary is built without I/O in the callback; the last accepted document stays unchanged and the original error is rethrown. Graph-diagnostic and format-selection regressions are included in the passing full local suite.

## What is verified and what failed

The subprocess fixture withholds the envelope closing brackets and message/turn completion until both text and scene callbacks acknowledge receipt. It passed, demonstrating actual progressive pipe/unit delivery without waiting for the complete envelope. Other fixtures cover commentary, unrelated identities, unknown-phase compatibility, completed-only fallback, exact duplicate completion, mismatches, missing completion, interruption, cancellation and pre-start scope rejection. These are deterministic authored subprocess responses, not real-model behavior.

The first real `gpt-5.6-luna`, low-effort structured trials had these results:

| Public case | Protocol completed | Text units | Scene units / meshes | Explanation quality |
|---|---:|---:|---:|---|
| Simplified brushed DC motor | Yes | 17 | 0 / 0 | Failed |
| Bent water molecule | Yes | 7 | 0 / 0 | Failed |

Both failed the unchanged progression, mesh/label/geometry and independent content gates. Their successful protocol completion does not count as successful generated lessons. The schema permits text-only unit arrays, and existing notebook policy says scenes are permitted rather than universally mandatory; those are plausible influences, **not a demonstrated explanation of the model's choice**. The first receipts did not retain narration, so they do not establish a refusal, capability claim or instruction conflict.

The subsequent Luna molecule diagnostic retained one brief narration unit describing illustrative water geometry. Its first scene was rejected with **Resource limit exceeded: scene depth**, ending after approximately 85.843 seconds with no scene admitted. The same-case Terra diagnostic also retained one normal water narration unit but rejected its first scene with **Invalid scene: parent must be group**, ending after approximately 18.564 seconds with no scene admitted. These are different failures from the first text-only results and establish that scene-admission failures are not limited to Luna. They do not identify either proposed graph's cause without a structural diagnostic. Native depth and parent validation remained enforced; no schema or prompt correction is inferred from these errors alone.

A subsequent original-schema Terra graph diagnostic ended at approximately 46.841 seconds with **Invalid scene: 3D label anchor** and no admitted scene. Its complete, untruncated rejection summary contained 18 proposed nodes, all `kind:text`, zero meshes, and label targets referencing `oxygen`; even nodes named as assemblies/groups were text. The summary establishes the proposed graph's kinds/references, not why the model selected them.

The first real `structuredUnifiedScene` Terra molecule trial completed the protocol at approximately **28.129 seconds**, producing **22 text units, zero scene units and zero meshes**. Narration described adding atoms/bonds and declared the explanation complete, but no geometry was admitted. The unchanged quality gate failed. This does not establish the cause of either node-union behavior or text-only output, and completion time without geometry is not a successful explanation-latency measurement.

The unified Luna molecule trial admitted **one narration unit and two scene units containing three meshes and no labels**. First accepted geometry arrived at **16.99267 seconds**. A later unit failed with **Invalid scene: 3D mesh needs geometry only**, ending at **43.78207 seconds** without successful protocol completion. Its untruncated rejected summary contained nine mesh rows with repeated oxygen/hydrogen IDs. The earlier three atoms remained retained; they do not establish bonds, a complete lesson, scientific accuracy or native-rendered output. Native admission and all quality gates remained enforced.

The same clean installed binary also ran a normal-path control, without a structured flag:

| Output / model | Public case | Accepted output | First typed geometry / provider finish | Result |
|---|---|---|---|---|
| NDJSON / Terra | Water molecule | 5 meshes, 4 anchored labels; 3 scene, 3 text and 3 progressive geometry units | 24.38992 s / 40.60417 s | Protocol, progression and independent illustrative-geometry checks passed |

A separate native helper loaded the control's saved public scene: all four labels were complete, all **three requested leaders** passed independent full-scene closest-surface ownership before/after programmatic camera movement, and the fourth label had no leader by design. Canonical hints, zero overlap, transparent own-view pixels, foreground/click-through, Clear and teardown passed; the final PNG was visually inspected. That native run did not call the provider, capture the desktop, use audio, physically drag the object or click Clear, or measure FPS. This single successful control helps distinguish the structured failures from normal-path behavior; it proves neither structured-mode success nor general reliability. Older motor and four-document surface checks remain separate historical evidence.

No Luna promotion, lower-latency guarantee, broader concept coverage or complete structured lesson is established. The Luna trial demonstrates partial accepted geometry progression followed by a terminal failure, distinct from a successful completed response. Next acceptance must require useful scene output as well as protocol correctness, repeat the previous failure and held-out cases, preserve the native geometry/surface oracles, and keep first delta, first accepted unit/geometry, provider completion, displayed pixels and audio clocks separate.

## Scene-required spatial steps: implemented, opt-in

`CodexOutputMode.structuredSpatialSteps`, selected only by `--structured-spatial-steps` in the public helper, uses this fixed-role format:

```json
{"steps":[{"text":"A sphere is round.","title":"Sphere","groups":[],"parts":[{"id":"ball","parentID":null,"fill":"#4488CC","opacity":null,"transform":null,"geometry":{"type":"sphere","radius":1,"segments":24}}],"labels":[],"animations":[],"removeIDs":[]}]}
```

This is a minimal transport example, not a complete lesson. Each step requires all seven fields and **one to three typed physical parts**. The envelope permits 1–48 steps; per step, groups/labels are capped at 32 each, animations at 64 and removals at 128. The host maps `groups`, `parts` and `labels` to native group/mesh/anchored-text kinds. The model cannot supply `kind`, `type` or `spatial3D` role overrides. The existing five primitives, material fields, transforms and renderer are reused, without science-name-based correction or new geometry. This format excludes ordinary 2D output and retains the new-standalone-only scope.

`ObjectArrayStreamFramer` releases only complete stage objects, bounded by 2 MB total, 262,144 bytes per stage and 32 nested containers. `StructuredSpatialStageCompiler` validates the immutable bundled schema's supported subset locally before canonical native decoding: exact required/nullable fields, nested closed objects, enums, patterns, finite/ranged numbers, integer segments and array limits. Raw duplicate keys, including escaped spellings at nested levels, are rejected before JSON decoding loses them. Node IDs are unique across the three role arrays; animation and removal IDs are unique within their own arrays. Remove-and-recreate overlaps remain permitted. Validation work is capped at 16,384 visits, with cancellation checks; no caller-supplied schema or external reference is accepted.

The compiler constructs a canonical scene unit and a text unit. It deliberately does **not** decide graph-reference existence, cycles, parent/target semantics, cross-field shape relationships or aggregate world/geometry budgets; the ordinary native scene transaction must still accept them atomically. A valid wire stage is not yet an accepted scene.

Delivery awaits the native **scene callback first**, checks cancellation, then releases the complete narration preview and text callback. A scene rejection releases neither preview nor text. Cancellation after a successful scene callback retains that scene but releases no narration; later errors retain prior accepted transactions as partial content, without replay or false completion. Shared thread/turn/item identity, phase and authoritative-completion checks remain unchanged. Deterministic subprocess fixtures withhold the envelope's closing brackets and item/turn completion until scene, preview and text callbacks acknowledge receipt, proving actual progressive callback delivery. Rejection, cancellation, pre-start scope, identity and non-replay cases pass in the **533-test local suite**.

The helper's `structuredStageProgress` is null outside reported stage mode. It separately records `decodedStages`, `admittedSceneUnits`, `admittedTextUnits` and `completedStages`, including partial failure. For cancellation immediately after one accepted scene, the counters are **1 / 1 / 0 / 0**. These are callback-admission clocks and counts, not visible pixels, spoken samples or successful provider completion.

Structural requirements do not prove a useful or visible lesson: a part can be fully transparent, an existing ID can be updated, and a one-step envelope is allowed. The prompt asks multipart lessons to use at least three steps; that is not a schema guarantee, and the existing helper still requires at least two units adding previously unseen geometry. Labels, progression, independent illustrative geometry and final native visible-surface/pixel checks remain separate quality gates. The recording's scale/fade, travelling assistant, direct floating orbit, component/speech alignment and acoustic/FPS behavior are not established by scene-before-text callback ordering.

This new mode has passed local compiler, decoder and subprocess transport tests only. Its signed build, real-model trial, native output check and clean installation are pending. No default promotion, lower-latency result, scientific accuracy or complete real-model lesson is claimed.

## Official contract versus local evidence

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server) documents current-turn `outputSchema`, streamed agent-message deltas and authoritative item completion. The installed CLI's generated schema describes a constraint on the **final assistant message**; this does not make arbitrary commentary schema-shaped or promise a particular chunk cadence for every model.

The [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs) documents streaming, closed objects, required/nullable properties and a supported JSON Schema subset, with refusal/incomplete-output handling still required. Its API guarantees must not be inflated into a claim that this client or every account/model produces useful progressive scenes. The subprocess checks, real structured-mode failures and normal-path native control remain separate evidence.
