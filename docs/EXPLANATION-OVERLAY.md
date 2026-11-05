# Explanation overlay: recording evidence and acceptance criteria

**Evidence reviewed and implementation checked: 5 November 2026.** The typed native renderer and passive explanation overlay are implemented. The final full suite passes 438 Swift tests (376 app, 21 store, 41 core), including the label-measurement regression, and a certificate-signed build passed. Corrected real-provider lessons, final native-helper reruns and visual inspection passed the bounded checks below. This is not full reference parity. Notebook remains the explicit editing path. A clean committed-source installation remains a separate pending checkpoint.

## Evidence boundary

The user-supplied recording is 60.705834 seconds long, with 3006 × 1958 video. Its SHA-256 is `87644c1fe8d36b446aa4f94cc6b6af743b8a47ffba17857e0f29c053ef47a2d6`. Only the reference overlay is described here; raw media, captures and underlying application content are excluded.

Separately extracted frames establish the observations below. Times are seconds from the recording start, subject to variable-frame-rate seek quantization. A sample timestamp establishes what is visible in that frame; a transition is bracketed between inspected frames. The recording's nominal 120 fps is not a measured application rendering rate.

The recording directly establishes a progressively assembled, shaded 3D motor with projected labels and later changing viewpoints. It resolves the visual-output uncertainty for **this motor recording**. It does not establish the contents of the separately reported water-cycle explanation.

## Recorded visual sequence

| Sample time | Visible evidence |
|---|---|
| 5.000; 10.500 | Cyan **Listening** text/bars. |
| 10.750; 16.750 | **Thinking** is visible. Listening → Thinking lies in `(10.500, 10.750]`. |
| 17.000 | **Speaking** begins to appear; the transition lies in `(16.750, 17.000]`. Orange bars are clear at 18.000. |
| 17.200–17.400 | A separate red assistant triangle enters the object area; no housing is visible at 17.400. |
| 17.600; 17.800 | A small, faint curved housing appears, then expands toward its normal size. The entrance has visible scale/fade progression. |
| 19.000; 20.000; 21.000 | Red upper magnet, blue lower magnet/base, then gray shaft are present in successive samples. |
| 24.000; 25.000 | Rotor/body, then the copper/orange loop are present. The complete object was not revealed at once. |
| 26.000; 27.000 | A leader/dot and partial magnet label appear; **Fixed magnet** is complete and **Copper coil** appears on the left by 27.000. |
| 30.000; 31.000 | **Magnetic** becomes **Magnetic force**. This proves staged prefix revelation here, not a universal letter interval. |
| 34.000–36.000; 39.000 | A copper commutator part develops; its label and leader are visible at 39.000. |
| 40.000; 41.000 | **Output** becomes **Output shaft**. |
| 42.000–46.000 | The assembled object and five labels persist while Speaking remains visible. Parts/view continue to change. |
| 46.500; 46.750 | **× Clear** appears while Speaking is still visible; Speaking is gone by 46.750 while Clear and the object remain. |
| 51.000–58.000 | A white hand-shaped system pointer appears, followed by rear/underside, oblique, side and end views. Labels reposition with the object. |
| 59.000–60.000 | The object remains. The selection border and bottom **Options/Capture** toolbar belong to macOS screen capture, not the reference application's playback controls. |

The visible white pill is **Clear**, not Close. No press on it is recorded. Its presence does not establish whether it clears one object, all objects or an underlying document.

## Surface, motion and interaction: known versus unknown

The object occupies the lower-right region over the existing application. No paper sheet, conventional title bar, traffic-light controls, surrounding Notebook frame or application playback toolbar is visible. The dark background is visually continuous around it. **Actual alpha transparency is unproven:** a transparent host and an opaque host matching that uniform background would look alike. The video provides no native window bounds, process ownership or window class; an analysis crop must not become a window-size specification.

Distinct shaded parts have material variation, softened edges, fine white edge strokes and a subtle shadow. A red triangular assistant with a soft halo travels independently of the white system pointer. White leaders and round anchors connect screen-facing, handwritten-looking labels to object parts. Their attachment and placement evolve as the view changes. Some rear/end views have crowded or overlapping labels; collision-free reference layout is not established.

