import Foundation

/// Ephemeral authority for one already-grounded target. No runtime source
/// identity, text, or speech receipt is persisted by this presentation owner.
struct GuidanceSpeechBeatContext: Sendable, Equatable {
  let generation: UInt64
  let leaseID: UUID
  let evidence: ScreenEvidenceIdentity

  var voiceContext: VoiceNarrationContext {
    .init(generation: generation, narrationID: leaseID)
  }
}

/// Owns only presentation. The host admits the target, starts the cursor flight,
/// enqueues actual speech and observes user actions. This owner never captures,
/// synthesizes speech, advances a guide, or estimates audio from elapsed time.
@MainActor final class GuidanceSpeechBeatCoordinator {
  enum FinishReason: String, Sendable {
    case speechFinished, speechCancelled, textFallbackFinished
    case cancelled, superseded, ownershipLost
  }

  var onCaptionStarted: ((GuidanceSpeechBeatContext, String, Bool) -> Void)?
  var onMarkStart: ((GuidanceSpeechBeatContext) -> Void)?
  var onCaptionProgress: ((GuidanceSpeechBeatContext, String) -> Void)?
  var onCaptionUpdate: ((VoiceUtteranceUpdate) -> Void)?
  var onCaptionFinished: ((GuidanceSpeechBeatContext) -> Void)?
  var onFinished: ((GuidanceSpeechBeatContext, FinishReason) -> Void)?

  private struct Beat {
    let context: GuidanceSpeechBeatContext
    let text: VoiceNarrationText
    let nativeSpeech: Bool
    var token: UUID?
    var started = false
    var markStarted = false
    var revealedEnd = 0
  }

  private let owns: (GuidanceSpeechBeatContext) -> Bool
  private var beat: Beat?
  private var watermark: UInt64 = 0
  private var cancelledThrough: UInt64?
  private var retiredLeases = Set<UUID>()
  private var transition: UInt64 = 0
  var currentContext: GuidanceSpeechBeatContext? { beat?.context }

  init(owns: @escaping (GuidanceSpeechBeatContext) -> Bool) { self.owns = owns }

  /// Install before calling VoiceService.speak(_:context:), including drivers
  /// which synchronously emit receipts. A native caption starts empty; its mark
  /// waits for didStart. Explicit no-speech fallback releases the mark locally.
  @discardableResult func begin(
    context: GuidanceSpeechBeatContext, text: String, nativeSpeech: Bool
  ) -> Bool {
    guard context.generation >= watermark,
      cancelledThrough.map({ context.generation > $0 }) ?? true,
      !retiredLeases.contains(context.leaseID), owns(context), !text.isEmpty,
      let content = VoiceNarrationText(text)
    else { return false }
    if let beat, beat.context == context {
      return beat.text.text == text && beat.nativeSpeech == nativeSpeech
    }
    if beat != nil {
      finish(reason: .superseded, settleCaption: false)
      guard beat == nil else { return false }
    }
    guard owns(context), context.generation >= watermark,
      cancelledThrough.map({ context.generation > $0 }) ?? true
    else { return false }
    if context.generation > watermark { retiredLeases.removeAll(keepingCapacity: true) }
    guard retiredLeases.count < 128 else { return false }
    watermark = context.generation
    transition &+= 1
    beat = Beat(context: context, text: content, nativeSpeech: nativeSpeech)
    let owner = transition
    onCaptionStarted?(context, content.text, nativeSpeech)
    guard remains(context, transition: owner) else { return false }
    if !nativeSpeech { releaseMark(context) }
    return beat?.context == context
  }

