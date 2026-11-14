# Active screen guidance module report

14 November 2026. Implementation checkpoint; complete native acceptance remains pending. The module is implemented, with automated tests, real-provider transport trials and bounded native component evidence. **Complete module acceptance remains open:** the latency goal is unmet, an earlier full public fixture walkthrough failed final image-text verification, subsequent installed retries refused during setup, and the three real-app outcomes remain pending. No exact HeyClicky parity, displayed FPS, acoustic timing or universal task accuracy is claimed.

The [updated plan](GUIDANCE-MODULE-PLAN.md) records remaining gates. Public benchmark receipts remain locally under ignored `build/guidance-module-2026-11-14/`. Private native artifacts and earlier failures are preserved rather than copied into the public repository.

## Implemented module

| Boundary | Current source behavior |
|---|---|
| Session ownership | [ActiveGuidanceRuntime](../Sources/OpenCompanion/ActiveGuidanceRuntime.swift) separates an explicitly armed session, original goal and selected scope from durable semantic history and individual provider generations. Saved preference/restore does not silently resume observation. |
| Perception | [ActiveGuidanceScreenObserver](../Sources/OpenCompanion/ActiveGuidanceScreenObserver.swift), [GuidanceObservationFrame](../Sources/OpenCompanion/GuidanceObservationFrame.swift) and [GuidanceAXObservation](../Sources/OpenCompanion/GuidanceAXObservation.swift) combine scoped visual detection and bounded metadata. The stream requests detector samples at most 256×160 BGRA, 10 Hz, queue depth 3, without cursor/audio or own overlays. A latest-only mailbox retains copied local samples; they are non-Codable and never become model screenshot authority. These settings are not measured displayed FPS. |
| Scheduling and scope | [AppModel](../Sources/OpenCompanion/AppModel.swift) keeps one inference and coalesced latest changes. Hard source changes revoke stale output. Visual-only activity hides a retained mark while bounded same-scope proof runs, instead of cancelling each animated frame. Stable AX identity plus target ROI proof can restore the original unexpired lease; unavailable/changed proof is not success. Unresolved visual activity gets a bounded recheck then pauses. Selected regions/windows never silently widen. |
| User action | [ScreenGuidanceCoordinator](../Sources/OpenCompanion/ScreenGuidanceCoordinator.swift) blocks new click/manual/voice continuation during proof. Only a previously authenticated down may finish its bounded menu/up/settle handoff. A rejected down cannot become valid when proof finishes before its up; late/duplicate ups remain suppressed until a new authenticated down. Ordinary selected-window liveness remains enforced outside that handoff. |
| Transport | [CodexProvider](../Sources/OpenCompanion/CodexProvider.swift) reuses a hardened process only for an explicit guidance session, with a fresh ephemeral thread/current evidence each turn. [Policy](../Sources/OpenCompanion/CodexGuidanceSessionPolicy.swift) limits metadata to 30 s, idle reuse to 30 s, total process lifetime to 180 s and 16 turns. Current config is read before inherited tools/plugins are disabled. Request/RPC/thread identity and cancellation stay separate; reuse does not switch authentication, accounts or service tier. |
| Motion and narration | [GuidanceSpeechBeatCoordinator](../Sources/OpenCompanion/GuidanceSpeechBeatCoordinator.swift), [CursorCompanionCoordinator](../Sources/OpenCompanion/CursorCompanionCoordinator.swift), [CursorFlight](../Sources/OpenCompanion/CursorCompanionCore.swift) and [GuidanceAnnotationLayout](../Sources/OpenCompanion/GuidanceAnnotationView.swift) share grounded presentation ownership. Retargeting preserves submitted position/analytic velocity; cursor and native mark reuse one bounded collision-aware label layout. Marks follow the flight; actual synthesis receipts drive native captions, with explicit local fallback. A timer is not treated as audio position. |
| Input/status/routing | [NotchActivityState](../Sources/OpenCompanion/NotchActivityState.swift) separates actual Listening, static “Release to send,” post-release finalization and response activity. The compact HUD does not expand the hover dashboard. Short active-task follow-ups retain the goal; explicit 3D follow-ups use bounded user-topic context and existing renderer/revision authority. Prior model capability-denial prose does not redefine the product. |

