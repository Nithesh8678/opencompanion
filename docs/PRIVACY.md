# Privacy and local boundaries

Microphone input starts only on explicit invocation. Holding Control + Option starts push-to-talk; releasing sends the recognized utterance to the configured reasoning provider and speaks the reply. The manual Talk button produces a draft for review before sending. Voice hotkey turns omit selected screen/file/memory evidence while preserving ordinary conversation and notebook context. Apple Speech uses on-device recognition where available; otherwise Apple may process audio. Speech output uses system voices. No audio recording is persisted by this build.

The global voice shortcut uses a passive event observer for modifier transitions and ordinary-key press/release categories so other shortcuts can cancel recording. It does not suppress events or read/store typed characters or key codes. macOS Input Monitoring or Accessibility permission is required; Settings reports whether the observer was actually installed.

While the notch surface is visible, a local timer reads the logical pointer position to detect hover even when the camera housing does not deliver mouse events. It does not capture pixels, observe keyboard content or retain a pointer history.

Add screen captures one selected display frame using ScreenCaptureKit. It excludes OpenCompanion's app windows. AX/OCR are bounded; secure AX fields are omitted. The selected image and extracted evidence are sent only with a user question. Frames are held in memory and can be removed. Region/scribble mode is explicit. Actual capture-exclusion acceptance is still required; see feature status.

Selected file content is read directly within its granted path. Text/PDF chunks contain path/page/line and current content hash. Screenshots do not stand in for offscreen file content. Images currently supply metadata, not visual interpretation.

Library data lives in ~/Library/Application Support/OpenCompanion/library.sqlite. Memory is explicitly written and selected. Library export excludes Keychain credentials; deletion is available per record. Diagnostics contain timing event names/generations, not prompts, screenshots or credentials. Do not publish your local database or diagnostics without reviewing them.

Provider API/relay and MCP account tokens are stored in Keychain. Subscription mode launches the installed Codex CLI, which manages its own ChatGPT login and renewal; OpenCompanion does not read/copy its tokens. Model usage remains subject to the provider plan and limits. Ephemeral teaching threads disable configured external tools; attempts to use tools are rejected.

The developer build is not App Sandbox-contained, because cross-application AX/desktop features require explicit OS permissions. A helper process is not a security sandbox. Native actions are selected explicitly; annotations do not authorize writes. Selfhost relay secrets live only in its configured process environment.
