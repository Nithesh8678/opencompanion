# Cursor companion

The floating cursor reconstructs the observed red triangle, compact red caption,
white rounded type, progressive label and separate system pointer from the UI
study. All drawing and motion here are original native code. No reference app
code or assets are included. Exact reference curves, typing constants, current
runtime performance and full conversational bubble behavior were not recovered.

The existing notch remains hover-only. Holding Control+Option starts a quiet
microphone preparation, then Listening with the real input level. Releasing the
keys submits through the existing voice flow. The cursor can show Thinking and
progressive reply text while the camera-height notch strip keeps its existing
voice status. A new hold clears the preceding answer synchronously. Escape
cancels the operation. Settings → Cursor controls the follower and nearby replies.

## Native presentation

`CursorCompanionCoordinator` owns one transparent nonactivating, non-key,
click-through panel. Mouse events only update a logical-point target: following
does not record screens, query Accessibility or call a model. A display-linked
analytic spring preserves follow velocity across retargets; the idle clock stops
after settling. The real pointer is never hidden, replaced or moved. The panel
hides over the notch surface, supports Reduce Motion, and removes its monitors
and clock at shutdown. Sleep/session suspension hides and resets presentation.

`CursorCompanionView` retains Core Animation layers for the body, caption, input
meter and progress dots. Updates disable implicit geometry/content animations.
Font measurement and drawing share the same rounded semibold font and four-line
limit. Captions retain the newest220 graphemes; Chat retains the complete answer.
The completed caption stays briefly for reading before returning to the follower.

`CursorTextReveal` holds at most8 units, each at most32,768 UTF-8 bytes. It reveals
extended grapheme clusters with short punctuation holds and accelerates a backlog
instead of adding unbounded delay. An unfinished final cluster is withheld until
safe to reveal. Capacity recovery may immediately finish a completed head; it
never silently evicts an incomplete prefix. Duplicate, stale or rewritten previews
cannot advance another caption. The provider's stricter text bound is32,000 bytes.

## Streaming and ownership

Both providers use `ProviderTextStreamDecoder`. The canonical ordered text shape
can emit inert cumulative previews before the JSON line completes. JSON escapes,
UTF-8 and surrogate pairs are handled incrementally; unsupported prefixes fall
back to complete validated decoding. Partial scenes, targets and actions never
execute. Canonical Chat and speech still require a complete validated text unit.
New model generations, cancellation and errors clear provisional presentation.

The Codex app-server remains the ChatGPT subscription integration. This change
does not switch providers, copy authentication tokens or require an API key.
Microphone recognition and local speech output retain their existing lifecycle.
Progressive captions use a local clock; phoneme/word synchronization is not claimed.

Guidance acquires independent presentation ownership only after the existing
`OverlayHost` validates the target against selected screen evidence. The triangle
flies to the left of the target and progressively reveals its instruction. Later
narration waits rather than cancelling the flight or being consumed invisibly.
Frame identity, foreground process,15-second evidence age, cancellation and a
bounded7.5-second annotation lifetime invalidate guidance. It then rejoins the
pointer smoothly. The fixed target ring remains; its duplicate instruction is
omitted when cursor replies are enabled. Turning the cursor off retains the fixed
annotation's text fallback. No cursor flight performs a desktop action.

## Verification

Run `swift test` for parser, Unicode, ordering, bounds, stale content, geometry and
flight tests. Build/install with the standard scripts and existing local signing
identity. Quit the normal app first, then run isolated installed checks:

```sh
/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion --cursor-acceptance /tmp/OpenCompanion-Cursor-Acceptance
/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion --interaction-acceptance /tmp/OpenCompanion-Notch-Acceptance
```

The cursor check drives only its own synthetic pointer locations and public text
fixtures. Own-window captures cover idle, preparation, Listening, Thinking, a
partial prefix, completed caption, immediate restart, long Reduce Motion text and
guidance. Assertions cover focus retention, click-through configuration, idle
clock suspension, evidence replacement and hover-only notch behavior. It records
display callback intervals; these are not measured presented FPS.

An explicit live check consumes one request on the signed-in Codex plan, using a
public Moon-phases question through the actual AppModel preview and Chat path:

```sh
/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion --cursor-live-acceptance /tmp/OpenCompanion-Cursor-Live
```

It records provider preview arrival, validated text completion and the first
visible glyph's render submission separately. A single trial is not a latency
guarantee. Render submission is not measured presentation or acoustic onset.
Physical hotkey/audio feel, prolonged use, mixed-scale physical displays,
fullscreen/Spaces and exact visual parity still require separate acceptance.