The real pointer/focus remain user owned. The helper and module do not automatically click/type. The microphone remains push-to-talk. Detector pixels, capture evidence, model decisions, native presentation, user observations and independently verified task outcomes are distinct boundaries.

## Automated checkpoint

The latest checkpoint, `/tmp/opencompanion-guidance-2026-11-14-full-17.log`, records **1,095 passing tests**:

| Target | Tests | Suites | Reported target test duration |
|---|---:|---:|---:|
| OpenCompanion | 990 | 120 | 13.531 s |
| CompanionStore | 28 | 3 | 0.086 s |
| CompanionCore | 77 | 7 | 0.031 s |

These are separate target summaries, not a summed build/end-to-end duration. The installed code checkpoint is `9fbb8b73b17a18ce76c51857fe5c8266cf8958d5`. The earlier `full-12` pass (986 app + 28 store + 77 core = 1,091) remains historical evidence rather than being overwritten.

The first retained full run failed nine assertions: four deliberately changed prompt hashes and five selected-window visibility-read expectations. The latter tests now require the new admission/down checks while retaining zero additional visibility reads through an authenticated up/settle handoff. Production liveness and native grounding oracles were not relaxed. Logs `full-1` through `full-17` remain under `/tmp`; later passes do not erase earlier failures. Four focused-window selection regressions also pass in the newer checkpoint.

## Real subscription transport measurements

The two final profiles used source `347802bfad1b40e9404c2219f53fcae005570709`, sequential authored public UI images and the unchanged grounding oracle. Each requested five process-cold and 30 warm trials. All selected routing was recorded: Terra `gpt-6.1-terra` / `low` / `terraGuidance`; diagnostic Luna `gpt-6-luna` / `low` / `configuredGuidance`.

| Profile | Full trial pass | Warm target samples | Requested-warm first valid target P50 / P95 | Cold first valid target P50 / P95 | Actual reused / requested warm |
|---|---:|---:|---:|---:|---:|
| Terra baseline | **35/35** | 30 observed, 0 missing | **3,749.98 / 5,702.50 ms** | 4,700.83 / 6,072.88 ms | 29/30 |
| Luna diagnostic | **32/35** | 27 observed, 3 missing | 3,739.57 / 5,028.09 ms | 4,542.60 / 10,420.53 ms | 28/30 |

| Requested-warm milestone | Terra P50 / P95 | Luna P50 / P95 |
|---|---:|---:|
| Setup | 82.29 / 439.22 ms | 75.23 / 607.16 ms |
| Provider completion | 3,761.59 / 5,715.21 ms; 30 observed | 3,809.34 / 5,045.78 ms; 29 observed, 1 missing |
| All-attempt time to terminal | 3,762.36 / 5,716.14 ms; all 30 | 3,752.68 / 5,047.52 ms; all 30 |

The target milestone is the first oracle-valid target, not necessarily a full trial pass: the latter also requires the permitted protocol envelope and whole unchanged oracle. Percentiles use nearest rank `ceil(p*n)` over observed milestones; missing milestones are not imputed as successes. Terminal distributions include failed attempts. Requested-warm trials can rotate under the process limits. Process-cold does not mean a remotely cold model/server.

**Luna is not promoted.** Its failures were trial 17, icon-only compose (`target-oracle-primary-count-or-condition`); trial 31, generic new note (`target-oracle-stale-candidate`); and trial 33, held-out profile (`provider-rejected`). Neither final profile timed out. A lower conditional successful-target P95 does not replace grounding correctness, and these sequential profiles are not a general causal speed ranking. Terra remains the guidance baseline.

The older `latency-v1-legacy-envelope/` profile at `a49c9abef320bb7bb8132b1cc2aed457a3b3f00e` remains a failed **31/35** profile with four refused revealed-sidebar cases. The later helper validates at most one status envelope separately before applying the unchanged grounding oracle; no geometry/shape rule is relaxed and no old result is rewritten. Raw wire bytes were not captured. Decoded-unit archives cannot reconstruct unknown outer keys, original whitespace or omitted-versus-null representation.

