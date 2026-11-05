import AppKit
import Carbon
import Combine
import CompanionStore
import SwiftUI

@main enum OpenCompanionApplication {
  @MainActor static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel!
  private var shell: CompanionShell?
  private var cursor: CursorCompanionCoordinator?
  private var screenGuidance: ScreenGuidanceCoordinator?
  private var manualGuidanceControls: ManualGuidanceControls?
  private var utilityWindow: NSWindow?
  private var explanationPanel: NSPanel?
  private var explanationOverlay: ExplanationOverlay?
  private var explanationRequestDisplay: (generation: UInt64, displayID: CGDirectDisplayID)?
  private let hotkey = HotkeyService()
  private let captureHotkey = HotkeyService()
  private let stopHotkey = HotkeyService()
  private let voiceShortcut = VoiceShortcutMonitor()
  private var voiceShortcutSubscription: AnyCancellable?
  private var activationSubscription: AnyCancellable?
  private var voiceHoldGeneration: UInt64?
  private var voiceLifecycleSubscriptions = Set<AnyCancellable>()
  private var stateSubscription: AnyCancellable?
  private var shortcutSubscription: AnyCancellable?
  private var stopKeyRegistered = false
  private var statusItem: NSStatusItem?
  private var localKeys: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let liveGuidanceAcceptance =
      CommandLine.arguments.contains("--guidance-live-acceptance")
      || CommandLine.arguments.contains("--guidance-manual-live-acceptance")
    let acceptanceMode = [
      "--keychain-acceptance", "--smoke-test-codex", "--render-acceptance", "--capture-acceptance",
      "--interaction-acceptance", "--cursor-acceptance", "--cursor-live-acceptance",
      "--guidance-live-acceptance", "--guidance-routing-acceptance",
      "--guidance-manual-live-acceptance",
      "--spatial-scene-live-acceptance", "--explanation-overlay-acceptance",
      "--explanation-orbit-live-acceptance",
      "--explanation-narration-acceptance",
    ].contains(where: CommandLine.arguments.contains)
    model = AppModel(acceptanceMode: acceptanceMode)
    model.onOpen = { [weak self] in self?.openRequestedSurface() }
    model.onCompanionRequested = { [weak self] in
      self?.utilityWindow?.orderOut(nil)
      self?.shell?.open()
    }
    model.onSceneReady = { [weak self] in self?.showGeneratedExplanation() }
    model.isScenePresentationVisible = { [weak self] documentID in
      guard let self else { return false }
      return self.explanationOverlay?.isVisible(documentID: documentID) == true
        || self.notebookEditorCanvas()?.renderedDocumentID == documentID
    }
    installMenus()
    if CommandLine.arguments.contains("--keychain-acceptance") {
      let service = "org.opencompanion.acceptance.\(UUID().uuidString)"
      let credentials = CredentialStore()
      do {
        defer { try? credentials.delete(service: service, account: "fixture") }
        let value = Data("public acceptance fixture".utf8)
        try credentials.save(value, service: service, account: "fixture")
        guard try credentials.load(service: service, account: "fixture") == value else {
          throw ProviderError.message("Keychain roundtrip mismatch")
        }
        print("KEYCHAIN_ACCEPTANCE_PASSED")
      } catch {
        print("KEYCHAIN_ACCEPTANCE_FAILED: \(error.localizedDescription)")
        exit(1)
      }
      NSApp.terminate(nil)
      return
    }
    if CommandLine.arguments.contains("--smoke-test-codex") {
      Task {
        do {
          try await CodexIntegrationSmoke.run(
            executable: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
              ".local/bin/codex"
            ).path
          ) { text in
            try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
          }
          print("CODEX_ACCEPTANCE_PASSED")
        } catch {
          print("CODEX_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--guidance-routing-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count else {
            throw ProviderError.message(
              "Provide an output directory for guidance routing acceptance.")
          }
          try await GuidanceRoutingAcceptance.run(
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            executable: model.codexPath, model: model.codexModel)
          print("GUIDANCE_ROUTING_ACCEPTANCE_PASSED")
        } catch {
          print("GUIDANCE_ROUTING_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--spatial-scene-live-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count else {
            throw ProviderError.message("Provide an output directory for spatial scene acceptance.")
          }
          try await SpatialSceneLiveAcceptance.run(
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            executable: model.codexPath, model: model.codexModel)
          print("SPATIAL_SCENE_LIVE_ACCEPTANCE_PASSED")
        } catch {
          print("SPATIAL_SCENE_LIVE_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--explanation-orbit-live-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count else {
            throw ProviderError.message("Provide an output directory for live orbit acceptance.")
          }
          try await ExplanationOrbitLiveAcceptance.run(
            model: model, output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("EXPLANATION_ORBIT_LIVE_ACCEPTANCE_PASSED")
        } catch {
          print("EXPLANATION_ORBIT_LIVE_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--explanation-narration-acceptance") {
      Task {
        do {
          guard CommandLine.arguments.count > index + 1 else {
            throw ProviderError.message("Provide an output directory for narration acceptance.")
          }
          try await ExplanationNarrationAcceptance.run(
            model: model, output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("EXPLANATION_NARRATION_ACCEPTANCE_PASSED")
          NSApp.terminate(nil)
        } catch {
          print("EXPLANATION_NARRATION_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--explanation-overlay-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count else {
            throw ProviderError.message("Provide an output directory for explanation acceptance.")
          }
          let sceneURL =
            index + 2 < CommandLine.arguments.count
            ? URL(fileURLWithPath: CommandLine.arguments[index + 2]) : nil
          try await ExplanationOverlayAcceptance.run(
            model: model, output: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            documentURL: sceneURL)
          print("EXPLANATION_OVERLAY_ACCEPTANCE_PASSED")
        } catch {
          print("EXPLANATION_OVERLAY_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    shell = CompanionShell(
      model: model, observePointer: !acceptanceMode,
      onOpenWorkspace: { [weak self] in self?.openRequestedSurface() })
    model.onPrepareScreenGuidance = { [weak self] generation, expectedPID in
      try Task.checkCancellation()
      guard let self, let shell = self.shell, self.model.taskGeneration == generation else {
        throw CancellationError()
      }
      self.utilityWindow?.orderOut(nil)
      self.explanationPanel?.orderOut(nil)
      self.explanationOverlay?.dismiss()
      try await shell.prepareScreenGuidance(generation: generation, expectedPID: expectedPID)
    }
    model.onVoiceResponseSubmitted = { [weak self] source, destination in
      self?.shell?.handoffVoiceActivity(from: source, to: destination)
    }
    shell?.show(anchor: .notch)
    if !acceptanceMode || CommandLine.arguments.contains("--cursor-acceptance")
      || CommandLine.arguments.contains("--cursor-live-acceptance")
      || liveGuidanceAcceptance
    {
      cursor = CursorCompanionCoordinator(
        model: model, observePointer: !acceptanceMode,
        preferences: acceptanceMode ? CursorCompanionPreferences() : nil,
        exclusionFrames: { [weak self] in
          guard let geometry = self?.shell?.geometry else { return [] }
          return [geometry.frame]
        })
      model.onCursorInputStarted = { [weak self] generation in
        self?.cursor?.beginInput(generation: generation)
      }
      model.onCursorResponseStarted = { [weak self] generation, guidance in
        self?.rememberExplanationDisplay(generation: generation)
        self?.cursor?.beginResponse(generation: generation, isGuidance: guidance)
      }
      model.onCursorTextPreview = { [weak self] generation, preview in
        self?.cursor?.accept(preview, generation: generation) ?? true
      }
      model.onCursorTargetAccepted = { [weak self] generation, target, evidence in
        self?.cursor?.guide(target: target, evidence: evidence, generation: generation) ?? 0
      }
      model.onCursorCancelled = { [weak self] generation in
        self?.cursor?.cancel(generation: generation)
        self?.screenGuidance?.cancel()
      }
      model.onNarrationCaptionStarted = { [weak self] text, context, nativeSpeech in
        self?.cursor?.beginNarration(text: text, context: context, nativeSpeech: nativeSpeech)
          ?? false
      }
      model.onNarrationCaptionUpdate = { [weak self] update in self?.cursor?.updateNarration(update)
      }
      model.onNarrationCaptionFinished = { [weak self] context in
        self?.cursor?.finishNarration(context: context)
      }
      cursor?.onNarrationCaptionCompleted = { [weak self] context in
        self?.model.completeExplanationCaption(context: context)
      }
      cursor?.sceneNodeVisitBounds = { [weak self] authority in
        self?.explanationOverlay?.sceneNodeVisitBounds(authority: authority)
      }
      cursor?.onSceneNodeVisitEnded = { [weak self] authority, reason in
        if reason == .hostBoundsUnavailable {
          self?.explanationOverlay?.reconcileSceneFocus(authority: authority)
        }
      }
      model.onExplanationFocusStarted = { [weak self] context, presentation in
        self?.explanationOverlay?.beginSceneFocus(context: context, presentation: presentation)
      }
      model.onExplanationFocusEnded = { [weak self] context in
        self?.explanationOverlay?.endSceneFocus(context: context)
      }
    }
    if !acceptanceMode || liveGuidanceAcceptance {
      screenGuidance = ScreenGuidanceCoordinator(model: model)
      if let screenGuidance {
        manualGuidanceControls = ManualGuidanceControls(coordinator: screenGuidance, model: model)
      }
      model.onManualGuidanceVoiceStart = { [weak self] in
        self?.screenGuidance?.takeManualStepForVoice()
      }
      model.onScreenGuidanceTargetAccepted = { [weak self] target, evidence, generation, request in
        self?.screenGuidance?.accept(
          target: target, evidence: evidence,
          generation: generation, request: request)
      }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--guidance-live-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count, let cursor else {
            throw ProviderError.message("Provide an output directory for live guidance acceptance.")
          }
          try await ScreenGuidanceLiveAcceptance.run(
            model: model, cursor: cursor,
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("GUIDANCE_LIVE_ACCEPTANCE_PASSED")
        } catch {
          print("GUIDANCE_LIVE_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--guidance-manual-live-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count, let cursor else {
            throw ProviderError.message(
              "Provide an output directory for manual guidance acceptance.")
          }
          try await ManualGuidanceLiveAcceptance.run(
            model: model, cursor: cursor,
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("MANUAL_GUIDANCE_LIVE_ACCEPTANCE_PASSED")
        } catch {
          print("MANUAL_GUIDANCE_LIVE_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--cursor-live-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count, let cursor else {
            throw ProviderError.message("Provide an output directory for live cursor acceptance.")
          }
          try await CursorCompanionLiveAcceptance.run(
            cursor: cursor, model: model,
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("CURSOR_LIVE_ACCEPTANCE_PASSED")
        } catch {
          print("CURSOR_LIVE_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--cursor-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count, let cursor, let shell else {
            throw ProviderError.message("Provide an output directory for cursor acceptance.")
          }
          try await CursorCompanionAcceptance.run(
            cursor: cursor, shell: shell, model: model,
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("CURSOR_ACCEPTANCE_PASSED")
        } catch {
          print("CURSOR_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--interaction-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count, let shell else {
            throw ProviderError.message("Provide an output directory for interaction acceptance.")
          }
          try await NotchAcceptance.run(
            shell: shell, model: model,
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } catch {
          print("NOTCH_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if let index = CommandLine.arguments.firstIndex(of: "--capture-acceptance") {
      Task { @MainActor in
        do {
          guard index + 1 < CommandLine.arguments.count else {
            throw ProviderError.message(
              "Provide a private output directory for capture acceptance.")
          }
          try await CaptureAcceptance.run(
            output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
          print("CAPTURE_ACCEPTANCE_PASSED")
        } catch {
          print("CAPTURE_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    if !acceptanceMode {
      registerGlobalShortcuts()
      voiceShortcutSubscription = voiceShortcut.$availability.sink { [weak self] availability in
        MainActor.assumeIsolated {
          self?.model.voiceShortcutAvailable = availability.isInstalled
          self?.model.voiceShortcutStatus = availability.statusText
          if !availability.isInstalled { self?.model.cancelPushToTalk() }
        }
      }
      for notification in [
        NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
        NSWorkspace.sessionDidResignActiveNotification,
      ] {
        NSWorkspace.shared.notificationCenter.publisher(for: notification).sink { [weak self] _ in
          MainActor.assumeIsolated {
            self?.voiceShortcut.cancelActive(reason: .sessionInactive)
            self?.model.cancelPushToTalk()
          }
        }.store(in: &voiceLifecycleSubscriptions)
      }
      activationSubscription = NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
      )
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.voiceShortcut.isObservationInstalled else { return }
          self.registerVoiceShortcut()
        }
      }
      shortcutSubscription = NotificationCenter.default.publisher(
        for: .shortcutPreferencesDidChange
      )
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.registerGlobalShortcuts() }
      }
      stateSubscription = model.$busy.combineLatest(
        model.$listening, model.$state, model.$presentingExplanation
      ).sink {
        [weak self] busy, listening, state, presenting in
        MainActor.assumeIsolated {
          guard let self else { return }
          let active =
            busy || listening || presenting || state == "Speaking" || state == "Observing"
            || self.model.voice.hasPendingSpeech
          guard active != self.stopKeyRegistered else { return }
          self.stopKeyRegistered = active
          if active {
            let result = self.stopHotkey.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {
              [weak self] in
              self?.voiceShortcut.cancelActive(reason: .manualStop)
              self?.model.stop()
              self?.shell?.collapse()
            }
            if case .failure(let error) = result {
              self.model.notice =
                "Global Escape is unavailable. Use the Stop control. \(error.localizedDescription)"
            }
          } else {
            self.stopHotkey.unregister()
          }
        }
      }
      localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let consume = MainActor.assumeIsolated {
          guard let self else { return false }
          let companionFocused = event.window?.identifier?.rawValue == "org.opencompanion.resident"
          let active =
            self.model.busy || self.model.listening || self.model.presentingExplanation
            || self.model.state == "Speaking"
            || self.model.state == "Observing" || self.model.voice.hasPendingSpeech
          if event.keyCode == 53 && (companionFocused || active) {
            self.voiceShortcut.cancelActive(reason: .manualStop)
            self.model.stop()
            self.shell?.collapse()
            return true
          }
          return false
        }
        return consume ? nil : event
      }
    }
    if CommandLine.arguments.contains("--render-acceptance") {
      Task { @MainActor in
        do {
          let path =
            CommandLine.arguments.drop(while: { $0 != "--render-acceptance" }).dropFirst().first
            ?? "/tmp/OpenCompanion-Acceptance"
          let output = URL(fileURLWithPath: path)
          try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
          try? await Task.sleep(for: .milliseconds(400))
          try shell?.exportSnapshot(to: output.appendingPathComponent("notch-collapsed.png"))
          if let geometry = shell?.geometry {
            try JSONEncoder().encode(geometry).write(
              to: output.appendingPathComponent("notch-geometry.json"))
          }
          shell?.toggle()
          try? await Task.sleep(for: .milliseconds(500))
          try shell?.exportSnapshot(to: output.appendingPathComponent("notch-expanded.png"))
          shell?.collapse()
          showWorkspace()
          model.sample("motor")
          try? await Task.sleep(for: .milliseconds(500))
          try RenderAcceptance.run()
          print("RENDER_ACCEPTANCE_PASSED")
        } catch {
          print("RENDER_ACCEPTANCE_FAILED: \(error)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
    }
  }

  private func registerGlobalShortcuts() {
    let preferences = ShortcutPreferences.load()
    var failures: [String] = []
    if case .failure(let error) = hotkey.register(
      keyCode: preferences.openShortcut.key.keyCode,
      modifiers: preferences.openShortcut.modifiers.carbonMask,
      action: { [weak self] in
        self?.model.record("hotkey.keyDown")
        self?.shell?.toggle()
        self?.model.record("hotkey.companionRequested")
      })
    {
      failures.append("Open companion: \(error.localizedDescription)")
    }
    if preferences.captureEnabled {
      if case .failure(let error) = captureHotkey.register(
        keyCode: preferences.captureShortcut.key.keyCode,
        modifiers: preferences.captureShortcut.modifiers.carbonMask,
        action: { [weak self] in self?.shell?.captureSelectedDisplay() })
      {
        failures.append("Capture screen: \(error.localizedDescription)")
      }
    } else {
      captureHotkey.unregister()
    }
    registerVoiceShortcut()
    if !failures.isEmpty { model.notice = failures.joined(separator: "\n") }
  }

  private func registerVoiceShortcut() {
    voiceShortcut.start(
      enabled: ShortcutPreferences.load().voiceHoldEnabled,
      onPressed: { [weak self] in
        guard let self else { return }
        self.voiceShortcut.logDiagnostics(reason: "hold-pressed")
        self.model.beginPushToTalk()
        self.voiceHoldGeneration = self.model.taskGeneration
        self.shell?.showVoiceActivity()
      },
      onReleased: { [weak self] in
        guard let self else { return }
        self.voiceShortcut.logDiagnostics(reason: "hold-released")
        let generation = self.voiceHoldGeneration
        self.voiceHoldGeneration = nil
        guard generation == self.model.taskGeneration else { return }
        self.model.endPushToTalk()
      },
      onCancelled: { [weak self] _ in
        guard let self else { return }
        self.voiceShortcut.logDiagnostics(reason: "hold-cancelled")
        let generation = self.voiceHoldGeneration
        self.voiceHoldGeneration = nil
        guard generation == self.model.taskGeneration else { return }
        self.model.stop()
      })
    voiceShortcut.logDiagnostics(reason: "registration")
  }

  private func installMenus() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: "Open companion", action: #selector(toggleCompanion), keyEquivalent: ""
    ).target = self
    appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
      .target = self
    appMenu.addItem(withTitle: "New chat", action: #selector(newChat), keyEquivalent: "n")
      .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit OpenCompanion", action: #selector(quit), keyEquivalent: "q")
      .target = self
    let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    main.addItem(edit)
    let editMenu = NSMenu(title: "Edit")
    edit.submenu = editMenu
    for (title, action, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
    NSApp.mainMenu = main
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    status.button?.image = NSImage(
      systemSymbolName: "sparkle", accessibilityDescription: "OpenCompanion")
    let menu = NSMenu()
    menu.addItem(withTitle: "Open companion", action: #selector(toggleCompanion), keyEquivalent: "")
      .target = self
    menu.addItem(
      withTitle: "Notebook & library", action: #selector(openWorkspace), keyEquivalent: ""
    ).target = self
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "").target = self
    status.menu = menu
    statusItem = status
  }

  private func openRequestedSurface() {
    if model.section == "Notebook" {
      model.endExplanationPlaybackForEditing()
      showExplanation(focus: true)
    } else {
      showWorkspace()
    }
  }

  private func rememberExplanationDisplay(generation: UInt64) {
    guard explanationRequestDisplay?.generation != generation,
      let screen = currentExplanationDisplay(),
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else { return }
    explanationRequestDisplay = (generation, displayID.uint32Value)
  }

  private func currentExplanationDisplay() -> NSScreen? {
    NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main ?? NSScreen.screens.first
  }

  private func showGeneratedExplanation() {
    guard let document = model.explanationDisplayDocument else { return }
    // An explicitly opened editor keeps its editing surface during same-doc
    // revisions. A newly generated document uses the passive presentation.
    if notebookEditorCanvas()?.renderedDocumentID == document.id { return }
    unmountNotebookEditor()
    let screen: NSScreen?
    if let binding = explanationRequestDisplay, binding.generation == model.taskGeneration {
      screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == binding.displayID
      }
    } else {
      screen = currentExplanationDisplay()
    }
    guard let screen else { return }
    if explanationOverlay == nil {
      explanationOverlay = ExplanationOverlay(model: model) { [weak self] in self?.model.stop() }
      explanationOverlay?.onSceneFocusPoint = { [weak self] authority, point in
        _ = self?.cursor?.visitSceneNode(authority: authority, point: point)
      }
      explanationOverlay?.onSceneFocusEnded = { [weak self] authority in
        self?.cursor?.cancelSceneNodeVisit(authority: authority)
      }
    }
    explanationOverlay?.show(document: document, on: screen)
  }

  private func unmountNotebookEditor() {
    explanationPanel?.orderOut(nil)
    explanationPanel?.contentView = nil
  }

  private func notebookEditorCanvas() -> RetainedCanvasView? {
    guard let panel = explanationPanel, panel.isVisible, let root = panel.contentView else {
      return nil
    }
    var remaining = [root]
    var visited = 0
    while let view = remaining.popLast(), visited < 512 {
      visited += 1
      guard !view.isHiddenOrHasHiddenAncestor else { continue }
      if let canvas = view as? RetainedCanvasView, canvas.window === panel { return canvas }
      remaining.append(contentsOf: view.subviews)
    }
    return nil
  }

  private func showExplanation(focus: Bool) {
    model.endExplanationPlaybackForEditing()
    explanationOverlay?.dismiss()
    if explanationPanel == nil {
      let display = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
      let panel = ExplanationPanel(
        contentRect: CGRect(
          x: 0, y: 0, width: min(980, display.width - 40), height: min(740, display.height - 40)),
        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered,
        defer: false)
      panel.title = "OpenCompanion Notebook"
      panel.isReleasedWhenClosed = false
      panel.minSize = CGSize(width: 760, height: 580)
      panel.collectionBehavior = [.fullScreenAuxiliary]
      panel.sharingType = .none
      panel.center()
      explanationPanel = panel
    }
    if explanationPanel?.contentView == nil {
      explanationPanel?.contentView = NSHostingView(
        rootView: WorkspaceView(model: model, notebookOnly: true).preferredColorScheme(.dark))
    }
    if focus {
      NSApp.activate(ignoringOtherApps: true)
      explanationPanel?.makeKeyAndOrderFront(nil)
    } else if explanationPanel?.isVisible != true {
      explanationPanel?.orderFrontRegardless()
    }
  }
  func showWorkspace() {
    if utilityWindow == nil {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1220, height: 820),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "OpenCompanion"
      window.titlebarAppearsTransparent = true
      window.backgroundColor = NSColor(white: 0.075, alpha: 1)
      window.isReleasedWhenClosed = false
      window.minSize = CGSize(width: 1000, height: 680)
      window.contentView = NSHostingView(
        rootView: WorkspaceView(model: model).preferredColorScheme(.dark))
      window.center()
      utilityWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    utilityWindow?.makeKeyAndOrderFront(nil)
  }
  @objc private func toggleCompanion() { shell?.toggle() }
  @objc private func openWorkspace() { showWorkspace() }
  @objc private func openSettings() {
    shell?.openSettings()
  }
  @objc private func newChat() {
    model.newConversation()
    shell?.navigate(to: .chat)
  }
  @objc private func stop() {
    voiceShortcut.cancelActive(reason: .manualStop)
    model.stop()
  }
  @objc private func quit() { NSApp.terminate(nil) }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    shell?.toggle()
    return false
  }
  func applicationWillTerminate(_ notification: Notification) {
    voiceShortcut.stop()
    cursor?.shutdown()
    screenGuidance?.shutdown()
    manualGuidanceControls?.shutdown()
    explanationOverlay?.shutdown()
    shell?.shutdown()
    model.stop()
    model.runner.stop()
    model.browser.stop()
    hotkey.unregister()
    captureHotkey.unregister()
    stopHotkey.unregister()
    if let localKeys { NSEvent.removeMonitor(localKeys) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private final class ExplanationPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func close() {
    contentView = nil
    super.close()
  }
}
