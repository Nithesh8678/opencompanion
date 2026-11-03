import AVFoundation
import Foundation
import Speech

@MainActor final class VoiceService: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var engine: AVAudioEngine?
  private var recognition: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognizer: SFSpeechRecognizer?
  var onTranscript: ((String, Bool) -> Void)?
  var onState: ((String) -> Void)?
  var onSpeechEvent: ((String) -> Void)?
  private var queued = 0
  override init() {
    super.init()
    synthesizer.delegate = self
  }
  func speak(_ text: String) {
    guard !text.isEmpty, queued < 24 else { return }
    queued += 1
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }
  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    queued = 0
    stopListening()
    onState?("Ready")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance)
  {
    onState?("Speaking")
    onSpeechEvent?("audio.synthesizerDidStart")
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance)
  {
    queued = max(0, queued - 1)
    onSpeechEvent?("audio.synthesizerDidFinish")
    if queued == 0 { onState?("Ready") }
  }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance)
  { onSpeechEvent?("audio.synthesizerDidCancel") }
  func startListening() async throws {
    stop()
    let mic = await AVCaptureDevice.requestAccess(for: .audio)
    guard mic else {
      throw ProviderError.message("Allow Microphone access in System Settings to use voice input.")
    }
    let authorization = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard authorization == .authorized else {
      throw ProviderError.message("Allow Speech Recognition in System Settings, or use text input.")
    }
    let locale = Locale(identifier: UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US")
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw ProviderError.message(
        "Speech recognition is unavailable for this language or network. Text input is ready.")
    }
    self.recognizer = recognizer
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    self.request = request
    let engine = AVAudioEngine()
    self.engine = engine
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else {
      throw ProviderError.message("No usable microphone route is available.")
    }
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
    recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let transcript = result?.bestTranscription.formattedString
      let final = result?.isFinal ?? false
      Task { @MainActor [weak self] in
        if let transcript { self?.onTranscript?(transcript, final) }
        if final || error != nil {
          self?.stopListening()
          self?.onState?(error == nil ? "Ready" : "Speech input interrupted")
        }
      }
    }
    engine.prepare()
    try engine.start()
    onState?("Listening")
  }
  func finishListening() {
    engine?.stop()
    engine?.inputNode.removeTap(onBus: 0)
    engine = nil
    request?.endAudio()
    onState?("Finishing speech")
  }
  func stopListening() {
    engine?.stop()
    engine?.inputNode.removeTap(onBus: 0)
    engine = nil
    request?.endAudio()
    request = nil
    recognition?.cancel()
    recognition = nil
    recognizer = nil
  }
}
