import Foundation

/// One bounded caption lease. Native speech exposes only reported character
/// ranges; the fallback uses the ordinary cursor word queue instead.
struct CursorNarrationCaption: Sendable {
  let context: VoiceNarrationContext
  let nativeSpeech: Bool
  private let content: VoiceNarrationText
  private var token: UUID?
  private var nativePrefix = ""
  private var nativeEnd = 0
  private var local = CursorTextReveal()
  private var finalWordReadyAt: TimeInterval?
  private var completionTaken = false
  private(set) var cancelled = false

  init?(text: String, context: VoiceNarrationContext, nativeSpeech: Bool) {
    guard !text.isEmpty, let content = VoiceNarrationText(text) else { return nil }
    self.context = context
    self.nativeSpeech = nativeSpeech
    self.content = content
    if !nativeSpeech {
      guard local.append(unitID: 0, text: content.text, isComplete: true) else { return nil }
    }
  }

  var text: String { content.text }
  var visibleText: String { nativeSpeech ? nativePrefix : local.visibleText }
  var hasRevealableText: Bool { !nativeSpeech && local.hasRevealableText }
  var needsLocalCompletionTick: Bool { !nativeSpeech && !completionTaken && !local.hasPending }

  /// The token is bound once. Delayed events from another utterance cannot
  /// advance or cancel this caption even if a caller mistakenly reuses context.
  @discardableResult mutating func receive(_ update: VoiceUtteranceUpdate) -> Bool {
    guard nativeSpeech, !cancelled, update.context == context,
      token == nil || token == update.token
    else { return false }
    if update.kind == .range {
      guard update.revealedUTF16End > nativeEnd,
        update.revealedUTF16End <= content.utf16Count
      else { return false }
    }
    token = update.token
    switch update.kind {
    case .range:
      let prefix = content.prefix(throughUTF16End: update.revealedUTF16End)
      let end = prefix.utf16.count
      guard end > nativeEnd else { return false }
      nativeEnd = end
      nativePrefix = prefix
      return true
    case .cancelled:
      cancelled = true
      return false
    case .enqueued, .started, .finished:
      return false
    }
  }

  @discardableResult mutating func advance(by elapsed: Double, reduceMotion: Bool) -> Bool {
    guard !nativeSpeech else { return false }
    return local.advance(by: elapsed, reduceMotion: reduceMotion)
  }

  /// Called after drawing the current caption. Repeated frames do not restart
  /// the final word's fade; Reduce Motion may explicitly bypass the remainder.
  mutating func didSubmitCaption(at uptime: TimeInterval, reduceMotion: Bool) {
    guard needsLocalCompletionTick, uptime.isFinite, uptime >= 0 else { return }
    if reduceMotion {
      finalWordReadyAt = uptime
    } else if finalWordReadyAt == nil {
      finalWordReadyAt = uptime + CursorCaptionWord.fadeDuration
    }
  }

  /// The last submitted local word retains its native fade lifetime. Forced
  /// surface loss releases the gate; native speech completion belongs to Voice.
  mutating func takeLocalCompletion(at uptime: TimeInterval, force: Bool = false)
    -> VoiceNarrationContext?
  {
    guard !nativeSpeech, !completionTaken else { return nil }
    if !force {
      guard !local.hasPending, uptime.isFinite, let readyAt = finalWordReadyAt,
        uptime >= readyAt
      else { return nil }
    }
    completionTaken = true
    return context
  }
}
