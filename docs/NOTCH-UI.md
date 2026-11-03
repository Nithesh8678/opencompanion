# Notch interface

Home, Chat and Settings now share the resident black surface. Hovering at the
physical camera cutout reveals Home without activating the app. Leaving tucks
the surface away, including Chat and Settings. Clicking a destination permits
keyboard interaction while the pointer remains in its surface. Escape tucks it
away, and an outside click also dismisses it. A dismissed
surface needs a pointer exit before hovering can open it again.

The Home footer opens the real local library/notebook and connection tools.
There are no placeholder usage, billing or referral controls. The top expansion
button opens the same conversation in the full workspace. Settings has nested
General, Voice, Shortcuts, Providers, Connections and Privacy & memory sections.
Notebook, saved library, memory, jobs and existing connection actions remain
available in the full workspace. The full chat uses a dark sidebar, blue user
bubbles, charcoal replies and a subtle static dot field. Its transcript stays
mounted when browsing other destinations and follows incoming text only near
the live edge; a Latest button returns to it.

## Voice and context

Hold Control + Option, speak and release to submit and hear the reply. This
shortcut reveals only a camera-height black activity strip: a white status
label left of the measured cutout and a small cyan listening meter or violet
thinking indicator on the right. The full dashboard remains hover-only. Hover
on either compact wing reveals Home; leaving returns to the compact strip
while that voice turn is active. Completion, empty input, failure and Stop
retract it into the hardware cutout. Other notch
open shortcuts also respect pointer presence. The Talk
button records for review before sending. These remain separate flows. Existing
typed drafts survive held voice turns. PTT still excludes the selected screen,
file and memory context; the visual redesign does not expand what it sends.
The configurable text shortcut remains Cmd + Shift + Space by default.
Double-Control and dictation shortcuts from other products are not advertised
as implemented.

Microphone preparation is visually quiet. Listening is the first visible input
status after the audio engine becomes ready. A fresh hold clears the previous
turn's text, dots and layer animations synchronously; entry into Listening never
crossfades a previous response. This prevents a Thinking/Listening overlap on
first use or when interrupting a reply. Response phases retain their short fades.

Listening bars now use a bounded real microphone RMS envelope, with attack and
release smoothing. The audio callback reads at most 2,048 samples across at most
two channels and publishes only a coalesced scalar through a nonblocking lock.
A 25 Hz UI sampler handles presentation; there is no task or UI mutation per
audio buffer. Session IDs reject stale updates. Every end/cancel/failure resets
the level. This is activity feedback, not a calibrated sound meter.

## Presentation and motion

Content destination, tucked/hover/interactive exposure and voice activity are
independent state. The compact activity scope begins only on a fresh hold, and
an explicit successful voice submission transfers it to the response generation.
Typed requests and stale callbacks cannot reopen it. Queued and active speech
keep the scope alive until the synthesizer completes. The strip is click-through
and cannot become key; it does not activate the app. Existing capture/task/document identities and focus checks
remain in place. Hover cannot become key; an explicit Chat open focuses its
composer. Hidden Chat and Settings controls are disabled, and a destination
change releases hidden text focus. Settings utility actions collapse the notch
before opening the full workspace. Voice has no presentation pin. Completed
voice errors/notices can be dismissed directly on Home.
The window picker belongs to the host that requested it; it cannot attach to
the tucked notch when opened from the full workspace. Leaving the notch also
cancels its pending picker so late enumeration cannot reopen a sheet.

The measured reference proportions informed a 516 x 160-point Home body and
an 800 x 650-point Settings body, with seven-point attachment shoulders at each
side on a cutout display. Chat uses a larger 600 x 480-point body. Display
geometry is derived from NSScreen safe/auxiliary areas, with clamping and a
notchless fallback. These are our chosen endpoints, not a recovered private UI.

One CADisplayLink drives a closed-form critically damped spring. Retargeting
preserves position and velocity. The native viewport stays fitted to the
surface instead of leaving a large invisible window over the desktop. Hosted
content retains its endpoint layout while a native attachment mask and viewport
animate. Each destination has an explicit layout envelope: hidden Settings
must not enlarge Home and push its header/footer outside the viewport.
The compact strip uses retained native text, bar, dot and radial glow layers.
Its 108/68-point left/right wings sit outside the actual camera gap, with no
content under the camera. Entry/exit uses the same spring and a short opacity
fade; response phases crossfade, and Core Animation drives the quiet glow/dots.
No timer or task is created per animation frame. Hidden and idle activity stops
repeating animations. These dimensions and curves are authored from the supplied
visual references, not recovered private implementation values.
Reduce Motion skips the geometry animation and unnecessary activity movement,
including the activity pulse and status crossfade.
Render/input work is local and independent of provider latency.

The shell uses an explicit black perimeter and no native window shadow or host
focus ring. Home, Chat and Settings share this border, including where the inner
Settings background is charcoal. Internal controls retain their own focus styles.

## Verification boundary

Swift tests cover negative-display/cutout placement, hover rearming, endpoint
proportions, spring reversal/uneven clock intervals, audio work bounds and
session/callback isolation. `--interaction-acceptance` uses isolated state and
synthetic pointer locations in the installed signed app. It checks more than
20 reveal/tuck cycles, draft/focus preservation, shared Settings navigation and
own-window screenshots. Compact-status fixtures also verify camera-height
placement, focus preservation, hover from a status wing, return from Home,
explicit response handoff, completion retraction and unrelated-turn isolation.
Pure state tests cover pending speech, late callbacks, cancellation and terminal
generations. Retained-layer tests cover prior-response reset, quiet preparation,
clean Listening entry and finite meter geometry. Native acceptance captures both
first preparation and an immediate restart from Thinking, then checks that no
old text, dots or glow are visible. It also verifies that expanded surfaces have
no native window shadow. Escape and visible Stop remain available while speech is queued,
including before the synthesizer's start callback. Acceptance never proves physical input delivery or acoustic
output. Its callback interval JSON measures local display-link scheduling,
not presented-frame FPS.

The new Home, Chat and Settings were inspected in the installed normal GUI.
An initial Home clipping problem was reproduced by the user and fixed with
explicit destination layout envelopes. Native tests also found and review
corrected voice-pin lifetime, hidden composer focus, settings handoff and
lazy transcript edge tracking. Screenshot/measurement artifacts remain private
and are not committed.

Exact reference animation curves, pixel parity, displayed FPS, full-screen and
multi-display behavior remain unverified. No proprietary code, binary, mascot
or captured reference image is included in this repository.
