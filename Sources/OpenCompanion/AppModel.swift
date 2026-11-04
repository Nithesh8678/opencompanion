import AppKit
import Combine
import CompanionCore
import CompanionStore
import SwiftUI

/// The host advances this binding only after a successful scene transaction.
/// Revisions are meaningful only inside the same retained document identity.
struct NotebookTurnBinding: Sendable, Equatable {
  let documentID: String?
  let revision: Int?

  func checkedBase(currentID: String?, currentRevision: Int?, proposedBase: Int?) throws -> Int {
    guard documentID == currentID, revision == currentRevision else {
      throw ProviderError.message(
        "The notebook changed while this response was being prepared. Your edits were kept; ask again to edit the current document."
      )
    }
    let base = revision ?? 0
    guard proposedBase == nil || proposedBase == base else {
      throw ProviderError.message(
        "The response used an outdated notebook revision. Your edits were kept.")
    }
    return base
  }
}

enum CapturePickerHost: Sendable, Equatable { case notch, workspace }

private enum GuidanceTurnStage: String { case prepare, capture, provider, target }

/// The actual selected-evidence payload for a turn. Manual capture provenance
/// authorizes retaining a typed attachment's scope; an automatic frame cannot
/// inherit that authority merely by remaining visible in the conversation.
struct ResponseInputPlan: Sendable {
  let requiresFreshGuidanceCapture: Bool
  let context: String
  let image: Data?
  let evidenceIdentity: ScreenEvidenceIdentity?

  static func resolve(
    policy: ResponsePolicy, voiceOnly: Bool, selectedContext: String,
    evidence: ScreenEvidence?, explicitManualEvidence: ScreenEvidenceIdentity?
  ) -> Self {
    if policy.route == .screenGuidance {
      if !voiceOnly, let evidence, explicitManualEvidence?.matches(evidence) == true {
        return .init(
          requiresFreshGuidanceCapture: false, context: evidence.semanticText,
          image: evidence.image, evidenceIdentity: ScreenEvidenceIdentity(evidence))
      }
      return .init(
        requiresFreshGuidanceCapture: true, context: "", image: nil, evidenceIdentity: nil)
    }
    if voiceOnly {
      return .init(
        requiresFreshGuidanceCapture: false, context: "", image: nil, evidenceIdentity: nil)
    }
    let selectedFrame = evidence.flatMap { frame in
      explicitManualEvidence?.matches(frame) == true ? frame : nil
    }
    return .init(
      requiresFreshGuidanceCapture: false,
      context: selectedContext + (selectedFrame?.semanticText ?? ""), image: selectedFrame?.image,
      evidenceIdentity: selectedFrame.map(ScreenEvidenceIdentity.init))
  }
}

