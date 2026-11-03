import AVFoundation
import Foundation
import Speech

@MainActor final class VoiceService: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var recognition: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognizer: SFSpeechRecognizer?
  private var input = VoiceInputStateMachine()
  private var tailTask: Task<Void, Never>?
  private var utterances = Set<ObjectIdentifier>()
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
    utterances.insert(ObjectIdentifier(utterance))
    synthesizer.speak(utterance)
  }

  func stop() {
    utterances.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    cancelInput()
    onState?("Ready")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance)
  {
    guard utterances.contains(ObjectIdentifier(utterance)) else { return }
    onState?("Speaking")
    onSpeechEvent?("audio.synthesizerDidStart")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance)
  {
    guard utterances.remove(ObjectIdentifier(utterance)) != nil else { return }
    onSpeechEvent?("audio.synthesizerDidFinish")
    if utterances.isEmpty && !input.snapshot.phase.isActive { onState?("Ready") }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance)
  {
    guard utterances.remove(ObjectIdentifier(utterance)) != nil else { return }
    onSpeechEvent?("audio.synthesizerDidCancel")
    if utterances.isEmpty && !input.snapshot.phase.isActive { onState?("Ready") }
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
      let authorization = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
      }
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
      engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
      }
      tapInstalled = true
      recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let transcript = result?.bestTranscription.formattedString
        let final = result?.isFinal ?? false
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
          guard let self, self.input.isActive(id: id) else { return }
          if let transcript { self.acceptTranscript(id: id, text: transcript, final: final) }
          if let message, self.input.isActive(id: id), self.input.snapshot.phase != .awaitingRelease
          {
            self.failInput(
              id: id,
              error: ProviderError.message(
                "Speech input was interrupted: \(message). Try holding Control+Option again, or use text input."
              ))
          }
        }
      }
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
