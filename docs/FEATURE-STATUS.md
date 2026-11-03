# Feature and evidence status

Updated 3 November 2026. This is an active engineering build, not a claim of full product or production readiness. `implemented` means code exists; `automated-tested` is limited to the named checks; `installed-tested` means observed in a launched native bundle. Remaining acceptance is listed explicitly.

| Report scope | Proven status | Evidence and remaining acceptance |
|---|---|---|
| Native app, menu bar, text invocation, stop | implemented; installed-tested (notch-only launch, expansion, text response) | Xcode application target; actual bundle launched with no workspace; AX accessible controls; live notch conversation completed. Global hotkey conflicts/Spaces need acceptance. |
| Configurable shortcuts | specified | Default ⌘⇧Space / ⌘⇧R / Escape implemented; configurable key choices pending. |
| Companion listening/thinking/speaking, notchless fallback | implemented | Notch-resident expandable companion with original character; mounted voice states. Large workspace is secondary. Actual microphone/speaker/device route acceptance pending. |
| Deliberate screen/AX/OCR, permissions/repair | implemented | ScreenCaptureKit excludes own app; bounded AX/OCR; native privacy settings controls. Actual capture exclusion, denial/revocation and multi-display physical acceptance pending. |
| Coordinate transforms, stale generations | implemented; automated-tested | Negative secondary display, inverse composition, stale scene/document independence, guidance verification tests. Physical rotated/scaled displays pending. |
| User region and vector spatial context | implemented | Explicit selector with Return/Escape and bounded vector context. Installed capture/send acceptance pending. |
| Transparent annotations without focus theft | implemented | Separate non-key non-main click-through panel, bounded lifetime, foreground checks. Fullscreen/Spaces/focus retention installed tests pending. |
| Voice input/output, streaming, interruption, dictation | implemented (Apple STT/TTS and review-before-send); specified (dictation) | macOS14.2-compatible Apple Speech fallback; accepted sentence speech, immediate stop. Audio-route and real input/output acceptance pending; synth callbacks are not acoustic measurements. |
| Generic 2D notebooks/diagrams/math/charts/labels | implemented (retained primitives and text) | Core Animation shape/text layers, native font measurement; generic model scene protocol. Rich math shaping, chart recipes and layout constraints pending. |
| Durable scenes, saved lessons, undo/export/reopen | implemented; automated-tested; installed-tested (save) | JSON documents, SQLite library; original55-node import, unrelated fixtures, save visible in Library. PNG/PDF render laboratory exports exist; user-facing PNG/PDF export implemented; native render outputs inspected. |
| Interactive local 3D, camera, parameters | implemented (SceneKit Metal backend) | Bounded box/sphere/cylinder geometry cache, orbit, local play/step/speed. General mesh format/material/light controls and two live3D lessons pending. No custom Metal pipeline claimed. |
| Speech/visual beat clocks, text fallback | implemented; automated-tested (core scheduler) | Core host-clock scheduling tests; visual-first app scene acceptance. Full audio-synchronized application reveal wiring pending. |
| Closed-loop tutorials, postconditions | implemented; automated-tested (core) | Explicit desktop tutorial UI verifies fresh title/value; scoped actions require fresh snapshot. Three-step unfamiliar-app installed acceptance pending. |
| Scoped native actions | implemented | Bounded focused-window AX, explicit per-action controls, focus validation and observed value/title outcomes. Installed acceptance pending. |
| Browser extension and native host | implemented; automated-tested | MV3 activeTab scope, document refs, hit tests, original host. Real Chromium content tests and Swift/Python/socket/framing integration. Installed-browser end-to-end pairing pending. |
| Selected files/context/previews/citations | implemented; automated-tested | Scoped text/PDF extraction, hashes/bookmarks/page/line provenance and bounded content. Image metadata only; no visual image-file answer claim. File preview and project-folder retrieval pending. |
| History/search/user memory | implemented; automated-tested | SQLite migration/reopen/search/export; explicit memory creation/use/delete. Memory editing UX and retained audio options pending. |
| MCP accounts/connectors | implemented; automated-tested (transport fixtures) | Actual initialize/tools/list/call, account token isolation in Keychain, cancellation/schema checks. No service catalog or OAuth registration bundled; live configured server acceptance pending. |
| Jobs/progress/cancel/recovery/routines | implemented; automated-tested | Leases/checkpoints/receipts/outcomeUnknown, actual result persistence, bounded routine missed runs, cancellation reaches executor. App-running only; no background-after-quit claim. |
| ChatGPT subscription reasoning | implemented; live-tested | Documented Codex app-server with managed ChatGPT sign-in; no tokens copied. Three completed native-adapter requests: motor12 nodes, photosynthesis12 nodes, stable-ID recolor preserving other parts. Catalog does not prove entitlement. |
| Personal BYOK | implemented; blocked (live acceptance) | Configurable HTTPS OpenAI-compatible stream; endpoint validation/Keychain. Needs user-configured API credentials. |
| Self-host profile | implemented; automated-tested | Authenticated open relay, cancellation, mocked upstream integration, deployment instructions. Live provider deployment needs key. |
| Optional hosted subscriptions/referrals | optional-profile; unsupported | No hosted billing/auth or paid service is advertised. |
| Onboarding/settings/accessibility/diagnostics | implemented; installed-tested (accessible launch) | Permission repair/text fallback, native controls, prompt-free bounded timing export. Reduce Motion/full keyboard/screenreader acceptance pending. |
| Packaging/upgrades/uninstall/release | implemented (reproducible app); automated-tested (DB migrations); blocked (distribution signing) | Ad-hoc local signature; stable bundle ID; no DeveloperID/notarization/update feed claim. macOS14.2 and Intel not exercised; Apple Silicon current Mac only. |

## Current release gates

DeveloperID identity/notarization/update signing, real microphone/audio routes, physical multi-display/fullscreen/permissions, installed browser pairing, held-out tutorials, long sessions, and cold/warm100+ trial latency remain required before a complete production release. A local render export proves local layer output, not measured displayed FPS. No exact HeyClicky parity is claimed.
