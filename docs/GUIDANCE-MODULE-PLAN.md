# Active screen guidance implementation plan

14 November 2026. Planning baseline: repository `01e96ff`, with application sources unchanged from the previously tested `b6847a4`. This plan covers one module: fast voice-driven screen guidance, its session lifecycle, live screen context, and the native cursor/mark/speech experience. It also covers the routing handoff that currently breaks explanation-to-3D follow-ups. It does not reopen 3D modeling quality, hosting, autonomous desktop actions, or unrelated app features.

Status: source audit and implementation plan. No application code, settings, permissions, or installed bundle changed during this planning pass. No fresh performance or live HeyClicky parity measurement is claimed.

## Intended experience

The user confirmed the Screen guidance toggle and the existing hold **Control + Option** gesture.

1. Enable Screen guidance. The setting enables the feature; an active user-invoked session owns observation. Relaunching the app never silently resumes screen observation.
2. Hold Control + Option. A compact acknowledgement appears immediately; Listening and its waveform represent actual microphone input. The full notch dashboard stays hover-only.
3. Release either modifier. Recording ends immediately and one Thinking transition covers speech finalization, fresh-screen preparation and reasoning. Old listening/response callbacks cannot overwrite it.
4. The assistant moves its visual cursor smoothly to one grounded control, reveals a circle or suitable outline, and gives a short matching instruction. The real pointer and keyboard focus remain under the user's control.
5. While the guide is active, screen observations stay current. Clicks, menus, scrolling, typing-related layout changes, navigation, window changes and loading can trigger a fresh check. The guide retains the original goal and verifies the result before advancing.
6. Hold the chord again to interrupt and ask a follow-up. “What next?”, “Where is it?” and “Show it in 3D” resolve against the explicitly owned task/topic. An independent 3D request hands off to the existing floating renderer; it does not cause a generic claim that the product is text-only. Screen-step advancement is paused during that explicit handoff.
7. Stop, Escape, disabling guidance, lock/sleep or permission loss revokes capture, inference, speech and old marks. Resume requires fresh authority and fresh evidence.

The microphone remains push-to-talk. Continuous awareness here means active-session screen observation. Each pointer movement updates the local follower; meaningful scene changes schedule reasoning. The model does not receive a request for every pointer sample.

The existing preference defaults to enabled, so its stored value must not be interpreted as a newly armed session. Make the current-session guidance selection explicit and visible; a deliberate toggle interaction can arm the next invocation in that run. Keep feature availability, armed mode and actively observing session separate. Upgrade/restart begins with no active capture authority, and the Settings description must explain the new behavior.

## What the source audit established

