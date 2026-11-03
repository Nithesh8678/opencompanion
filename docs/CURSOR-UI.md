# Cursor companion and screen guidance

Updated 4 November 2026. This describes current source behavior. The latest
combined visual and guidance revision still needs its final native acceptance;
the commands below are verification entry points, not recorded pass results.

## Reference and implementation

The supplied reference recordings informed the separate system pointer and
assistant triangle, progressive text, target annotations and return to following.
They do not establish an exact reference spring, word clock, render FPS, model
latency or speech synchronization. All graphics and motion here are original
native code; no reference application code or assets are included. The palette
and timing values below describe this implementation.

The full notch surface remains hover-only. Control+Option prepares the microphone
quietly, shows Listening with the real input level, and submits recognized speech
on release. A new hold synchronously clears the previous cursor answer. Escape
cancels the current operation. Settings → Cursor has independent controls for the
floating follower, nearby replies and Screen guidance.

## Conversational cursor

`CursorCompanionCoordinator` owns one transparent, nonactivating, non-key,
click-through panel. Pointer events update a logical-point target; following does
not capture screens, query Accessibility or contact a model. A display-linked
analytic spring preserves velocity across retargets, and the idle clock stops
when settled. The real system pointer remains visible and is never moved. The
panel hides over the notch surface and resets on sleep/session suspension.

`CursorCompanionView` retains a red rounded triangle and soft red halo. Nearby
answers use a light pink gradient capsule with dark rounded semibold text.
Geometry updates disable implicit animations. Native CoreText line plans are
shared by measurement and drawing, including fallback emoji ascent/descent.
A grapheme-safe trailing window fits at most four rows, adds a leading ellipsis
when earlier text is omitted, and keeps the newest visible words. Input to this
caption layout is capped at 220 graphemes; the full answer remains in Chat.
Sizing is cached and reused by drawing. A new word fades in on its own retained
text layer, leaving the capsule and already visible words steady.

`CursorTextReveal` uses these authored presentation values:

| Behavior | Current value |
|---|---|
| Ordinary word-group interval | 0.22 seconds |
| Additional sentence-ending pause | 0.15 seconds |
| Additional comma/semicolon/colon pause | 0.10 seconds |
| Additional newline pause | 0.16 seconds |
| Newly revealed word opacity fade | 0.14 seconds |
| Completed-answer reading hold | 3.5 seconds after provider, queued text and speech finish |
| Caption exit fade | 0.18 seconds |

At most one group advances per display callback; a late frame or backlog does
not accelerate the normal word clock. Groups preserve attached punctuation and
Unicode graphemes. Long unbroken words use bounded chunks, unspaced scripts use
small groups, and symbols remain whole. An unfinished final word/cluster waits
for more transport data. The queue holds at most eight units, each at most
32,768 UTF-8 bytes; the provider text limit is stricter at 32,000 bytes. Queue
pressure suspends provider delivery through asynchronous backpressure instead
of silently dropping a paragraph. Reduce Motion bypasses progressive pacing
and opacity/pulse animation while preserving complete Unicode content.

## Streaming and cancellation

Both provider transports use `ProviderTextStreamDecoder`. An ordered canonical
text object can emit inert cumulative previews before its NDJSON line completes.
Escapes, UTF-8 and surrogate pairs are recognized incrementally; unsupported
prefixes defer to complete validated JSON decoding. Decoded NDJSON lines are
capped at 256 KiB and each transport caps cumulative text output at 2,000,000
UTF-8 bytes. Partial
scenes, targets and actions are never applied. Canonical Chat and local speech
still wait for a complete validated text unit.

Task generations, immutable evidence identities and retained notebook revisions
have separate ownership. New turns, cancellation and errors discard provisional
cursor presentation. Codex app-server remains the ChatGPT subscription path;
this presentation does not copy its credentials or require a separate API key.
Local speech is queued by complete text unit. The word clock is local visual
pacing, not measured alignment to spoken words, phonemes or output audio samples.

## Requested screen guidance

Screen guidance is enabled by default, with backward-compatible saved settings.
At held-voice submission, `GuidanceIntent` uses a bounded English heuristic to
recognize requests such as “show me where to click” or “how can I create a table
in Supabase.” It distinguishes the covered general explanation/diagram cases,
covers specific screen-privacy opt-out phrases, and rejects input over 32,000
UTF-8 bytes. This is limited English phrase matching, not a general intent model;
requests can be missed or misclassified. Manual Add screen remains available in
Chat. Nonmatching voice questions do not trigger automatic capture.

A recognized, enabled request establishes its new response generation first,
then captures one fresh active-screen frame inside that turn task. The display
under the pointer is preferred, with the selected display as fallback. The
existing capture service excludes OpenCompanion windows and supplies bounded
AX/OCR context. Publication checks the task, capture generation, request,
preference, expiry and foreground app before provider delivery. Capture failure
reports an error rather than continuing with an ungrounded target.

