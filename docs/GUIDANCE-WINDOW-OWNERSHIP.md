# Guidance window ownership investigation

This checkpoint records a native macOS experiment, not a new production window guard. Installed app source remains `68c644e4815ed21b21bf7a41e71065be1603d44c`; its executable hash was independently rechecked as `5748c67c6fbf108d97d7569129dd77fca7a873ba1385f06d5c6180aca89fc8ba`. The existing 875-test and exact-source CI results belong to that source. No app source, model routing, permission or installation changed in this investigation.

## Source-confirmed gap

Preparation restores an application PID (`OpenCompanionApp` and `CompanionShell.prepareScreenGuidance`). Capture uses an exact selected window ID and owner, but `desktopIndependentWindow` can supply that window's pixels even when a sibling from the same PID covers it. Overlay and continuation ownership currently compare the foreground PID. Those checks do not establish that the selected window/control is exposed.

A selected window may also be followed by a region crop. Therefore `ScreenEvidence.screenRect` is not universally the complete captured window frame. A new geometry check must retain trusted whole-window capture bounds separately rather than infer movement from crop-size inequality.

The locally inspected public AppKit SDK documents `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` as a mouse-down destination query at a global logical point. Passing zero excludes no window. A nonzero exclusion skips that window and every window above it; using that as an assistant-panel workaround could also skip a real blocker. CoreGraphics documents its on-screen window list as ordered front to back.

## Native experiment

A standalone Swift 6 component created three own nonactivating public test panels: A, B and a configurable cover. It used accessory policy, never activated, made no key window and preserved the initial foreground PID through every sample. Only own-window numeric metadata and bounded booleans were written to an exclusive private receipt. It captured no pixels, inspected no AX content, called no model, used no microphone/audio and posted no input.

The final run passed all setup/ownership/settlement prerequisites and all **12 stages**:

| Stage | Configuration | Observed hit |
|---|---|---|
| 0 | A alone | A |
| 1 | Same-PID B over A | B |
| 2 | B removed, native on-screen list acknowledged removal | A |
| 3–8 | Clear and filled passive covers at floating, floating + 1 and status-bar + 1 | A in all six samples |
| 9 | Cover made interactive | Cover |
| 10 | Cover made passive again | A |
| 11 | Cover removed, native on-screen list acknowledged removal | A |

The cover was independently found on screen during the passive stages. These were configured test panels at production-relevant levels, not the installed cursor/annotation classes. No screenshot/compositor-pixel or physical mouse-down assertion follows. Even a filled, opaque-configured passive panel was excluded from the hit result: this reinforces the distinction between **input destination** and **visual exposure**.

Two earlier attempts remain preserved. V1 sampled before B's order-out finished; B still appeared in on-screen metadata, making the ordering prerequisite inconclusive. V2 obtained the expected hit outcomes but required complete hidden-window metadata that its reader could not establish. V3 instead waited for a valid bounded on-screen list with owned anchor A present and the removed target absent. It never waited for a preferred hit-query result. Both independent structural acknowledgements passed, around 269 ms and 262 ms after their requests. Those are this fixture's hide acknowledgements, not guidance latency or a performance benchmark.

The final private probe source SHA-256 is `90be038a6898e89fd7e4806375732380df03d67c52f4ccddf3b703e8447f279b`; binary SHA-256 is `2d471a6fb863d57d82ae1c78c1aecea0fbd3103758988d4116361f2141dea334`. It compiled with Swift 6 complete concurrency checking and exited 0. Raw sources and numeric receipts remain outside the public repository.

## Implementation implications

Before cursor flight, annotation or action publication, a selected-window target needs exact current window-ID/owner/bounds checks plus a target-interior input-destination sample. The cursor's flight destination may lie outside the control, so it is unsuitable as the check point. Ordered higher-window bounds can conservatively refuse visual overlaps, including same-PID siblings. Only exact, currently tracked passive assistant panels may be exempted; interactive assistant windows must remain blockers. Bounding-box overlap is conservative and does not prove per-pixel occlusion.

Click observation needs a separate lease-bound mouse-down-to-mouse-up contract. The current coordinator sees mouse-up only. A menu can open on mouse-down, so a new hit query on mouse-up or after the settling delay can reject a legitimate transition and cannot authenticate the earlier destination. The public event PID and window-under-pointer fields are available, but their actual global-monitor delivery still needs native receipts before adoption. Unknown or contradictory ownership must not silently become PID-only authority. Every continuation still requests fresh perception and verifies progress; no observed click proves success.

Remaining native acceptance includes the actual passive cursor/annotation panels, selected A behind same-PID B, partial coverage, interactive own controls, move/resize/minimize/close, sheets, mixed scales/negative origins and legitimate menu transitions. The new guard and authenticated event handoff are **not implemented or verified** by this experiment. Complete external-task acceptance, latency targets and all **21 whole-product parity gates remain open**.
