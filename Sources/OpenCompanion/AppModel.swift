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
  private(set) var conversationID = UUID().uuidString
  @Published var state = "Ready"
  @Published var error: String?
  @Published var notice: String?
  @Published var busy = false
  @Published private(set) var presentingExplanation = false
  @Published private(set) var explanationPresentation: ExplanationPresentation?
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
  @Published var scene: SceneDocument? {
    didSet {
      // Host edits and replacements revoke queued snapshots, including edits
      // that accidentally reuse the current revision. Provider commits below
      // advance the canonical tip explicitly without exposing future geometry.
      if !committingExplanationScene, scene != explanationCanonicalTip {
        if explanationPlaybackEnabled { stop() }
        explanationPresentation = nil
      }
    }
  }
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
  let voice: VoiceService
  let overlay = OverlayHost()
  let guidanceSession = GuidanceSessionController()
  private var guidanceSessionSubscription: AnyCancellable?
  private var guidanceTurnToken: GuidanceTurnToken?
  private var guidanceLoadingTask: Task<Void, Never>?
  private var guidanceStatusReceived = false
  // Ephemeral only: a restored semantic workflow has no capture authorization.
  private var guidanceWorkflowCapture:
    (workflowID: UUID, selectedScope: ScreenGuidanceCaptureScope?)?
  private let observesGuidanceSceneChanges: Bool
  private(set) var guidanceSceneScope: GuidanceSceneScope?
  private var guidanceSceneExpiryTask: Task<Void, Never>?
  private lazy var guidanceSceneObserver = GuidanceSceneObserver(
    observeSystemEvents: observesGuidanceSceneChanges
  ) { [weak self] scope, reason in
    self?.guidanceSceneDidChange(scope: scope, reason: reason)
  }
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
  private var voiceGuidanceContinuation: ManualGuidanceVoiceContinuation?
  private let screenGuidanceEnabled: @MainActor () -> Bool
  private let guidanceForegroundPID: @MainActor () -> pid_t?
  private let scopedGuidanceRefresh: (@MainActor (ScreenEvidence) async throws -> ScreenEvidence)?
  private let responseStream: ReasoningTurnStream?
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
  var onNarrationCaptionStarted: ((String, VoiceNarrationContext, Bool) -> Bool)?
  var onNarrationCaptionUpdate: ((VoiceUtteranceUpdate) -> Void)?
  var onNarrationCaptionFinished: ((VoiceNarrationContext) -> Void)?
  var onExplanationNarrationEvent: ((VoiceUtteranceUpdate) -> Void)?
  var onExplanationPresentationChanged: ((ExplanationPresentation) -> Void)?
  var onExplanationFocusStarted: ((VoiceNarrationContext, ExplanationPresentation) -> Void)?
  var onExplanationFocusEnded: ((VoiceNarrationContext) -> Void)?
  var onManualGuidanceVoiceStart: (() -> ManualGuidanceStep?)?
  var onPrepareScreenGuidance: ((UInt64, pid_t) async throws -> Void)?
  private(set) var responsePolicy = ResponsePolicy.resolve(text: "", screenGuidanceEnabled: false)
  private var outputSceneIncludesExistingNotebook = false
  private var acceptedGuidanceTarget = false
  private var guidanceNarration: String?
  private var narrationGate = TurnNarrationGate()
  private let explanationPlayback = ExplanationPlayback()
  private var explanationPlaybackEnabled = false
  private var explanationCanonicalTip: SceneDocument?
  private var committingExplanationScene = false
  private var currentExplanationNarration: (context: VoiceNarrationContext, text: String)?
  private var explanationRenderWait: Task<Void, Never>?
  private var explanationRenderWaitID: UUID?
  var explanationDisplayDocument: SceneDocument? { explanationPresentation?.document ?? scene }
  private var guidanceTurnStage: GuidanceTurnStage?
  private(set) var cursorFailureGeneration: UInt64?
  private(set) var activeGuidanceRequest: ScreenGuidanceRequest?
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
  private(set) var selectedCaptureSelectionID: UUID?
  private var invalidatedManualGuidanceScope = false
  private var undoStack: [SceneDocument] = []
  private var redoStack: [SceneDocument] = []
  private var timer: Timer?
  private var lastTick = ProcessInfo.processInfo.systemUptime
  private var badge: NSPanel?
  var onOpen: (() -> Void)?
  var onCompanionRequested: (() -> Void)?
  var onSceneReady: (() -> Void)?
  /// Native presentation owns visibility and document identity. A sidebar or
  /// an unrelated utility window cannot authorize edits to a retained scene.
  var isScenePresentationVisible: ((String) -> Bool)?
  private var trace: [[String: String]] = []
  init(
    acceptanceMode: Bool = false, store: LocalStore? = nil,
    voice suppliedVoice: VoiceService? = nil,
    observeGuidanceSceneChanges: Bool? = nil,
    guidanceForegroundPID: @escaping @MainActor () -> pid_t? = {
      NSWorkspace.shared.frontmostApplication?.processIdentifier
    },
    screenGuidanceEnabled: @escaping @MainActor () -> Bool = {
      CursorCompanionPreferences.load().screenGuidanceEnabled
    },
    scopedGuidanceRefresh: (@MainActor (ScreenEvidence) async throws -> ScreenEvidence)? = nil,
    responseStream: ReasoningTurnStream? = nil
  ) {
    self.voice = suppliedVoice ?? VoiceService()
    self.store = store
    self.observesGuidanceSceneChanges = observeGuidanceSceneChanges ?? !acceptanceMode
    self.screenGuidanceEnabled = screenGuidanceEnabled
    self.guidanceForegroundPID = guidanceForegroundPID
    self.scopedGuidanceRefresh = scopedGuidanceRefresh
    self.responseStream = responseStream
    if !acceptanceMode {
      if store == nil {
        do {
          let url = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[
              0
            ]
            .appendingPathComponent("OpenCompanion", isDirectory: true)
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          self.store = try LocalStore(url: url.appendingPathComponent("library.sqlite"))
        } catch { self.error = "Local library could not open: \(error.localizedDescription)" }
      }
      apiKey =
        (try? credentials.load(
          service: "org.opencompanion.provider", account: configuration.endpoint))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    if let store = self.store { guidanceSession.setStore(store) }
    guidanceSession.onPersisted = { [weak self] in Task { await self?.reload() } }
    guidanceSessionSubscription = guidanceSession.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    voice.onState = { [weak self] state in
      guard let self else { return }
      if !self.listening {
        self.state =
          state == "Ready" && (self.busy || self.presentingExplanation) ? "Thinking" : state
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
    voice.onUtteranceUpdate = { [weak self] update in self?.acceptNarrationUpdate(update) }
    explanationPlayback.onPresent = { [weak self] presentation in
      guard let self, self.explanationPlaybackEnabled,
        presentation.generation == self.generation,
        self.scene == self.explanationCanonicalTip
      else { return }
      self.explanationPresentation = presentation
      self.record("explanation.visual.released")
      self.explanationRenderWait?.cancel()
      self.explanationRenderWaitID = nil
      if ExplanationOverlay.hasRenderableContent(presentation.document) {
        self.explanationRenderWaitID = presentation.beatID
        self.explanationRenderWait = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          guard let self, self.explanationPlaybackEnabled,
            self.explanationPresentation == presentation,
            self.explanationRenderWaitID == presentation.beatID
          else { return }
          self.finishTurnFailure(
            error: ProviderError.message(
              "The explanation surface could not present this step. Ask again."),
            generation: presentation.generation, policy: self.responsePolicy)
        }
      }
      self.onExplanationPresentationChanged?(presentation)
      guard self.explanationPlaybackEnabled, self.explanationPresentation == presentation else {
        return
      }
      if !self.scenePresentedForTurn {
        self.scenePresentedForTurn = true
        self.onSceneReady?()
      }
    }
    explanationPlayback.onNarration = { [weak self] context, text in
      self?.startExplanationNarration(context: context, text: text)
    }
    explanationPlayback.onActivityChanged = { [weak self] active in
      guard let self else { return }
      self.presentingExplanation = active
      if !active && !self.busy && !self.voice.hasPendingSpeech { self.state = "Ready" }
    }
    if !acceptanceMode {
      lastExternalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
      workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let pid =
          (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
          .processIdentifier
        // The observer's .main queue preserves the recorded activation order;
        // deferred tasks must not clear a newer guide after a rapid round trip.
        MainActor.assumeIsolated {
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
    guard section == "Notebook", let documentID = scene?.id else { return false }
    return isScenePresentationVisible?(documentID) == true
  }

  func send() { send(textOverride: nil, voiceOnly: false, speakAloud: false) }
  private func send(
    textOverride: String?, voiceOnly: Bool, speakAloud: Bool,
    guidanceRequest: ScreenGuidanceRequest? = nil,
    expectedGuidanceForegroundPID: pid_t? = nil,
    transcriptText: String? = nil, continuingWorkflow: Bool = false
  ) {
    let text = (textOverride ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let guidanceEnabled = screenGuidanceEnabled()
    guard guidanceRequest == nil || guidanceEnabled else {
      notice = "Screen guidance is disabled. Enable it before continuing this guide."
      if voiceOnly { voiceNotice = notice }
      return
    }
    let policy = ResponsePolicy.resolve(
      text: text, screenGuidanceEnabled: guidanceEnabled,
      explicitGuidance: guidanceRequest != nil, inNotebook: notebookContextIsVisible,
      hasNotebook: scene != nil)
    let inputPlan = ResponseInputPlan.resolve(
      policy: policy, voiceOnly: voiceOnly, selectedContext: selectedContext, evidence: evidence,
      explicitManualEvidence: explicitManualEvidence)
    guard
      !(policy.route == .screenGuidance && !voiceOnly
        && inputPlan.requiresFreshGuidanceCapture && invalidatedManualGuidanceScope)
    else {
      notice =
        "The selected screen context changed. Recapture that window or region, or remove screen context before asking for current-screen guidance."
      return
    }
    // Preserve only explicitly selected capture scope. A prior automatic
    // guidance image is not a user-selected attachment for a later question.
    let declaredGuidance: ScreenGuidanceRequest?
    do {
      if policy.route == .screenGuidance {
        if let guidanceRequest {
          if let scope = guidanceRequest.selectedScope, !ownsSelectedGuidanceScope(scope) {
            throw ProviderError.message(
              "The selected area changed. Choose a screen before continuing this guide.")
          }
          declaredGuidance = guidanceRequest
        } else {
          let scope = inputPlan.evidenceIdentity == nil ? nil : try currentSelectedGuidanceScope()
          declaredGuidance = ScreenGuidanceRequest(
            prompt: text, speakAloud: speakAloud, selectedScope: scope)
        }
      } else {
        declaredGuidance = nil
      }
    } catch {
      showError(error)
      return
    }
    let previousGuidanceInstruction =
      (guidanceRequest?.step ?? 0) > 0
      ? messages.last(where: { $0.role == "assistant" }).map { String($0.text.prefix(800)) } : nil
    let sourceGeneration = generation
    if declaredGuidance == nil { guidanceSession.pause() }
    cancelActiveTurn()
    var workflowToken: GuidanceTurnToken?
    if let request = declaredGuidance {
      do {
        if !continuingWorkflow || guidanceSession.workflow == nil {
          try guidanceSession.start(goal: request.prompt, speakAloud: request.speakAloud)
        }
        workflowToken = try guidanceSession.beginCheck()
        if let workflowToken {
          guidanceWorkflowCapture = (workflowToken.workflowID, request.selectedScope)
        }
      } catch {
        showError(error)
        guidanceSession.pause()
        return
      }
    }
    guidanceTurnToken = workflowToken
    guidanceStatusReceived = false
    let savedGuidanceContext = workflowToken == nil ? "" : guidanceSession.plannerContext
    if textOverride == nil { input = "" }
    turnSpeaksAloud = speakAloud
    voiceNotice = nil
    error = nil
    generation += 1
    let current = generation
    activeGuidanceRequest = declaredGuidance
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
    // Provider control instructions never become visible or persisted messages.
    // Guidance history below still receives the full private continuation text.
    messages.append(ChatLine(role: "user", text: transcriptText ?? text))
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
    let turnProviderMode = providerMode
    let turnCodexPath = codexPath
    let turnCodexModel = codexModel
    turn = Task { [weak self] in
      guard let self else { return }
      do {
        let turnContext: String
        let turnImage: Data?
        let turnEvidence: ScreenEvidenceIdentity?
        if let request = declaredGuidance {
          let frame: ScreenEvidence
          if let scope = request.selectedScope {
            guard self.ownsSelectedGuidanceScope(scope), let selected = self.evidence else {
              throw CancellationError()
            }
            frame = try await self.prepareSelectedGuidanceEvidence(
              ScreenEvidenceIdentity(selected), generation: current, captureToken: captureToken,
              selectedScope: scope)
          } else {
            frame = try await self.captureGuidanceEvidence(
              request: request, generation: current, captureToken: captureToken,
              expectedForegroundPID: expectedGuidanceForegroundPID)
          }
          turnContext =
            frame.semanticText + (savedGuidanceContext.isEmpty ? "" : "\n\n" + savedGuidanceContext)
          turnImage = frame.image
          turnEvidence = ScreenEvidenceIdentity(frame)
        } else {
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
        let reasoningInput = ReasoningTurnInput(
          messages: history, context: turnContext, image: turnImage, scene: activeScene,
          responsePolicy: policy)
        if let responseStream = self.responseStream {
          try await responseStream(reasoningInput, handler, preview)
        } else if turnProviderMode == "ChatGPT via Codex" {
          let adapter = CodexProvider()
          self.codex = adapter
          try await adapter.stream(
            executable: turnCodexPath, model: turnCodexModel, messages: reasoningInput.messages,
            context: reasoningInput.context,
            image: reasoningInput.image, scene: reasoningInput.scene, guidanceModel: guidanceModel,
            onRouting: { [weak self] selection in
              await self?.acceptModelRouting(selection, generation: current, policy: policy)
            }, onUnit: handler, onText: preview,
            responsePolicy: reasoningInput.responsePolicy)
        } else {
          try await self.provider.stream(
            configuration: config, key: key, messages: reasoningInput.messages,
            context: reasoningInput.context,
            image: reasoningInput.image,
            scene: reasoningInput.scene, onUnit: handler, onText: preview,
            responsePolicy: reasoningInput.responsePolicy)
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
        if let workflowToken, self.guidanceSession.owns(workflowToken) {
          try self.guidanceSession.finishTurn(
            token: workflowToken,
            fallbackSummary: String(
              (self.guidanceNarration ?? "A fresh screen check is needed.").prefix(480)))
          self.scheduleGuidanceLoadingCheck(token: workflowToken, generation: current)
        }
        if policy.route == .screenGuidance, !self.acceptedGuidanceTarget,
          self.guidanceSession.workflow?.phase != .loading
        {
          self.endGuidanceSceneObservation()
        }
        self.busy = false
        if self.state != "Speaking" {
          self.state = self.presentingExplanation ? "Thinking" : "Ready"
        }
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
  func acceptProviderUnit(
    _ unit: ProviderUnit, generation: UInt64, expectedEvidence: ScreenEvidenceIdentity?,
    guidanceBinding: ScreenGuidanceTurnBinding?, captureToken: UInt64
  ) async throws {
    if unit.type == "guidanceStatus", responsePolicy.route == .screenGuidance,
      let binding = guidanceBinding, binding.hasPresentedPrimary,
      let frame = evidence, ScreenEvidenceIdentity(binding.current).matches(frame),
      generation == self.generation, captureGate.permits(captureToken, cancelled: Task.isCancelled),
      expectedEvidence?.matches(frame) != true
        || ProcessInfo.processInfo.systemUptime - frame.capturedAt
          >= ScreenGuidancePolicy.admissionEvidenceAge
    {
      guard !guidanceStatusReceived, let assessment = unit.guidance,
        !assessment.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        assessment.summary.utf8.count <= 2_048
      else {
        throw ProviderError.message("Invalid or duplicate screen-guidance assessment.")
      }
      try requireGuidanceForeground(binding.source.foregroundPID)
      guidanceStatusReceived = true
      // This assessment still belongs to the model's earlier input frame. Do
      // not rebind it to a newer native-verified target or revoke that target.
      record("guidance.assessment.staleOmitted")
      return
    }
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
    let prepared: ProviderTarget
    do {
      prepared = try await binding.prepare(
        payload,
        refresh: {
          guard stillOwned() else { throw CancellationError() }
          self.record("guidance.lateTarget.refresh.started")
          return try await self.refreshGuidanceEvidence(binding.source)
        }, stillOwned: stillOwned)
    } catch ScreenGuidanceTurnBinding.Decline.secondaryWouldRefreshPresentedPrimary {
      guard stillOwned() else { throw CancellationError() }
      try requireGuidanceForeground(binding.source.foregroundPID)
      record("guidance.secondary.deferred.awaitingUser")
      setGuidanceStage(.provider, generation: generation)
      return
    }
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
    binding.recordPresentedTarget(prepared)
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
    guard pid > 0, guidanceForegroundPID() == pid else {
      throw ProviderError.message("The active app changed. Ask for screen guidance again.")
    }
  }

  /// Declare output ownership once for the current turn, independent of any
  /// retained document or previously selected sidebar destination.
  func configureResponseOutput(_ policy: ResponsePolicy) {
    cancelExplanationPlayback(stopSpeech: false)
    responsePolicy = policy
    cursorFailureGeneration = nil
    guidanceTurnStage = nil
    setGuidanceStage(.prepare, generation: generation)
    outputSceneIncludesExistingNotebook = policy.includesExistingNotebook
    outputSceneBinding =
      policy.allowsNotebook
      ? NotebookTurnBinding(documentID: scene?.id, revision: scene?.revision) : nil
    scenePresentedForTurn = false
    explanationPlaybackEnabled = policy.allowsNotebook && !policy.includesExistingNotebook
    explanationCanonicalTip = scene
    if explanationPlaybackEnabled { explanationPlayback.begin(generation: generation) }
  }

  /// Keep a current guidance failure readable without turning it into chat,
  /// speech, notebook content, or a retry. Stale work cannot alter a newer turn.
  func finishTurnFailure(error: Error, generation: UInt64, policy: ResponsePolicy) {
    guard generation == self.generation else { return }
    endGuidanceSceneObservation()
    cancelExplanationPlayback(stopSpeech: true)
    overlay.clear()
    activeGuidanceRequest = nil
    guidanceSession.pause()
    guidanceTurnToken = nil
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

  /// A deliberately selected capture defines scope, not indefinitely current
  /// pixels. Refresh that same scope before the model receives this request.
  func prepareSelectedGuidanceEvidence(
    _ selectedFrame: ScreenEvidenceIdentity, generation: UInt64, captureToken: UInt64,
    refresh: (@MainActor (ScreenEvidence) async throws -> ScreenEvidence)? = nil,
    selectedScope: ScreenGuidanceCaptureScope? = nil
  ) async throws -> ScreenEvidence {
    try Task.checkCancellation()
    let request = activeGuidanceRequest
    let ownsRequest: @MainActor () -> Bool = { [weak self] in
      guard let selectedScope else { return true }
      guard let self, let request, request.selectedScope == selectedScope else { return false }
      return self.activeGuidanceRequest == request && request.expires.isFinite
        && ProcessInfo.processInfo.systemUptime < request.expires
    }
    guard ownsRequest(), generation == self.generation,
      captureGate.permits(captureToken, cancelled: Task.isCancelled),
      explicitManualEvidence == selectedFrame, let source = evidence, selectedFrame.matches(source),
      screenGuidanceEnabled(),
      selectedScope.map(ownsSelectedGuidanceScope) ?? true
    else { throw CancellationError() }
    let selectionID = selectedCaptureSelectionID
    try monitorGuidanceScene(
      generation: generation, foregroundPID: selectedFrame.foregroundPID,
      sourceRect: selectedFrame.screenRect)
    guard let scope = guidanceSceneScope else { throw CancellationError() }
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
      guidanceSceneScope == scope, screenGuidanceEnabled(), ownsRequest(),
      selectedCaptureSelectionID == selectionID,
      selectedScope.map(ownsSelectedGuidanceScope) ?? true
    else { throw CancellationError() }
    try requireGuidanceForeground(selectedFrame.foregroundPID)
    setGuidanceStage(.capture, generation: generation)
    record("guidance.selectedCapture.refresh.started")
    let stillOwned: @MainActor () -> Bool = { [weak self] in
      guard let self else { return false }
      return generation == self.generation
        && self.captureGate.permits(captureToken, cancelled: Task.isCancelled)
        && self.explicitManualEvidence == selectedFrame && selectedFrame.matches(self.evidence)
        && self.guidanceSceneScope == scope && ownsRequest()
        && self.selectedCaptureSelectionID == selectionID
        && (selectedScope.map(self.ownsSelectedGuidanceScope) ?? true)
        && self.screenGuidanceEnabled()
    }
    let fresh = try await SelectedGuidanceEvidenceRefresh.capture(
      original: source,
      refresh: refresh ?? scopedGuidanceRefresh ?? { [self] original in
        try await refreshGuidanceEvidence(original)
      },
      stillOwned: stillOwned)
    try Task.checkCancellation()
    try requireGuidanceForeground(selectedFrame.foregroundPID)
    guard stillOwned(), captureGate.permits(captureToken, cancelled: Task.isCancelled) else {
      throw CancellationError()
    }
    // A refresh replaces pixels, not the user's selection authorization.
    explicitManualEvidence = ScreenEvidenceIdentity(fresh)
    evidence = fresh
    record("guidance.selectedCapture.refresh.accepted")
    return fresh
  }

  /// Capture only the current active screen for this explicit guidance turn.
  /// Selected file/memory context stays in the UI and is never part of this payload.
  private func captureGuidanceEvidence(
    request: ScreenGuidanceRequest, generation: UInt64, captureToken: UInt64,
    expectedForegroundPID: pid_t?
  ) async throws -> ScreenEvidence {
    try Task.checkCancellation()
    guard request.selectedScope == nil, generation == self.generation,
      activeGuidanceRequest == request,
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
    // Choose the source once before preparation can yield. A later pointer
    // movement cannot silently move this request to another display.
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
        ?? selectedDisplay.flatMap({ screens[$0] == nil ? nil : $0 }),
      let sourceRect = screens[displayID]
    else { throw ProviderError.message("No active display is available for screen guidance.") }
    try monitorGuidanceScene(
      generation: generation, foregroundPID: intendedPID, sourceRect: sourceRect)
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
    selectedCaptureSelectionID = nil
    evidence = frame
    if selectedContext.isEmpty { contextTitle = "Screen: \(frame.foregroundName)" }
    record("guidance.capture.accepted")
    return frame
  }

  /// Active request metadata only. This never captures pixels or expands a
  /// selected region/window. Arm before the first preparation/capture await.
  func monitorGuidanceScene(
    generation: UInt64, foregroundPID: pid_t, sourceRect: CGRect
  ) throws {
    guard generation == self.generation, responsePolicy.route == .screenGuidance,
      busy, foregroundPID != ProcessInfo.processInfo.processIdentifier
    else { throw CancellationError() }
    endGuidanceSceneObservation()
    guard
      let scope = guidanceSceneObserver.arm(
        generation: generation, foregroundPID: foregroundPID, sourceRect: sourceRect)
    else {
      throw ProviderError.message(
        "Screen-change observation is unavailable for this guidance request. Recheck the selected app and screen."
      )
    }
    guidanceSceneScope = scope
    let deadline =
      activeGuidanceRequest?.expires
      ?? ProcessInfo.processInfo.systemUptime + ScreenGuidancePolicy.maximumRequestLifetime
    let delay = max(
      0,
      min(
        ScreenGuidancePolicy.maximumRequestLifetime,
        deadline - ProcessInfo.processInfo.systemUptime))
    guidanceSceneExpiryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, self.guidanceSceneScope == scope else { return }
      self.guidanceSceneDidChange(scope: scope, reason: .expired)
    }
  }

  /// A scene change revokes old inference and marks, while semantic progress
  /// remains resumable. No event is interpreted as successful user action.
  func guidanceSceneDidChange(scope: GuidanceSceneScope, reason: GuidanceSceneChange) {
    guard scope == guidanceSceneScope, scope.generation == generation,
      responsePolicy.route == .screenGuidance
    else { return }
    let selectedCaptureChanged = explicitManualEvidence != nil
    stop()
    invalidatedManualGuidanceScope = selectedCaptureChanged
    explicitManualEvidence = nil
    selectedCaptureSelectionID = nil
    evidence = nil
    if selectedContext.isEmpty {
      contextTitle = selectedCaptureChanged ? "Screen context changed — recapture or remove" : ""
    }
    overlay.clear()
    if selectedCaptureChanged {
      notice =
        "The selected screen context changed. Recapture it or remove screen context to continue."
    } else {
      switch reason {
      case .scroll: notice = "The screen scrolled. Recheck guidance using a fresh screen."
      case .foregroundChanged:
        notice = "The active app changed. Resume guidance for a fresh screen check."
      case .expired: notice = "Guidance screen tracking expired. Resume for a fresh screen check."
      case .displayChanged:
        notice = "The display arrangement changed. Recheck guidance using a fresh screen."
      }
    }
    record("guidance.scene.invalidated.\(reason.rawValue)")
  }

  private func endGuidanceSceneObservation() {
    guidanceSceneExpiryTask?.cancel()
    guidanceSceneExpiryTask = nil
    guidanceSceneScope = nil
    guidanceSceneObserver.disarm()
  }

  var guidanceProgressTitle: String? {
    guard let workflow = guidanceSession.workflow else { return nil }
    let step = workflow.actions.isEmpty ? "Guidance" : "Step \(workflow.actions.count)"
    let status: String
    switch workflow.phase {
    case .ready: status = "Ready to check"
    case .checking: status = "Checking the screen"
    case .awaitingUser: status = "Waiting for you"
    case .loading: status = "Waiting for the page"
    case .paused: status = "Paused"
    case .needsAttention: status = "Needs a fresh check"
    case .modelReportedComplete: status = "Model reports complete"
    case .independentlyVerified: status = "Result verified"
    case .abandoned: status = "Stopped"
    }
    return "\(step) · \(status)"
  }

  var guidanceProgressDetail: String {
    if let error { return String(error.prefix(480)) }
    if let issue = guidanceSession.persistenceIssue { return issue }
    if let notice { return String(notice.prefix(480)) }
    guard let workflow = guidanceSession.workflow else { return "" }
    if workflow.phase == .modelReportedComplete {
      return
        "The model assessed the latest screen. This result has not been independently verified."
    }
    if workflow.phase == .awaitingUser, let action = workflow.currentAction {
      return action.instruction
    }
    return workflow.checks.last?.summary ?? workflow.goal
  }

  var guidanceCanPause: Bool {
    guard let phase = guidanceSession.workflow?.phase else { return false }
    return [.ready, .checking, .awaitingUser, .loading, .needsAttention].contains(phase)
  }
  var guidanceCanResume: Bool {
    guard !busy, !listening, let workflow = guidanceSession.workflow else { return false }
    return workflow.phase == .paused && workflow.canBeginCheck
  }
  var guidanceCanRecheck: Bool {
    guard !busy, !listening, let workflow = guidanceSession.workflow else { return false }
    return [.awaitingUser, .needsAttention, .modelReportedComplete].contains(workflow.phase)
  }

  /// Current selection authority is independent from frame identity: internal
  /// refresh changes pixels, while an explicit replacement rotates this ID.
  func currentSelectedGuidanceScope() throws -> ScreenGuidanceCaptureScope {
    guard let frame = evidence, explicitManualEvidence?.matches(frame) == true,
      let selectionID = selectedCaptureSelectionID
    else {
      throw ProviderError.message("Choose screen context before continuing this guide.")
    }
    return try ScreenGuidanceCaptureScope(evidence: frame, selectionID: selectionID)
  }

  private func ownsSelectedGuidanceScope(_ scope: ScreenGuidanceCaptureScope) -> Bool {
    selectedCaptureSelectionID == scope.selectionID && scope.matches(evidence)
      && explicitManualEvidence?.matches(evidence) == true
  }

  var guidanceHasSelectedScope: Bool { (try? currentSelectedGuidanceScope()) != nil }

  var guidanceRequiresScopeChoice: Bool {
    guard let workflow = guidanceSession.workflow,
      let binding = guidanceWorkflowCapture, binding.workflowID == workflow.id
    else { return true }
    return binding.selectedScope.map { !ownsSelectedGuidanceScope($0) } ?? false
  }

  func pauseGuidance() { stop() }
  func abandonGuidance() {
    stop()
    guidanceSession.abandon()
    guidanceWorkflowCapture = nil
  }
  func resumeGuidance() { restartGuidance(scopeChoice: .retained) }
  func recheckGuidance() { restartGuidance(scopeChoice: .retained) }
  func resumeGuidanceWithSelectedContext() { restartGuidance(scopeChoice: .selected) }
  func resumeGuidanceOnCurrentScreen() { restartGuidance(scopeChoice: .currentScreen) }

  private enum GuidanceResumeScopeChoice { case retained, selected, currentScreen }

  private func restartGuidance(scopeChoice: GuidanceResumeScopeChoice) {
    guard screenGuidanceEnabled(), !busy, !listening,
      let workflow = guidanceSession.workflow,
      workflow.phase != .abandoned && workflow.phase != .independentlyVerified
    else { return }
    let selectedScope: ScreenGuidanceCaptureScope?
    do {
      switch scopeChoice {
      case .currentScreen:
        // This explicit UI action authorizes a new current-screen scope.
        selectedScope = nil
      case .selected:
        selectedScope = try currentSelectedGuidanceScope()
      case .retained:
        guard let binding = guidanceWorkflowCapture, binding.workflowID == workflow.id,
          binding.selectedScope.map(ownsSelectedGuidanceScope) ?? true
        else {
          notice = "Choose the selected area or current screen to resume this guide."
          return
        }
        selectedScope = binding.selectedScope
      }
    } catch {
      showError(error)
      return
    }
    stop()
    guard guidanceSession.workflow?.canBeginCheck == true else {
      notice = "This guide has reached its check limit. Start a new guide for further help."
      return
    }
    // A new request/check always captures fresh pixels. Saved progress carries
    // no scope; only a retained live binding or an explicit scope choice may resume.
    let request = ScreenGuidanceRequest(
      prompt: workflow.goal, step: workflow.checks.count, speakAloud: workflow.speakAloud,
      selectedScope: selectedScope)
    send(
      textOverride:
        "Recheck the current screen and continue this goal using the saved semantic progress. Do not assume any previous instruction succeeded. Original goal: "
        + workflow.goal,
      voiceOnly: true, speakAloud: workflow.speakAloud, guidanceRequest: request,
      transcriptText: "Resume guide", continuingWorkflow: true)
  }

  private func scheduleGuidanceLoadingCheck(token: GuidanceTurnToken, generation: UInt64) {
    guard guidanceSession.owns(token), guidanceSession.workflow?.phase == .loading,
      let request = activeGuidanceRequest, let frame = evidence,
      ScreenGuidancePolicy.permitsContinuation(step: request.step)
    else { return }
    let expectedEvidence = ScreenEvidenceIdentity(frame)
    guidanceLoadingTask?.cancel()
    guidanceLoadingTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
      guard let self, self.generation == generation, self.guidanceSession.owns(token),
        self.guidanceSession.workflow?.phase == .loading
      else { return }
      guard self.activeGuidanceRequest == request, expectedEvidence.matches(self.evidence),
        self.guidanceForegroundPID() == frame.foregroundPID,
        ProcessInfo.processInfo.systemUptime < request.expires, self.screenGuidanceEnabled()
      else {
        self.stop()
        self.notice = "The screen or guide changed while loading. Resume for a fresh check."
        return
      }
      self.guidanceLoadingTask = nil
      let next = ScreenGuidanceRequest(
        id: request.id, prompt: request.prompt, step: request.step + 1,
        expires: request.expires, speakAloud: request.speakAloud,
        selectedScope: request.selectedScope)
      self.record("guidance.loading.freshCheck")
      self.send(
        textOverride:
          "The previous fresh screen showed loading. Check this new capture for settlement; do not repeat the user action or assume success. If it is still loading, say so. Original goal: "
          + request.prompt,
        voiceOnly: true, speakAloud: request.speakAloud, guidanceRequest: next,
        expectedGuidanceForegroundPID: frame.foregroundPID,
        transcriptText: "Check loading page", continuingWorkflow: true)
    }
  }

  /// An observed user click requests fresh perception, never an automatic click
  /// or an assumption that the previous instruction succeeded.
  func beginScreenGuidance(_ prompt: String, speakAloud: Bool = true) {
    guard screenGuidanceEnabled() else { return }
    send(
      textOverride: prompt, voiceOnly: true, speakAloud: speakAloud,
      guidanceRequest: ScreenGuidanceRequest(prompt: prompt, speakAloud: speakAloud))
  }

  func continueScreenGuidance(
    request: ScreenGuidanceRequest, expectedEvidence: ScreenEvidenceIdentity, generation: UInt64,
    observation: ScreenGuidanceContinuationObservation = .click
  ) {
    guard generation == self.generation, activeGuidanceRequest == request,
      ScreenGuidancePolicy.permitsContinuation(step: request.step), request.expires.isFinite,
      ProcessInfo.processInfo.systemUptime < request.expires,
      screenGuidanceEnabled(),
      expectedEvidence.matches(evidence),
      request.selectedScope.map(ownsSelectedGuidanceScope) ?? true
    else { return }
    if let token = guidanceTurnToken, guidanceSession.owns(token) {
      do {
        try guidanceSession.observeAction(
          token: token, kind: observation == .click ? .click : .manualContinue)
      } catch {
        showError(error)
        return
      }
    }
    let next = ScreenGuidanceRequest(
      id: request.id, prompt: request.prompt, step: request.step + 1, expires: request.expires,
      speakAloud: request.speakAloud, selectedScope: request.selectedScope)
    let instruction = guidanceContinuationText(
      request: request, next: next, observation: observation)
    send(
      textOverride: instruction, voiceOnly: true, speakAloud: request.speakAloud,
      guidanceRequest: next,
      expectedGuidanceForegroundPID: expectedEvidence.foregroundPID,
      transcriptText: "Continue", continuingWorkflow: true)
  }

  private func guidanceContinuationText(
    request: ScreenGuidanceRequest, next: ScreenGuidanceRequest,
    observation: ScreenGuidanceContinuationObservation
  ) -> String {
    let observedAction =
      observation == .click
      ? "The user clicked the highlighted control. This is not proof that the click succeeded."
      : "The user requested Continue after a manual step. This requests a fresh check; it is not proof that any typing, dragging or other action happened or succeeded."
    return """
      \(observedAction) Inspect the new screen capture to verify what changed. If that revealed a menu or sidebar, guide its next distinct nested control rather than repeating the opener. Continue the original functional goal using actual current app labels, even if the user named the app colloquially. Copy candidate IDs only from this fresh frame. If the task is complete, say so without another target. If progress is unclear, explain the ambiguity rather than invent a control.
      Original task: \(request.prompt)
      Guidance step: \(next.step)
      """
  }
  private func acceptTextPreview(_ preview: ProviderTextPreview, generation: UInt64) async throws {
    guard generation == self.generation else { throw CancellationError() }
    if let scope = activeGuidanceRequest?.selectedScope, !ownsSelectedGuidanceScope(scope) {
      throw CancellationError()
    }
    // A standalone explanation owns its complete semantic captions. Previewing
    // future narration here would reveal it before its visual/speech beat.
    guard !explanationPlaybackEnabled else { return }
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
    if let scope = activeGuidanceRequest?.selectedScope, !ownsSelectedGuidanceScope(scope) {
      throw CancellationError()
    }
    switch unit.type {
    case "guidanceStatus":
      guard responsePolicy.route == .screenGuidance, !guidanceStatusReceived,
        let assessment = unit.guidance,
        !assessment.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        assessment.summary.utf8.count <= 2_048
      else {
        throw ProviderError.message("Invalid or duplicate screen-guidance assessment.")
      }
      guard let evidence, let expectedEvidence, expectedEvidence.matches(evidence),
        ProcessInfo.processInfo.systemUptime >= evidence.capturedAt,
        ProcessInfo.processInfo.systemUptime - evidence.capturedAt
          < ScreenGuidancePolicy.admissionEvidenceAge
      else {
        throw ProviderError.message(
          "The guidance assessment used a changed screen. Recheck the current screen.")
      }
      try requireGuidanceForeground(evidence.foregroundPID)
      guidanceStatusReceived = true
      if let token = guidanceTurnToken, guidanceSession.owns(token) {
        let outcome: GuidanceWorkflow.AssessmentOutcome
        switch assessment.status {
        case .progress: outcome = .progress
        case .unchanged: outcome = .unchanged
        case .loading: outcome = .loading
        case .uncertain: outcome = .uncertain
        case .complete: outcome = .goalComplete
        }
        try guidanceSession.assess(token: token, outcome: outcome, summary: assessment.summary)
        record("guidance.assessment.\(assessment.status.rawValue)")
      }
    case "text":
      guard let text = unit.text, text.utf8.count <= 32000 else {
        throw ProviderError.message("Invalid text unit.")
      }
      if explanationPlaybackEnabled {
        try explanationPlayback.checkCapacity(document: nil, narration: text)
      }
      messages.append(ChatLine(role: "assistant", text: text))
      if responsePolicy.route == .screenGuidance { guidanceNarration = text }
      record("semantic.text.accepted")
      if explanationPlaybackEnabled {
        try explanationPlayback.enqueue(document: nil, narration: text)
      } else {
        speakNarration(text)
      }
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
      if let narration = unit.narration, narration.utf8.count > 32_000 {
        throw ProviderError.message("Oversized scene narration.")
      }
      if explanationPlaybackEnabled {
        try explanationPlayback.checkCapacity(
          document: document, narration: unit.narration, focusID: unit.focusID)
      }
      snapshotUndo()
      committingExplanationScene = true
      scene = document
      committingExplanationScene = false
      explanationCanonicalTip = document
      self.outputSceneBinding = NotebookTurnBinding(
        documentID: document.id, revision: document.revision)
      outputSceneIncludesExistingNotebook = true
      section = "Notebook"
      if explanationPlaybackEnabled {
        // Saving and revision checks always use the canonical document. Only
        // the native floating surface consumes these ordered snapshots.
        try explanationPlayback.enqueue(
          document: document, narration: unit.narration, focusID: unit.focusID)
      } else {
        explanationPresentation = nil
        if !scenePresentedForTurn {
          scenePresentedForTurn = true
          onSceneReady?()
        }
      }
      if let narration = unit.narration, !narration.isEmpty {
        messages.append(ChatLine(role: "assistant", text: narration))
        if !explanationPlaybackEnabled { speakNarration(narration) }
      }
      record("visual.accepted")
    case "target":
      guard responsePolicy.route == .screenGuidance else {
        record("guidance.suppressed.responsePolicy")
        return
      }
      setGuidanceStage(.target, generation: generation)
      guard let payload = unit.target, payload.instruction.utf8.count <= 32_000,
        payload.awaitUser != true || payload.advanceOn == "manual",
        (payload.label?.prefix(81).count ?? 0) <= 80
      else { throw ProviderError.message("Invalid or oversized screen guidance target.") }
      guard let evidence, let expectedEvidence, expectedEvidence.matches(evidence)
      else {
        throw ProviderError.message(
          "The selected screen evidence changed. Capture again before requesting guidance.")
      }
      let resolved = try evidence.resolvingTarget(payload)
      let target = GuidanceTargetPresentation.styled(resolved)
      let cursorPreferences = CursorCompanionPreferences.load()
      if let request = activeGuidanceRequest {
        guard cursorPreferences.screenGuidanceEnabled,
          ProcessInfo.processInfo.systemUptime < request.expires
        else { throw CancellationError() }
      }
      let primaryAction =
        target.advanceOn == "click"
        || (target.advanceOn == "manual" && target.awaitUser == true)
      if primaryAction, let token = guidanceTurnToken, guidanceSession.owns(token),
        let workflow = guidanceSession.workflow
      {
        guard workflow.actions.count < GuidanceWorkflow.maximumActions,
          workflow.checks.count < GuidanceWorkflow.maximumChecks,
          workflow.currentAction?.checkID != token.checkID
        else {
          throw ProviderError.message(
            "This guide reached its action/check limit or emitted a second action. Start a new guide to continue."
          )
        }
      }
      if primaryAction, let token = guidanceTurnToken, guidanceSession.owns(token) {
        try guidanceSession.validateAction(
          token: token, instruction: String(target.instruction.prefix(480)),
          label: target.label, kind: target.advanceOn == "click" ? .click : .manual)
      }
      try overlay.validate(target: target, evidence: evidence)
      let introDelay = onCursorTargetAccepted?(generation, target, evidence) ?? 0
      try overlay.show(
        target: target, evidence: evidence,
        showInstruction: true,
        append: true, introDelay: introDelay, ownerGeneration: generation)
      acceptedGuidanceTarget = true
      if let request = activeGuidanceRequest, cursorPreferences.screenGuidanceEnabled,
        ProcessInfo.processInfo.systemUptime < request.expires
      {
        onScreenGuidanceTargetAccepted?(target, evidence, generation, request)
      }
      if primaryAction, let token = guidanceTurnToken, guidanceSession.owns(token) {
        try guidanceSession.presentAction(
          token: token, instruction: String(target.instruction.prefix(480)),
          label: target.label, kind: target.advanceOn == "click" ? .click : .manual)
      }
      messages.append(ChatLine(role: "assistant", text: target.instruction))
      speakNarration(target.instruction)
      record("guidance.presented.awaitingUser")
      setGuidanceStage(.provider, generation: generation)
    default: throw ProviderError.message("Unsupported model output kind: \(unit.type)")
    }
  }
  private func speakNarration(_ text: String) {
    guard configuration.speechEnabled || turnSpeaksAloud, narrationGate.allows(text) else { return }
    if voice.speak(text) { _ = narrationGate.admit(text) }
  }

  func acknowledgeExplanationRenderSubmitted(_ presentation: ExplanationPresentation) {
    guard explanationPlaybackEnabled, presentation == explanationPresentation,
      presentation.generation == generation, scene == explanationCanonicalTip
    else { return }
    if explanationRenderWaitID == presentation.beatID {
      explanationRenderWait?.cancel()
      explanationRenderWait = nil
      explanationRenderWaitID = nil
    }
    if explanationPlayback.acknowledgeRenderSubmitted(
      beatID: presentation.beatID, generation: presentation.generation,
      documentID: presentation.document.id, revision: presentation.document.revision)
    {
      record("explanation.visual.renderSubmitted")
    }
  }

  private func startExplanationNarration(context: VoiceNarrationContext, text: String) {
    guard explanationPlaybackEnabled, context.generation == generation,
      scene == explanationCanonicalTip
    else { return }
    currentExplanationNarration = (context, text)
    let useSpeech = (configuration.speechEnabled || turnSpeaksAloud) && narrationGate.allows(text)
    if useSpeech { _ = onNarrationCaptionStarted?(text, context, true) }
    guard explanationPlaybackEnabled, context.generation == generation,
      currentExplanationNarration?.context == context
    else { return }
    if useSpeech { beginExplanationFocus(context: context) }
    guard explanationPlaybackEnabled, context.generation == generation,
      currentExplanationNarration?.context == context
    else { return }
    if useSpeech, voice.speak(text, context: context) {
      guard explanationPlaybackEnabled, context.generation == generation,
        currentExplanationNarration?.context == context
      else { return }
      _ = narrationGate.admit(text)
      record("explanation.narration.enqueued")
      return
    }
    // Voice off, deduplicated or declined: the local word reveal is an explicit
    // completion clock. It never impersonates AVSpeech playback progress.
    startExplanationTextFallback(context: context, text: text)
  }

  private func startExplanationTextFallback(context: VoiceNarrationContext, text: String) {
    guard currentExplanationNarration?.context == context, context.generation == generation,
      explanationPlaybackEnabled
    else { return }
    record("explanation.narration.textFallback")
    let captionAvailable = onNarrationCaptionStarted?(text, context, false) == true
    beginExplanationFocus(context: context)
    if !captionAvailable {
      completeExplanationCaption(context: context)
    }
  }

  private func beginExplanationFocus(context: VoiceNarrationContext) {
    guard explanationPlaybackEnabled, currentExplanationNarration?.context == context,
      let presentation = explanationPresentation, presentation.beatID == context.narrationID,
      presentation.generation == context.generation, presentation.focusID != nil
    else { return }
    onExplanationFocusStarted?(context, presentation)
  }

  func explanationFocusIsCurrent(_ authority: SceneFocusAuthority) -> Bool {
    guard explanationPlaybackEnabled, generation == authority.generation,
      currentExplanationNarration?.context.narrationID == authority.beatID,
      explanationPresentation?.beatID == authority.beatID,
      explanationPresentation?.focusID == authority.focusID,
      let document = explanationDisplayDocument
    else { return false }
    return authority.matches(document: document)
  }

  private func acceptNarrationUpdate(_ update: VoiceUtteranceUpdate) {
    guard explanationPlaybackEnabled, update.context.generation == generation,
      let current = currentExplanationNarration, current.context == update.context,
      scene == explanationCanonicalTip
    else { return }
    onExplanationNarrationEvent?(update)
    guard explanationPlaybackEnabled, update.context.generation == generation,
      currentExplanationNarration?.context == update.context
    else { return }
    onNarrationCaptionUpdate?(update)
    switch update.kind {
    case .finished:
      record("explanation.narration.engineFinished")
      onNarrationCaptionFinished?(update.context)
      completeExplanationCaption(context: update.context)
    case .cancelled:
      // Host Stop already revoked the context. An unexpected engine cancellation
      // has a visible, paced fallback rather than silently skipping the beat.
      startExplanationTextFallback(context: update.context, text: current.text)
    case .started: record("explanation.narration.engineStarted")
    case .range: record("explanation.narration.wordProgress")
    case .enqueued: break
    }
  }

  func completeExplanationCaption(context: VoiceNarrationContext) {
    guard explanationPlaybackEnabled, context.generation == generation,
      currentExplanationNarration?.context == context, scene == explanationCanonicalTip
    else { return }
    onExplanationFocusEnded?(context)
    guard explanationPlaybackEnabled, context.generation == generation,
      currentExplanationNarration?.context == context
    else { return }
    currentExplanationNarration = nil
    _ = explanationPlayback.completeNarration(context: context)
  }

  /// Called when the user explicitly chooses an editor. The accepted canonical
  /// scene remains editable; unreleased presentation and speech lose ownership.
  func endExplanationPlaybackForEditing() {
    if explanationPlaybackEnabled { stop() }
    explanationPresentation = nil
  }

  func explanationSurfaceBecameUnavailable(documentID: String) {
    guard explanationPlaybackEnabled, scenePresentedForTurn,
      explanationPresentation?.document.id == documentID
    else { return }
    stop()
    record("explanation.surface.unavailable")
  }

  private func cancelExplanationPlayback(stopSpeech: Bool) {
    let owned = explanationPlaybackEnabled
    let endedFocus = currentExplanationNarration?.context
    explanationPlaybackEnabled = false
    currentExplanationNarration = nil
    explanationRenderWait?.cancel()
    explanationRenderWait = nil
    explanationRenderWaitID = nil
    explanationPlayback.invalidate()
    if owned {
      outputSceneBinding = nil
      if stopSpeech {
        onCursorCancelled?(generation)
        voice.stop()
      }
    }
    if let endedFocus { onExplanationFocusEnded?(endedFocus) }
  }

  func stop() {
    guidanceSession.pause()
    cancelActiveTurn()
  }

  private func cancelActiveTurn() {
    endGuidanceSceneObservation()
    guidanceLoadingTask?.cancel()
    guidanceLoadingTask = nil
    guidanceTurnToken = nil
    generation += 1
    cancelExplanationPlayback(stopSpeech: false)
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
    voiceGuidanceContinuation = nil
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
    let manualStep = mode == .pushToTalk ? onManualGuidanceVoiceStart?() : nil
    let manualWorkflowToken = manualStep == nil ? nil : guidanceTurnToken
    if manualStep != nil {
      cancelActiveTurn()
      // Only semantic progress is retained. The existing voice handoff still
      // validates the exact original frame, generation, foreground and lease.
      guidanceTurnToken = manualWorkflowToken
    } else {
      stop()
    }
    if let manualStep {
      voiceGuidanceContinuation = ManualGuidanceVoiceContinuation(
        step: manualStep, inputGeneration: generation)
    }
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
    let continuation = voiceGuidanceContinuation
    voiceGuidanceContinuation = nil
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
      if let continuation,
        continueManualGuidanceVoice(
          continuation, transcript: completion.transcript,
          foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
          now: ProcessInfo.processInfo.systemUptime)
      {
        return
      }
      // Keep the typed draft and ordinary conversation. Screen help uses one
      // fresh capture; ordinary voice questions omit selected file/memory/image evidence.
      send(
        textOverride: completion.transcript, voiceOnly: true, speakAloud: true)
    } else {
      notice = "Transcript ready. Review the draft and send when ready."
      updateBadge()
    }
  }

  /// Returns true when an exact spoken continuation was handled, including a
  /// disabled/stale refusal. Such a refusal must never become a new chat turn.
  @discardableResult func continueManualGuidanceVoice(
    _ continuation: ManualGuidanceVoiceContinuation, transcript: String,
    foregroundPID: pid_t?, now: TimeInterval
  ) -> Bool {
    guard ManualGuidanceVoiceContinuation.isContinueCommand(transcript) else { return false }
    guard screenGuidanceEnabled() else {
      notice = "Screen guidance is disabled. Enable it before continuing this guide."
      voiceNotice = notice
      updateBadge()
      return true
    }
    guard
      let next = continuation.nextRequest(
        transcript: transcript, generation: generation, evidence: evidence,
        foregroundPID: foregroundPID, now: now)
    else {
      notice = "That guidance step changed or expired. Ask for a fresh guide on this screen."
      voiceNotice = notice
      updateBadge()
      return true
    }

    guard next.selectedScope.map(ownsSelectedGuidanceScope) ?? true else {
      notice = "The selected area changed. Choose a screen before continuing this guide."
      voiceNotice = notice
      return true
    }
    if let token = guidanceTurnToken, guidanceSession.owns(token) {
      do { try guidanceSession.observeAction(token: token, kind: .manualContinue) } catch {
        showError(error)
        return true
      }
    }
    record("guidance.voiceContinue.requested")
    send(
      textOverride: guidanceContinuationText(
        request: continuation.step.request, next: next, observation: .explicitContinue),
      voiceOnly: true, speakAloud: next.speakAloud, guidanceRequest: next,
      expectedGuidanceForegroundPID: continuation.step.evidence.foregroundPID,
      transcriptText: transcript, continuingWorkflow: true)
    return true
  }
  private func invalidateCapture() {
    captureGate.invalidate()
    captureTask?.cancel()
    captureTask = nil
  }
  /// Display rearrangement changes the coordinate authority even if an older
  /// screenshot is young and its former foreground application is still active.
  func invalidateScreenEvidence() {
    if let scope = guidanceSceneScope {
      guidanceSceneDidChange(scope: scope, reason: .displayChanged)
      record("capture.displayTopologyInvalidated")
      return
    }
    invalidateCapture()
    explicitManualEvidence = nil
    selectedCaptureSelectionID = nil
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
    if activeGuidanceRequest?.selectedScope != nil
      || voiceGuidanceContinuation?.step.request.selectedScope != nil
    {
      stop()
    }
    invalidatedManualGuidanceScope = false
    invalidateCapture()
    explicitManualEvidence = nil
    selectedCaptureSelectionID = nil
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
        guard publishSelectedCapture(frame, token: token, strokes: strokes) else { return }
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
  /// Single publication boundary for the host's explicit capture result. A
  /// cancelled or replaced selection cannot restore old screen authority.
  @discardableResult func publishSelectedCapture(
    _ frame: ScreenEvidence, token: UInt64, strokes: String = ""
  ) -> Bool {
    guard captureGate.permits(token, cancelled: Task.isCancelled) else { return false }
    explicitManualEvidence = ScreenEvidenceIdentity(frame)
    selectedCaptureSelectionID = UUID()
    invalidatedManualGuidanceScope = false
    evidence = frame
    if !strokes.isEmpty {
      selectedContext = "User-drawn spatial context (normalized top-left points): " + strokes
    }
    if selectedContext.isEmpty { contextTitle = "Screen: \(frame.foregroundName)" }
    return true
  }
  func clearContext() {
    invalidatedManualGuidanceScope = false
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
  @discardableResult func openRecord(_ record: StoredRecord) -> Task<Void, Never>? {
    if record.kind == "guidance" {
      newConversation()
      let expectedGeneration = generation
      return Task {
        do {
          try await guidanceSession.restore(
            record: record,
            stillCurrent: { [weak self] in
              self?.generation == expectedGeneration
            })
          guard generation == expectedGeneration else { return }
          section = "Companion"
          onOpen?()
        } catch {
          guard generation == expectedGeneration, !(error is CancellationError) else { return }
          showError(error)
        }
      }
    }
    if record.kind == "conversation" {
      newConversation()
      let expectedGeneration = generation
      let emptyConversationID = conversationID
      return Task {
        do {
          // Library rows are snapshots. Read the latest payload and reject a
          // deleted item instead of restoring transcript bytes from a stale row.
          var latest = record
          if let store { latest = try await store.record(id: record.id) }
          try Task.checkCancellation()
          guard generation == expectedGeneration, conversationID == emptyConversationID else {
            return
          }
          guard latest.kind == "conversation", let data = latest.payload else {
            throw StoreError.invalidValue("The saved conversation has no readable transcript.")
          }
          let lines = try JSONDecoder().decode([ChatLine].self, from: data)
          conversationID = latest.id
          messages = lines
          section = "Companion"
        } catch {
          guard generation == expectedGeneration, conversationID == emptyConversationID,
            !(error is CancellationError)
          else { return }
          showError(error)
        }
      }
    }
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
    } else {
      memoryTitle = record.title
      memoryBody = record.body
      section = "Memory"
    }
    return nil
  }
  @discardableResult func deleteRecord(_ id: String) -> Task<Void, Never>? {
    guard let store else { return nil }
    if records.contains(where: { $0.id == id && $0.kind == "guidance" })
      || guidanceSession.workflow?.id.uuidString == id
    {
      if guidanceSession.workflow?.id.uuidString == id {
        stop()
        guidanceWorkflowCapture = nil
      }
      return Task {
        do {
          try await guidanceSession.delete(id: id)
          await reload()
        } catch { showError(error) }
      }
    }
    let isConversation =
      id == conversationID || records.contains(where: { $0.id == id && $0.kind == "conversation" })
    // Detach the active transcript before yielding. Any already queued save is
    // either removed by this deletion or rejected by its durable tombstone.
    if id == conversationID { newConversation() }
    return Task {
      do {
        if isConversation {
          try await store.deleteConversation(id: id)
        } else {
          try await store.deleteRecord(id: id)
        }
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
    guard let store, !messages.isEmpty else { return }
    // Capture one immutable transcript before the actor hop. Reopening another
    // conversation while this save completes cannot change its destination ID.
    let id = conversationID
    let lines = messages
    do {
      let saved = try await store.saveConversation(
        id: id, title: String(lines.first?.text.prefix(90) ?? "Conversation"),
        body: lines.map(\.text).joined(separator: "\n"), payload: JSONEncoder().encode(lines))
      if saved == nil, conversationID == id {
        notice = "This conversation was deleted. Start a new chat to save another conversation."
      }
      await reload()
    } catch {
      if conversationID == id { showError(error) }
    }
  }

  /// A new chat has a new persistence identity. Independent notebook content
  /// remains available, while the previous chat's attachments lose authority.
  func newConversation() {
    stop()
    guidanceSession.detach()
    guidanceWorkflowCapture = nil
    clearContext()
    conversationID = UUID().uuidString
    messages = []
    input = ""
    error = nil
    notice = nil
    section = "Companion"
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
