# Cursor companion and screen guidance

Updated 4 November 2026. The installed cursor/annotation and notch checks passed,
and a public conversational request completed through ChatGPT via Codex. A live
public-screen request grounded its first target correctly. Physical click-to-next-
frame continuation remains pending in the saved trace; the UI driver's button
invocation does not deliver a global mouse-up event. The user separately reported
that the next Table name field was highlighted. These boundaries are separate
from source and unit-test coverage.

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

## Shared response routes and notebook ownership

Typed messages and completed held-voice requests use the same `ResponsePolicy`
before generation starts. Its three routes describe permitted output:

| Route | Intended behavior |
|---|---|
| Conversation | Routine questions, factual answers and text tasks stay in Chat/nearby replies. No notebook scene is applied. |
| Screen guidance | Requests for help using a visible app, including “how do I create a new chat in ChatGPT?”, use grounded target annotations. Notebook scenes are not applied. |
| Notebook | Explicit drawings, plots and diagrams, or mechanism teaching that can benefit from spatial relationships, may use a scene. A scene is permitted when useful, never required. |

This is a bounded English heuristic, not general language understanding. It
classifies only the current request, with a 32,000 UTF-8-byte limit and covered quoted
examples excluded from positive intent. Text-only instructions keep the response
conversational; no-diagram instructions prohibit notebook output. Screen-privacy
instructions prevent automatic screen access. A privacy preface such as “No
screenshot. Draw a diagram of a lever” still permits the independent conceptual
drawing. Disabled Screen guidance falls back to conversation.

The policy is fixed for that turn and supplied as trusted instructions to both
provider transports. `AppModel` also enforces the notebook capability: scene
units on conversation/guidance routes are ignored before document mutation,
undo changes, navigation or notebook presentation. Valid text units can continue.
Target units outside the screen-guidance route are likewise ignored before
cursor movement, annotation presentation or instruction/history mutation.
An old notebook or previous conversation about diagrams cannot grant a new turn
permission to edit it or reopen its panel.

A permitted new visual starts an independent notebook document on its first
accepted scene unit. Later scene units in that response patch that same document.
Existing notebook content is supplied for editing only when the notebook context
is visible and the current request clearly asks for an edit/reference, such as
recoloring the selected arrow. Document identity and revision checks still reject
late responses after a concurrent edit or notebook replacement. The notebook
panel is presented at most once per visual turn, after an accepted scene; these
rules do not change explicit New notebook, built-in example, saved-notebook or
manual editing actions.

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
The shared response policy uses `GuidanceIntent` for typed and held-voice
requests such as “show me where to click,” “how can I create a table in Supabase,”
or the covered new-chat requests in ChatGPT. Recognized spoken ChatGPT spellings
are normalized. General explanations, authored tutorial wording, quoted examples
and covered screen-privacy opt-outs are distinguished from requests to inspect
an app. Requests can still be missed or misclassified. Manual Add screen remains
available in Chat. Nonmatching questions do not trigger automatic capture.

A recognized, enabled request without a matching deliberately selected typed
screen attachment establishes its new response generation first, then captures
one fresh active-screen frame inside that turn task. Before capture, the app hides
its utility/notebook panels and tucks the
notch. If OpenCompanion owns focus, it requests normal activation of the intended
previous external app and waits at most one second for that exact app. A changed
external foreground, cancelled task or replaced generation aborts preparation.
This is focus preparation for the explicit guidance request, never a click or
typed action in the target app.

The display under the pointer is preferred, with the selected display as fallback.
The existing capture service excludes OpenCompanion windows and supplies bounded
AX/OCR context. Publication checks the task, capture generation, request,
preference, expiry and foreground app before provider delivery. Capture failure
reports an error rather than continuing with an ungrounded target.

Automatic guidance supplies only that fresh frame's image and semantic text as
selected evidence. Selected file/memory content is omitted, and the current
notebook is not sent or edited by this path. The existing conversation history
remains; selected context is retained in the UI. A typed request can reuse a
screen attachment only when explicit manual-selection provenance matches the
current immutable evidence identity. This covers deliberately selected full
displays, windows, regions and captures made with spatial strokes. It retains
that exact frame rather than broadening to the display. An old automatic-guidance
frame does not acquire manual provenance merely by remaining in memory; it
requires a fresh automatic capture for the next guidance request.

