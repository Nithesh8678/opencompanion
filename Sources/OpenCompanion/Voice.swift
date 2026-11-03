import AVFoundation
import Foundation
import Speech

struct VoiceRecognitionUpdate: Sendable {
  let text: String?
  let final: Bool
  let errorMessage: String?
}

enum VoiceSpeechEvent: Sendable { case started, finished, cancelled }

/// The only unchecked conformance is this bounded value map. Every access is
/// protected by its lock; neither framework objects nor service state enter it.
final class VoiceUtteranceTokens: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ObjectIdentifier: UUID] = [:]

  func insert(_ id: ObjectIdentifier) -> UUID? {
    lock.withLock {
      guard values.count < 24 else { return nil }
      let token = UUID()
      values[id] = token
      return token
    }
  }
  func token(for id: ObjectIdentifier) -> UUID? { lock.withLock { values[id] } }
  func matches(_ id: ObjectIdentifier, token: UUID) -> Bool {
    lock.withLock { values[id] == token }
  }
  @discardableResult func remove(_ id: ObjectIdentifier, token: UUID) -> Bool {
    lock.withLock {
      guard values[id] == token else { return false }
      values.removeValue(forKey: id)
      return true
    }
  }
  func removeAll() { lock.withLock { values.removeAll() } }
}

