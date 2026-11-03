# Notch and hold-to-talk

Idle coincides with the camera-cutout rectangle reported by `NSScreen.safeAreaInsets` and the two auxiliary top areas. It does not place an extra bubble underneath. Controls are rendered below the cutout. A display without a reported cutout uses a small capsule below the menu bar.

Hover opens a compact peek without activating the application or taking keyboard focus. Pointer exit tucks it; drafts remain intact. Open chat or the configurable text shortcut opens the full conversation explicitly. A voice turn retains the compact activity surface through listening, thinking and speaking.

The hover target includes the display's exact top edge. Event monitors are supplemented by a 20 Hz read of the logical pointer position, because movement over the camera housing can bypass the app's mouse-event stream. This requires no screen capture or Accessibility permission. The resident surface uses opaque black, white and neutral gray so it blends into the camera housing.

Hold Control + Option to prepare the microphone and listen. Release either modifier to end audio capture and submit the recognized utterance. A final transcript completes immediately; an800ms upper bound handles an already captured recognition tail. Releasing during permission/startup cancels startup and requires a fresh hold. Extra modifiers or an ordinary key cancel the gesture without suppressing the original keyboard events.

Push-to-talk preserves the typed draft, normal conversation history and the active notebook. Selected screen/file/memory evidence is omitted from that voice turn; no screen capture starts automatically. The response is spoken for this turn without changing the saved speech preference. The Talk button retains manual transcript review.

Stop, sleep, session lock, disabled observation or a newer voice session invalidate pending transcription, including the tail after physical key release. Settings reports actual event-tap installation separately from permission eligibility. Input Monitoring or Accessibility, Microphone and Speech Recognition remain controlled by macOS.

Changing an ad-hoc build changes its code identity and may invalidate earlier permissions. Keep the canonical install path and a consistent [local signing identity](LOCAL-SIGNING.md). The first install under that identity still needs permission from the user.

The interaction follows the compact peek/explicit Home behavior described in the September24 [official HeyClicky changelog](https://www.heyclicky.com/changelog) and held voice invocation in the [Mac guide](https://www.heyclicky.com/for-mac). Public source also documents modifier-only hold/release handling. This implementation uses original code/artwork. Its70ms hover dwell,230ms exit grace,1.2s terminal feedback and exact layout are reconstruction choices; they are not measured HeyClicky constants.

`--interaction-acceptance <output-directory>` exercises real panel geometry, focus and repeat hover using synthetic pointer locations and an isolated model. This shell explicitly uses `observePointer: false`: both mouse-event monitors and pointer polling are disabled so the physical pointer cannot replace a synthetic test location. Ordinary app shells keep pointer observation enabled. A separate run-loop test verifies the polling transport with an injected location source and no mouse events. Its own-window images contain only fixture UI. These checks do not inject OS keyboard/pointer input, record speech or call an AI provider. Physical hover, key delivery and microphone/acoustic behavior require installed user acceptance.