Manual guidance sends only the matching frame's image and semantic text. Selected
file/memory/context text and raw drawn-stroke vectors are not added to this
payload. This path also prepares the intended external foreground and tucks/hides
own panels before provider delivery, without recapturing or broadening the selected
frame. Cancellation, generation, selected evidence identity and foreground are
checked again after the preparation wait. Its target still has to pass frame-identity, freshness and foreground
checks. Automatic click continuation belongs to the fresh-capture request path.
Cancelling pending capture work invalidates publication tokens and stops that
work; it is distinct from removing an already published attachment. Remove
context, replacement selection and display-topology invalidation clear the
attachment and its selection authority.

Ordinary typed requests can use deliberately attached context. Ordinary voice
questions omit selected screen/file/memory evidence; notebook inclusion is
separately controlled by the shared edit policy. Manual Talk still prepares a
draft for review rather than submitting it. There is no continuous screen capture
or background AX polling.

## Target drawing and user-click continuation

`AppModel` binds targets to an immutable frame identity. `OverlayHost` then
validates normalized bounds, foreground app and evidence age under 15 seconds
before presentation. The cursor flight starts only after validation. Target
geometry and the capsule share one
layout model. Rounded rectangles use a dashed red outline; ellipses use an
original hand-drawn-style red path. Both have a restrained glow and light fill.
Current provider instructions require an ellipse for a compact button/icon and
reserve rounded rectangles for fields or larger regions. Live acceptance of this
tightened shape instruction remains pending.
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

If a guidance response has no valid target because the scene is ambiguous or the
task is complete, its completed text explanation can appear as a nearby reply.
That fallback does not open a notebook or establish a click-advancing target.

Fixed annotations have independent lifetimes of at most 45 seconds. At most
eight marks from the same frame coexist; appending does not extend older marks.
Foreground changes and explicit cancellation clear them. The triangle's brief
writing flight and the fixed annotation's longer lifetime are separate.

`ScreenGuidanceCoordinator` passively observes a left-mouse-up only while a
validated target with `advanceOn: "click"` is active. The handler converts the
recorded event's Quartz coordinates to global AppKit coordinates, rather than
sampling a pointer that may already have moved. Missing/nonfinite event
coordinates fail closed. A click inside that target
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
inject a click itself. Physical hotkey/audio feel, prolonged use, mixed-scale
displays, fullscreen/Spaces and exact visual parity need separate acceptance.

## Recorded verification

- Latest completed automated checkpoint: 222 Swift tests and 29 Python
  installer/signing tests passed. The capture-provenance and target-admission
  follow-ups require another regression run before extending that evidence.
- Shared typed/PTT routing, notebook admission/new-document isolation and retained
  edit regressions passed automated tests; the updated native app built. Live
  routing and foreground-preparation acceptance for this change is pending.
- Certificate-signed native bundle built and installed at the canonical path.
- Installed cursor acceptance passed: unfinished word waits, ordered whole-word
  reveal, one canonical Chat commit, immediate restart, four-row emoji caption,
  Reduce Motion, idle clock shutdown, fixed annotation capture and no focus theft.
  Transparent capture inspection used alpha compositing onto a neutral dark
  background; raw transparent PNG RGB is not the composited on-screen appearance.
- Installed notch regression passed: compact voice state lifecycle, cutout
  placement, repeated synthetic hover, draft preservation and foreground focus.
- One live public Moon question passed with incremental previews. First preview
  arrived at 5,413.49 ms, first-glyph render submission at 5,422.36 ms and complete
  text at 5,900.48 ms. The local preview-to-submission gap was 8.87 ms. This was
  one cold request, not a latency distribution or measured display presentation.
- The live public practice screen produced a correct click-advancing target
  around “Open table settings.” The driver changed to the next page through
  native control invocation, but generated no global mouse-up; the two-step
  acceptance therefore did not pass. Its bounded target expired as designed.
  The user separately reported the next Table name field was highlighted. The
  timed physical test recorded target expiry without a second frame, so that
  visual report is not treated as a trace-confirmed two-step run.