@MainActor final class AppModel: ObservableObject {
  @Published var section = "Companion"
  @Published var input = ""
  @Published var messages: [ChatLine] = []
  @Published var state = "Ready"
  @Published var error: String?
  @Published var notice: String?
  @Published var busy = false
  @Published var listening = false
  @Published var pushToTalkActive = false
  @Published var voiceInputState = "Ready"
  @Published var voiceShortcutAvailable = false
  @Published var voiceShortcutStatus = "Control+Option shortcut is not registered."
  @Published var voiceTranscript = ""
  @Published var voiceNotice: String?
  @Published private(set) var microphoneLevel: Double = 0
  @Published var configuration = ProviderConfiguration.load()
  @Published var providerMode =
    UserDefaults.standard.string(forKey: "providerMode") ?? "ChatGPT via Codex"
  @Published var codexPath =
    UserDefaults.standard.string(forKey: "codexPath")
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")
    .path
  @Published var codexModel = UserDefaults.standard.string(forKey: "codexModel") ?? ""
  @Published var guidanceModelPreference =
    GuidanceModelPreference(rawValue: UserDefaults.standard.string(forKey: "guidanceModel") ?? "")
    ?? .terra
  @Published private(set) var guidanceProviderStatus = "Terra for screen guidance"
  @Published var apiKey = ""
  @Published var scene: SceneDocument?
  @Published var selectedNodeID: String?
  @Published var playing = true
  @Published var playTime = 0.0
  @Published var seekRevision = 0
  @Published var drawing = false
  @Published var speed = 1.0
  @Published var records: [StoredRecord] = []
  @Published var jobs: [DurableJob] = []
  @Published var search = ""
  @Published var selectedContext = ""
  @Published var contextTitle = ""
  @Published var evidence: ScreenEvidence?
  @Published var captureWindows: [CaptureWindow] = []
  @Published var showingWindowPicker = false
  @Published var windowPickerHost: CapturePickerHost = .workspace
  var lastExternalPID: pid_t = 0
  private var workspaceObserver: NSObjectProtocol?
  private var displaySubscription: AnyCancellable?
  @Published var selectedDisplay: CGDirectDisplayID?
  @Published var memoryTitle = ""
  @Published var memoryBody = ""
  @Published var connectionStatus = "Not tested"
  let spatialSelector = SpatialContextSelector()
  let runner = JobRunner()
  let browser = BrowserBridge()
  let voice = VoiceService()
  let overlay = OverlayHost()
  let capture = CaptureService()
  let provider = ReasoningProvider()
  var codex: CodexProvider?
  let credentials = CredentialStore()
  private(set) var store: LocalStore?
  private var turn: Task<Void, Never>?
  private var voiceStartTask: Task<Void, Never>?
  private var voiceSessionID: UUID?
  private var voiceMode: VoiceInputMode?
  private var voiceDraftGuard: VoiceDraftGuard?
  private var turnSpeaksAloud = false
  private var generation: UInt64 = 0
  var taskGeneration: UInt64 { generation }
  /// Only a successfully recognized held utterance transfers compact HUD ownership.
  var onVoiceResponseSubmitted: ((UInt64, UInt64) -> Void)?
  var onCursorInputStarted: ((UInt64) -> Void)?
  var onCursorResponseStarted: ((UInt64, Bool) -> Void)?
  var onCursorTextPreview: ((UInt64, ProviderTextPreview) -> Bool)?
  var onCursorTargetAccepted: ((UInt64, ProviderTarget, ScreenEvidence) -> TimeInterval)?
  var onScreenGuidanceTargetAccepted:
    ((ProviderTarget, ScreenEvidence, UInt64, ScreenGuidanceRequest) -> Void)?
  var onCursorCancelled: ((UInt64) -> Void)?
  var onPrepareScreenGuidance: ((UInt64, pid_t) async throws -> Void)?
  private(set) var responsePolicy = ResponsePolicy.resolve(text: "", screenGuidanceEnabled: false)
  private var outputSceneIncludesExistingNotebook = false
  private var acceptedGuidanceTarget = false
  private var guidanceNarration: String?
  private var narrationGate = TurnNarrationGate()
  private var guidanceTurnStage: GuidanceTurnStage?
  private(set) var cursorFailureGeneration: UInt64?
  private var activeGuidanceRequest: ScreenGuidanceRequest?
  private var receivedTextPreview = false
  var capturePublicationRevision: UInt64 { captureGate.generation }
  var captureResultID: UUID? { evidence?.frameID }
  private var scenePresentedForTurn = false
  private var outputSceneBinding: NotebookTurnBinding?
  private var captureTask: Task<Void, Never>?
  private var windowPickerTask: Task<Void, Never>?
  private var windowPickerRequestID: UUID?
  private var captureGate = CapturePublicationGate()
  /// Assigned only by successful explicit captures. Cancelling pending work
  /// does not remove the scope of an attachment that is still selected.
  private var explicitManualEvidence: ScreenEvidenceIdentity?
  private var undoStack: [SceneDocument] = []
  private var redoStack: [SceneDocument] = []
  private var timer: Timer?
  private var lastTick = ProcessInfo.processInfo.systemUptime
  private var badge: NSPanel?
  var onOpen: (() -> Void)?
  var onCompanionRequested: (() -> Void)?
  var onSceneReady: (() -> Void)?
  private var trace: [[String: String]] = []
  init(acceptanceMode: Bool = false) {
    if !acceptanceMode {
      do {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
          0
        ]
        .appendingPathComponent("OpenCompanion", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store = try LocalStore(url: url.appendingPathComponent("library.sqlite"))
      } catch { self.error = "Local library could not open: \(error.localizedDescription)" }
      apiKey =
        (try? credentials.load(
          service: "org.opencompanion.provider", account: configuration.endpoint))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    voice.onState = { [weak self] state in
      guard let self else { return }
      if !self.listening {
        self.state = state == "Ready" && self.busy ? "Thinking" : state
        self.updateBadge()
      }
    }
    voice.onInputState = { [weak self] snapshot in self?.acceptVoiceState(snapshot) }
    voice.onInputLevel = { [weak self] id, level in
      guard let self, self.voiceSessionID == id else { return }
      let value =
        self.voiceInputState == VoiceInputPhase.listening.label && level.isFinite
        ? min(1, max(0, level)) : 0
      if self.microphoneLevel != value { self.microphoneLevel = value }
    }
    voice.onTranscript = { [weak self] id, mode, text, _ in
      self?.acceptVoiceTranscript(id: id, mode: mode, text: text)
    }
    voice.onInputCompletion = { [weak self] completion in self?.completeVoiceInput(completion) }
    voice.onInputError = { [weak self] id, error in
      guard let self, self.voiceSessionID == id else { return }
      self.voiceSessionID = nil
      self.voiceMode = nil
      self.listening = false
      self.pushToTalkActive = false
      self.microphoneLevel = 0
      self.showError(error)
      self.state = "Ready"
      self.updateBadge()
    }
    voice.onInputNotice = { [weak self] id, notice in
      guard let self, self.voiceSessionID == id else { return }
      self.notice = notice
      self.voiceNotice = notice
    }
    voice.onSpeechEvent = { [weak self] event in self?.record(event) }
    if !acceptanceMode {
      lastExternalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
      workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let pid =
          (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        Task { @MainActor [weak self] in
          guard let self, let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
          self.lastExternalPID = pid
          self.overlay.clear()
        }
      }
    }
    displaySubscription = NotificationCenter.default.publisher(
      for: NSApplication.didChangeScreenParametersNotification
    ).sink { [weak self] _ in
      MainActor.assumeIsolated { self?.invalidateScreenEvidence() }
    }
    if !acceptanceMode {
      Task {
        await reload()
        startJobs()
      }
    }
  }
  func record(_ event: String) {
    trace.append([
      "event": event, "time": String(ProcessInfo.processInfo.systemUptime),
      "generation": String(generation),
    ])
    if trace.count > 10000 { trace.removeFirst(1000) }
  }
  var diagnosticEvents: [[String: String]] { trace }
  func showError(_ error: Error) { self.error = error.localizedDescription }
  func reload() async {
    guard let store else { return }
    do {
      records = try await store.records(query: search)
      jobs = try await store.jobs()
    } catch { showError(error) }
  }
  func saveSettings() {
    do {
      configuration.save()
      UserDefaults.standard.set(providerMode, forKey: "providerMode")
      UserDefaults.standard.set(codexPath, forKey: "codexPath")
      UserDefaults.standard.set(codexModel, forKey: "codexModel")
      UserDefaults.standard.set(guidanceModelPreference.rawValue, forKey: "guidanceModel")
      if apiKey.isEmpty {
        try credentials.delete(
          service: "org.opencompanion.provider", account: configuration.endpoint)
      } else {
        try credentials.save(
          Data(apiKey.utf8), service: "org.opencompanion.provider", account: configuration.endpoint)
      }
      notice = "Settings saved. Credentials are stored in Keychain."
    } catch { showError(error) }
  }
  func testConnection() {
    saveSettings()
    connectionStatus = "Testing a live request…"
    Task {
      do {
        if providerMode == "ChatGPT via Codex" {
          let adapter = CodexProvider()
          codex = adapter
          let received = ReceiptFlag()
          try await adapter.stream(
            executable: codexPath, model: codexModel,
            messages: [
              ChatLine(
                role: "user",
                text: "Reply using one JSON line: {\"type\":\"text\",\"text\":\"Ready\"}")
            ], context: "", image: nil, scene: nil
          ) { _ in await received.mark() }
          connectionStatus =
            await received.value ? "Live ChatGPT-plan request completed." : "No accepted content."
        } else {
          connectionStatus = try await provider.test(configuration: configuration, key: apiKey)
        }
      } catch { connectionStatus = error.localizedDescription }
    }
  }
  private var notebookContextIsVisible: Bool {
    guard section == "Notebook" else { return false }
    return NSApp?.windows.contains {
      $0.isVisible && ($0.title == "OpenCompanion Notebook" || $0.title == "OpenCompanion")
    } ?? false
  }

  func send() { send(textOverride: nil, voiceOnly: false, speakAloud: false) }
  private func send(
    textOverride: String?, voiceOnly: Bool, speakAloud: Bool,
    guidanceRequest: ScreenGuidanceRequest? = nil,
    expectedGuidanceForegroundPID: pid_t? = nil
  ) {
    let text = (textOverride ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let policy = ResponsePolicy.resolve(
      text: text, screenGuidanceEnabled: CursorCompanionPreferences.load().screenGuidanceEnabled,
      explicitGuidance: guidanceRequest != nil, inNotebook: notebookContextIsVisible,
      hasNotebook: scene != nil)
    let inputPlan = ResponseInputPlan.resolve(
      policy: policy, voiceOnly: voiceOnly, selectedContext: selectedContext, evidence: evidence,
      explicitManualEvidence: explicitManualEvidence)
    // Preserve only explicitly selected capture scope. A prior automatic
    // guidance image is not a user-selected attachment for a later question.
    let automaticGuidance =
      inputPlan.requiresFreshGuidanceCapture
      ? guidanceRequest ?? ScreenGuidanceRequest(prompt: text, speakAloud: speakAloud) : nil
    let previousGuidanceInstruction =
      (guidanceRequest?.step ?? 0) > 0
      ? messages.last(where: { $0.role == "assistant" }).map { String($0.text.prefix(800)) } : nil
    let sourceGeneration = generation
    stop()
    if textOverride == nil { input = "" }
    turnSpeaksAloud = speakAloud
    voiceNotice = nil
    error = nil
    generation += 1
    let current = generation
    activeGuidanceRequest = automaticGuidance
    configureResponseOutput(policy)
    record("response.route.\(policy.route.rawValue)")
    acceptedGuidanceTarget = false
    guidanceNarration = nil
    let captureToken = captureGate.generation
    scenePresentedForTurn = false
    busy = true
    state = "Thinking"
    receivedTextPreview = false
    onCursorResponseStarted?(current, policy.route == .screenGuidance)
    if voiceOnly { onVoiceResponseSubmitted?(sourceGeneration, current) }
    updateBadge()
    record("turn.declaredEnd.textSubmit")
    messages.append(ChatLine(role: "user", text: text))
    // Guidance needs the current goal and preceding step, rather than unrelated
    // lesson/chat history that increases both latency and evidence ambiguity.
    let history: [ChatLine]
    if policy.route == .screenGuidance {
      history =
        (previousGuidanceInstruction.map { [ChatLine(role: "assistant", text: $0)] } ?? [])
        + [ChatLine(role: "user", text: text)]
    } else {
      history = messages
    }
    let activeScene = policy.includesExistingNotebook ? scene : nil
    let config = configuration
    let key = apiKey
    let guidanceModel = guidanceModelPreference
    turn = Task { [weak self] in
      guard let self else { return }
      do {
        let turnContext: String
        let turnImage: Data?
        let turnEvidence: ScreenEvidenceIdentity?
        if let automaticGuidance {
          let frame = try await self.captureGuidanceEvidence(
            request: automaticGuidance, generation: current, captureToken: captureToken,
            expectedForegroundPID: expectedGuidanceForegroundPID)
          turnContext = frame.semanticText
          turnImage = frame.image
          turnEvidence = ScreenEvidenceIdentity(frame)
        } else {
          if policy.route == .screenGuidance, let selectedFrame = inputPlan.evidenceIdentity {
            try await self.prepareSelectedGuidanceEvidence(
              selectedFrame, generation: current, captureToken: captureToken)
          }
          turnContext = inputPlan.context
          turnImage = inputPlan.image
          turnEvidence = inputPlan.evidenceIdentity
        }
        try Task.checkCancellation()
        guard current == self.generation else { throw CancellationError() }
        let guidanceBinding: ScreenGuidanceTurnBinding?
        if policy.route == .screenGuidance, let frame = self.evidence,
          turnEvidence?.matches(frame) == true
        {
          guidanceBinding = ScreenGuidanceTurnBinding(source: frame)
        } else {
          guidanceBinding = nil
        }
        let handler: @Sendable (ProviderUnit) async throws -> Void = { [weak self] unit in
          try Task.checkCancellation()
          try await self?.acceptProviderUnit(
            unit, generation: current, expectedEvidence: turnEvidence,
            guidanceBinding: guidanceBinding, captureToken: captureToken)
        }
        let preview: @Sendable (ProviderTextPreview) async throws -> Void = { [weak self] value in
          try Task.checkCancellation()
          try await self?.acceptTextPreview(value, generation: current)
        }
        self.setGuidanceStage(.provider, generation: current)
        if self.providerMode == "ChatGPT via Codex" {
          let adapter = CodexProvider()
          self.codex = adapter
          try await adapter.stream(
            executable: self.codexPath, model: self.codexModel, messages: history,
            context: turnContext,
            image: turnImage, scene: activeScene, guidanceModel: guidanceModel,
            onRouting: { [weak self] selection in
              await self?.acceptModelRouting(selection, generation: current, policy: policy)
            }, onUnit: handler, onText: preview,
            responsePolicy: policy)
        } else {
          try await self.provider.stream(
            configuration: config, key: key, messages: history, context: turnContext,
            image: turnImage,
            scene: activeScene, onUnit: handler, onText: preview, responsePolicy: policy)
        }
        guard current == self.generation else { return }
        self.record("generation.completed")
        if policy.route == .screenGuidance, !self.acceptedGuidanceTarget,
          let explanation = self.guidanceNarration
        {
          // If the screen is ambiguous or the task is complete, keep the model's
          // clarification visible. Successful guidance owns fixed target labels.
          self.onCursorResponseStarted?(current, false)
          _ = self.onCursorTextPreview?(
            current, ProviderTextPreview(unitID: 0, text: explanation, isComplete: true))
        }
        self.busy = false
        if self.state != "Speaking" { self.state = "Ready" }
        self.updateBadge()
        await self.persistConversation()
      } catch {
        self.finishTurnFailure(error: error, generation: current, policy: policy)
      }
    }
  }

  private func acceptModelRouting(
    _ selection: CodexRoutingSelection, generation: UInt64, policy: ResponsePolicy
  ) {
    guard generation == self.generation, policy.route == .screenGuidance else { return }
    let modelName = String(selection.model.prefix(120))
    guidanceProviderStatus = "\(modelName) · \(selection.effort ?? "default") effort"
    record("guidance.model.\(selection.reason.rawValue)")
    if selection.reason == .terraUnavailableFallback {
      notice =
        "Terra is unavailable for images in this account. Using \(modelName) for this request."
    }
  }

  /// Slow model output may only advance after one real, same-scope capture
  /// corroborates the old target. Never extend the original frame's timestamp.
  private func acceptProviderUnit(
    _ unit: ProviderUnit, generation: UInt64, expectedEvidence: ScreenEvidenceIdentity?,
    guidanceBinding: ScreenGuidanceTurnBinding?, captureToken: UInt64
  ) async throws {
    guard unit.type == "target", responsePolicy.route == .screenGuidance,
      let binding = guidanceBinding, let payload = unit.target
    else {
      try accept(unit, generation: generation, expectedEvidence: expectedEvidence)
      return
    }
    setGuidanceStage(.target, generation: generation)
    let previous = ScreenEvidenceIdentity(binding.current)
    let request = activeGuidanceRequest
    let stillOwned: @MainActor @Sendable () -> Bool = { [weak self] in
      guard let self else { return false }
      return generation == self.generation
        && self.captureGate.permits(captureToken, cancelled: Task.isCancelled)
        && previous.matches(self.evidence) && self.activeGuidanceRequest == request
        && CursorCompanionPreferences.load().screenGuidanceEnabled
        && (request.map { ProcessInfo.processInfo.systemUptime < $0.expires } ?? true)
    }
    guard stillOwned() else { throw CancellationError() }
    try requireGuidanceForeground(binding.source.foregroundPID)
    let prepared = try await binding.prepare(
      payload,
      refresh: {
        guard stillOwned() else { throw CancellationError() }
        self.record("guidance.lateTarget.refresh.started")
        return try await self.refreshGuidanceEvidence(binding.source)
      }, stillOwned: stillOwned)
    guard stillOwned() else { throw CancellationError() }
    try requireGuidanceForeground(binding.source.foregroundPID)
    if previous != ScreenEvidenceIdentity(binding.current) {
      evidence = binding.current
      if explicitManualEvidence == previous {
        explicitManualEvidence = ScreenEvidenceIdentity(binding.current)
      }
      record("guidance.lateTarget.refresh.verified")
    }
    var resolvedUnit = unit
    resolvedUnit.target = prepared
    try accept(
      resolvedUnit, generation: generation,
      expectedEvidence: ScreenEvidenceIdentity(binding.current))
  }

  private func refreshGuidanceEvidence(_ source: ScreenEvidence) async throws -> ScreenEvidence {
    try Task.checkCancellation()
    try requireGuidanceForeground(source.foregroundPID)
    let screens = Dictionary(
      uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
        guard
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { return nil }
        return (number.uint32Value, screen.frame)
      })
    guard let display = screens[source.displayID], display.contains(source.screenRect) else {
      throw ProviderError.message("The selected screen changed. Ask for screen guidance again.")
    }
    // Exact original display/window/crop, regardless of the pointer's new display.
    // A region limits the recapture and omits application-wide AX enrichment.
    let fresh = try await capture.capture(
      displayID: source.displayID, foregroundPID: source.foregroundPID,
      foregroundName: source.foregroundName, region: source.screenRect,
      windowID: source.windowID, screens: screens)
    try Task.checkCancellation()
    try requireGuidanceForeground(source.foregroundPID)
    return fresh
  }

  private func requireGuidanceForeground(_ pid: pid_t) throws {
    guard pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
      throw ProviderError.message("The active app changed. Ask for screen guidance again.")
    }
  }

