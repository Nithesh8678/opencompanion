# Guidance task verification

6 November 2026. The stricter public-fixture task verifier is implemented, but **no live full-task pass has been achieved**. Directly launched helpers refused before capture, while a separate normal canonical app launch subsequently reported actual Accessibility trust available. These launch contexts must remain distinct. The first app-owned helper subsequently passed AX trust and accepted one production capture, then failed the retained-mark matching check; it did not reach external input. The earlier [two-step manual/Continue pass](MANUAL-GUIDANCE-LIVE-CHECK.md) remains separate: it ended ready for the checkbox click with `taskComplete=false`. All 21 whole-product gates remain open.

## What the stricter check requires

`--guidance-manual-task-acceptance <output-directory>` opts into the full task. The existing `--guidance-manual-live-acceptance` retains its two-step endpoint and false task-completion fields.

The full check uses the existing production guidance route against the separate opaque public Guidance Fixture. It does not type, click, activate another app or start an extra provider turn to manufacture progress. A passing run must establish:

1. An initially checked Protect data control and a table name that does not yet match “Release QA”; a grounded manual field target and native Continue controls.
2. External field editing followed by exactly one native Continue request; a second capture containing the edited name while Protect data is still checked, followed by the grounded checkbox target.
3. An actual click observed by the production checkbox lease, then a third capture. The same goal/request must own distinct frame IDs, increasing evidence revisions and the expected generations—**2 → 4 → 6** in a clean helper run. Foreground, full-display scope and existing lifetime guards must remain valid.
4. Independent fixture AX readings showing the requested name and unchecked Protect data on both sides of the final capture, with ordered timestamps. These are observation boundaries, not an atomic AX/image snapshot. The capture must have a valid encoded image header and visible edited text. The final generation must admit nonempty text, finish successfully and emit no new target or notebook mutation.

The protocol's final response is ordinary text, not a typed completion command. `providerFinalTextAccepted` is recorded separately from `fixturePostconditionVerified` and `taskComplete`; model wording cannot establish the checkbox state. An AX press by a driver is not assumed to produce the global mouse-up required by click continuation. Input provenance must remain explicit, with no inference of physical hardware input.

The fixture-state reader is restricted to the exact public fixture bundle/process, foreground display and opaque window identity. It checks the unique `fixture.tableName`/`fixture.protectData` IDs and expected roles, reads only those values, returns booleans/timing/PID, and fails explicitly when access or identity is unavailable. It uses the app's existing AX grant without prompting, with per-object messaging timeouts, a bounded traversal and cancellation checks. No raw field value, OCR text, prompt or screenshot is exported by this state reader.

## Native mark checks and the corrected oracle

The helper work introduced in `04ac41c` and carried by manifest-pinned `03e0774` adds five exact native mark checkpoints: step 0 initially, after the cursor returns, and immediately before Continue; step 1 initially and after the cursor returns. Each checks the admitted mark's identity/geometry, visibility, opacity, lifetime, passive panel properties and retained layer state, and writes an own-view PNG.

The independent raster oracle checks red outline alpha, contour placement and coverage on all four sides. Authored negative cases reject blank, shifted and label-only rasters, plus unsupported-shape tags. They do not establish rejection of every incorrectly shaped rendered image. These are **retained own-view/model-layer checks**, not proof that WindowServer displayed the pixels above the desktop, nor FPS or visual parity measurements.

