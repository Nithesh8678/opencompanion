# HeyClicky public feature and parity checklist

Scene-pointing checkpoint, **6 November 2026**: signed source `e8a7278` passed **665 local Swift tests** and two installed native narration/focus checks, including recovery after temporarily unavailable host bounds. The user separately confirmed the real Control+Option flow: the cursor points at narrated parts and captions stay close. See the [contract, exact artifacts and verification limits](SCENE-CURSOR-POINTING.md). All 21 whole-product acceptance gates remain open.

Historical installed timing checkpoint **`228d49502960a165c77fb8e60279ce7aa36f5ec2`** passed **629 local Swift tests (557 app across 69 suites, 21 store across two suites, 51 core across four suites)**. The exact signed installation passed two public authored scene/narration stages with real synthesis start/range/finish callbacks, matching native scene submission before speech, caption prefixes and first-finish-before-second-scene ordering. Its separate water-scene rendering/leader/orbit regression and exact-source [CI run 42078512787](https://github.com/Nithesh8678/opencompanion/actions/runs/42078512787) passed. [Timing contract and evidence](SPEECH-VISUAL-TIMING.md). The user then confirmed that parts and captions follow the speech smoothly in the actual Control+Option water-molecule workflow; this is attributed feedback for one turn. No whole-product gate closes, and acoustic alignment, trace-correlated provider/output timing, frame rate and exact HeyClicky parity remain unverified.

Official changelog, homepage/pricing, latest Mac release, trust and privacy pages rechecked **5 November 2026**; creator-authored posts and other sources retain their separately stated **4 November** checks. Shared runtime observations and the user's **5 November** recording are labeled independently. This is a research inventory, not a claim that OpenCompanion implements the whole reference product. This refresh performed no reference app interaction, account change, remote-media download or product-source edit. No proprietary assets or source are included.

The objective of broad product parity is substantially larger than the current guidance and explanation slices. A passing target or scene test proves neither a complete assistant nor a successful external task. Use the checklist below to choose and verify independent end-to-end flows.

## Evidence rules

| Label | Meaning |
|---|---|
| **PUBLIC CLAIM** | An official page or creator says the capability exists. This is not an independent runtime test. |
| **RECORDED VISUAL** | A previously streamed official recording contains the stated visible behavior at the recorded player time. Its build and editing are not independently established. |
| **USER RECORDING** | A dated user-supplied recording was inspected locally. It establishes the stated visible sequence, not unrecorded input, acoustic timing or the reference's internal architecture. |
| **CREATOR TRANSCRIPT** | The primary post exposes the creator's narration. The narration was read; that is distinct from watching and verifying the task. |
| **LOCAL OBSERVATION** | A prior dated installed-app inspection observed a particular account/state. It does not establish every release or account. |
| **PROPOSED ACCEPTANCE** | An authored OpenCompanion verification task. These rows describe work to do, not recovered HeyClicky implementation details. |

Public release labels: **Mac 1.1.2 (2026-10-30); Windows 1.1.4 (2026-11-01)**. GitHub displays Mac 1.1.2 as **31 Oct, 02:13**, timezone unresolved. [Official changelog][changelog], [official Mac release][release]

**5 November refresh:** no later release or newly dated feature entry was observed on the inspected official pages; GitHub's latest-release link still resolves to Mac 1.1.2. The workspace, language, browser-store distribution and automatic-update claims remain vendor claims, not new runtime acceptance. Existing Skills/Suggestions pauses remain the relevant historical boundary. [Official changelog][changelog], [latest Mac release][latest-release]

The historical public repository explicitly says newer work became private in its 27 April 2026 update. Community ports and that historical code cannot prove current official behavior. [Creator repository][repository]

## Version ledger: compact vendor inventory

All rows below are **PUBLIC CLAIM**, condensed from the [official changelog][changelog]. Dates are in 2026; Mac unless marked Windows. This is a capability index rather than a reproduction of release notes.

| ID | Version / date | Capability index |
|---|---|---|
| R01 | 1.0 · 2026-04-06 | Screen-aware voice |
| R02 | 1.0.10 · 2026-04-27 | Background agents |
| R03 | 1.0.11 · 2026-04-30 | Connectors; customizable shortcuts |
| R04 | 1.0.15 · 2026-05-13 | Notch |
| R05 | 1.0.21 · 2026-05-30 | Realtime voice; guidance; Notes removed |
| R06 | 1.0.23 · 2026-06-08 | File drop; selectable replies |
| R07 | 1.0.26 · 2026-06-19 | Click continuation; computer use |
| R08 | 1.0.28 · 2026-06-23 | App skills |
| R09 | 1.0.33 · 2026-07-06 | Spatial context; memory; skill library |
| R10 | 1.0.37 · 2026-07-14 | Dictation; dictionary |
| R11 | 1.0.40 · 2026-07-17 | Tutorial; sketched marks |
| R12 | 1.0.44 · 2026-07-23 | Teams |
| R13 | 1.0.46 · 2026-08-01 | Warmup; tracking removed |
| R14 | 1.0.47 · 2026-08-13 | Whole-document context |
| R15 | 1.0.48 · 2026-08-25 | 15-step walkthroughs |
| R16 | 1.0.49 · 2026-09-12 | Persistent Clickys; previews; MCP; routines; Skills paused |
| R17 | 1.0.51 · 2026-09-18 | Resizable Home |
| R18 | 1.0.52 · 2026-09-24 | Peek; referrals; announcements |
| R19 | 1.0.53 · 2026-10-02 | Multiple accounts |
| R20 | 1.1.1 · 2026-10-23 | 2D/3D; Drive; Chrome; captions; unified notch; Suggestions paused |
| R21 | 1.1.2 · 2026-10-30 | Workspace; 130+ spoken languages; 83 dictation languages; 30 voices; automatic updates |
| R22 | 1.1.4 · 2026-11-01 · Windows | Corresponding workspace/language update |

**Current versus historical:** Skills (R16) and Suggestions (R20) were paused. Earlier demonstrations remain historical.

## Core product, privacy and commercial boundaries

The [homepage][home] advertises hotkey-invoked screen-aware conversation, teaching and task agents. Its broad any-visible-app claim is marketing, not a measured compatibility matrix. It lists macOS Sonoma 14.2+, Windows 10/11 and one account across platforms. Monthly published plans are Free (25 talk and 25 agent messages), Pro ($20; unlimited talk/dictation and 150 agent messages), and Max ($100; unlimited talk/dictation and 1,000 agent messages). These are time-sensitive vendor terms, not OpenCompanion entitlements or a proposed billing implementation.

The [trust page][trust] says screen analysis is hotkey-triggered, raw screenshots are discarded after processing, and prompts/AI screenshot analyses can be retained. It describes cloud AI processing and identifies a separate once-daily, read-only check of connected integrations while the app is open; that check can be disabled. It says quitting stops local activity and makes no SOC 2/ISO 27001 certification claim. These are policy statements, not independently audited retention or infrastructure facts.

The [privacy policy][privacy] also names Anthropic, OpenAI, Deepgram and Cerebras as providers. It describes browser tasks reading page content and acting through Chrome native messaging, including signed-in sites. It says the extension does not fill password, verification-code or payment-card fields, excludes incognito windows, and exposes Stop; stopping does not undo prior effects. Do not infer a specific current model, provider route or local perception algorithm from these general statements.

Screen-question support without an integration and browser task execution through an extension are different workflows. A vision answer does not establish browser-control capability. Hosted accounts, billing, referrals and teams are a separate service scope from a local/BYOK or subscription-adapter desktop build.

## Demos: what is actually supported by the evidence

| Source | Specific evidence | Limit |
|---|---|---|
| [Official FL Studio clip][fl-video] | **RECORDED VISUAL, observed 3 Nov:** approximately 3.100 s shows a black real pointer, separate gold assistant triangle, ring and short target label. | A recorded example, not broad application accuracy or proof of the latest installed build. |
| [Official spatial clip][spatial-video] | **RECORDED VISUAL, observed 3 Nov:** approximately 6.037 s shows `del`; 6.245 s shows `deltoid`; 9.782 s shows a second anatomical label while the real pointer remains elsewhere. | Supports visible prefix reveal in a short guidance label. It does not establish full conversational reply cadence, exact easing, FPS or speech synchronization. |
| [Creator spatial-context post][spatial-post] | **CREATOR TRANSCRIPT, rechecked 4 Nov:** describes indicating a region during invocation, asking about anatomy and passing a circled website area to an agent. | This is user-to-model context, distinct from model-to-user targeting. Exact post date is not exposed by the rendered primary page. |
| [Creator dictation post][dictation-post] | **CREATOR TRANSCRIPT, rechecked 4 Nov:** describes speech streaming into the focused field, a screen-aware Gmail draft, a terminal follow-up prompt and skill-assisted drafting. | The creator's roughly 450 ms transcription and roughly five-second drafting examples measure different workflows. Neither is an independently measured current answer-latency distribution. Exact post date unresolved. |
| [Creator collaborators post][collaborators-post] | **CREATOR TRANSCRIPT, rechecked 4 Nov:** an interview produces three role-specific collaborators; suggestions are approved; voice follow-ups steer the intended worker; results include Gmail drafts and research. | Edited demonstration/narration, not a repeatability result. Suggestions here are historical relative to R20's pause. Exact post date unresolved. |
| [Creator agents post][agents-post] | **CREATOR TRANSCRIPT, rechecked 4 Nov:** desktop cleanup, a native reminder, influencer CSV research and creation of a Spotify-control Mac app are narrated. | This does not prove arbitrary agent success, permissions, execution reliability or current task duration. |
| [Official About timeline][about] | Lists an earlier cursor companion, screen drawing and hands-free milestones. | Its 2025 chronology differs from the changelog's April 2026 v1.0 framing. Preserve the inconsistency; do not invent a reconciliation. |

The [official YouTube channel][youtube] and [creator X demo][x-demo] are linked primary sources, but usable playback/transcripts were not obtained through this research fetch path. No visual, latency or feature conclusion is added from inaccessible playback. Homepage montage filenames alone are not behavioral proof; editorial subtitles are not native captions.

Prior local inspection of installed **1.1.2 (69), 3 November** observed attached Home/Chat/Settings, voice/dictation/cursor preference controls and a separate expanded chat window. It did not connect services, execute jobs or exercise 3D. It observed the current account without populated pins/files on Home. That absence must not be generalized to every account or earlier release. The public [1.1.2 release][release] corroborates the release identity, not those local runtime details. Private captures and account contents remain outside this repository.

## Shared reference runtime follow-up — 5 November 2026

These observations were supplied by the shared native-UI inspection lane. They are separate from the public web check and the earlier version-identified inspection; this research lane did not operate the reference app or re-establish its binary identity.

| Evidence | Observation | What remains unverified |
|---|---|---|
| **LOCAL OBSERVATION — settings** | Shortcut settings, dictation's auto-detect control and Integrations were observed. | Visible controls do not establish shortcut delivery, successful dictation, connected-service authorization or completed integration tasks. No account identities, private history or dictionary contents are recorded here. |
| **LOCAL OBSERVATION — generic answer** | A new generic water-cycle question completed a text answer. The invocation was typed; microphone input was not exercised. | Text completion does not independently verify the drawing, its contents, speech playback or task-wide latency. |
| **USER REPORT — visual answer** | The user reported an additional diagram in a separate window/display surface. | Native CUA returned only a transparent host, so the diagram's pixels, location and composition were not independently inspected. Its visual output is **unknown, not absent**. Do not label this result text-only or infer that diagram generation failed. |
| **USER RECORDING — motor explanation** | In the 5 November recording, no housing is visible at 17.400 s; a small housing appears at 17.600 s, followed by staged motor parts and anchored-looking label prefixes. The model persists after Speaking disappears by 46.750 s; hand-pointer/view changes at 51–58 s support an orbit interpretation. The visible control is **× Clear**, not Close. | No conventional paper/window chrome is visible, but actual alpha/window ownership is unproven on the uniform background. Input events, audible content and exact speech alignment were not established. Raw media and private background content remain outside the repository. [Detailed recording evidence and reconstruction boundary](EXPLANATION-OVERLAY.md). |

The motor recording resolves the visible motor-presentation gap; it does not establish the contents of the separately reported water-cycle diagram. No FPS, exact animation curve, speech/audio synchronization, acoustic latency or complete 3D interaction parity is established by this follow-up.

## Proposed acceptance checklist for the whole parity goal

Every checkbox is intentionally **open**. The current implementation or a test under a similar name is insufficient to close a whole-product row. These are our original acceptance proposals; the release IDs identify the relevant vendor inventory, not proof the proposed test has been run.

| Priority / scope | Proposed observable acceptance | Current OpenCompanion boundary |
|---|---|---|
| **P0 — full guidance loop** · R01/R07/R15 | [ ] On unfamiliar public fixture apps, ask by speech and text, reveal a hidden destination, click the real intended control, capture the changed scene, then reach and verify the requested result. Include profile, settings, export, menus, keyboard/manual steps, slow loading and genuine ambiguity. | Thirteen authored-image provider cases cover target selection or clarification envelopes. Physical continuation and a general unfamiliar-app success rate remain separate. |
| **P0 — input and permission continuity** · R01/R03 | [ ] Repeated physical hold/release, brief-tap cancellation, Stop, sleep/wake, revoked permissions and a signed upgrade preserve a correct observable status and never revive an old turn. | Input/generation code and targeted installed observations exist. Full audio-route and permission lifecycle coverage remains open. |
| **P0 — no false task success** · R02/R07 | [ ] A visible click, a provider completion and a changed application result each receive separate evidence. Failed or ambiguous effects retain an unknown/failed outcome. | Guidance is advisory; explicit native actions and jobs are separate implementations. A target PNG is not a completed task. |
| **P1 — conceptual explanation** · R20 | [ ] Explain two unfamiliar mechanisms with useful native diagrams, readable math/labels, locally smooth reveals and a follow-up that edits only the intended part. Answer a simple fact without opening a notebook. | Corrected motor/molecule provider and bounded native visible-surface attachment checks pass. Narrated native focus and typed-receipt caption pacing are implemented; see [scene pointing](SCENE-CURSOR-POINTING.md) for the bounded recovery evidence. Independent label/focus meaning, more held-out concepts including 2D, math layout, follow-up editing and broad speech/reveal correspondence remain open. |
| **P1 — interactive objects** · R20 | [ ] Generate two materially different 3D explanations, orbit each, select a meaningful part, ask about it, change a parameter and export/reopen without losing meaning. | Typed primitives, projected leaders and passive explanation presentation exist. Option-only floating orbit is implemented; historical `228d495` retained it with a native hand cursor/black cue and passing installed synthetic native checks. Historical `a5dff4c` also passed one external-input trace, with input source unverified and human-physical-input field false. Historical `ac38f823` stayed passive. Notebook can orbit. Broader interaction remains open. Physical part selection/follow-up and general meaningful-object accuracy are not established. |
| **P1 — dictation** · R10/R21 | [ ] Dictate into public native, browser and Electron text fields; exercise hands-free mode, corrections, vocabulary, punctuation and mixed languages. Preserve the target field, never send a message implicitly, and keep terminal insertion nonexecuting. | Dictation is still a specified gap in the feature ledger; microphone-to-chat transcription is not focused-app dictation. |
| **P1 — contextual drafting** · creator dictation demo | [ ] From an authored email/task screen, ask for a draft with an explicit destination; inspect the text before committing; keep user edits and make failed insertion visible. | Needs a complete focused-field insertion and review flow, not a clipboard-only or chat-only demo. |
| **P1 — spatial input** · creator spatial demo | [ ] Circle one object among several public diagram parts, ask a deictic question, and verify the answer concerns that exact region. Test a scribble, cancelled stroke, replaced image and scaled/negative-origin display. | Region/stroke selection is implemented; installed capture-to-answer acceptance remains open. User-drawn context must not become an automatic desktop action. |
| **P1 — durable workers** · R02/R16 | [ ] Create two distinctly scoped workers, run real bounded tasks concurrently, steer one, stop another, inspect artifacts and continue the intended worker after restart. Test crash-after-effect reconciliation. | Jobs, storage and transport scaffolding exist. A polished persistent worker experience and live end-to-end task evidence remain incomplete. |
| **P1 — consented desktop control** · R20 | [ ] In an authored canary app, grant a precise temporary scope, observe a real effect, interrupt it with the supported user gesture, and verify no further input occurs. | Explicit per-action AX controls do not establish an independently accepted autonomous Drive workflow. Never silently broaden advisory guidance into control. |
| **P2 — connected services** · R03/R16/R19 | [ ] Connect a sandbox service, distinguish two accounts, inspect reported tools, reject expired credentials, reconnect and complete a real read/write task with the right account and receipt. | Generic MCP transport tests do not prove a built-in service catalog, OAuth registration or working account-specific task flow. |
| **P2 — browser execution** · R20/R21 | [ ] Pair the installed extension with the canonical app; navigate an authored signed-in-like fixture, resolve fresh document references, act, stop and verify the changed DOM. | MV3/native-host tests exist. Installed Chromium pairing and user-facing distribution remain separate gates. |
| **P2 — files and context** · R06/R14/R16 | [ ] Drop, paste and attach public files; ask a question whose answer is beyond the visible first page; verify citations; preview generated documents beside chat; reopen and export correctly. | Scoped extraction and storage exist. Visual image answers, rich preview and folder retrieval are not all accepted. |
| **P2 — memory** · R09/R16 | [ ] Explicitly save a preference, use it in a later relevant task, inspect/edit/delete it and prove an unrelated/private context never leaks into a new turn. | Explicit local memory is implemented. It is a different scope from automatic inferred personal profiles. |
| **P2 — scheduling** · R16/R20 | [ ] Create, pause, resume and delete a routine; sleep through two deadlines; wake offline; recover once after reconnection without duplicate external effects or misleading completion. | App-running routines/checkpoints exist. No background-after-quit capability is claimed. |
| **P2 — complete shell** · R04/R17/R20/R21 | [ ] Traverse Home, chat, Settings and a deliberate large window with one shared draft/history. Test resized surfaces, keyboard navigation, scroll retention, every disclosure, multiple displays and invisible-area click-through. | The notch and cursor have native acceptance. Exact reference curves/FPS and complete navigation/state coverage remain open. |
| **P2 — audio/readability** · R05/R21 | [ ] Distinguish follower replies, attached target labels, bottom captions and the full transcript. Test long answers, interruption, voice speed, headphones, route changes, muted output and text fallback. | Paced text and real mic levels exist. Several audio surfaces/routes remain only partly verified. |
| **P2 — preferences and identity** · prior local inspection | [ ] Every visible cursor, voice, language, microphone, shortcut, Dock/exposure and accessibility preference changes real behavior, persists across restart and has a safe unsupported-state fallback. Use original characters and assets. | Native settings exist; a visible selector is not evidence that the advertised capability works. Configuration must remain consistent across shell, activity strip, follower and full workspace. |
| **P2 — usable onboarding** · R11/R20 | [ ] A fresh user completes one talk, one capture/mark, one contextual question and one safe task, with denial and text-only alternatives and a replay path. | Native permission controls exist; a complete first-run teaching tour is a separate product task. |
| **P3 — distribution and maintenance** · R21/R22 | [ ] Independently verify supported OS/architecture coverage, stable signing/privacy identity, one canonical installation, recoverable upgrades, update signatures and uninstall/data preservation. | The local signed installer is tested. Developer ID/notarization, an update feed, Intel/oldest macOS and Windows are not a completed release scope. |
| **Separate hosted scope** · R12/R18/homepage | [ ] If hosted parity is chosen, specify and test account lifecycle, plan limits, billing/refunds, teams, referrals and server-side data deletion before exposing those controls. | Hosted billing/referral infrastructure is unsupported. Do not display copied account/upgrade controls that have no real service behind them. |

## What the 333-test checkpoint actually proves

At the historical `cf443ec` checkpoint, [FEATURE-STATUS.md](FEATURE-STATUS.md) recorded **333 Swift tests** (293 app, 15 store, 25 core), **29 Python installer/signing tests**, a signed app build and installed native checks. That checkpoint's real-provider authored-image run reports 13 passing cases: 11 target cases and two bounded clarification envelopes; seven image-only targets used native pixel conversion. Reported first valid target callbacks took 4.507–9.049 seconds, median 5.164, with the exact profile request at 4.507 seconds. These are existing project records, not rerun by this research pass.

The provider fixture supplies authored images/candidates and uses the real provider and native final-layer renderer. It bypasses capture permissions, actual AX harvest, foreground preparation, AppModel admission, displayed animation, physical input and notebook mutation. Its clarification and instruction meanings are not automatically judged. One sweep is not a latency distribution or reliability claim. [Guidance evidence and limits](CURSOR-UI.md)

## Current 587-test checkpoint: additional, bounded evidence

Historical clean installed `cc6bcd3` passed **587 local Swift tests (515 app across 65 suites, 21 store, 51 core across four suites)**, a signed build, canonical installation and exact-installed native regression. The normal NDJSON path adds bounded static endpoint connectors compiled into ordinary native cylinders. The diagnostic debug water retry used one connector unit/two cylinders and passed unchanged geometry checks, while an earlier protocol failure and a pendulum pass with no connectors remain explicit. The exact installed default-provider water trial, its separate native check and exact-source CI passed. No default or whole-feature gate is promoted. [Connector evidence](SPATIAL-CONNECTORS.md).

The exact installed native helper loaded the public diagnostic water document generated by debug artifact `2cf6da1a`: five meshes, three complete visible labels and all three requested leaders passed independent full-scene closest-target surface ownership before/after programmatic camera movement, unchanged canonical hints, zero overlap, foreground preservation and Clear/stale/current teardown. Its PNG was visually inspected: coherent spheres, joining bonds and white handwritten labels/dots/leaders. A separate authored box passed one synthetic own-view drag/end, zero cancellations, one surface-verified leader and lifecycle guards. These native checks made no provider call, desktop capture, audio recording, physical input or FPS measurement.

Historical installed `a5dff4c` passed a later trace-correlated external-input orbit check after its first fixture timed out: Option press/release 1/1, native start/end 1/1, 347 drag events and zero cancellations, with camera movement, unchanged foreground/document, released buttons/modifier and passive return. The helper posted no input. `inputSource` remains unverified and `humanPhysicalInputVerified` remains false. This trace belongs to that older binary, not `cc6bcd3`; the user separately reported smooth rotation and clicks passing through after release; broader interaction coverage remains open. Bounded whole-panel ownership while armed is not transparent-pixel click-through. [Orbit contract](FLOATING-ORBIT.md).

At the historical connector checkpoint, the installed source was `cc6bcd3443bec403d32ac9d7accefc15ec6d02e3`, with executable SHA-256 `a5563fa7a29852f501bdc8b860b379023fd119d1cdcab0d306b9f3c1552d4172`. The existing certificate is reused; deep strict signature verification and the designated requirement are valid, and build/install receipts, Info.plist and actual hash agree. This is a local arm64 build, not a notarized distribution. Only `/Applications/OpenCompanion.app` remains, with no cleanup issues or temporary build/staging app bundles. The exact-source [CI run `42071584703`](https://github.com/Nithesh8678/opencompanion/actions/runs/42071584703) passed native tests/build and protocol checks. After all helpers, CUA reopened the normal updated canonical app: only `org.opencompanion.cursor` was exposed, without Dashboard or Notebook. See [installed metadata](FEATURE-STATUS.md).

The exact installed `cc6bcd3` default-path water request passed with no explicit model argument: actual `gpt-5.6-terra`, low effort, routing `terraVisual`, three scene/text units, five meshes, three anchored labels and one connector unit compiling two cylinders. The unchanged independent water checks passed and no rejected public unit was recorded. First accepted typed geometry took **22.23689s**; provider finish took **32.16641s**. This completed request verifies access for that request, not general entitlement or reliability. The separate native check of this newly generated document also passed; the earlier `cc6bcd3` native pass loaded the debug `2cf6da1a` document. These are distinct provider artifacts and native runs.

A second, separate exact-installed native run loaded the fresh default-provider water document: five meshes, three complete visible labels and all three requested leaders resolved to independently checked full-scene target surfaces before/after programmatic camera movement. Canonical anchors, zero overlap, foreground, retained-document Clear and unmount checks passed. Its inspected PNG showed both bonds joining the atoms and three white handwritten labels/dots/leaders. The separate authored-box synthetic orbit also passed. This native helper used no provider, desktop capture, audio, physical gesture or FPS measurement.

Historical revision `ac38f823ff258de29937f5cb28ba753ab84a148e` passed **533 local Swift tests** (471 app across 60 suites, 21 store, 41 core), a signed build and exact-source [CI run `42057268761`](https://github.com/Nithesh8678/opencompanion/actions/runs/42057268761). Its installation metadata agreed and cleanup passed at that checkpoint. CUA quit/reopening and the final post-helper check retained cursor-only Accessibility state, without Dashboard/Notebook; those observations establish no physical input or audio acceptance.

Historical `ac38f823`'s opt-in spatial-steps/Terra water trial passed with three stages, three scene/text units each, three new-geometry units, five meshes and three anchored labels. Independent illustrative-geometry checks passed; first geometry took 21.51103 s and provider finish 31.65646 s. A separate native render passed all three complete labels/requested leaders' full-scene closest-target surface ownership before/after programmatic camera movement, unchanged canonical hints, zero overlap, alpha pixels, foreground/click-through, stale/current Clear and teardown. Its PNG was visually inspected. The native helper used no provider, desktop capture, audio, physical drag/Clear click or FPS measurement. This is one accepted lesson, not broad parity or latency/reliability proof.

The same steps format's Terra motor completed four stages with seven meshes/seven labels, but failed independent quality: its housing was a solid cylinder, with no cutaway tube despite the narration. First geometry took 29.17236 s; finish took 54.24596 s. Luna water completed three stages with five meshes/five labels, but all were tubes, failing geometry variety and atom roles (11.93385 s first geometry; 26.90201 s finish). Neither invalid lesson received a native render trial. Protocol success and faster rejected geometry close no feature gate and justify no default/routing change.

Historical installed `96180a1` passed 498 local tests and exact-source [CI `42052198287`](https://github.com/Nithesh8678/opencompanion/actions/runs/42052198287). Its separate normal NDJSON/Terra water control passed independent illustrative geometry with five meshes, four labels and three scene/text/new-geometry units. First geometry took 24.38992 s; finish took 40.60417 s. Its native check passed all four labels and three requested leaders (the fourth label had no leader), canonical hints, zero overlap, alpha pixels, foreground/Clear and teardown. That control is not attributed to `ac38f823` or to structured output.

The earlier 457-test `6e55f75` checkpoint is historical, with its clean six-leader motor rerun and exact-source [GitHub native tests/build and protocol pass](https://github.com/Nithesh8678/opencompanion/actions/runs/42042274452). Public-prompt Terra lessons passed typed admission, progressive new-part checks and fixture-specific world-geometry checks. Earlier four own-view runs on modified source checked all 20 leaders across motor/molecule documents against independent full-scene closest visible target/descendant triangles before/after camera movement, preserving canonical hints. Complete labels, zero overlap, clocks, alpha pixels, foreground and Clear teardown passed; the corrected housing dot was visually inspected. Those native checks did not call the provider, capture the desktop, use audio or physically orbit/click Clear, and are not attributed to `96180a1` or `ac38f823`. [Explanation checkpoint](EXPLANATION-OVERLAY.md)

The [structured-output experiment](STRUCTURED-EXPLANATION-STREAMING.md) preserves default NDJSON/Terra behavior and is not promoted. Historical units-schema trials failed quality/admission; their nested-conformance gate remains open. The new scene-required steps mode is implemented with strict validation of its trusted bundled subset and scene-before-narration callbacks; its first water provider/native checks passed. Native graph admission, visible pixels and semantic usefulness remain separate requirements. No whole-feature row closes from one lesson, partial geometry or a protocol-completed text-only answer.

The host's bounded surface resolution fixes the specific housing-cavity attachment defect while retaining the requested hint, but does not prove that a model chose the correct semantic target or explanation. The earlier two-case Terra timing run took approximately **20–30 seconds** to first accepted geometry, with less than one second of measured setup; the later installed water control took 24.38992 seconds. Very low answer latency remains unmet. A process-only Luna comparison failed one of two lessons, so the Terra default is unchanged. Local label-settlement intervals must not substitute for provider or acoustic latency. A later external orbit trace passed on `a5dff4c`; human-source verification, broader object interaction, speech alignment and concept/follow-up coverage remain open. No whole-feature checkbox closes on these historical checkpoints. The newer [scene-pointing report](SCENE-CURSOR-POINTING.md) records its own artifact-scoped evidence and bounded recovery verification.

The next meaningful quality gain is to close the first three P0 rows with physical, trace-correlated workflows and then finish complete explanation, dictation and worker slices. Adding more isolated primitives or sample screenshots cannot close the remaining rows by itself.

## Unresolved facts and research limits

- Current reference model routing, prompt construction, perception algorithm, capture schema, timing distributions, failure rates and exact animation curves are not established by the public sources. Static component names are a different evidence class.
- A prefix appearing in an edited short label does not prove a full reply uses per-character rather than word/mask reveal. No exact FPS or fixed interval is claimed.
- Historical default microphone, shortcut, menu-bar, cursor, skill, suggestion and approval behavior can change. Verify the active version and exposed settings before recreating a remembered demo.
- The [trust page][trust] and [privacy policy][privacy] describe data practices at different levels of detail. This research cannot independently audit retention, training exclusions, deletion completion, backend security or provider configuration.
- A policy permitting a daily integration read does not establish whether a suggestion job currently runs. The current release pause and older collaborator demos must remain distinct.
- This is a comprehensive capability-family checklist of the inspected public product, not a promise that every minor bug fix, account-specific experiment or unpublished feature has been discovered.

## Primary source directory

- [Homepage and current pricing][home] — rechecked 5 Nov 2026.
- [Official changelog][changelog] — rechecked 5 Nov 2026; no later entry observed, version/date labels above.
- [Official Mac release][release] and [latest-release redirect][latest-release] — rechecked 5 Nov 2026; [release list][releases] last checked 4 Nov 2026.
- [Trust][trust] and [privacy policy][privacy] — rechecked 5 Nov 2026; no explicit policy effective date established here.
- [Creator's historical repository][repository] — checked 4 Nov 2026; private-development notice dated 27 Apr 2026.
- [Creator spatial-context post][spatial-post], [dictation post][dictation-post], [collaborators post][collaborators-post], [agents post][agents-post] — checked 4 Nov 2026; relative ages only, exact publication dates not established.
- [Official About timeline][about], [Mac installation page][mac], [Windows installation page][windows] — checked 4 Nov 2026.
- [Official FL Studio video][fl-video] and [spatial video][spatial-video] — earlier browser-stream observations dated 3 Nov 2026; not downloaded or replayed in this pass.

[home]: https://www.heyclicky.com/
[changelog]: https://www.heyclicky.com/changelog
[release]: https://github.com/farzaa/clicky-releases/releases/tag/v1.1.2
[latest-release]: https://github.com/farzaa/clicky-releases/releases/latest
[releases]: https://github.com/farzaa/clicky-releases/releases
[repository]: https://github.com/farzaa/clicky
[trust]: https://www.heyclicky.com/trust
[privacy]: https://www.heyclicky.com/privacy-policy
[about]: https://www.heyclicky.com/about
[mac]: https://www.heyclicky.com/mac
[windows]: https://www.heyclicky.com/windows
[fl-video]: https://www.heyclicky.com/assets/clicky-fl.mp4
[spatial-video]: https://www.heyclicky.com/assets/clicky-spatial.mp4
[spatial-post]: https://www.linkedin.com/posts/farza-majeed-76685612a_today-were-shipping-spatial-context-this-activity-7480718045032665088-nY9f
[dictation-post]: https://www.linkedin.com/posts/farza-majeed-76685612a_today-were-shipping-screen-aware-dictation-activity-7482887327762030592-nCC3
[collaborators-post]: https://www.linkedin.com/posts/farza-majeed-76685612a_today-were-shipping-collaborators-each-activity-7510433420842319872-L4mk
[agents-post]: https://www.linkedin.com/posts/farza-majeed-76685612a_introducing-clicky-agents-this-is-the-simplest-activity-7454552863227285504-vQrQ
[youtube]: https://www.youtube.com/@HeyClicky
[x-demo]: https://x.com/FarzaTV/status/2041314633978659092
