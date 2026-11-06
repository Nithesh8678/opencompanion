# Manual guidance: live-check boundary

6 November 2026. Exact-installed `735dd15` passed one bounded, production-capture manual-input/Continue flow in the opaque public Guidance Fixture. It observed the edited field in a fresh frame and grounded the next checkbox target. It did not perform or verify the checkbox action, so `taskComplete=false`. Three earlier startup refusals remain recorded separately. All 21 whole-product acceptance gates remain open.

## Retained attempts

| Attempt | Private artifact root | Observed outcome |
| --- | --- | --- |
| Run 1 | `/tmp/OpenCompanion-Manual-Guidance-c331b85-2026-11-06-Run1/` | The helper reported waiting for the public fixture, then refused after 90 seconds without observing it foreground. |
| Run 2 | `/tmp/OpenCompanion-Manual-Guidance-c331b85-2026-11-06-Run2/` | The same foreground-timeout refusal; no capture, provider or test-input phase was reached. |
| Run 3 | `/tmp/OpenCompanion-Manual-Guidance-735dd15-2026-11-06-Run3/` | Terminal startup refusal: the fixture was foreground, but the full-display coverage guard failed. No capture, provider request or test input occurred. |
| Run 4 | `/tmp/OpenCompanion-Manual-Guidance-735dd15-2026-11-06-Run4/` | Passed the bounded two-capture manual-input/Continue flow; ended ready for the checkbox click, without completing that action. |

Run 1 and Run 2 retain `manifest.json` and `run.log`. Each log contains `GUIDANCE_MANUAL_WAITING_FOR_PUBLIC_FIXTURE`, followed by the explicit 90-second startup failure. Neither contains `manual-guidance-live-acceptance.json`: that version registered its receipt-writing cleanup only after startup checks. The absent receipts are preserved rather than replaced with invented stage counts. Manifest descriptions of intended input methods are not evidence that those inputs occurred.

A user readiness acknowledgement does not establish the fixture's actual foreground state. A later read-only NSWorkspace check reported `fixtureRunning=true`, `isActive=false`, `frontmostFixture=false`, `foregroundAvailable=true` and `activeCount=1` at that check instant. No other application names are recorded. That snapshot establishes that running and active were different states then; it neither reconstructs the entire attempts nor establishes why foreground activation was not observed. No cause is assigned to the user, UI driver or operating system.

Run 3 retains an early terminal receipt and phase receipt with `failureCode=startup-public-fixture-display-not-covered`, `foregroundIsPublicFixture=true`, `captureAttempted=false`, `providerPhaseObserved=false` and zero capture/input counts. A later independent, geometry-only NSWorkspace/CGWindow check passed the full-display guard. That later snapshot does not explain the earlier refusal or establish its cause; no guard was relaxed for Run 4.

## Run 4: observed integration

The receipt identifies the actual path as `AppModel/CaptureService`, with two accepted full-display captures, both encoded at **1440 × 935 pixels**. The production provider status was **`gpt-6.1-terra · low effort`**. There was no reported provider error or notebook mutation.

- The first target was the visible Table name field, with `advanceOn=manual`, `awaitUser=true`, a rounded rectangle and visible native Continue controls. The initial capture did not contain “Release QA”.
- CUA set the public field value to “Release QA” and verified it. The native Continue control was invoked once. This is driver-assisted field editing and a native control action; no physical keyboard or mouse provenance is inferred.
- Continue requested fresh perception under the same guidance request. The second frame ID was distinct, evidence revision advanced **1 → 2**, and generation advanced **2 → 4**. The new capture contained “Release QA”. Its grounded next target was Protect data, with click advancement and the native ellipse style.

The receipt records one armed manual continuation, one `manualContinue.requested` event, two accepted captures and zero `userClick.observed` events. Continue used its native control path, rather than raw-click advancement. The helper itself did not type or click, and used no audio or microphone.

First-step readiness was **5,913.038 ms** from helper start; second-step readiness was **47,913.412 ms**; the terminal result was recorded at **49,993.022 ms**. These are one run's helper milestones and include the wait for field editing and Continue. They are not model-only latency, displayed-pixel latency, frame-rate or acoustic measurements.

The content-free diagnostic events place the first next-model-target event **5,121.733 ms after the Continue request**. That interval includes settling, fresh capture and provider work; it excludes the preceding manual wait and does not measure visible annotation latency or a latency distribution.

Run 4 retains `manifest.json`, `run.log`, `manual-guidance-phase.json`, `manual-guidance-live-acceptance.json` and `manual-guidance-diagnostics.json`. Its result is `passed`, with `endState=ready-for-checkbox-click`, `checkboxCompletionVerified=false` and `taskComplete=false`.

## Source change and verification status

Source `735dd15` creates the output directory and installs startup receipt handling before foreground waiting. It adds `manual-guidance-phase.json`, early terminal `manual-guidance-live-acceptance.json` receipts, closed failure codes, finite-safe elapsed/display values and directly written stdout markers. Phase reporting distinguishes startup, capture/model work, waiting for manual input and continuation. Generation replacement is classified as interruption even when the helper Task itself is not cancelled.

The helper honors a disabled saved Screen guidance preference by refusing explicitly; it does not enable the preference. Existing foreground, opaque full-display coverage, image/header, target, input, generation and continuation validation remain intact. It does not activate an app, inject input, broaden capture, change permissions or alter ordinary model/input defaults.

The signed release build and canonical installation passed for source **`735dd15ed87534f9bda4dd81691f7f01dc656c74`**, using the existing signing team **`BPR2T4D656`**. The actual installed executable SHA-256 was **`57cda0366f4096b3c3a163e936bfc38549c797c343b581810a4d5ba5cb92a630`**. One app remains at `/Applications/OpenCompanion.app`; the install receipt reported `cleanupIssues=[]`.

| Verification | Status at this source checkpoint |
| --- | --- |
| Existing full Swift suite | Exited 0 before the final one-line generation-interruption classification correction. |
| Exact final-source focused tests | Passed 18 tests across three guidance suites. |
| Exact-source CI | [42175398887](https://github.com/Nithesh8678/opencompanion/actions/runs/42175398887) passed native tests, the native release build and Python/browser protocol checks. |
| Signed release build and canonical installation | Passed; exact source/hash above. |
| Runtime manual-input/Continue integration | Run 4 passed the bounded two-capture flow. Run 3 remains a coverage refusal. |
| Checkbox action and complete task postcondition | Pending; explicitly false in the passing receipt. |

## Required next evidence

Verifying the checkbox action and the final fixture state still requires an additional observed action and fresh postcondition evidence. Preserve explicit input provenance and the existing foreground, coverage, generation and evidence guards. This passing two-stage flow does not establish displayed annotation pixels, FPS, acoustic timing, physical microphone acceptance, unknown-app tutorials or exact reference parity. See [guidance contract](CURSOR-UI.md#manual-steps-and-explicit-continuation) and [whole-product gates](HEYCLICKY-PUBLIC-FEATURES.md#proposed-acceptance-checklist-for-the-whole-parity-goal).