The trial clock begins before authored fixture encoding. It includes local transport/setup/model/semantic admission, **not ASR, real desktop capture, actual AX harvest, AppModel native display or audio**. The intended warm release-to-useful-mark gate remains **P50 ≤2 s / P95 ≤4 s**. Even this narrower Terra proxy exceeds both thresholds: the latency goal is **unmet**. Do not subtract setup, hide Thinking, omit missing targets or relax freshness to claim otherwise.

Receipts: `build/guidance-module-2026-11-14/latency-terra/summary.json`, `latency-luna/summary.json`, per-trial results and unfiltered decoded-unit archives. These ignored outputs are not public repository assets.

## Native evidence and preserved refusals

The installed component run in `build/guidance-module-2026-11-14/observation-1/` passed a 20-second observation window, terminal elapsed **20,724.22 ms**, with 48 accepted copied frames, one visual-change event and unchanged diagnostics through the 500 ms post-stop wait. It requested no app activation, posted no input, saved no screenshots and used no provider/microphone/audio. **AX registrations and events were zero** (`unavailable-visual-fallback`), so this is visual-fallback/component evidence, not successful AX subscription or a complete AppModel workflow.

The direct-shell attempt in `build/guidance-module-2026-11-14/workflow-1/` failed preparation before any accepted capture or provider completion. A System Settings row alone did not establish the helper's effective AX grant. [GuidanceAcceptanceLauncher](../Sources/OpenCompanion/GuidanceAcceptanceLauncher.swift) now offers fixed developer-only normal-app → same-installed-executable modes, preserving canonical identity, work/draft and private-output guards. Launcher context is relevant to investigation; it is not an automatic assertion of a working child grant.

The later installed `b02821ad364baed5d22194c29ded120d57062df8` workflow is retained at `/var/folders/lr/4ytr_ms905n8yk__r8zb_4l80000gn/T/OpenCompanion-Guidance-Task-4envOP/`:

- Correct opener → Table name → Protect data targets were submitted as native marks. The external CUA/AX driver supplied actions; the helper did not click, type, activate an app or play audio.
- It recorded **four semantic checks, three offered actions, four accepted-capture events, three active fresh-check events, zero mouse-up advancement and zero Continue requests**. Five retained distinct image frame/revisions include local verification captures; four checks do not mean only four images were acquired.
- Native preparation snapshots observed the pristine form, then name `Release QA` with protection on, then that exact name/protection off before the final capture. The provider completed its assessment. Elapsed **86,629.53 ms** includes external-driver waiting and is not an inference latency sample.
- The terminal result is still **failed**, `final-production-evidence-incomplete`: fast grounding OCR did not find `Release QA` in any retained image. The driver's actual rendered view showed the name/off state, but after-final-capture AX verification was not reached. `taskComplete` remains false.

The `3f461a9` source retains the image condition and adds one acceptance-only accurate Vision OCR fallback over the immutable final JPEG when fast OCR misses. It records frame/fast/accurate boolean proof metadata, never OCR text. Header, public source, generation, cancellation, deadline and notebook ownership are rechecked after the await and before final independent AX. Production perception and native/frame oracles are unchanged. The subsequent installed retry did not reach this check, so **native acceptance of the fallback remains pending**. The failed directory remains intact.

## Installed checkpoint and pending acceptance ledger