  /// Declare output ownership once for the current turn, independent of any
  /// retained document or previously selected sidebar destination.
  func configureResponseOutput(_ policy: ResponsePolicy) {
    responsePolicy = policy
    cursorFailureGeneration = nil
    guidanceTurnStage = nil
    setGuidanceStage(.prepare, generation: generation)
    outputSceneIncludesExistingNotebook = policy.includesExistingNotebook
    outputSceneBinding =
      policy.allowsNotebook
      ? NotebookTurnBinding(documentID: scene?.id, revision: scene?.revision) : nil
    scenePresentedForTurn = false
  }

  /// Keep a current guidance failure readable without turning it into chat,
  /// speech, notebook content, or a retry. Stale work cannot alter a newer turn.
  func finishTurnFailure(error: Error, generation: UInt64, policy: ResponsePolicy) {
    guard generation == self.generation else { return }
    activeGuidanceRequest = nil
    busy = false
    state = "Ready"
    updateBadge()
    let cancelled = error is CancellationError
    let showGuidanceFailure = policy.route == .screenGuidance && !cancelled
    cursorFailureGeneration = showGuidanceFailure ? generation : nil
    if !cancelled { showError(error) }
    if showGuidanceFailure {
      record("guidance.failed.\((guidanceTurnStage ?? .prepare).rawValue)")
    }
    guidanceTurnStage = nil
    record(cancelled ? "turn.cancelled" : "turn.failed")
    if showGuidanceFailure {
      onCursorResponseStarted?(generation, false)
      guard generation == self.generation, cursorFailureGeneration == generation else { return }
      _ = onCursorTextPreview?(
        generation,
        ProviderTextPreview(
          unitID: 0, text: Self.guidanceFailureText(error.localizedDescription), isComplete: true))
    } else {
      onCursorCancelled?(generation)
    }
  }

