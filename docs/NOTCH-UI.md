# Notch interface

Home, Chat and Settings now share the resident black surface. Hovering at the
physical camera cutout reveals Home without activating the app. Leaving tucks
the hover surface away. Clicking a destination pins it for interaction; Escape
tucks it away, and an outside click dismisses a pinned surface. A dismissed
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

Hold Control + Option, speak and release to submit and hear the reply. The Talk
button records for review before sending. These remain separate flows. Existing
typed drafts survive held voice turns. PTT still excludes the selected screen,
file and memory context; the visual redesign does not expand what it sends.
The configurable text shortcut remains Cmd + Shift + Space by default.
Double-Control and dictation shortcuts from other products are not advertised
as implemented.

Listening bars now use a bounded real microphone RMS envelope, with attack and
release smoothing. The audio callback reads at most 2,048 samples across at most
two channels and publishes only a coalesced scalar through a nonblocking lock.
A 25 Hz UI sampler handles presentation; there is no task or UI mutation per
audio buffer. Session IDs reject stale updates. Every end/cancel/failure resets
the level. This is activity feedback, not a calibrated sound meter.

## Presentation and motion

Content destination, tucked/hover/pinned exposure and voice activity are
independent state. Existing capture/task/document identities and focus checks
remain in place. Hover cannot become key; an explicit Chat open focuses its
composer. Hidden Chat and Settings controls are disabled, and a destination
change releases hidden text focus. Settings utility actions collapse the notch
before opening the full workspace. A transient voice pin is retired independently
of explicit navigation.

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
Reduce Motion skips the geometry animation and unnecessary activity movement.
Render/input work is local and independent of provider latency.

## Verification boundary

Swift tests cover negative-display/cutout placement, hover rearming, endpoint
proportions, spring reversal/uneven clock intervals, audio work bounds and
session/callback isolation. `--interaction-acceptance` uses isolated state and
synthetic pointer locations in the installed signed app. It checks more than
20 reveal/tuck cycles, draft/focus preservation, shared Settings navigation and
own-window screenshots. It never proves physical input delivery or acoustic
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
