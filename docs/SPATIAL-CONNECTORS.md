# Static spatial connectors: contract and evidence

Source-stage checkpoint, 5 November 2026. The source adds host-compiled endpoint connectors to the normal NDJSON scene protocol and passes **587 local Swift tests**: 515 app tests across 65 suites, 21 store tests and 51 core tests across four suites. One real Terra water trial used two host-compiled connectors and passed the unchanged independent geometry checks. An earlier water trial failed the line protocol, and a pendulum pass used no connectors; both remain recorded below. A clean signed build/installation and separate native-render check remain **pending**. The earlier 560-test result predates connector support. Production defaults remain NDJSON with the existing Terra selection policy. Structured scene/steps modes remain explicit experiments and do not gain this field.

## Why add construction rather than more geometry advice?

The narrow preceding experiment clarified solid versus hollow primitives and made cutaway advice conditional. It did not establish general explanation reliability. The held-out pendulum used the expected box, cylinder and sphere, but its independently specified cylinder stopped short of the support. The connector contract lets the model identify endpoints while native code derives one cylinder's midpoint, length and orientation. It does not infer the right scientific parts, choose a missing target or repair a model-authored mesh.

## Wire and native construction

`ProviderUnit.connectors` is an optional array on an NDJSON `scene` unit. For two typed meshes already created in the same or an earlier unit:

```json
{"type":"scene","nodes":[],"connectors":[{"id":"link","from":{"targetID":"part-a"},"to":{"targetID":"part-b"},"radius":0.05,"fill":"#AABBCC","parentID":"assembly"}],"removeIDs":[]}
```

This example requires those meshes and the optional `assembly` group to exist; it is not a complete standalone lesson. Each endpoint requires `targetID`. Its optional `point:{x,y,z}` is in that target's local coordinates and defaults to its center. The host does **not** move that point onto a surface or check that it represents the intended semantic attachment. Appropriate endpoints and independently checked connections still matter.

The connector requires `id`, `from`, `to`, positive `radius` and `fill`. Optional `segments` defaults to 24 and `opacity` to 1. With no `parentID`, the resulting cylinder is in world space. A supplied parent must be an existing typed 3D group; radius and the generated cylinder dimensions use that parent's local units. Parent scaling therefore affects the world-space cross-section.

`SpatialConnectorCompiler` composes the two targets' transforms to obtain world endpoints, then converts them into the connector parent's space when supplied. It derives the midpoint, endpoint distance and rotation mapping the cylinder's local +Y axis onto the endpoint direction. The result is an ordinary typed `SceneNode` mesh using the existing solid-cylinder geometry. No new renderer primitive, name-based shape inference, asset, URL, executable expression or custom shader is introduced. Connector payloads cannot also supply geometry or a transform.

This is **one-time static construction**. Endpoints, their ancestor chains and the connector parent's ancestor chain must be unbound and unanimated. The new connector cannot be animated in its construction transaction. Its recipe is not retained in the saved `SceneDocument`: only the ordinary generated cylinder is saved. Later edits do not make it follow an endpoint. Explicitly remove and recreate an affected connector after moving its attachments; this is not a persistent joint, constraint solver or physical simulation.

## Admission and bounds

- At most **16 connectors per scene unit**. IDs are nonempty and at most 256 UTF-8 bytes.
- Every connector ID must be unique and absent from the proposed working graph, including its supplied nodes. An explicit prior removal permits recreation. Endpoints cannot reference another connector being created by that batch.
- Endpoints must reference actual typed meshes; the optional parent must reference an actual typed group. Same-transaction labels may target the newly generated connector.
- Endpoint coordinates must be finite and within the configured spatial dimension bound, capped at 1,000 per component. Transformed world coordinates must satisfy the scene coordinate budget. Singular parent transforms, cycles, excessive ancestry and coincident/too-short endpoints reject.
- Cylinder radius/length and segment counts use existing geometry validation: default dimensions 0.001–1,000 and segments 3–64. Existing node, operation, vertex/triangle and final-document budgets still apply; adding a recipe does not bypass them.

`ProviderSceneBoundary` resolves recipes against the complete proposed graph after explicit operations, removals and node replacements. It adds generated meshes to the **same atomic transaction** and performs final native document admission. It does not publish an intermediate graph or increment the revision separately for a connector. A failed reference, recipe, geometry or final transaction rejects that unit without mutating the accepted document. Earlier accepted response units remain partial content. Existing generation ownership and document-revision checks remain in force.

Source boundaries: [wire and prompt](../Sources/OpenCompanion/Provider.swift), [endpoint math and validation](../Sources/CompanionCore/SpatialConnector.swift), [atomic provider admission](../Sources/OpenCompanion/ProviderSceneBoundary.swift). Native rendering and saved-document handling continue to consume ordinary typed meshes.

## Pre-connector public trials

These debug trials used modified source based on `f0950ac`, not an installed release and not connector-enabled code. The first two calls were started concurrently, so their durations are **not a controlled model-latency comparison**. A successful protocol completion is separate from the fixture's explanation-quality result.

| Public case / explicit mode | Actual model / effort | Scene + text units | Meshes / anchored labels | First typed geometry / provider finish | Independent quality result |
|---|---|---:|---:|---:|---|
| Simplified brushed DC motor / structured steps | `gpt-5.6-terra` / low | 4 + 4 | 7 / 6 | 50.60624s / 71.51813s | Failed `motor-axial-part-roles`; protocol completed. |
| Water molecule / structured steps | `gpt-5.6-luna` / low | 3 + 3 | 5 / 3 | 13.40080s / 24.81710s | Passed the existing water geometry checks, with spheres and cylinders; protocol completed. |
| Static simple pendulum / normal NDJSON | `gpt-5.6-terra` / low | 3 + 3 | 3 / 3 | 17.28340s / 30.45405s | Failed `pendulum-rod-connects-parts`; protocol completed. |