  private func setGuidanceStage(_ stage: GuidanceTurnStage, generation: UInt64) {
    guard generation == self.generation, responsePolicy.route == .screenGuidance else { return }
    guidanceTurnStage = stage
    record("guidance.stage.\(stage.rawValue)")
  }

  private static func guidanceFailureText(_ message: String) -> String {
    let fallback = "Screen guidance could not continue. Try again."
    let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = ""
    var count = 0
    var bytes = 0
    for character in message {
      let part = String(character)
      guard count < 240, bytes + part.utf8.count <= 1_021 else {
        return result.isEmpty ? fallback : result + "…"
      }
      result.append(character)
      count += 1
      bytes += part.utf8.count
    }
    return result.isEmpty ? fallback : result
  }

  /// Restore only the application of a deliberately selected capture. Preparing
  /// its presentation never replaces a window or region with a broader frame.
  private func prepareSelectedGuidanceEvidence(
    _ selectedFrame: ScreenEvidenceIdentity, generation: UInt64, captureToken: UInt64
  ) async throws {
    try Task.checkCancellation()
    guard generation == self.generation,
      captureGate.permits(captureToken, cancelled: Task.isCancelled),
      explicitManualEvidence == selectedFrame, selectedFrame.matches(evidence),
      CursorCompanionPreferences.load().screenGuidanceEnabled
    else { throw CancellationError() }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    if let prepare = onPrepareScreenGuidance {
      try await prepare(generation, selectedFrame.foregroundPID)
    } else if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
      throw ProviderError.message("Switch to the app you want help with, then ask again.")
    }
    try Task.checkCancellation()
    guard generation == self.generation,
      captureGate.permits(captureToken, cancelled: Task.isCancelled),
      explicitManualEvidence == selectedFrame, selectedFrame.matches(evidence),
      CursorCompanionPreferences.load().screenGuidanceEnabled
    else { throw CancellationError() }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == selectedFrame.foregroundPID
    else {
      throw ProviderError.message("The active app changed. Ask for screen guidance again.")
    }
  }

  /// Capture only the current active screen for this explicit guidance turn.
  /// Selected file/memory context stays in the UI and is never part of this payload.
  private func captureGuidanceEvidence(
    request: ScreenGuidanceRequest, generation: UInt64, captureToken: UInt64,
    expectedForegroundPID: pid_t?
  ) async throws -> ScreenEvidence {
    try Task.checkCancellation()
    guard generation == self.generation, activeGuidanceRequest == request,
      request.expires.isFinite, ProcessInfo.processInfo.systemUptime < request.expires,
      CursorCompanionPreferences.load().screenGuidanceEnabled,
      captureGate.permits(captureToken, cancelled: Task.isCancelled)
    else { throw CancellationError() }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let initialForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if let expectedForegroundPID, initialForeground != expectedForegroundPID {
      throw ProviderError.message("The active app changed. Ask for screen guidance again.")
    }
    let intendedPID = initialForeground == ownPID ? lastExternalPID : (initialForeground ?? 0)
    if let prepare = onPrepareScreenGuidance, intendedPID > 0, intendedPID != ownPID {
      try await prepare(generation, intendedPID)
      try Task.checkCancellation()
      guard generation == self.generation, activeGuidanceRequest == request,
        captureGate.permits(captureToken, cancelled: Task.isCancelled)
      else { throw CancellationError() }
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == intendedPID else {
        throw ProviderError.message("The active app changed. Ask for screen guidance again.")
      }
    } else if initialForeground == ownPID {
      throw ProviderError.message("Switch to the app you want help with, then ask again.")
    }
    let screens = Dictionary(
      uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
        guard
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { return nil }
        return (number.uint32Value, screen.frame)
      })
    let pointer = NSEvent.mouseLocation
    guard
      let displayID = screens.first(where: { $0.value.contains(pointer) })?.key
        ?? selectedDisplay.flatMap({ screens[$0] == nil ? nil : $0 })
    else { throw ProviderError.message("No active display is available for screen guidance.") }
    let foreground = NSWorkspace.shared.frontmostApplication
    let previous = NSRunningApplication(processIdentifier: lastExternalPID)
    let app = foreground?.processIdentifier == ownPID ? previous : (foreground ?? previous)
    let foregroundPID = app?.processIdentifier == ownPID ? 0 : (app?.processIdentifier ?? 0)
    guard expectedForegroundPID == nil || expectedForegroundPID == foregroundPID else {
      throw ProviderError.message("The active app changed. Ask for screen guidance again.")
    }
    setGuidanceStage(.capture, generation: generation)
    record("guidance.capture.started")
    let frame = try await capture.capture(
      displayID: displayID, foregroundPID: foregroundPID,
      foregroundName: foregroundPID == 0 ? "Desktop" : (app?.localizedName ?? "Application"),
      screens: screens)
    try Task.checkCancellation()
    guard generation == self.generation, activeGuidanceRequest == request,
      ProcessInfo.processInfo.systemUptime < request.expires,
      CursorCompanionPreferences.load().screenGuidanceEnabled,
      captureGate.permits(captureToken, cancelled: Task.isCancelled)
    else { throw CancellationError() }
    guard frame.displayID == displayID else {
      throw ProviderError.message("The active display changed. Ask for screen guidance again.")
    }
    let currentForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let currentExternal = currentForeground == ownPID ? lastExternalPID : currentForeground
    guard foregroundPID == 0 || currentExternal == foregroundPID else {
      throw ProviderError.message("The active app changed. Ask for screen guidance again.")
    }
    explicitManualEvidence = nil
    evidence = frame
    if selectedContext.isEmpty { contextTitle = "Screen: \(frame.foregroundName)" }
    record("guidance.capture.accepted")
    return frame
  }

  /// An observed user click requests fresh perception, never an automatic click
  /// or an assumption that the previous instruction succeeded.
  func beginScreenGuidance(_ prompt: String, speakAloud: Bool = true) {
    guard CursorCompanionPreferences.load().screenGuidanceEnabled else { return }
    send(
      textOverride: prompt, voiceOnly: true, speakAloud: speakAloud,
      guidanceRequest: ScreenGuidanceRequest(prompt: prompt, speakAloud: speakAloud))
  }

  func continueScreenGuidance(
    request: ScreenGuidanceRequest, expectedEvidence: ScreenEvidenceIdentity, generation: UInt64
  ) {
    guard generation == self.generation, activeGuidanceRequest == request,
      (0..<5).contains(request.step), request.expires.isFinite,
      ProcessInfo.processInfo.systemUptime < request.expires,
      CursorCompanionPreferences.load().screenGuidanceEnabled,
      expectedEvidence.matches(evidence)
    else { return }
    let next = ScreenGuidanceRequest(
      id: request.id, prompt: request.prompt, step: request.step + 1, expires: request.expires,
      speakAloud: request.speakAloud)
    let instruction = """
      The user clicked the highlighted control. Inspect the new screen capture to verify what changed; do not assume the click succeeded. If that revealed a menu or sidebar, guide its next distinct nested control rather than repeating the opener. Continue the original functional goal using actual current app labels, even if the user named the app colloquially. Copy candidate IDs only from this fresh frame. If the task is complete, say so without another target. If progress is unclear, explain the ambiguity rather than invent a control.
      Original task: \(request.prompt)
      Guidance step: \(next.step)
      """
    send(
      textOverride: instruction, voiceOnly: true, speakAloud: request.speakAloud,
      guidanceRequest: next,
      expectedGuidanceForegroundPID: expectedEvidence.foregroundPID)
  }
  private func acceptTextPreview(_ preview: ProviderTextPreview, generation: UInt64) async throws {
    guard generation == self.generation else { throw CancellationError() }
    // Inert presentation only. Chat, speech, scenes and actions still wait for
    // a complete validated ProviderUnit through accept(_:generation:...).
    if !receivedTextPreview && !preview.text.isEmpty {
      receivedTextPreview = true
      record("cursor.firstTextPreview.received")
    }
    while onCursorTextPreview?(generation, preview) == false {
      // Bound presentation without accelerating words or dropping a paragraph.
      // This suspends one provider task; it never blocks the render/audio thread.
      try await Task.sleep(for: .milliseconds(50))
      guard generation == self.generation else { throw CancellationError() }
      try Task.checkCancellation()
    }
  }
  func accept(_ unit: ProviderUnit, generation: UInt64, expectedEvidence: ScreenEvidenceIdentity?)
    throws
  {
    guard generation == self.generation else { throw CancellationError() }
    switch unit.type {
    case "text":
      guard let text = unit.text, text.utf8.count <= 32000 else {
        throw ProviderError.message("Invalid text unit.")
      }
      messages.append(ChatLine(role: "assistant", text: text))
      if responsePolicy.route == .screenGuidance { guidanceNarration = text }
      record("semantic.text.accepted")
      speakNarration(text)
    case "scene":
      guard responsePolicy.allowsNotebook else {
        record("visual.suppressed.responsePolicy")
        return
      }
      guard let outputSceneBinding else { throw CancellationError() }
      let expectedBase = try outputSceneBinding.checkedBase(
        currentID: scene?.id, currentRevision: scene?.revision,
        proposedBase: outputSceneIncludesExistingNotebook ? unit.baseDocumentRevision : nil)
      if !outputSceneIncludesExistingNotebook, let base = unit.baseDocumentRevision, base != 0 {
        throw ProviderError.message("A new notebook must start at document revision zero.")
      }
      let document = try ProviderSceneBoundary.applying(
        unit,
        to: outputSceneIncludesExistingNotebook
          ? scene ?? SceneDocument(title: unit.title ?? "Explanation", width: 900, height: 560)
          : SceneDocument(title: unit.title ?? "Explanation", width: 900, height: 560),
        baseRevision: outputSceneIncludesExistingNotebook ? expectedBase : 0)
      snapshotUndo()
      scene = document
      self.outputSceneBinding = NotebookTurnBinding(
        documentID: document.id, revision: document.revision)
      outputSceneIncludesExistingNotebook = true
      section = "Notebook"
      if !scenePresentedForTurn {
        scenePresentedForTurn = true
        onSceneReady?()
      }
      record("visual.accepted")
    case "target":
      guard responsePolicy.route == .screenGuidance else {
        record("guidance.suppressed.responsePolicy")
        return
      }
      setGuidanceStage(.target, generation: generation)
      guard let payload = unit.target, payload.instruction.utf8.count <= 32_000,
        (payload.label?.prefix(81).count ?? 0) <= 80
      else { throw ProviderError.message("Invalid or oversized screen guidance target.") }
      guard let evidence, let expectedEvidence, expectedEvidence.matches(evidence)
      else {
        throw ProviderError.message(
          "The selected screen evidence changed. Capture again before requesting guidance.")
      }
      let resolved = try ScreenGrounding.resolve(
        payload, candidates: evidence.groundingCandidates, frameID: evidence.frameID)
      let target = GuidanceTargetPresentation.styled(resolved)
      let cursorPreferences = CursorCompanionPreferences.load()
      if let request = activeGuidanceRequest {
        guard cursorPreferences.screenGuidanceEnabled,
          ProcessInfo.processInfo.systemUptime < request.expires
        else { throw CancellationError() }
      }
      try overlay.validate(target: target, evidence: evidence)
      let introDelay = onCursorTargetAccepted?(generation, target, evidence) ?? 0
      try overlay.show(
        target: target, evidence: evidence,
        showInstruction: true,
        append: true, introDelay: introDelay)
      acceptedGuidanceTarget = true
      if let request = activeGuidanceRequest, cursorPreferences.screenGuidanceEnabled,
        ProcessInfo.processInfo.systemUptime < request.expires
      {
        onScreenGuidanceTargetAccepted?(target, evidence, generation, request)
      }
      messages.append(ChatLine(role: "assistant", text: target.instruction))
      speakNarration(target.instruction)
      record("guidance.presented.awaitingUser")
      setGuidanceStage(.provider, generation: generation)
    default: throw ProviderError.message("Unsupported model output kind: \(unit.type)")
    }
  }
  private func speakNarration(_ text: String) {
    guard configuration.speechEnabled || turnSpeaksAloud, narrationGate.admit(text) else { return }
    voice.speak(text)
  }

  func stop() {
    generation += 1
    cursorFailureGeneration = nil
    guidanceTurnStage = nil
    activeGuidanceRequest = nil
    onCursorCancelled?(generation)
    invalidateCapture()
    cancelWindowPicker()
    outputSceneBinding = nil
    spatialSelector.cancel()
    turn?.cancel()
    turn = nil
    voiceStartTask?.cancel()
    voiceStartTask = nil
    voiceSessionID = nil
    voiceMode = nil
    voiceDraftGuard = nil
    turnSpeaksAloud = false
    voice.stop()
    narrationGate.reset()
    listening = false
    pushToTalkActive = false
    microphoneLevel = 0
    voiceInputState = "Ready"
    busy = false
    state = "Ready"
    overlay.clear()
    record("turn.cancelled")
    updateBadge()
  }
  /// Manual microphone capture ends in a reviewable draft; it never submits.
  func toggleVoice() {
    if voiceMode == .manualReview, let id = voiceSessionID, listening {
      voiceStartTask?.cancel()
      voiceStartTask = nil
      voice.finishListening(id: id)
      return
    }
    beginVoiceInput(mode: .manualReview)
  }

  /// The global modifier hotkey calls these two edges. Repeated keyDown events
  /// cannot restart a held session; hover/panel focus is managed independently.
  func beginPushToTalk() {
    guard !pushToTalkActive else { return }
    beginVoiceInput(mode: .pushToTalk)
  }
  func endPushToTalk() {
    guard voiceMode == .pushToTalk, let id = voiceSessionID else { return }
    voiceStartTask?.cancel()
    voiceStartTask = nil
    record("ptt.released")
    voice.finishListening(id: id)
  }

  /// Lifecycle/tap loss also cancels the recognized tail after physical key
  /// release. A manual microphone session or an already submitted turn is kept.
  func cancelPushToTalk() {
    guard voiceMode == .pushToTalk else { return }
    stop()
  }

  private func beginVoiceInput(mode: VoiceInputMode) {
    stop()
    error = nil
    voiceTranscript = ""
    voiceNotice = nil
    let id = UUID()
    voiceSessionID = id
    voiceMode = mode
    voiceDraftGuard = VoiceDraftGuard(draft: input)
    record(mode == .pushToTalk ? "keyDown.ptt" : "manualVoice.started")
    voice.beginInput(id: id, mode: mode)
    onCursorInputStarted?(generation)
    voiceStartTask = Task { [weak self] in
      guard let self else { return }
      do { try await self.voice.startListening(id: id) } catch {
        // Current permission/route errors are emitted by VoiceService. Released
        // or stopped startup tasks deliberately produce no late UI mutation.
      }
    }
  }

  private func acceptVoiceState(_ snapshot: VoiceInputSnapshot) {
    guard let id = snapshot.sessionID, id == voiceSessionID else { return }
    voiceInputState = snapshot.phase.label
    voiceTranscript = snapshot.transcript
    if snapshot.phase != .listening { microphoneLevel = 0 }
    listening = snapshot.phase.isActive
    pushToTalkActive = snapshot.mode == .pushToTalk && snapshot.isHeld && snapshot.phase.isActive
    state = snapshot.phase.isActive ? snapshot.phase.label : (busy ? "Thinking" : "Ready")
    updateBadge()
  }

  private func acceptVoiceTranscript(id: UUID, mode: VoiceInputMode, text: String) {
    guard voiceSessionID == id else { return }
    voiceTranscript = text
    guard mode == .manualReview else { return }
    guard
      let replacement = voiceDraftGuard?.replacement(
        mode: mode, transcript: text, currentDraft: input)
    else {
      voiceStartTask?.cancel()
      voiceSessionID = nil
      voiceMode = nil
      voice.cancelInput()
      listening = false
      pushToTalkActive = false
      microphoneLevel = 0
      voiceInputState = "Ready"
      state = busy ? "Thinking" : "Ready"
      notice = "Your typed edit was kept. Speech input stopped."
      updateBadge()
      return
    }
    input = replacement
  }

  private func completeVoiceInput(_ completion: VoiceInputCompletion) {
    guard voiceSessionID == completion.sessionID else { return }
    voiceSessionID = nil
    voiceMode = nil
    voiceStartTask = nil
    listening = false
    pushToTalkActive = false
    microphoneLevel = 0
    voiceInputState = "Ready"
    state = "Ready"
    guard !completion.transcript.isEmpty else {
      notice =
        "No speech was captured. Hold Control+Option until Listening appears, then speak and release."
      voiceNotice = notice
      updateBadge()
      return
    }
    if completion.mode.submitsOnCompletion {
      record(completion.isFinal ? "ptt.finalTranscript" : "ptt.recognizedTailDeadline")
      // Keep the typed draft and ordinary conversation. Screen help uses one
      // fresh capture; ordinary voice questions omit selected file/memory/image evidence.
      send(
        textOverride: completion.transcript, voiceOnly: true, speakAloud: true)
    } else {
      notice = "Transcript ready. Review the draft and send when ready."
      updateBadge()
    }
  }
  private func invalidateCapture() {
    captureGate.invalidate()
    captureTask?.cancel()
    captureTask = nil
  }
  /// Display rearrangement changes the coordinate authority even if an older
  /// screenshot is young and its former foreground application is still active.
  func invalidateScreenEvidence() {
    invalidateCapture()
    explicitManualEvidence = nil
    cancelWindowPicker()
    spatialSelector.cancel()
    if evidence != nil {
      evidence = nil
      selectedContext = ""
      contextTitle = ""
    }
    overlay.clear()
    record("capture.displayTopologyInvalidated")
  }
  @discardableResult private func beginContextSelection() -> UInt64 {
    invalidateCapture()
    explicitManualEvidence = nil
    cancelWindowPicker()
    spatialSelector.cancel()
    evidence = nil
    selectedContext = ""
    contextTitle = ""
    overlay.clear()
    return captureGate.generation
  }
  func observe() { performCapture() }
  func performCapture(region: CGRect? = nil, window: CaptureWindow? = nil, strokes: String = "") {
    let token = beginContextSelection()
    let foreground = NSWorkspace.shared.frontmostApplication
    let previous = NSRunningApplication(processIdentifier: lastExternalPID)
    let app = foreground?.bundleIdentifier == Bundle.main.bundleIdentifier ? previous : foreground
    let screens = Dictionary(
      uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
        guard
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { return nil }
        return (number.uint32Value, screen.frame)
      })
    let displayID = selectedDisplay
    state = "Observing"
    updateBadge()
    captureTask = Task { [weak self] in
      guard let self else { return }
      do {
        let frame = try await capture.capture(
          displayID: displayID, foregroundPID: window?.pid ?? app?.processIdentifier ?? 0,
          foregroundName: window?.appName ?? app?.localizedName ?? "Desktop", region: region,
          windowID: window?.id, screens: screens)
        guard captureGate.permits(token, cancelled: Task.isCancelled) else { return }
        explicitManualEvidence = ScreenEvidenceIdentity(frame)
        evidence = frame
        if !strokes.isEmpty {
          selectedContext = "User-drawn spatial context (normalized top-left points): " + strokes
        }
        if selectedContext.isEmpty { contextTitle = "Screen: \(frame.foregroundName)" }
        notice = "One screen frame selected. It will be sent with your next question."
        state = "Ready"
        captureTask = nil
        updateBadge()
      } catch {
        guard captureGate.permits(token, cancelled: Task.isCancelled) else { return }
        state = "Ready"
        captureTask = nil
        updateBadge()
        if !(error is CancellationError) { showError(error) }
      }
    }
  }
  func clearContext() {
    _ = beginContextSelection()
    if state == "Observing" {
      state = "Ready"
      updateBadge()
    }
  }
  func sample(_ type: String) {
    do {
      stop()
      snapshotUndo()
      scene =
        type == "motor"
        ? try BuiltInLessons.motor()
        : type == "lever" ? BuiltInLessons.lever() : BuiltInLessons.circuit()
      playTime = 0
      section = "Notebook"
      seekRevision += 1
      onOpen?()
      notice = "Built-in example • local interactive lesson"
    } catch { showError(error) }
  }
  func newNotebook() {
    stop()
    snapshotUndo()
    scene = SceneDocument(title: "Untitled notebook", width: 900, height: 560)
    section = "Notebook"
    playTime = 0
    seekRevision += 1
    onOpen?()
  }
  func snapshotUndo() {
    if let scene {
      undoStack.append(scene)
      if undoStack.count > 50 { undoStack.removeFirst() }
    }
    redoStack.removeAll()
  }
  func undo() {
    guard var previous = undoStack.popLast() else { return }
    if let scene {
      redoStack.append(scene)
      previous.revision = scene.revision + 1
    }
    scene = previous
  }
  func redo() {
    guard var next = redoStack.popLast() else { return }
    if let scene {
      undoStack.append(scene)
      next.revision = scene.revision + 1
    }
    scene = next
  }
  func editNode(id: String, text: String? = nil, x: Double? = nil, y: Double? = nil) {
    guard var document = scene, let index = document.nodes.firstIndex(where: { $0.id == id }) else {
      return
    }
    if let text {
      snapshotUndo()
      document.nodes[index].text = String(text.prefix(8000))
    }
    if let x {
      document.nodes[index].x = x
      document.nodes[index].bindings.removeValue(forKey: "x")
    }
    if let y {
      document.nodes[index].y = y
      document.nodes[index].bindings.removeValue(forKey: "y")
    }
    document.revision += 1
    do { scene = try document.validated() } catch { showError(error) }
  }
  func addText() {
    guard var document = scene else { return }
    snapshotUndo()
    document.nodes.append(
      SceneNode(
        id: UUID().uuidString, kind: .text, x: 40, y: 40, width: 340, height: 90, text: "Your note",
        color: "#2458A6", fontSize: 22))
    document.revision += 1
    scene = document
    selectedNodeID = document.nodes.last?.id
  }
  func setParameter(_ name: String, value: Double) {
    guard var document = scene else { return }
    document.parameters[name]?.value = value
    document.revision += 1
    scene = document
  }
  func saveScene() {
    guard let scene, let store else { return }
    Task {
      do {
        _ = try await store.saveRecord(
          id: scene.id, kind: "notebook", title: scene.title,
          body: scene.nodes.map(\.text).joined(separator: " "), payload: JSONEncoder().encode(scene)
        )
        notice = "Notebook saved in Library."
        await reload()
      } catch { showError(error) }
    }
  }
  func openRecord(_ record: StoredRecord) {
    if record.kind == "notebook", let data = record.payload {
      do {
        let document = try JSONDecoder().decode(SceneDocument.self, from: data).validated()
        stop()
        scene = document
        section = "Notebook"
        playTime = 0
        seekRevision += 1
        onOpen?()
      } catch { showError(error) }
    } else if record.kind == "conversation", let data = record.payload,
      let lines = try? JSONDecoder().decode([ChatLine].self, from: data)
    {
      stop()
      messages = lines
      section = "Companion"
    } else {
      memoryTitle = record.title
      memoryBody = record.body
      section = "Memory"
    }
  }
  func deleteRecord(_ id: String) {
    guard let store else { return }
    Task {
      do {
        try await store.deleteRecord(id: id)
        await reload()
      } catch { showError(error) }
    }
  }
  func saveMemory() {
    guard let store, !memoryTitle.isEmpty else { return }
    Task {
      do {
        _ = try await store.saveRecord(kind: "memory", title: memoryTitle, body: memoryBody)
        notice = "Memory saved. Select it explicitly to include it in a question."
        memoryTitle = ""
        memoryBody = ""
        await reload()
      } catch { showError(error) }
    }
  }
  func useRecord(_ record: StoredRecord) {
    clearContext()
    selectedContext = "Saved \(record.kind): \(record.title)\n\(record.body)"
    contextTitle = record.title
    section = "Companion"
  }
  func persistConversation() async {
    guard let store else { return }
    do {
      _ = try await store.saveRecord(
        kind: "conversation", title: String(messages.first?.text.prefix(90) ?? "Conversation"),
        body: messages.map(\.text).joined(separator: "\n"), payload: JSONEncoder().encode(messages))
      await reload()
    } catch { showError(error) }
  }
  func importFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let token = beginContextSelection()
    captureTask = Task { [weak self] in
      guard let self else { return }
      do {
        let context = try await Task.detached {
          try FileContextReader().read(url: url, allowedRoot: url.deletingLastPathComponent())
        }.value
        guard captureGate.permits(token, cancelled: Task.isCancelled) else { return }
        selectedContext = context.chunks.map { "\($0.citation):\n\($0.text)" }.joined(
          separator: "\n")
        contextTitle = url.lastPathComponent
        notice = "Selected file context is ready for your next question."
        section = "Companion"
        captureTask = nil
      } catch {
        guard captureGate.permits(token, cancelled: Task.isCancelled) else { return }
        captureTask = nil
        if !(error is CancellationError) { showError(error) }
      }
    }
  }
  func exportScene() {
    guard let scene else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = scene.title + ".json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(scene).write(to: url, options: .atomic)
      notice = "Editable document exported."
    } catch { showError(error) }
  }
  func exportLibrary() {
    guard let store else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "OpenCompanion-library.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        try await store.exportData().write(to: url, options: .atomic)
        notice = "Library exported without credentials."
      } catch { showError(error) }
    }
  }
  func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "OpenCompanion-diagnostics.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "appVersion": "0.1.0", "architecture": "arm64", "trace": trace,
          "note": "Monotonic host events; no acoustic or display-sensor measurements.",
        ], options: [.prettyPrinted, .sortedKeys])
      try data.write(to: url, options: .atomic)
    } catch { showError(error) }
  }
  func updateBadge() { badge?.contentView = NSHostingView(rootView: CompanionBadge(state: state)) }
  func showBadge() { onCompanionRequested?() }
}

