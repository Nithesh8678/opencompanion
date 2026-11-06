# NDJSON delivery and scene grammar

The delivery correction applies to normal Codex NDJSON responses; its content-derived audit is opt-in for the explicit fixed-public-scene helper. A separate notebook-prompt clarification fixes label/connector placement and separates whole-response generation from locally queued speech playback. Model selection, effort, introduction-first ordering and native validators remain unchanged. No latency improvement or general lesson-quality claim follows from this adapter correction. The three new exact-installed trials below all completed delivery; only water passed the unchanged independent geometry checks. Neither broad quality nor low latency is established.

## Delivery and admission boundaries

The [official app-server contract](https://learn.chatgpt.com/docs/app-server) identifies completed items as authoritative and links deltas by item identity. The prior adapter ignored completed text and shared one line buffer across item boundaries. This could drop completed-only content or join distinct messages. The 12 earlier trials lack item-level receipts, so neither gap is claimed as their proven cause.

The app-server can deliver several sequential agent-message items within one owned turn. Each item has its own declared phase, streamed deltas and authoritative completed text. A turn is not complete merely because one item ended, a starter part was admitted, or a text delta stopped arriving.

The NDJSON adapter binds the expected thread and turn, tracks bounded item identities internally, and feeds complete protocol lines through awaited host admission. At an authoritative item completion it compares the completed text with the exact UTF-8 streamed prefix. A matching suffix can supply bytes that were absent from deltas; an identical completion cannot replay accepted units. Changed prefixes, overlapping or restarted items, identity/type/phase conflicts, malformed protocol and unsupported host capabilities remain failures. Earlier admitted content stays retained on a later failure. This does not repair or coerce a rejected scene.

The terminal audit separates transport-delivered bytes, protocol/admission counts and the terminal outcome. It cannot establish useful geometry, complete requested parts, rendered pixels, correct focus, native presentation, sound or an external task result. Existing independent motor, molecule and static-pendulum checks continue to decide fixture quality.

## Notebook generation grammar

All group, mesh and text-label nodes belong in `nodes`; `connectors` contains only endpoint recipes. A connector label still belongs in `nodes`, even when it targets a connector created atomically in that same unit. The updated generic prompt sample shows both arrays together, and the prohibition on duplicating a generated connector explicitly does not prohibit its separate text label. The decoder still rejects the observed malformed mixed array; no parser repair or inferred geometry is added.

The prompt also distinguishes generating all requested units now from the native host's later scene/speech queue for new standalone explanations; retained notebook edits update immediately. It preserves both existing startup modes rather than promoting the failed geometry-first experiment. Conversation and guidance prompt fingerprints stay unchanged. Positive admission of the actual embedded generic sample and negative mixed-array retention tests accompany the wording change; model adherence and scientific usefulness require live and independent checks.

## Public-helper opt-in and receipt

Only `--spatial-scene-live-acceptance` with normal NDJSON installs the optional `onNDJSONAudit` callback. Normal AppModel requests leave it nil. Structured experiments do not opt into this audit. No global preference, account setting, model, effort, routing or service tier changes.

Each per-case `result.json` records:

- `ndjsonAuditRequested`: whether this public request installed the callback. The aggregate receipt repeats this flag.
- `ndjsonAudit`: the Codable terminal snapshot, or null when no callback arrived. Setup can fail before the tracker exists; requested=true with a null snapshot must not be treated as completed delivery.
- The existing failure, timing, scene-start, accepted-scene, first-admission and quality fields remain unchanged. The audit is retained even when the provider throws after earlier admission. A duplicate terminal callback cannot replace the first retained snapshot.

The snapshot contains a closed outcome (`completed`, `failed` or `cancelled`), total accepted units, delta/completed byte counts, completion-only item and duplicate-completion counts, ignored-scope-event count, and at most 16 local ordinal item rows. Item rows carry bounded phase metadata, start/delta/completion status and byte counts, appended-suffix bytes and SHA-256 fingerprints of streamed/completed text. They contain no remote item/thread/turn IDs, prompts, response text, node names or screenshot/audio content. Fingerprints are still content-derived diagnostics; keep this explicit public-fixture scope rather than enabling them for normal private conversations.

Audit byte counts are not tokens. Completed-byte totals can include repeated completion notifications; accepted-unit counts are not native-render or speech counts. The scalar audit does not expose the model's internal plan or distinguish remote queueing, reasoning, generation and network delay.

## Frozen default-path trial

The signed installed executable at source `a5cdbd5d218e9690664fcb4548019823eea17790` ran the three original cases sequentially using the same configured CLI/account/model, no concurrent provider request and unchanged public prompts/oracles. The private artifact root is `/tmp/OpenCompanion-NDJSON-Delivery-2026-11-06-a5cdbd5/`; its manifest freezes source/binary identity and its summary retains all three results. No `--geometry-first`, structured-output or explicit model flag was supplied: startup stayed `introductionFirst`, output stayed NDJSON, and receipts report actual `gpt-5.6-terra`, low effort, routing `terraVisual`. The executed command pattern was:

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

Every row ran once, including after a quality failure. Per-case and aggregate receipts, exit codes, logs and scenes remain retained. No rejected protocol line was recorded. No earlier [first-geometry experiment](FIRST-GEOMETRY-LATENCY.md) artifact was replaced, and no old failure is retroactively assigned a transport cause.

Local diagnostics tests cover absent callbacks, failed terminal snapshots after rejected admission, immutable first terminal ownership and cancellation without invented admission. The initial focused run passed 84 tests in seven suites. After review added a contradictory-turn-ID regression and qualified retained-edit playback wording, the final full run passed 726 tests (654 app across 78 suites, 21 store across two and 51 core across four). The final signed build and exact-source CI passed; live and native evidence follows. Physical microphone, acoustic and user-action acceptance remains separately scoped.


## Exact-installed results, 6 November 2026

All elapsed times are seconds from request start, rounded to three decimals. These are three separate requests, not latency distributions or controlled comparisons against older prompts. Shared notebook instructions were 12,277 UTF-8 bytes; the grammar change means they are a new prompt treatment. Introduction-first remains the default, geometry-first remains opt-in, and no model/effort change is promoted.

| Public case | Independent quality / exit | Meshes / labels | Progressive scene units | First text delta | First typed geometry | Provider finish |
| --- | --- | --- | --- | --- | --- | --- |
| Brushed DC motor | Failed: `motor-coaxial-axes` / 1 | 7 / 5 | 3 | 13.986 | 21.089 | 71.367 |
| Water molecule | Passed / 0 | 5 / 3 | 3 | 8.604 | 14.226 | 45.866 |
| Static pendulum | Failed: `pendulum-rod-connects-parts` / 1 | 3 / 3 | 3 | 28.090 | 33.479 | 59.119 |

All three had one started `final_answer` item, completed delivery audits and matching streamed/completed SHA-256 and UTF-8 byte lengths: motor 7,370; water 4,769; pendulum 4,507. Each admitted four protocol units: one standalone introduction and three scenes with attached narration. The collector's four text units include those three narrations; they are not seven wire units. Every audit recorded zero missing-suffix bytes, completed-only items, duplicate completions and ignored-scope events. Thus authoritative response bytes were fully delivered for these requests. This does not establish that earlier turns had the same event sequence, nor does it live-test the completed-only recovery exercised by the deterministic fixtures.

The motor has a world housing axis `(-1,0,0)` while rotor, shaft and commutator axes are `(0,0,1)` after their extra local rotation: approximately 90 degrees apart, versus the oracle's 10-degree limit. Its commutator is also 1.26 world units off-axis, exceeding the 0.3375 tolerance. The pendulum rod's upper axial endpoint is approximately `(0.001253,1.798709,0)`; the support's lower surface is at `y=1.825`, leaving a 0.026291 gap. The lower endpoint enters the bob. These are model-authored transform/contact errors, not evidence of dropped transport content. No oracle was weakened and neither invalid lesson received a native rendering acceptance run.

The successful water lesson used two static connector recipes, compiled into two native cylinder bonds, and all three required atom labels. Its exact-installed native check at `/tmp/OpenCompanion-NDJSON-Native-Water-a5cdbd5/explanation-acceptance.json` passed: five meshes, three complete visible non-overlapping labels, all three requested leaders independently resolved to the full-scene closest target triangle before and after programmatic camera movement, unchanged canonical hints, passive foreground, Clear and teardown. Composite sampling matched 66/66; separate synthetic own-view orbit also passed. The own-view PNG was inspected and shows the connected bent molecule with white labels and leaders. This used no provider, desktop capture, audio, physical orbit/Clear click or FPS measurement; it is a separate native run loading the newly generated public document.

Two separately retained authored native narration checks stopped before their first speech range on the unchanged physical-pointer-baseline guard. First receipt: `/tmp/OpenCompanion-NDJSON-Native-Narration-a5cdbd5/explanation-narration-acceptance.json`; separate repeat: `/tmp/OpenCompanion-NDJSON-Native-Narration-Repeat-a5cdbd5/explanation-narration-acceptance.json`. Both observed stage-one scene submission before synthesis enqueue and a native speech start, but neither verified focus arrival, close captions, completion, cancellation or unchanged pointer. No source of pointer movement was established, no pointer automation was posted, no guard was relaxed and no further repeat was performed. Earlier successful native/user reports remain attributed to their earlier binaries; they do not convert these failures into passes.

The single canonical `/Applications/OpenCompanion.app` is certificate-signed with the existing local identity, Team `BPR2T4D656`; strict deep verification passed with normal Keychain trust access. Source revision in build/install receipts and Info.plist agrees, with actual executable SHA-256 `546fd1984a84d43ac31f3bb78c8f90d1add9a818e83e06c1270efc00b2c2883c`. Cleanup issues are empty, no temporary build/staging app bundles remain, and no second installed copy was found. [Exact-source CI 42102369738](https://github.com/Nithesh8678/opencompanion/actions/runs/42102369738) passed; the remote `main` SHA was independently verified after pushing both source commits, and repository metadata reported public visibility. CUA then reopened the normal canonical app; accessibility exposed only `org.opencompanion.cursor` and menus, with no Dashboard or Notebook surface. This remains a local build, without a new distribution or full parity claim. All 21 whole-product gates remain open.