Only this fresh frame's image and semantic text supply selected evidence for the
guidance turn. Selected file/memory content is omitted and the current notebook
is not sent or edited by this path. The existing conversation history remains;
selected context is retained in the UI. Ordinary voice questions retain their
normal conversation/notebook behavior while omitting selected screen/file/memory
evidence. There is no continuous screen capture or background AX polling.

## Target drawing and user-click continuation

`AppModel` binds targets to an immutable frame identity. `OverlayHost` then
validates normalized bounds, foreground app and evidence age under 15 seconds
before presentation. The cursor flight starts only after validation. Target
geometry and the capsule share one
layout model. Rounded rectangles use a dashed red outline; ellipses use an
original hand-drawn-style red path. Both have a restrained glow and light fill.
The attached label uses pink/light fill and dark text, bounded to 80 graphemes
and 4,096 UTF-8 bytes. When the model omits a label, its instruction is the
fixed annotation fallback even if nearby replies are enabled. Target instructions
are capped at 32,000 UTF-8 bytes.

The triangle flies to the label or target, using its flight duration to delay
the native annotation introduction. The outline draws over 0.35 seconds. The
label fades in over 0.16 seconds, then its shaped-prefix mask advances one Swift
`Character` every 0.06 seconds; this preserves joined emoji and combining marks.
For an ellipse the body traces its contour; for a label it follows the writing
edge. After that short presentation it returns smoothly to the real pointer.
The conversational reply text bubble is suppressed for guidance turns, so the
fixed label owns the instruction. Reduce Motion presents the final geometry/text
without the flight/write-on animation.

Fixed annotations have independent lifetimes of at most 45 seconds. At most
eight marks from the same frame coexist; appending does not extend older marks.
Foreground changes and explicit cancellation clear them. The triangle's brief
writing flight and the fixed annotation's longer lifetime are separate.

`ScreenGuidanceCoordinator` passively observes a left-mouse-up only while a
validated target with `advanceOn: "click"` is active. A click inside that target
is evidence of a user click, not proof that the requested action succeeded.
Observation is removed immediately to prevent duplicate continuation. After a
300 ms settling interval, the current generation, frame, request, foreground,
preference and deadlines are checked again. The next turn captures one fresh
frame and asks the provider to verify progress before giving the next target.
A foreground switch before queued capture also fails closed. Manual/explanatory
marks do not take over the advancing target on the same frame.

One request permits at most six steps, numbered 0–5, within 180 seconds from its
creation. Each admitted click target expires within 45 seconds and the request's
remaining lifetime. New turns, Stop, disabled guidance, changed evidence/display topology,
sleep/session suspension and ownership loss invalidate pending continuation.
No cursor flight or observed click injects a desktop click, types text, performs
an AX action, or proves a model-generated postcondition. The user performs the
actions; fresh perception is used to request verification.

## Verification entry points

Run `swift test` for parser, word pacing, Unicode, caption layout, ownership,
geometry and click-policy regressions. Build/install through the standard
scripts with the existing local signing identity. Quit the ordinary app before
launching an isolated installed acceptance instance:

```sh
/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion --cursor-acceptance /tmp/OpenCompanion-Cursor-Acceptance
/Applications/OpenCompanion.app/Contents/MacOS/OpenCompanion --interaction-acceptance /tmp/OpenCompanion-Notch-Acceptance
```

These entry points exercise synthetic controller input and public text fixtures;
they do not prove a physical modifier hold, microphone route or actual user
click. Own-window capture checks should inspect long mixed-script/emoji captions,
new-word fade, immediate restart, return-to-pointer, Reduce Motion, focus and
click-through behavior. Display-callback intervals are not presented-frame FPS.

The opt-in `--cursor-live-acceptance OUTPUT_DIRECTORY` path consumes a live
Codex-plan request for a public Moon-phases question. It records preview arrival,
validated text completion and first-glyph render submission separately. One trial
is not a latency distribution; render submission is not presentation or acoustic
onset.

For a live guidance check, `scripts/build-guidance-fixture.sh` creates the
separate public `/tmp/OpenCompanionGuidanceFixture.app`, never an Applications
installation. Open that fixture first and keep its opaque practice screen
frontmost with the pointer on the covered display. The acceptance entry point
checks public fixture window metadata to require an opaque layer-zero fixture
window covering that entire display before capture. The installed
`--guidance-live-acceptance OUTPUT_DIRECTORY` path uses real screen perception
and Codex requests, with speech disabled across its continuation steps. A person
or an explicitly authorized UI acceptance driver must click its highlighted
“Open table settings” control.
It checks that the next grounded target uses a different frame identity on the
fixture's second page. This entry point does not test microphone recognition or
inject a click itself. Final captures/results for the latest revision remain
pending; physical hotkey/audio feel, prolonged use, mixed-scale displays,
fullscreen/Spaces and exact visual parity need separate acceptance.