actor ReceiptFlag {
  var value = false
  func mark() { value = true }
}

extension AppModel {
  func enqueueJob(_ instruction: String, interval: Int) {
    guard let store else { return }
    Task {
      do {
        if interval > 0 {
          try await store.saveRoutine(
            Routine(
              title: String(instruction.prefix(80)), instruction: instruction,
              scope: "reasoning-only", interval: Double(interval), nextRunAt: Date(),
              missedRunPolicy: .runOnce))
        } else {
          _ = try await store.enqueueJob(
            instruction: instruction, scope: "reasoning-only", retryClass: .idempotent,
            retryBudget: 1)
        }
        startJobs()
        await runner.refresh()
        await reload()
      } catch { showError(error) }
    }
  }
  func startJobs() {
    guard let store else { return }
    runner.start(
      store: store,
      executor: { [weak self] job in
        guard let self else { throw CancellationError() }
        return try await self.executeJob(job)
      }, onChange: { [weak self] jobs in self?.jobs = jobs },
      onError: { [weak self] error in self?.showError(error) })
  }
  func executeJob(_ job: DurableJob) async throws -> Data {
    let collector = JobOutputCollector()
    let messages = [ChatLine(role: "user", text: job.instruction)]
    let callback: @Sendable (ProviderUnit) async throws -> Void = { unit in
      await collector.append(unit)
    }
    if providerMode == "ChatGPT via Codex" {
      try await CodexProvider().stream(
        executable: codexPath, model: codexModel, messages: messages, context: "", image: nil,
        scene: nil, onUnit: callback)
    } else {
      try await provider.stream(
        configuration: configuration, key: apiKey, messages: messages, context: "", image: nil,
        scene: nil, onUnit: callback)
    }
    let output = await collector.text
    guard !output.isEmpty else {
      throw ProviderError.message("Job completed without a textual result.")
    }
    if let store {
      _ = try await store.saveRecord(
        kind: "job-result", title: String(job.instruction.prefix(90)), body: output)
    }
    return Data(output.utf8)
  }
  func cancelJob(_ id: String) {
    Task {
      do {
        try await runner.cancel(jobID: id)
        await reload()
      } catch { showError(error) }
    }
  }
  func viewJobResult(_ data: Data) {
    messages.append(ChatLine(role: "assistant", text: String(decoding: data, as: UTF8.self)))
    section = "Companion"
  }
}
actor JobOutputCollector {
  var text = ""
  func append(_ unit: ProviderUnit) { if let part = unit.text { text += part + "\n\n" } }
}