| Gap | Current source | Consequence |
|---|---|---|
| The toggle is a one-shot feature preference | [Settings](../Sources/OpenCompanion/CompanionSettingsView.swift#L274) explicitly says the screen is not continuously monitored. | Enabling it does not establish the requested ongoing session. |
| Routing ignores the active topic | [ResponsePolicy](../Sources/OpenCompanion/ResponsePolicy.swift#L37) classifies current text; its visual heuristic at line 299 also requires specific nouns. | Short requests such as “show it in 3D” can fall back to conversation. |
| A restrictive turn can look like a product limitation | Conversation policy forbids scenes; [AppModel](../Sources/OpenCompanion/AppModel.swift#L1472) suppresses them. Non-guidance requests carry ordinary prior assistant history. | A prior “no viewer” answer can influence a later turn. This is a plausible explanation of the reported refusal, not a trace-confirmed diagnosis of that exact request. |
| Ordinary follow-ups can leave the guide | [Voice completion](../Sources/OpenCompanion/AppModel.swift#L1913) has a special Continue path, while ordinary recognized text is reclassified. | “What next?” can become chat and pause the guide. |
| Screen changes often pause rather than continue | [Observer](../Sources/OpenCompanion/GuidanceSceneObserver.swift#L116) watches activation/scroll; [host invalidation](../Sources/OpenCompanion/AppModel.swift#L1141) stops and pauses. | Scrolling can terminate the live loop. Same-app window/tab/menu/reflow changes are incompletely observed. |
| Waiting is not represented by one shared runtime owner | [Escape registration](../Sources/OpenCompanion/OpenCompanionApp.swift#L437) and [sleep handling](../Sources/OpenCompanion/OpenCompanionApp.swift#L411) depend on narrower activity predicates. | A silent awaiting-user guide can lose global Escape coverage; submitted inference lacks a common suspend boundary. |
| Every step repeats setup | [CodexProvider](../Sources/OpenCompanion/CodexProvider.swift#L104) launches and initializes a process, reads account/catalog/config, then creates an ephemeral thread. [Capture](../Sources/OpenCompanion/Perception.swift#L258) waits for AX/OCR enrichment. | Repeated setup and enrichment can add to time before the first useful target. Their actual contribution needs measurement. |
| Guidance speech and marks use separate timing | [Target presentation](../Sources/OpenCompanion/AppModel.swift#L1577) schedules flight/marks then legacy speech; [annotation reveal](../Sources/OpenCompanion/GuidanceAnnotationView.swift#L136) is locally timed. | Shared speech-beat ownership is incomplete for guidance. |
| Retargeting resets speed | [SceneCursorVisit](../Sources/OpenCompanion/SceneCursorVisit.swift#L39) restarts a [zero-endpoint-speed flight](../Sources/OpenCompanion/CursorCompanionCore.swift#L427). | Position continuity does not establish smooth moving-target velocity. |
| Caption pacing can delay semantic delivery | [AppModel](../Sources/OpenCompanion/AppModel.swift#L1397) retries a bounded visual queue with 50 ms waits. | A long reveal backlog can delay subsequent ingestion. |

The HeyClicky reports support a separation between semantic reasoning, native motion, speech beats and observed task outcomes. They do not establish its current private model routing, exact native trajectories, physical FPS or latency. The reference remains the existing [workflow study](../../heyclicky-voice-guidance-2026-11-06/WORKFLOW-REPORT.txt) and [native workflow design](../../heyclicky-voice-guidance-2026-11-06/notes/native-workflow-design.txt); reconstruction choices below are ours.

## Architecture and ownership

Keep physical chord state, microphone state, guidance-session state and presentation state separate, coordinated by one active guidance runtime. Extend the existing durable `GuidanceSessionController`; do not replace its semantic history or confuse saved progress with screen authorization.

The runtime owns an ephemeral session lease, original goal/topic, chosen scope policy, scene epoch, current frame, inference generation, expected interaction, and current target lease. Durable workflow history contains semantic progress only.

The visible progression is:

```text
Ready → Preparing microphone → Listening → Thinking → Guiding → Waiting for you
                                                             ↓
                                      screen change/action → Settling → Checking → Guiding
Any active phase → Paused / Stopped / Suspended
```

An early final recognition result while the chord is still held must show the appropriate release/ready-to-send state, not start inference or revive an old Listening phase. Thinking is not shown while simply waiting for the user. Quiet background checks must not make the dashboard expand or repeatedly announce unchanged screens.

### Host-owned intent and capabilities

- Add bounded active-task context to routing: goal, topic, previous instruction, observed outcome and requested output mode. Prior assistant prose and screen text cannot grant capabilities or screen scope.
- Explicit current intent, privacy opt-outs and Stop commands take priority. A short continuation uses an owned active task; it does not borrow authority from arbitrary old chats.
- Distinguish guiding the user in a 3D application from independently showing an explanatory 3D scene. Preserve the existing floating-renderer handoff and its document revision ownership.
- Describe actual host capabilities to the provider separately from a turn's allowed output types. A text-only turn does not redefine the application as having no renderer. Preserve transcript history for the user, while projecting relevant semantic context into a capability change instead of replaying stale capability denials as authority.
- For an explicit request to generate/show a 3D artifact, require an admitted drawable result before reporting that request successful. Merely permitting scene units is insufficient. A text-only denial should trigger a bounded format/capability recovery or an accurate host error; never fabricate placeholder geometry or claim the renderer is unavailable solely from model prose. Implicit explanatory questions may still use text when appropriate.

### Active screen perception

- Introduce a session-scoped ScreenCaptureKit stream with bounded buffers, own-overlay exclusion and a latest-frame application slot. Copy/freeze the selected evidence before processing; do not retain mutable sample buffers as immutable frames.
- Start observation only for the invoked active guide. Keep screen audio/microphone capture disabled in this stream. Stop it on Pause/Stop/suspend, and retain no screen video on disk by default.
- Combine app activation, scoped AX window/focus/layout notifications, existing browser navigation signals where already paired, scroll/click metadata and local visual-change detection. AX support varies; visual change detection supplies the fallback.
- Do not log keystrokes or read secure field values. A typing event is a settlement/dirty signal; it is not a transcript of what was typed.
- Preserve frame IDs, source content timestamps, image dimensions, transforms, display/window identity and scene epochs. A completed asynchronous capture is not automatically a current frame. Idle stream events must not be relabeled as new changed evidence.
- Declare scope policy explicitly. A current-screen session may rebind after a foreground transition using new authority and a fresh frame. An explicitly selected window/region remains pinned; losing it pauses for a scope choice rather than silently widening access.

Apple's [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration) provides capture dimensions, cursor inclusion, frame interval and queue-depth controls. Its frame [displayTime](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/displaytime) represents WindowServer display time; clock-domain conversion needs tests. AX observation uses registered [notification constants](https://developer.apple.com/documentation/applicationservices/axnotificationconstants_h). These APIs support the proposed design; they do not establish our runtime reliability or a frame-rate guarantee.

### Latest-only reasoning scheduler

- Maintain one active inference and one coalesced pending scene revision. Repeated scroll/typing/loading changes replace the pending work rather than create a backlog.
- Revoke stale marks immediately. After bounded local settlement, acquire the newest scoped frame and verify the current goal. Use a maximum settlement wait so animated pages cannot starve the guide forever.
- Preserve authenticated mouse-down ownership through a legitimate menu-opening transition and its mouse-up. Never restore the older up-time hit-test rule that loses that handoff.
- Separate quick screen readiness from optional expensive enrichment. Benchmark bounded AX-first, image-first and full AX/OCR paths; use only candidates belonging to the exact submitted frame. OCR is evidence, not action authority.
- Reuse a hardened initialized provider transport during the session where supported, with isolated turn inputs, current request IDs, cancellation, health checks and disabled desktop/tools/plugins. Cache bounded model/catalog configuration with invalidation; do not reuse old screenshot history or replay an uncertain completed turn.
- Keep Terra as the existing baseline, limited to account-advertised compatible models/efforts. Measure setup, network/model and local work separately before choosing a faster supported route. Do not promise a specific cloud latency from a model name.
- Request one next action and concise narration. Keep raw semantic admission independent from cosmetic word-reveal buffering, while preserving canonical ordering, bounded memory and the complete text in Chat.
- Keep existing action/check/freshness limits initially. Local screen observation does not consume a model-check budget. Expired marks need a fresh owned revalidation, never an extension of old coordinates.

### Grounding and verification

Use current AX candidate IDs when actionable, otherwise validated image-pixel bounds mapped natively. Recheck current window/source ownership before publication and while awaiting action. Window motion/reflow invalidates the old target rather than animating an unverified rectangle into a new place.

A click, hover, Continue, speech ending or elapsed timer is an observation, not task success. Re-observe the expected effect: menu opened, field accepted, destination visible, or requested state changed. Wrong clicks and no-effect actions trigger a fresh grounded instruction. Completion must distinguish model assessment from independent native/fixture verification; uncertain outcomes remain explicit.

No automatic clicking or typing belongs in this module.

### Cursor, marks and speech

- Follow the real pointer on the native display clock, independently of capture/model work. Guidance flight starts from the current presented position.
- Preserve velocity when a valid destination is replaced, using a bounded native retargeting curve/spring. Test reversals and interruptions; position-only continuity is insufficient.
- Keep the real pointer unchanged, target windows nonactivating, and passive annotations click-through. A cancelled target cannot keep flying toward an obsolete control.
- Create a guidance narration beat containing one grounded target, short instruction, speech ownership and matching marks. Prepare speech and flight concurrently; acknowledge the current target's native presentation before releasing its instruction. Use real synthesis start/range/finish receipts for captions and mark timing, with an explicit local fallback.
- Keep full response/presentation lifetime separate from provider completion. A pending caption fallback must not disappear merely because the network completed.
- Score a small bounded set of label placements against the primary control, nearby authorized text and existing marks. Preserve contrast/glow, restrained pacing, display-edge fit and Reduce Motion behavior.

## Implementation order and checkpoints

1. **Reproduction and trace baseline.** Add send-path fixtures for explanation → “show it in 3D,” active guide → “what next?”, and toggle-on voice screen requests. Instrument content-free monotonic milestones. Record the original failure before changing behavior.
2. **Intent and runtime lifecycle.** Implement bounded topic-aware routing, product-capability context, active-session ownership, Listening/Thinking arbitration, Escape while waiting, new-turn interruption and sleep/lock cancellation. Keep manual microphone review unchanged.
3. **Continuous scoped perception.** Add the stream/latest-frame slot, scoped AX/visual observers and immediate stale-mark revocation. Test pinned versus current-screen policy and metadata/pixel races.
4. **Fresh continuation and latency.** Introduce the latest-only scheduler, expected-effect verification, loading/no-effect recovery and measured warm provider reuse. Remove repeated cold setup only after isolation/cancellation tests pass.
5. **Native presentation.** Add velocity-continuous retargeting, guidance speech beats, nonblocking caption presentation, collision-aware labels and correct notch presentation lifetime.
6. **Acceptance and release.** Complete the declared cross-app workflows, latency distributions, physical voice/cursor checks and failure recovery. Run the relevant full suite and exact-source CI. Then replace only `/Applications/OpenCompanion.app` with the existing signing identity and verify receipt/hash/signature/cleanup. Keep commits incremental and the repository public.

Each checkpoint requires behavioral evidence for its own contract. A green build is not a completed guidance walkthrough. No further 3D mesh work enters this sequence; only the routing/handoff regression is part of this module.

## Performance targets

These are proposed acceptance targets for named hardware/provider conditions, not measured current results or HeyClicky claims.

| Measurement | Proposed gate |
|---|---|
| Accepted chord → compact acknowledgement | P95 ≤50 ms; Listening still waits for actual microphone readiness. |
| Release → stopped waveform / finalizing feedback | P95 ≤50 ms; no old Listening/Thinking overlap. |
| Material scene change → stale marks revoked | P95 ≤100 ms, with zero stale publications in deterministic race tests. |
| Local pointer sample → render submission | P95 within one display interval; deliberate smoothing lag measured separately. |
| Stop/new-turn replacement → old visuals removed | Within two display intervals; zero resurrection from late callbacks. |
| Warm release → first correctly grounded useful mark | P50 ≤2 s, P95 ≤4 s, including ASR finalization, capture, provider and admission. |
| Idle outside an active guide | Zero capture/model work attributable to guidance. |

Record microphone readiness, ASR tail, frame content age, capture/enrichment, process/setup, first model delta, first admitted target, native submission, speech callbacks and post-action verification independently. A callback interval is not displayed FPS, and a speech delegate callback is not acoustic onset. Benchmark output must include failures and timeouts, not only successful requests.

If the current subscription/provider cannot meet the warm target, report that limit with its measured breakdown. Do not reduce freshness, guess coordinates, hide thinking time or call an ungrounded answer “fast” to pass the gate.

## Definition of done for this module

- The public rocket explanation → 3D follow-up and guidance → short-follow-up regressions pass through the real host routing and renderer/continuation boundaries.
- Control + Option works through fast release, repeated holds, interruption, recognition delay and permission errors. Listening is first; the dashboard remains hover-only. Escape/Stop work while waiting, during inference and during speech.
- Active observation handles app/tab/window/menu changes, scrolling, typing/reflow, wrong clicks, no-effect clicks and slow loading. It stops on pause/disable/lock/sleep and never widens selected scope silently.
- Stale frame, generation, target, mouse handoff and queued-callback tests pass without weakening freshness/ownership checks.
- At least three declared real apps, including a browser and native app, complete 3–5-step public workflows with independently inspectable final states. Include an AX-poor screen. Record every failure and correction, not just first-target highlights.
- Collect at least 30 warm trials per declared latency profile and five cold starts, plus failure/permission/suspend cases. Report accuracy and complete-task success alongside P50/P95.
- Physical acceptance includes real hold/release speech, clicks/menu handoff, cursor motion, audio/mark alignment, Reduce Motion and available mixed-scale display configurations. Consolidate manual checks into a short final pass rather than repeatedly asking the user to babysit each build.
- Relevant unit/integration/native checks, full Swift suite, strict build, exact-source CI and single-canonical-app verification pass. Update feature status only for observed outcomes. Remaining unavailable hardware/provider conditions stay explicitly unverified.

Planning is complete when this scope and sequence are reviewable. Implementation, fresh benchmarks and installed acceptance are separate subsequent work.