The initial full-suite run failed four assertions in the new raster oracle because it flipped the bitmap Y coordinate a second time. The failed log is retained at `/tmp/opencompanion-guidance-task-tests-2026-11-06.log`. The oracle was corrected to use `minY + row`, with an independent asymmetric raw-RGBA regression; thresholds were unchanged. Source `03e0774` then passed **745 Swift tests: 673 app tests across 80 suites, 21 store tests and 51 core tests**. [Exact-source CI 42179040994](https://github.com/Nithesh8678/opencompanion/actions/runs/42179040994) passed tests, the native build and protocol checks. These automated passes do not substitute for a live full-task result.

## Retained actual attempts

| Artifact | Observed result and boundary |
| --- | --- |
| `/tmp/OpenCompanion-Guidance-Task-03e0774-2026-11-06/readiness-attempt-1.json` | The aggregate foreground/full-coverage readiness result stayed false within 60 seconds. No task helper was launched; capture, provider work and field editing were not attempted. No component cause was established. |
| `/tmp/OpenCompanion-Guidance-Task-03e0774-2026-11-06/Run1/` | The installed helper reached preparation, then failed approximately 41 ms after preparation began. There were zero accepted captures, provider requests, inputs or mark checkpoints. The older source's receipt reports `production-turn-error`; its cause remains unestablished. |
| `/tmp/OpenCompanion-Guidance-Task-3ddfa73-2026-11-06/Run1/` | Early terminal refusal: `startup-fixture-state-accessibility-denied`, with `fixtureStateAccessibilityTrusted=false`. Foreground/full-coverage preflight passed, but no screenshot, provider request, input or mark phase was reached. Task and checkbox completion remain false. |
| `/tmp/OpenCompanion-Guidance-Task-3ddfa73-2026-11-06/Run2/` | Refused after the 90-second foreground wait with `startup-public-fixture-foreground-timeout`. The AX trust check was not reached; there was no capture, provider request or task input. |
| `/tmp/OpenCompanion-Guidance-Task-3ddfa73-2026-11-06/Run3/` | After the user activated the fixture, foreground and full-coverage checks passed. Direct-helper AX trust was still false; the terminal phase was recorded at **21.660 ms**, with the same explicit Accessibility-denied startup code and zero capture/provider/input/mark activity. |

The launched attempts retain their manifests, logs and terminal receipts; the older active-path attempt also retains diagnostic events. A manifest describes intended test inputs, not inputs proved to have occurred. The older attempt's cause must not be inferred retrospectively from the newer trust diagnostic.

The public fixture now has an explicit **Bring practice screen forward** control. CUA invoked that control, and independent macOS foreground and full-coverage checks both passed afterward. This is an external action on the authored fixture; the task helper did not auto-activate it. It does not establish why earlier readiness checks failed.

During `3ddfa73` Run 1, the running app's `AXIsProcessTrusted` result was false while CUA observed OpenCompanion's Accessibility toggle on in System Settings. Those observations conflict; they do not establish staleness, a signing mismatch, an operating-system defect or any other root cause.

The user subsequently approved refreshing **only OpenCompanion's** Accessibility entry. CUA removed that exact row and re-added `/Applications/OpenCompanion.app`; System Settings showed the entry on afterward. Run 3's direct-helper refusal does not establish that the normal app's grant failed.

The existing direct-CLI `--interaction-acceptance` diagnostic passed its isolated UI regression, but reported `inputMonitoring=true` and `accessibility=false`. Its artifacts are in `/tmp/OpenCompanion-Guidance-Task-3ddfa73-2026-11-06/PostRefreshLocalDiagnostic/`. It used own-view snapshots, with no desktop capture, model request or audio, and is not a full guidance result.

A separate **normal canonical CUA app launch** produced a registration diagnostic at **13:15:23.420**, PID **41324**, for `/Applications/OpenCompanion.app`, source `3ddfa73`: `inputMonitoring=true`, `accessibility=true`, `tapInstalled=true` and `tapEnabled=true`, with zero input edges. The private evidence location is `/tmp/OpenCompanion-Guidance-Task-3ddfa73-2026-11-06/post-refresh-normal-launch.log`, line 2. This establishes successful actual AX trust for that normal process after the refresh. It does not establish a physical hotkey event, fixture AX read, capture or complete task.

Targeted TCC metadata showed different responsible identities across launch contexts: `com.openai.codex` for direct helpers and `org.opencompanion.mac` for earlier normal app processes. **Inference:** launcher context is relevant to the differing trust results. The retained direct-helper excerpt lacks a final TCC allow/deny decision, so it does not prove the complete causal explanation. Raw logs are not published.

## Verified `3ddfa73` source and installation boundary

Source **`3ddfa730f8691044655f8ad6339782f27d67f5a7`** adds own-process AX-trust preflight and closed diagnostics identifying allowlisted AX attributes, operation categories and numeric AX error codes. It does not record attribute values or raw system error messages. The fixture, identity, timeout, generation, input and task-postcondition guards remain intact.

| Verification | Recorded status |
| --- | --- |
| Focused checks on `3ddfa73` | 34 tests across three suites passed before the signed build. |
| Signed build and installer | Passed using the existing certificate/team `BPR2T4D656`; installer reports one canonical `/Applications/OpenCompanion.app` and `cleanupIssues=[]`. |
| Executable SHA-256 in the current build/install records | `c84d10c6e052f84f49a1a21b8cb5dee91ae7c064450bdb9942730698c2a8eee2` |
| Independent post-install identity verification | Passed deep strict signature verification and Info.plist/build/install/hash concordance. One canonical app was present, with temporary app bundles absent. |
| Exact-source CI for `3ddfa73` | [42180810164](https://github.com/Nithesh8678/opencompanion/actions/runs/42180810164) passed native tests, the release build and protocol checks. |
| Direct-helper full-task runtime | Runs 1/3 refused at AX-trust preflight; Run 2 refused at the foreground gate. No complete task, native mark or three-capture pass claimed. |
| Normal canonical launch after refresh | Actual AX trust reported true for PID 41324; no guidance task was exercised by that registration diagnostic. |

Run artifacts remain outside the public repository. No raw user content, screenshots or proprietary assets are committed with this report.

## Explicit normal-app helper launcher

New source adds **Developer → Check public screen guidance…** to the normal app and status menus through `GuidanceAcceptanceLauncher`. This explicit action starts the existing isolated acceptance model using the same installed executable and the fixed `--guidance-manual-task-acceptance` mode. The launcher requires the canonical and resolved bundle/executable paths under `/Applications/OpenCompanion.app`, the expected executable name and bundle ID `org.opencompanion.mac`.

It refuses busy or listening work, pending speech, a current guidance request, an open utility editor, a visible explanation or an unsent draft. The launcher itself performs no capture, input or app activation. The child retains the existing public-fixture, permission, foreground, coverage, deadline, generation and postcondition guards.

Output uses a private `mkdtemp` directory with mode `0700` and an exclusively created, non-symlink `run.log` with mode `0600`. The content-free `launch-manifest.json` records `prepared` and, after successful process start, `process-started`; it explicitly keeps `taskComplete=false`. Neither status proves that a task ran or passed. The parent quits only after `Process.run()` succeeds; a launch failure keeps the parent running and shows its notice.

Two focused launcher tests passed in the revised v2 run. The first compile attempt failed on an optional scene-ID expression; that expression was corrected without changing verification thresholds. Independent source review reported no critical findings. The full suite is still in progress at this checkpoint, and the new source's signed build, installation and actual helper launch-context verification remain pending. The positive normal-process AX registration described above belongs to historical installed `3ddfa73`, not this unverified launcher revision.

## App-owned developer launcher

The normal app and status menus now include **Developer → Check public screen guidance…**. This explicit action starts only the same canonical executable with the existing `--guidance-manual-task-acceptance` mode. That child creates its isolated acceptance model before loading ordinary user state. The launcher performs no capture, activation, desktop input, microphone work or provider request itself; the unchanged helper must satisfy all existing fixture, freshness, lifetime and postcondition gates.

The launcher checks the exact bundle ID and both canonical and resolved bundle/executable paths. It refuses busy/listening/pending-speech states, a current guidance request, visible editor/explanation surfaces and an unsent draft. A private `mkdtemp` directory has mode 0700; `run.log` is created exclusively with mode 0600 and no symlink following. A content-free launch manifest records source/path/process identity and explicitly retains `taskComplete=false`. `process-started` means only that `Process.run` succeeded.

The parent retains the child process and terminates only after successful launch. A setup or launch failure leaves the normal app running with a notice. The child inherits its standard-output descriptors before the parent's copies close. Manifest-update failure after a successful start cannot be mistaken for a failed launch. Acceptance-mode menus omit this developer command to prevent recursive test launches.

The first focused compile exposed an optional-scene access error in the menu guard; it was corrected before installation. The corrected focused run passed two launch-policy tests. The full suite then passed **747 tests: 675 app tests across 81 suites, 21 store tests and 51 core tests**. Independent read-only review found no remaining critical issue. The initial and corrected focused logs and full-suite log remain private under `/tmp/opencompanion-guidance-launcher-*-2026-11-06.log`. Signed source `67456df9dd18d207f986a8885026822eb753d2b6` then built and installed with the existing team `BPR2T4D656`. Independent verification confirmed the strict deep signature, matching Info/build/install source and executable hash `e01438e95ac1348cb5d893f93e23e6c2daf7889e9a61713a7c12e7876f29f00c`, one canonical app, absent temporary bundles and no cleanup issues. The initial sandboxed independent certificate check failed; the normal macOS certificate-services check passed. A fresh normal-launch registration for PID 44499 reports AX/Input Monitoring and installed/enabled tap all true. [Exact-source CI 42191527235](https://github.com/Nithesh8678/opencompanion/actions/runs/42191527235) passed native tests/build and protocols. A full-task result remains unverified.

## App-owned Run 1 and mark-matching follow-up

The explicit menu launched child PID **45226** from normal PID **44499** under signed source `67456df`. Private directory `OpenCompanion-Guidance-Task-DDJEFA/` retains its launch manifest, log, phase, terminal receipt and native-mark observation. Its own AX trust, fixture foreground, full display and observer gates passed. One production capture was accepted; actual Terra/low output created a native mark and armed manual Continue. At approximately 7.48 seconds the helper refused with `target-or-continuation-validation`: the retained mark did not satisfy its exact candidate filter. There were **zero external field edits, Continue requests or checkbox clicks**, no notebook mutation and no full-task pass.

The retained observation shows a visible, passive native mark with owner generation 2. The original diagnostic did not record the expected identity/rectangle beside it, so the failed comparison's precise component is not established. It is not evidence that no highlight was created. This app-owned run establishes the child's actual trust and production capture separately from all direct-helper refusals.

The follow-up adds content-free expected target/frame/generation/display/PID/shape metadata and allows only **eight floating-point units at display scale** in the rectangle comparison. All values remain finite and bounded; display size remains at most 100,000 points. Exact ownership and shape checks, path tolerances, independent raster thresholds and task postconditions are unchanged. This avoids exact floating-point equality as an extra failure source; it does not establish the cause of the preceding runtime refusal.

The first focused compile needed an explicit `CGFloat.infinity` in the new invalid-geometry test. A subsequent attempted `CGRect.intersection` reproduction did not produce the expected inequality and that assertion failed; the final test instead explicitly checks authored machine-precision differences, meaningful shifts/resizes and invalid bounds. The corrected focused run passed **11 tests**. Review added rejection of negative raw rectangle sizes; the final full suite passed **749 tests: 677 app, 21 store and 51 core**. All failed logs remain retained. New signed runtime acceptance is pending.

## Remaining acceptance

A fresh task run through the explicit normal-app launcher must establish its own AX trust and satisfy the unchanged mark, input, capture and independent postcondition checks; prior receipts remain preserved. No new-source build or runtime pass is claimed. Even a passing fixture run would establish only this bounded workflow. It would not prove unfamiliar-app reliability, physical speech input, acoustic timing, displayed desktop pixels or exact reference choreography.

The implementation still uses **six steps**, a **180-second request lifetime** and a **45-second marked-target lifetime**; the helper also keeps its original 120-second active deadline. A resumable **15-step** walkthrough with a completed-step record, slow-page/network loading handling and a verified final result remains a substantial gap. See the [whole-product guidance gate](HEYCLICKY-PUBLIC-FEATURES.md#proposed-acceptance-checklist-for-the-whole-parity-goal). All 21 gates remain open.