extension AppModel {
  func chooseRegion(_ mode: SpatialSelectionMode) {
    guard
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == selectedDisplay
      }) ?? NSScreen.main
    else { return }
    let token = beginContextSelection()
    captureTask = Task { [weak self] in
      guard let self else { return }
      if let selection = await spatialSelector.choose(screen: screen, mode: mode) {
        guard captureGate.permits(token, cancelled: Task.isCancelled) else { return }
        let encoded = selection.normalizedStrokes.map { $0.map { [Double($0.x), Double($0.y)] } }
        let data = try? JSONSerialization.data(withJSONObject: encoded)
        performCapture(
          region: mode == .region ? selection.rect : nil,
          strokes: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
      }
    }
  }
  /// Dismissing enumeration must not cancel an already selected capture or
  /// erase evidence the user deliberately retained for a question.
  func cancelWindowPicker() {
    windowPickerRequestID = nil
    windowPickerTask?.cancel()
    windowPickerTask = nil
    if showingWindowPicker { showingWindowPicker = false }
  }
  func chooseWindow(host: CapturePickerHost = .workspace) {
    cancelWindowPicker()
    windowPickerHost = host
    let requestID = UUID()
    windowPickerRequestID = requestID
    windowPickerTask = Task { [weak self] in
      guard let self else { return }
      do {
        let windows = try await capture.windows()
        guard !Task.isCancelled, windowPickerRequestID == requestID else { return }
        captureWindows = windows
        showingWindowPicker = true
        windowPickerRequestID = nil
        windowPickerTask = nil
      } catch {
        guard !Task.isCancelled, windowPickerRequestID == requestID else { return }
        windowPickerRequestID = nil
        windowPickerTask = nil
        if !(error is CancellationError) { showError(error) }
      }
    }
  }
  func renameScene(_ title: String) {
    guard var document = scene else { return }
    document.title = String(title.prefix(200))
    document.revision += 1
    scene = document
  }
}

extension AppModel {
  func addStroke(_ points: [Point2D]) {
    guard var document = scene, points.count >= 2, points.count <= 8192 else { return }
    snapshotUndo()
    document.nodes.append(
      SceneNode(
        id: UUID().uuidString, kind: .path, color: "#2458A6", strokeWidth: 3, points: points))
    document.revision += 1
    do { scene = try document.validated() } catch { showError(error) }
  }
}
