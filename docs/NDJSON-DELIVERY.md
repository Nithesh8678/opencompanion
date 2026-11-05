# NDJSON delivery and scene grammar

The delivery correction applies to normal Codex NDJSON responses; its content-derived audit is opt-in for the explicit fixed-public-scene helper. A separate notebook-prompt clarification fixes label/connector placement and separates whole-response generation from locally queued speech playback. Model selection, effort, introduction-first ordering and native validators remain unchanged. No latency improvement or general lesson-quality claim follows from this adapter correction. No new live result is recorded here yet.

## Delivery and admission boundaries

The [official app-server contract](https://learn.chatgpt.com/docs/app-server) identifies completed items as authoritative and links deltas by item identity. The prior adapter ignored completed text and shared one line buffer across item boundaries. This could drop completed-only content or join distinct messages. The 12 earlier trials lack item-level receipts, so neither gap is claimed as their proven cause.

The app-server can deliver several sequential agent-message items within one owned turn. Each item has its own declared phase, streamed deltas and authoritative completed text. A turn is not complete merely because one item ended, a starter part was admitted, or a text delta stopped arriving.

The NDJSON adapter binds the expected thread and turn, tracks bounded item identities internally, and feeds complete protocol lines through awaited host admission. At an authoritative item completion it compares the completed text with the exact UTF-8 streamed prefix. A matching suffix can supply bytes that were absent from deltas; an identical completion cannot replay accepted units. Changed prefixes, overlapping or restarted items, identity/type/phase conflicts, malformed protocol and unsupported host capabilities remain failures. Earlier admitted content stays retained on a later failure. This does not repair or coerce a rejected scene.

The terminal audit separates transport-delivered bytes, protocol/admission counts and the terminal outcome. It cannot establish useful geometry, complete requested parts, rendered pixels, correct focus, native presentation, sound or an external task result. Existing independent motor, molecule and static-pendulum checks continue to decide fixture quality.

## Notebook generation grammar

All group, mesh and text-label nodes belong in `nodes`; `connectors` contains only endpoint recipes. A connector label still belongs in `nodes`, even when it targets a connector created atomically in that same unit. The updated generic prompt sample shows both arrays together, and the prohibition on duplicating a generated connector explicitly does not prohibit its separate text label. The decoder still rejects the observed malformed mixed array; no parser repair or inferred geometry is added.

The prompt also distinguishes generating all requested units now from the native host's later scene/speech queue. It preserves both existing startup modes rather than promoting the failed geometry-first experiment. Conversation and guidance prompt fingerprints stay unchanged. Positive admission of the actual embedded generic sample and negative mixed-array retention tests accompany the wording change; model adherence and scientific usefulness require live and independent checks.

## Public-helper opt-in and receipt

Only `--spatial-scene-live-acceptance` with normal NDJSON installs the optional `onNDJSONAudit` callback. Normal AppModel requests leave it nil. Structured experiments do not opt into this audit. No global preference, account setting, model, effort, routing or service tier changes.

Each per-case `result.json` records:

- `ndjsonAuditRequested`: whether this public request installed the callback. The aggregate receipt repeats this flag.
- `ndjsonAudit`: the Codable terminal snapshot, or null when no callback arrived. Setup can fail before the tracker exists; requested=true with a null snapshot must not be treated as completed delivery.
- The existing failure, timing, scene-start, accepted-scene, first-admission and quality fields remain unchanged. The audit is retained even when the provider throws after earlier admission. A duplicate terminal callback cannot replace the first retained snapshot.

The snapshot contains a closed outcome (`completed`, `failed` or `cancelled`), total accepted units, delta/completed byte counts, completion-only item and duplicate-completion counts, ignored-scope-event count, and at most 16 local ordinal item rows. Item rows carry bounded phase metadata, start/delta/completion status and byte counts, appended-suffix bytes and SHA-256 fingerprints of streamed/completed text. They contain no remote item/thread/turn IDs, prompts, response text, node names or screenshot/audio content. Fingerprints are still content-derived diagnostics; keep this explicit public-fixture scope rather than enabling them for normal private conversations.

Audit byte counts are not tokens. Completed-byte totals can include repeated completion notifications; accepted-unit counts are not native-render or speech counts. The scalar audit does not expose the model's internal plan or distinguish remote queueing, reasoning, generation and network delay.

## Planned default-path check

After freezing one signed executable with the adapter and helper integration, run the three original cases sequentially. Use the same configured CLI/account/model, no concurrent provider request, unchanged public prompts/oracles, and a new private artifact root. Do not pass `--geometry-first` or a structured-output flag: the start mode stays `introductionFirst` and output stays NDJSON. These commands are a plan, not an executed result:

```sh
"$trial_executable" \
  --spatial-scene-live-acceptance "$trial_root/01-motor" \
  --spatial-scene-case brushed-dc-motor

"$trial_executable" \
  --spatial-scene-live-acceptance "$trial_root/02-water" \
  --spatial-scene-case water-molecule

"$trial_executable" \
  --spatial-scene-live-acceptance "$trial_root/03-pendulum" \
  --spatial-scene-case simple-pendulum
```

Run every row even after a quality failure. Preserve per-case/aggregate receipts, exit codes, logs and public scenes; preserve a bounded rejected public unit when the existing explicit helper records one. Report actual source/binary identity, model/effort/routing, audit presence/outcome, item phases and byte reconciliation, admitted units, first geometry, completion and every unmet quality check. Compare adapter evidence with fixture quality without relabeling a protocol pass as a complete lesson. No silent retries or replacement of the earlier [first-geometry experiment](FIRST-GEOMETRY-LATENCY.md) artifacts.

Local diagnostics tests cover absent callbacks, failed terminal snapshots after rejected admission, immutable first terminal ownership and cancellation without invented admission. The focused run passed 84 tests in seven suites; the full run passed 725 tests (653 app across 78 suites, 21 store across two and 51 core across four). The signed build and planned real-provider requests remain pending at this source checkpoint. Any later native rendering, physical microphone or user-action acceptance needs its own artifact and scope.