Current code `9fbb8b73b17a18ce76c51857fe5c8266cf8958d5` is signed and installed as the single canonical application. Independent verification passed, including a repeat after the Codex desktop update; the installed executable SHA-256 is `949b820b520405d565958e1f6355bd8e71a69488897f5bea2e43128672b01209`. [Current exact-source CI 43623694156](https://github.com/Nithesh8678/opencompanion/actions/runs/43623694156) passed native tests/build and protocols. Earlier checkpoint CI [43622728928](https://github.com/Nithesh8678/opencompanion/actions/runs/43622728928) and [43621748225](https://github.com/Nithesh8678/opencompanion/actions/runs/43621748225) passed. The GitHub repository was reverified public. These checks establish this code/build checkpoint, not complete native task acceptance.

Historical code `3f461a9572ceb02b81deada104bfcbcf6f824996` was previously verified installed with executable SHA-256 `2e5271e61348977ec260a9e068b736e1930e0457cccfeee71ed7409202ae0ca3`; it is not the current installed checkpoint.

| Installed `3f461a9` attempt | Observed terminal result | Evidence work reached | Complete-task verdict |
|---|---|---|---|
| Observation, output suffix `egU3nw` | Refused: `public-fixture-front-window-does-not-cover-display` | No native stream | Not a component pass. |
| Active fixture workflow, output suffix `FlYCsK` | Failed while waiting for the public fixture; generic fixture-state failure 15 | Before accepted capture/provider work | Pending; accurate final image proof was not reached. |
| Browser, output suffix `kwaKND` | Foreground wait refused after 45 s | No capture/model request | Pending; no browser task outcome established. |
| TextEdit | Pending | No result recorded in this draft | Pending. |
| Calculator | Pending | No result recorded in this draft | Pending. |

These are preserved setup refusals, not successes, and do not establish a component cause. 14 terminal native attempts are retained under ignored `build/guidance-module-2026-11-14/native/`, including the earlier failed fixture run. Final native outcomes will be appended without replacing them. One fixture's three stages are never counted as three real apps.

The `3f6…` attempt with suffix `pBIBdp` supplied a concrete window-selection diagnosis: the first Safari CG-window candidate was 66×20 while the focused AX window was 1,324×940. The helper now requires a unique same-PID CG window matching the focused AX geometry, rather than taking the first candidate. A subsequent whole-front-stack chrome allowlist also refused the actual setup. The final helper removes that acceptance-only whole-stack precheck; it does **not** remove production per-target visibility, input-destination hit checks or foreign-occlusion rejection. Stronger native-target/AX geometry and final model-completion oracles remain in force.

This is a capture/input-authority distinction, not permission to annotate hidden controls. Apple's WWDC22 [Take ScreenCaptureKit to the next level, session 10155](https://developer.apple.com/videos/play/wwdc2022/10155/) documents that a desktop-independent single-window filter includes only that window, excluding child/pop-up windows, and can still provide its content while covered or off-screen. Our inference is that whole-desktop front-stack appearance is not the authority for isolated-window image provenance; current on-screen control visibility and input ownership must still be independently checked before native marks/actions. Apple's capture behavior does not prove our task success or perfect occlusion detection.

| Current `9fbb8b7` check | Observed status | Acceptance boundary |
|---|---|---|
| Safari public workflow, suffix `PsH1mJ` | Refused after 180.098 s waiting for Safari as foreground; zero capture/model work | No native app completion claimed. |
| TextEdit public workflow | Pending | No task result claimed. |
| Calculator public workflow | Pending | No task result claimed. |
| Strict complete fixture task after accurate final OCR | Pending | Earlier three-target/fast-OCR failure remains failed. |

The real-app helper now allows a bounded **180-second foreground wait**, followed by a separate **150-second task deadline**. Receipts keep total `elapsedMS`, `foregroundWaitMS` and `taskElapsedMS` separate, so human setup waiting cannot be presented as model response latency. Neither waiting nor process launch is a workflow pass.

## Remaining boundaries

Native Browser, TextEdit and Calculator outcomes remain **pending**. The latest foreground timeout is preserved independently; neither user-reported activation nor a retained background AX window establishes which app received key events during that run. A missing NSWorkspace subscription/cache cause is unproven. Native UI automation became unavailable when Codex Desktop restarted for an update, so the next installed walkthrough requires a standalone physical check. Three stages in one fixture do not establish three-application coverage. Real held-microphone recognition, physical mouse delivery, audible speech/mark synchronization, mixed-scale/fullscreen behavior, longer unknown-app tutorials and displayed frame-time distributions also remain open. Retained-layer submission/event callbacks are not WindowServer pixel proof, physical-input provenance, FPS or acoustic onset.

Actual native outcomes must be appended after the installed walkthroughs. All 21 whole-product gates remain open; these source and bounded-test outcomes do not establish the complete HeyClicky-like product goal.
