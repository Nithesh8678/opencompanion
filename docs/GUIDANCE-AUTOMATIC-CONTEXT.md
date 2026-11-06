# Automatic context for UI questions

## Reported failure

Both “can u tell me how to create a new table” and “check screen and tell me how to create a new table” could route to ordinary conversation without a screenshot. The first had a procedural software task but no named application or extra UI qualifier. The second used bare “check screen”, while the classifier required a determiner or a deictic word. This explains the source path leading to an app-name question or a no-screen reply; the original screenshot alone does not prove a provider transport failure.

## Corrected flow

Typed questions and recognized push-to-talk text share the same routing decision. Procedural/help requests involving software objects now use the current application without requiring its name. Leading screen-inspection requests accept informal wrappers and a bare screen/desktop/display. The route remains bounded and preserves explicit no-screen/text-only requests, quoted instructions, direct authored content, coding questions and common physical/mathematical meanings. This is an English heuristic, not universal intent recognition.

A guidance request then uses the existing acquisition transaction: retain an explicitly selected typed capture’s exact scope when applicable; otherwise choose the active display once, tuck the assistant’s surfaces, restore/check the intended external app and acquire a fresh screenshot with current AX/OCR semantics. The exact image and current question go into the same reasoning turn. Unrelated prior chat, selected file/memory content and retained notebooks do not become guidance input. The model can infer the current app from the supplied image and semantics, then mark its next grounded visible control. Capture failure stops before provider submission; it has no text-only fallback. No screenshot is claimed when capture fails.

The normal acquisition implementation and foreground/selection checks are unchanged. An internal acquisition dependency allows deterministic host tests to suspend/fail acquisition or return an authored frame. That boundary checks request/generation/capture ownership, cancellation, fresh frame identity/timestamp, expected foreground, bounded full-display metadata and real JPEG dimensions before publication. Its default is the native transaction. The dependency does not prove native capture or display coverage.

## Verification

The focused run passed **100 tests in seven suites**. The full run passed **911 tests**: 818 app tests across 98 suites, 28 store tests and 65 core tests. Added coverage includes 57 classifier examples, typed submission and authored speech-completion callback paths for both reported phrases, fresh image/semantics/current candidates, removal of stale no-screen history, independent notebook/context preservation, capture failure, Stop during acquisition, malformed/stale handoffs and privacy opt-out.

A real Python subprocess also recorded the production Codex adapter’s actual input: one turn contains the current question/context and exactly one image data URI whose decoded bytes equal the authored valid JPEG. This exercises encoding and pipe delivery without real credentials or a live AI response. Authored speech completion is not microphone, recognition or physical-hotkey verification. These tests do not establish real screen acquisition, unknown-app guidance, physical continuation, acoustic timing or a latency benchmark. Signed installation and exact-source CI for this correction are pending at this source checkpoint.