  func receive(_ update: VoiceUtteranceUpdate) {
    guard var current = beat, current.nativeSpeech,
      update.context == current.context.voiceContext,
      current.token == nil || current.token == update.token,
      update.observedUptime.isFinite, update.observedUptime >= 0,
      update.revealedUTF16End >= 0, update.revealedUTF16End <= current.text.utf16Count
    else { return }
    guard owns(current.context) else {
      finish(reason: .ownershipLost, settleCaption: false)
      return
    }
    let owner = transition
    switch update.kind {
    case .enqueued:
      current.token = update.token
      beat = current
      onCaptionUpdate?(update)
    case .started:
      guard !current.started else { return }
      current.token = update.token
      current.started = true
      beat = current
      releaseMark(current.context)
      guard remains(current.context, transition: owner) else { return }
      onCaptionUpdate?(update)
    case .range:
      guard current.started, update.revealedUTF16End > current.revealedEnd,
        update.revealedUTF16End <= current.text.utf16Count
      else { return }
      let prefix = current.text.prefix(throughUTF16End: update.revealedUTF16End)
      let end = prefix.utf16.count
      guard end > current.revealedEnd else { return }
      current.token = update.token
      current.revealedEnd = end
      beat = current
      onCaptionProgress?(current.context, prefix)
      guard remains(current.context, transition: owner) else { return }
      onCaptionUpdate?(
        .init(
          token: update.token, context: update.context, kind: .range,
          observedUptime: update.observedUptime, revealedUTF16End: end))
    case .finished:
      finish(reason: .speechFinished, settleCaption: true, terminalUpdate: update)
    case .cancelled:
      finish(reason: .speechCancelled, settleCaption: false, terminalUpdate: update)
    }
  }

  /// The actual local caption owner supplies completion, never a guessed timer.
  func finishTextFallback(context: GuidanceSpeechBeatContext) {
    guard let beat, beat.context == context, !beat.nativeSpeech else { return }
    guard owns(context) else {
      finish(reason: .ownershipLost, settleCaption: false)
      return
    }
    finish(reason: .textFallbackFinished, settleCaption: true)
  }

  /// Explicit speech-enqueue refusal is a local fallback, not a synthetic
  /// native start. Keeping the grounded lease prevents target authority drift.
  @discardableResult func fallBackToText(context: GuidanceSpeechBeatContext) -> Bool {
    guard let current = beat, current.context == context, owns(context)
    else { return false }
    if !current.nativeSpeech { return true }
    transition &+= 1
    let owner = transition
    var fallback = Beat(context: context, text: current.text, nativeSpeech: false)
    fallback.markStarted = current.markStarted
    beat = fallback
    onCaptionStarted?(context, current.text.text, false)
    guard remains(context, transition: owner) else { return false }
    releaseMark(context)
    return beat?.context == context
  }

  func cancel(context: GuidanceSpeechBeatContext) {
    guard beat?.context == context else { return }
    finish(reason: .cancelled, settleCaption: false)
  }

  func cancel(generation: UInt64) {
    guard generation >= watermark else { return }
    watermark = generation
    transition &+= 1
    cancelledThrough = max(cancelledThrough ?? 0, generation)
    if beat != nil { finish(reason: .cancelled, settleCaption: false) }
  }

  private func releaseMark(_ context: GuidanceSpeechBeatContext) {
    guard var current = beat, current.context == context, !current.markStarted,
      owns(context)
    else { return }
    current.markStarted = true
    beat = current
    onMarkStart?(context)
  }

  private func remains(_ context: GuidanceSpeechBeatContext, transition owner: UInt64) -> Bool {
    transition == owner && beat?.context == context && owns(context)
  }

  private func finish(
    reason: FinishReason, settleCaption: Bool, terminalUpdate: VoiceUtteranceUpdate? = nil
  ) {
    guard let current = beat else { return }
    beat = nil
    retiredLeases.insert(current.context.leaseID)
    transition &+= 1
    let owner = transition
    func deliverable() -> Bool { transition == owner && owns(current.context) }
    if settleCaption, deliverable() {
      onCaptionProgress?(current.context, current.text.text)
    }
    if let terminalUpdate, deliverable() { onCaptionUpdate?(terminalUpdate) }
    if settleCaption, deliverable() { onCaptionFinished?(current.context) }
    guard transition == owner else { return }
    onFinished?(current.context, reason)
  }
}
