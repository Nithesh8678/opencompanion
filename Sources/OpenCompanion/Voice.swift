import AVFoundation
import Foundation
import Speech

struct VoiceRecognitionUpdate: Sendable {
  let text: String?
  let final: Bool
  let errorMessage: String?
}

enum VoiceSpeechEvent: Sendable { case started, finished, cancelled }

/// A bounded estimate for activity presentation, not a calibrated sound meter.
/// At most two channels and 2,048 samples are read from any input buffer.
enum MicrophoneRMS {
  static let maximumSamples = 2_048

  static func calculate(
    frameCount: Int, channelCount: Int, sampleAt: (Int, Int) -> Double
  ) -> Double {
    guard frameCount > 0, channelCount > 0 else { return 0 }
    let channels = min(2, channelCount)
    let maximumFrames = maximumSamples / channels
    let step = 1 + (frameCount - 1) / maximumFrames
    var frame = 0
    var count = 0
    var sum = 0.0
    while frame < frameCount && count < maximumSamples {
      for channel in 0..<channels where count < maximumSamples {
        let raw = sampleAt(frame, channel)
        let value = raw.isFinite ? min(1, max(-1, raw)) : 0
        sum += value * value
        count += 1
      }
      guard frameCount - frame > step else { break }
      frame += step
    }
    return count > 0 ? sqrt(sum / Double(count)) : 0
  }

  static func measure(_ buffer: AVAudioPCMBuffer) -> Double {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    let stride = max(1, Int(buffer.stride))
    let interleaved = buffer.format.isInterleaved
    if let data = buffer.floatChannelData {
      return calculate(frameCount: frames, channelCount: channels) { frame, channel in
        Double(data[interleaved ? 0 : channel][frame * stride + (interleaved ? channel : 0)])
      }
    }
    if let data = buffer.int16ChannelData {
      return calculate(frameCount: frames, channelCount: channels) { frame, channel in
        Double(data[interleaved ? 0 : channel][frame * stride + (interleaved ? channel : 0)])
          / 32_768
      }
    }
    if let data = buffer.int32ChannelData {
      return calculate(frameCount: frames, channelCount: channels) { frame, channel in
        Double(data[interleaved ? 0 : channel][frame * stride + (interleaved ? channel : 0)])
          / 2_147_483_648
      }
    }
    return 0
  }
}

struct MicrophoneLevelEnvelope: Sendable {
  private(set) var level = 0.0

  mutating func advance(rms: Double, elapsed: TimeInterval) -> Double {
    let bounded = rms.isFinite ? min(1, max(0, rms)) : 0
    let target = bounded > 0 ? min(1, max(0, (20 * log10(bounded) + 60) / 54)) : 0
    let interval = elapsed.isFinite ? min(0.25, max(0, elapsed)) : 0
    let timeConstant = target > level ? 0.025 : 0.14
    level += (target - level) * (1 - exp(-interval / timeConstant))
    level = level < 0.001 ? 0 : min(1, max(0, level))
    return level
  }

  mutating func reset() { level = 0 }
}

/// One coalesced scalar, never an audio buffer. The audio thread never waits:
/// a contended sample is dropped and a later buffer can publish a newer peak.
final class MicrophoneLevelMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var peak = 0.0

  func publish(rms: Double) {
    guard rms.isFinite, lock.try() else { return }
    peak = max(peak, min(1, max(0, rms)))
    lock.unlock()
  }

  func consumePeak() -> Double {
    lock.withLock {
      let value = peak
      peak = 0
      return value
    }
  }
}

private final class VoiceMicrophoneLevelSession {
  let id: UUID
  let mailbox: MicrophoneLevelMailbox
  var envelope = MicrophoneLevelEnvelope()
  var lastTick = ProcessInfo.processInfo.systemUptime
  var timer: Timer?

  init(id: UUID, mailbox: MicrophoneLevelMailbox) {
    self.id = id
    self.mailbox = mailbox
  }
  deinit { timer?.invalidate() }
}

/// This unchecked conformance covers only a bounded value map. Every access is
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
  private var microphoneLevelSession: VoiceMicrophoneLevelSession?
  private var utterances = Set<ObjectIdentifier>()
  var hasPendingSpeech: Bool { !utterances.isEmpty }
  private nonisolated let utteranceTokens = VoiceUtteranceTokens()
  var onInputState: ((VoiceInputSnapshot) -> Void)?
  var onTranscript: ((UUID, VoiceInputMode, String, Bool) -> Void)?
  var onInputCompletion: ((VoiceInputCompletion) -> Void)?
  var onInputError: ((UUID, Error) -> Void)?
  var onInputNotice: ((UUID, String) -> Void)?
  var onInputLevel: ((UUID, Double) -> Void)?
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
  /// Meter work is bounded and only a coalesced scalar leaves the callback.
  nonisolated private static func audioTap(
    request: SFSpeechAudioBufferRecognitionRequest, levels: MicrophoneLevelMailbox
  ) -> AVAudioNodeTapBlock {
    { buffer, _ in
      request.append(buffer)
      levels.publish(rms: MicrophoneRMS.measure(buffer))
    }
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
    onInputLevel?(id, 0)
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
      let levels = MicrophoneLevelMailbox()
      engine.inputNode.installTap(
        onBus: 0, bufferSize: 1024, format: format,
        block: Self.audioTap(request: request, levels: levels))
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
      startMicrophoneLevels(id: id, mailbox: levels)
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

  private func startMicrophoneLevels(id: UUID, mailbox: MicrophoneLevelMailbox) {
    stopMicrophoneLevels()
    let session = VoiceMicrophoneLevelSession(id: id, mailbox: mailbox)
    let timer = Timer(timeInterval: 1.0 / 25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.publishMicrophoneLevel(id: id) }
    }
    timer.tolerance = 0.008
    session.timer = timer
    microphoneLevelSession = session
    RunLoop.main.add(timer, forMode: .common)
  }

  private func publishMicrophoneLevel(id: UUID) {
    guard let session = microphoneLevelSession, session.id == id else { return }
    guard input.isActive(id: id), input.snapshot.phase == .listening else {
      stopMicrophoneLevels()
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let level = session.envelope.advance(
      rms: session.mailbox.consumePeak(), elapsed: now - session.lastTick)
    session.lastTick = now
    onInputLevel?(id, level)
  }

  private func stopMicrophoneLevels() {
    guard let session = microphoneLevelSession else { return }
    microphoneLevelSession = nil
    session.timer?.invalidate()
    session.envelope.reset()
    onInputLevel?(session.id, 0)
  }

  private func stopAudioCapture() {
    stopMicrophoneLevels()
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
