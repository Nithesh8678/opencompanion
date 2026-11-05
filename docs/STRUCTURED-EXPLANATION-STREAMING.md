# Structured explanation streaming: experimental checkpoint

**Checkpoint, 5 November 2026.** This is an opt-in output-format experiment, not a promoted explanation path or a model-default change. The completed full local suite passes **498 Swift tests** (436 app across 57 suites, 21 store, 41 core), and a signed experimental build passed. A clean committed-source replacement installation is still forthcoming. Original-schema trials failed explanation quality or native admission; unified Terra completed with no scene units, while unified Luna retained three atoms before a later scene was rejected. Neither produced an accepted complete lesson. Defaults and native quality gates remain unchanged.

Normal production output remains **NDJSON**, with the existing **Terra** selection policy unchanged. Passing a schema or pipe fixture does not establish useful geometry, scientific accuracy, native rendering, speech alignment or lower answer latency.

## Scope and wire format

The explicit structured modes add a raw JSON Schema to `turn/start.outputSchema` and request one final object. The original mode is `CodexOutputMode.structuredScene`; the alternate is `structuredUnifiedScene`:

```json
{"units":[{"type":"text","text":"A short explanation."},{"type":"scene","title":"Public lesson","nodes":[],"removeIDs":[],"animations":[]}]}
```

This example shows framing only; an empty scene does not pass the lesson-quality gate. Complete text and scene units retain the existing `ProviderUnit` meaning. The prototype supports bounded typed 3D groups, meshes and anchored labels, plus a restricted set of 2D nodes and animations. Geometry variants have exact keys; foreign primitive keys are not added as null placeholders. Genuine nullable fields retain native default semantics.

The adapter rejects these modes **before process startup** unless the immutable response policy authorizes a new standalone notebook explanation, without a retained notebook, supplied scene or image. Conversation, screen guidance and existing-document editing remain outside the experiment. The requested schemas exclude parameters, bindings, expressions, operations, arbitrary assets and renderer code; complete local enforcement of nested schema exclusions remains a promotion gate below. No normal preference is changed.

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
| One unit | 262,144 UTF-8 bytes |
| One decoded narration unit | 32,000 UTF-8 bytes |
| Envelope units | 96 |
| Parser container depth | 32 |
| Message items per turn | 16 |
| Turn/item identifier | 256 UTF-8 bytes |

The supplied schema has its own closed-object, variant and range constraints. Native scene/node/geometry/triangle budgets still apply before allocation; schema adherence does not prove references, connected geometry, label meaning or a useful explanation.

**Server schema, client framing and native admission are distinct.** The adapter supplies a schema for remote generation. Its local parser enforces bounded framing and allowed root/unit fields, then native decoders and transactions enforce supported scene semantics and budgets. This is not a complete local validator for the supplied schema. In particular, excluded nested bindings or unknown nested fields are not comprehensively rejected by the framing layer: an underlying native decoder can accept its existing bounded feature or ignore an unknown field. That does not grant tools or arbitrary execution, but it prevents claiming full client-side prototype conformance. Before promotion, validate against the trusted bundled schema locally, or explicitly enforce every prototype exclusion at the native boundary; never accept a model-supplied schema as authority.

The explicit public-prompt helper maps `--structured-scene-output` to the original `structuredScene` mode and `--structured-unified-output` to `structuredUnifiedScene`. With neither flag it uses NDJSON. Repeated, conflicting or value-bearing format flags reject before output-directory/provider work; neither format is an automatic fallback for the other. `--spatial-scene-case water-molecule` or `brushed-dc-motor` selects one existing case. Missing, unknown, repeated or malformed case arguments reject before any provider turn. Results record output mode, selected cases, actual model/effort, unmet quality checks and content-free timing stages.

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

No Luna promotion, lower-latency guarantee, broader concept coverage or complete structured lesson is established. The Luna trial demonstrates partial accepted geometry progression followed by a terminal failure, distinct from a successful completed response. Next acceptance must require useful scene output as well as protocol correctness, repeat the previous failure and held-out cases, preserve the native geometry/surface oracles, and keep first delta, first accepted unit/geometry, provider completion, displayed pixels and audio clocks separate.

## Next design proposal: scene-required steps, not implemented

The proposed next contract replaces a text-or-scene unit choice with a bounded `steps` array. Each step must contain a scene proposal and narration. Scene data has fixed-role `groups`, `parts` and `labels` arrays, with **at least one part** rather than an all-text alternative. The host assigns native group/mesh/anchored-text kinds from those roles. This reuses the existing five geometry primitives and renderer; it adds no science-name-based correction or geometry capability. Required labels and progression still need explicit quality acceptance rather than an assumption that a nonempty part array makes a useful lesson.

Before delivery, a proposed compiler must validate the trusted bundled schema locally, reject foreign fields and duplicate IDs, check group/target references and budgets, and construct a canonical native scene transaction. The host must accept that complete transaction atomically **before releasing the step's narration**. A rejected step leaves previous accepted steps retained as partial content and stops the response; it must not announce the rejected geometry as complete, silently repair its semantic roles or replay earlier steps. Existing generation/revision and cancellation authority remain in force.

Diagnostics must distinguish a decoded transport step, canonical scene validation, host acceptance, native first pixels, narration delivery, acoustic output and successful provider completion. A completed envelope is not a completed lesson until independent content/native acceptance passes. This is a design recommendation only: no step-schema parser, compiler, delivery ordering, real comparison or test pass is claimed, and neither experimental mode nor the production default changes here.

## Official contract versus local evidence

The [official app-server documentation](https://learn.chatgpt.com/docs/app-server) documents current-turn `outputSchema`, streamed agent-message deltas and authoritative item completion. The installed CLI's generated schema describes a constraint on the **final assistant message**; this does not make arbitrary commentary schema-shaped or promise a particular chunk cadence for every model.

The [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs) documents streaming, closed objects, required/nullable properties and a supported JSON Schema subset, with refusal/incomplete-output handling still required. Its API guarantees must not be inflated into a claim that this client or every account/model produces useful progressive scenes. The subprocess checks, real text-only failures and future native checks remain separate evidence.