The hand pointer and contiguous viewpoint changes at 51.000–58.000 support an orbit/drag interpretation. Button events, the input source and exact gesture semantics are unavailable. Earlier movement could combine part animation, scripted camera motion and user input. No selected-part follow-up, zoom slider, play/pause, speed control, reset or export action is exercised.

Listening/Thinking/Speaking are visible states. The audio track was not listened to or transcribed in this analysis. These frames do not establish spoken content, word/component synchronization, microphone source, acoustic quality, interruption behavior or end-to-end answer latency. No exact easing curve, frame rate, renderer, backend or model protocol is recovered from the pixels.

## OpenCompanion presentation and remaining gap

Previously, the explanation path produced retained scene documents in a titled, resizable Notebook panel. Generated explanations now use a separate passive native presentation; explicitly opening Notebook keeps the existing editing, saving and export path. The actually mounted document identity controls edit authority, rather than a sidebar selection or a retained hidden scene.

Typed geometry, native projection, local part/label reveal, independent revision/generation ownership and bounded Clear are implemented. A fitted oblique camera and bounded label-placement search reduce object coverage, crossings and label overlap; impossible label density remains observable rather than guaranteed collision-free. A separate assistant triangle travelling between new explanation parts, reference-matched materials/curves, direct floating-surface orbit and verified speech/visual beat alignment remain open. Completing speech does not itself discard the retained explanation.

## Implemented contract and current limits

`SceneNode.spatial3D` carries typed groups, boxes, spheres, cylinders, toruses and bounded partial/full tubes. Transforms use right-handed world space, +Y up, and local `T * Rz * Ry * Rx * S`. Labels reference a stable target part and a target-local 3D anchor; native camera projection supplies their screen position and leaders. The host chooses materials and native geometry. Model-generated code, textures, URLs and imported meshes are not accepted.

Documents containing typed spatial fields encode as `opencompanion.scene/2`; existing 2D documents retain version 1 and their meaning. Typed payloads cannot masquerade as version 1. Node/geometry/triangle budgets apply before native allocation. Local values, composed world transforms, primitive bounds and label anchors are checked, including at animation time. Scene patches are atomic; converting an existing part between legacy and typed domains requires explicit remove/create.

The visual window is wholly click-through, transparent, nonactivating and excluded from capture. Its only interactive companion window is the bounded **× Clear** pill. Clear stops the current response, unmounts both windows and retains the document and transcript. A per-presentation lease prevents an old Clear action affecting a renewed presentation. Sleep and session activity have independent gates. A removed display dismisses the presentation rather than moving it to another display.

New physical parts fade in locally. Anchored overlay labels reveal one bounded word group at a time using the existing 0.22-second cursor cadence; excess frame delay never creates a catch-up burst. Canonical full text supplies stable layout bounds. Changed label/document ownership resets presentation; a new generation settles prior labels. Reduce Motion reveals text immediately. The display clock also handles labels when scene animation is paused, and stops after settlement or dismissal. This is local pacing, not speech synchronization or measured display FPS.

Anchored overlay labels use the built-in `ChalkboardSE-Regular` font when available, with a system-font fallback. Native/CoreText measurement matches the drawing font. Model width is a preference; an unbroken word's intrinsic width can expand it within the 260-point label cap. The regression and final visual check confirm **Commutator** stays whole on one line in these lessons, rather than orphaning its last letter. Arbitrarily long words and maximum label density remain bounded-layout cases, not a universal no-wrap guarantee.