The motor/water executable SHA-256 was `e5e9b55e9e932348d65238ceb8ae0de26254f0eda9dc916396e34fbcdbe186d2`, at the **559-test** debug checkpoint. The pendulum executable SHA-256 was `1d7e79dc75d7dc62ff8b2140608b324c9abb76086c85d32f8893c5936fc2a6d2`, at the **560-test** debug checkpoint, after adding the static-pendulum assertion. Neither hash establishes signed installed-release provenance or connector support.

The pendulum's rod top was at Y=1.15 while the support's bottom was at Y=1.175: a real 0.025-unit gap, despite correct primitive categories and labels. The new held-out oracle requires distinct visible solid support/rod/bob roles, no animations, and the rod's actual transformed endpoints to enter the support and bob in either orientation. It checks composed transforms and rejects disconnected or excessive-length rods. It does not claim pendulum dynamics. The existing motor and water quality oracles remain unchanged; no tolerance is widened to turn these failures into passes.

These provider checks use public authored requests without desktop capture or audio. No native rendering, acoustic timing, physical accuracy, human interaction or FPS is verified by their results. One later Luna water success does not erase earlier failures or justify a model/default change. See [structured streaming evidence](STRUCTURED-EXPLANATION-STREAMING.md) for the historical experimental formats.

## Connector verification checkpoint

The passing 587-test suite includes 11 core connector cases across 10 test methods and nine provider-boundary tests, with asynchronous collector coverage for committed connector counts and retention of the accepted document after a rejected later unit. Bounded rejected-line diagnostics and their opt-in transport behavior are also covered. These are deterministic local construction/admission checks, not evidence that the installed renderer displayed the result.

The first connector-enabled debug executable SHA-256 was `afa3fdc7d9e1ac38d0415510fc4e8528e941847321c0b640e33c1984b5e064e9`. The diagnostic-enabled debug executable was `2cf6da1ace6f6f07a9d1396f08a9019832d5ef8eeef6efeffd2aa5162421bc89`. Both used modified source based on `f0950ac`; neither is an installed signed release or either pre-connector artifact above.

All three following trials used normal NDJSON with actual `gpt-5.6-terra`, low effort, and public authored requests:

| Debug artifact / public case | Result | Scene + text units | Meshes / anchored labels | Connector units / compiled connectors | First typed geometry / terminal time |
|---|---|---:|---:|---:|---:|
| `afa3fdc7` / static pendulum | Passed the static endpoint/role checks; protocol completed. | 3 + 3 | 3 / 3 | 0 / 0 | 23.39097s / 34.85053s |
| `afa3fdc7` / water molecule | Failed the line protocol before the next unit callback; protocol did not complete. | 2 + 3 retained | 3 / 3 retained | 0 / 0 | 13.96947s / 30.96208s |
| `2cf6da1a` / one diagnostic water retry | Passed unchanged water geometry checks; protocol completed. | 3 + 3 | 5 / 3 | 1 / 2 | 19.62690s / 32.60357s |

The pendulum pass used an ordinary model-authored cylinder, so it proves no live connector use. The first water trial retained three spheres and three labels but lacked the two bonds; it failed mesh-count, geometry-variety and atom-connection checks. Its `lastRejectedScene` was null: the failure occurred in line decoding, not native scene admission. The diagnostic retry actually emitted one connector-bearing unit and native code compiled two cylinders, producing the five-mesh water model. Its result had no rejected public unit recorded. This verifies live use on one public case, not general reliability, a controlled latency improvement or the cause of the earlier protocol failure.

### Bounded public diagnostics

`ProviderTextStreamDecoder` and `CodexProvider.stream` accept an optional `onRejectedLine` callback, defaulting to nil. Only the fixed-public-prompt acceptance helper opts in. It retains the first failed line up to the existing **262,144-byte (256 KiB)** line bound and can write `public-rejected-unit.txt` into its local output directory. Normal AppModel and BYOK operation do not opt in; structured modes do not use this callback. No rejected model payload is copied into this repository.

The diagnostic does not retry, reinterpret, repair or admit malformed JSON. Earlier accepted transactions remain partial content and the original error is rethrown. The successful diagnostic retry produced no failed-line artifact, so the first water failure's underlying cause remains **unresolved**. A successful later response is not a diagnosis of an earlier one.

## Pending verification and remaining limits

The source-stage checkpoint now has deterministic construction/admission coverage and one real water trial with measured connector use. It still needs a clean signed build/install receipt and a separate native check of that admitted document. The public provider helper records actual model/effort, connector units/counts, unchanged quality oracles and accepted versus rejected transactions; a text promise to connect parts is insufficient. The newly recorded installed orbit event pass belongs to the separate `a5dff4c` artifact in [FLOATING-ORBIT.md](FLOATING-ORBIT.md), not these connector debug binaries.

The intended benefit is exact construction **between supplied endpoints**, without another model round trip. Lower latency has not been measured. Wrong primitives, incorrect endpoint choices, missing cutaways, weak explanations, occlusion, arbitrary concepts, animated mechanical relationships and scientific accuracy remain independent problems. No whole-product parity gate closes from this addition.