@MainActor final class VoiceService: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var recognition: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognizer: SFSpeechRecognizer?
  private var input = VoiceInputStateMachine()
  private var tailTask: Task<Void, Never>?
  private var utterances = Set<ObjectIdentifier>()
  private nonisolated let utteranceTokens = VoiceUtteranceTokens()
  var onInputState: ((VoiceInputSnapshot) -> Void)?
  var onTranscript: ((UUID, VoiceInputMode, String, Bool) -> Void)?
  var onInputCompletion: ((VoiceInputCompletion) -> Void)?
  var onInputError: ((UUID, Error) -> Void)?
  var onInputNotice: ((UUID, String) -> Void)?
  var onState: ((String) -> Void)?
  var onSpeechEvent: ((String) -> Void)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String) {
    guard !text.isEmpty, utterances.count < 24 else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    let id = ObjectIdentifier(utterance)
    guard utteranceTokens.insert(id) != nil else { return }
    utterances.insert(id)
    synthesizer.speak(utterance)
  }

  func stop() {
    utteranceTokens.removeAll()
    utterances.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    cancelInput()
    onState?("Ready")
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
  ) {
    forwardSpeechEvent(.started, utteranceID: ObjectIdentifier(utterance))
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    forwardSpeechEvent(.finished, utteranceID: ObjectIdentifier(utterance))
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    forwardSpeechEvent(.cancelled, utteranceID: ObjectIdentifier(utterance))
  }

  private nonisolated func forwardSpeechEvent(
    _ event: VoiceSpeechEvent, utteranceID: ObjectIdentifier
  ) {
    // Resolve while the delegate's utterance argument is still alive. A queued
    // event cannot match a later object which happens to reuse that address.
    guard let token = utteranceTokens.token(for: utteranceID) else { return }
    Self.deliverSpeechEvent(event, utteranceID: utteranceID) { [weak self] id, event in
      self?.acceptSpeechEvent(event, utteranceID: id, token: token)
    }
  }

  private func acceptSpeechEvent(
    _ event: VoiceSpeechEvent, utteranceID: ObjectIdentifier, token: UUID
  ) {
    switch event {
    case .started:
      guard utteranceTokens.matches(utteranceID, token: token), utterances.contains(utteranceID)
      else { return }
      onState?("Speaking")
      onSpeechEvent?("audio.synthesizerDidStart")
    case .finished, .cancelled:
      guard utteranceTokens.remove(utteranceID, token: token), utterances.remove(utteranceID) != nil
      else { return }
      onSpeechEvent?(
        event == .finished ? "audio.synthesizerDidFinish" : "audio.synthesizerDidCancel")
      if utterances.isEmpty && !input.snapshot.phase.isActive { onState?("Ready") }
    }
  }

  /// SDK completion blocks are not actor-isolated, even when requested by UI.
  /// CheckedContinuation.resume is thread safe; no service state is touched here.
  nonisolated static func speechAuthorization(
    using request:
      @Sendable (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
  ) async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      request { @Sendable status in continuation.resume(returning: status) }
    }
  }

  nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await speechAuthorization { @Sendable completion in
      SFSpeechRecognizer.requestAuthorization(completion)
    }
  }

  /// Only immutable Swift values cross from the framework callback to MainActor.
  nonisolated static func recognitionHandler(
    receive: @escaping @MainActor @Sendable (VoiceRecognitionUpdate) -> Void
  ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
    { @Sendable result, error in
      let update = VoiceRecognitionUpdate(
        text: result?.bestTranscription.formattedString, final: result?.isFinal ?? false,
        errorMessage: error?.localizedDescription)
      Task { @MainActor in receive(update) }
    }
  }

  /// Constructed outside MainActor so entry on AVAudioEngine's audio thread
  /// cannot assert actor isolation. Append stays on that thread: no UI work,
  /// Task creation, copying, logging or crossing of audio buffers is performed.
  nonisolated private static func audioTap(
    request: SFSpeechAudioBufferRecognitionRequest
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in request.append(buffer) }
  }

  nonisolated static func deliverSpeechEvent(
    _ event: VoiceSpeechEvent, utteranceID: ObjectIdentifier,
    receive: @escaping @MainActor @Sendable (ObjectIdentifier, VoiceSpeechEvent) -> Void
  ) {
    Task { @MainActor in receive(utteranceID, event) }
  }

  /// Synchronous setup closes the keyDown -> scheduled Task race. Async startup
  /// never creates a new session and cannot revive a released/cancelled one.
  func beginInput(id: UUID, mode: VoiceInputMode) {
    cancelInput()
    input.begin(id: id, mode: mode)
    publishInputState()
  }

  func startListening(id: UUID) async throws {
    do {
      try requirePreparing(id)
      let mic = await AVCaptureDevice.requestAccess(for: .audio)
      try requirePreparing(id)
      guard mic else {
        throw ProviderError.message(
          "Allow Microphone access for OpenCompanion in System Settings → Privacy & Security → Microphone, then hold Control+Option again. Text input remains available."
        )
      }
      let authorization = await Self.speechAuthorization()
      try requirePreparing(id)
      guard authorization == .authorized else {
        throw ProviderError.message(
          "Allow Speech Recognition for OpenCompanion in System Settings → Privacy & Security → Speech Recognition, then try voice again. Text input remains available."
        )
      }
      let locale = Locale(
        identifier: UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US")
      guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
        throw ProviderError.message(
          "Speech recognition is unavailable for this language or network. Try again or use text input."
        )
      }
      try requirePreparing(id)
      self.recognizer = recognizer
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
      self.request = request
      let engine = AVAudioEngine()
      self.engine = engine
      let format = engine.inputNode.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw ProviderError.message(
          "No usable microphone route is available. Select a microphone in System Settings → Sound → Input."
        )
      }
      engine.inputNode.installTap(
        onBus: 0, bufferSize: 1024, format: format, block: Self.audioTap(request: request))
      tapInstalled = true
      recognition = recognizer.recognitionTask(
        with: request,
        resultHandler: Self.recognitionHandler { [weak self] update in
          guard let self, self.input.isActive(id: id) else { return }
          if let transcript = update.text {
            self.acceptTranscript(id: id, text: transcript, final: update.final)
          }
          if let message = update.errorMessage, self.input.isActive(id: id),
            self.input.snapshot.phase != .awaitingRelease
          {
            self.failInput(
              id: id,
              error: ProviderError.message(
                "Speech input was interrupted: \(message). Try holding Control+Option again, or use text input."
              ))
          }
        })
      engine.prepare()
      try engine.start()
      guard input.microphoneReady(id: id) else { throw CancellationError() }
      onSpeechEvent?("voice.microphoneReady")
      publishInputState()
    } catch {
      if input.isActive(id: id), !(error is CancellationError) { failInput(id: id, error: error) }
      throw error
    }
  }

  func finishListening(id: UUID) {
    let effect = input.finish(id: id)
    if effect == .finishAudio {
      stopAudioCapture()
      request?.endAudio()
      onSpeechEvent?("voice.captureEnded")
      scheduleTailDeadline(id: id)
    } else if effect == .cancelledBeforeReady {
      cleanupRecognition()
      onInputNotice?(
        id,
        "The microphone was not ready before release. Grant any requested permissions, then start voice again."
      )
    }
    publishInputState()
    handle(effect)
  }

  func cancelInput() {
    input.cancel()
    tailTask?.cancel()
    tailTask = nil
    cleanupRecognition()
    publishInputState()
  }

  private func requirePreparing(_ id: UUID) throws {
    try Task.checkCancellation()
    guard input.canStart(id: id) else { throw CancellationError() }
  }

  private func acceptTranscript(id: UUID, text: String, final: Bool) {
    guard input.isActive(id: id), input.snapshot.phase.acceptsRecognition,
      let mode = input.snapshot.mode
    else { return }
    let effect = input.recognize(id: id, text: text, final: final)
    onTranscript?(id, mode, input.snapshot.transcript, final)
    if final { cleanupRecognition() }
    publishInputState()
    handle(effect)
  }

  private func scheduleTailDeadline(id: UUID) {
    tailTask?.cancel()
    tailTask = Task { @MainActor [weak self] in
      // No fixed silence delay: a final callback completes immediately. This is
      // only the upper bound for the recognizer's already captured tail.
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      guard let self, !Task.isCancelled, self.input.isActive(id: id),
        self.input.snapshot.phase == .finishing
      else { return }
      let effect = self.input.tailDeadline(id: id)
      self.cleanupRecognition()
      self.publishInputState()
      self.handle(effect)
    }
  }

  private func handle(_ effect: VoiceInputEffect) {
    guard case .completed(let completion) = effect else { return }
    tailTask?.cancel()
    tailTask = nil
    cleanupRecognition()
    onInputCompletion?(completion)
  }

  private func failInput(id: UUID, error: Error) {
    guard input.fail(id: id) else { return }
    tailTask?.cancel()
    tailTask = nil
    cleanupRecognition()
    publishInputState()
    onInputError?(id, error)
  }

  private func publishInputState() { onInputState?(input.snapshot) }

  private func stopAudioCapture() {
    engine?.stop()
    if tapInstalled {
      engine?.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine = nil
  }

  private func cleanupRecognition() {
    stopAudioCapture()
    request?.endAudio()
    request = nil
    recognition?.cancel()
    recognition = nil
    recognizer = nil
  }
}