**Direct floating-surface orbit remains open.** Native camera control works in the explicitly opened Notebook editor; the passive visual window deliberately cannot receive drag events. Apple documents [`ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) for a whole window and [`allowsCameraControl`](https://developer.apple.com/documentation/scenekit/scnview/allowscameracontrol) for events delivered to SceneKit. Neither establishes cross-application mouse holes for alpha-zero SceneKit pixels. The [transparent-window sample](https://developer.apple.com/library/archive/samplecode/RoundTransparentWindow/Listings/Classes_CustomWindow_m.html) does not verify that modern SceneKit input behavior. No event reposting or pointer-triggered capture workaround is used.

The opt-in `--explanation-overlay-acceptance OUTPUT [PUBLIC_SCENE_JSON]` checks only this app's native views and windows. It uses native SceneKit output and the retained label composite; it does not capture the desktop, call a provider, inject input or record audio. Programmatic camera movement is distinguished from a physical orbit gesture. Controller Clear invocation is distinguished from a real mouse click. Raw reference media and private background content are excluded from the repository.

## Corrected provider and native-helper evidence

One corrected public-prompt run selected the account's advertised `gpt-5.6-terra`, low effort, with routing reason `terraVisual`. Notebook turns use focused text/scene instructions plus the typed spatial contract and current response policy, without screen-target examples. Both generated lessons passed atomic semantic admission, progressive new-part checks and independent illustrative geometry checks.

| Public case | Meshes / anchored labels | New-geometry units | First accepted typed geometry | Provider finished |
|---|---:|---:|---:|---:|
| Simplified brushed DC motor | 7 / 6 | 4 | 24.91675 s | 54.19467 s |
| Bent water molecule | 5 / 4 | 3 | 18.11225 s | 35.32046 s |

The motor oracle checks transformed common axes, centerline/axial proximity and a meaningful camera-facing cutaway. The molecule oracle checks distinct bonds' transformed endpoints against assigned atom bodies and a broadly bent arrangement. Earlier count-only structural passes missed misaligned axes and inverted bond rotations. Generic coordinate instructions and independent regressions address those failures; the renderer contains no science-name-based correction. These checks do not establish scientific or physical accuracy.

The clocks start before adapter startup and end at accepted geometry or provider return. No desktop image, microphone or retained Notebook was supplied. These are not hotkey-to-first-pixel or acoustic clocks, and one trial is not a reliability result or latency distribution. **Very low latency remains unmet:** first accepted geometry took approximately 18–25 seconds.

Final native-helper reruns loaded those corrected documents and passed with all 6/4 complete labels, zero reported label overlaps, actual native-clock advancement, transparent own-view composite pixels and unchanged foreground. Programmatic camera movement verified all 6/4 leaders against native anchor projection. Stale/current Clear handling and teardown passed while retaining the scene. Labels settled approximately 0.86827 s / 0.65058 s from the first own-view snapshot to settlement; these local presentation intervals are not provider or acoustic latency. The final motor and molecule PNGs were visually inspected, including the repaired one-line label and handwritten appearance. These runs did not physically drag the object or click Clear, call the provider, capture the desktop or use audio; own-view output is not WindowServer or cross-application input proof.

The installed signed font build used for these checks has binary SHA-256 `0bc2f9f038d1552b773ce2ab5130e1f1313b92d52ba060da4b505b9d71d73e15`. It was built from modified source; the forthcoming clean committed-source installation is not claimed by these results.

## Acceptance before claiming this slice complete

1. Extend the real-provider motor plus one held-out 3D case to at least two held-out concepts, including a 2D explanation. Retain typed validation, progressive arrival, independent content checks and final native visual inspection.
2. Inspect actual native pixels over contrasting, nonuniform backgrounds. Verify the intended transparency, visible bounds, controls, multi-display placement and display scaling without a desktop-sized invisible input blocker.
3. Exercise Notebook orbit with real input; verify part-anchor projection, label readability, Clear, keyboard/Accessibility access and Reduce Motion. Any future interactive overlay needs independent input-routing acceptance. Record supported zoom or selection separately rather than inferring it from the reference.
4. Test cancellation during reveal, a replacement turn, Clear followed by late output, and speech finishing before the explanation is dismissed. Confirm ordinary conversation/guidance does not open Notebook unnecessarily and deliberate Notebook editing still works.
5. Record capture/provider/reveal/audio clocks separately if measured. Verify actual narration and interruption independently before claiming speech alignment, latency or animation-performance parity.

Implementation and test results belong in [FEATURE-STATUS.md](FEATURE-STATUS.md). The broader reference inventory remains in [HEYCLICKY-PUBLIC-FEATURES.md](HEYCLICKY-PUBLIC-FEATURES.md); this recording closes only the specific visual-evidence gap described here.
