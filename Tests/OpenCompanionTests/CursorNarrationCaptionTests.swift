import Foundation
import Testing

@testable import OpenCompanion

@Suite struct CursorNarrationCaptionTests {
  private let context = VoiceNarrationContext(generation: 42, narrationID: UUID())
  private let token = UUID()

  private func event(
    _ kind: VoiceUtteranceUpdate.Kind, end: Int = 0,
    token: UUID? = nil, context: VoiceNarrationContext? = nil
  ) -> VoiceUtteranceUpdate {
    VoiceUtteranceUpdate(
      token: token ?? self.token, context: context ?? self.context, kind: kind,
      observedUptime: 12, revealedUTF16End: end)
  }

  @Test func nativeCaptionCannotAdvanceWithoutReportedSpeechRanges() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "The rotor turns.", context: context, nativeSpeech: true))
    caption.receive(event(.enqueued))
    caption.receive(event(.started))
    let normalAdvance = caption.advance(by: 120, reduceMotion: false)
    let reducedAdvance = caption.advance(by: 120, reduceMotion: true)
    #expect(!normalAdvance)
    #expect(!reducedAdvance)
    #expect(caption.visibleText.isEmpty)
    #expect(!caption.hasRevealableText)
    #expect(caption.takeLocalCompletion(at: 0, force: true) == nil)
    caption.receive(event(.range, end: 9))
    #expect(caption.visibleText == "The rotor")
  }

  @Test func nativeRangesRemainMonotonicAndGraphemeSafe() throws {
    let family = "👨‍👩‍👧‍👦"
    let text = "A" + family + "e\u{301}Z"
    var caption = try #require(
      CursorNarrationCaption(text: text, context: context, nativeSpeech: true))
    caption.receive(event(.range, end: 2))
    #expect(caption.visibleText == "A")
    let familyEnd = ("A" + family).utf16.count
    caption.receive(event(.range, end: familyEnd))
    #expect(caption.visibleText == "A" + family)
    caption.receive(event(.range, end: 1))
    caption.receive(event(.range, end: Int.max))
    caption.receive(event(.range, end: -1))
    #expect(caption.visibleText == "A" + family)
    caption.receive(event(.range, end: text.utf16.count - 1))
    #expect(caption.visibleText == "A" + family + "e\u{301}")
    caption.receive(event(.range, end: text.utf16.count))
    #expect(caption.visibleText == text)
  }

  @Test func staleContextAndUtteranceCannotRevealOrCancelTheOwnedCaption() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "Current caption", context: context, nativeSpeech: true))
    caption.receive(event(.enqueued))
    let staleContext = VoiceNarrationContext(generation: 41, narrationID: context.narrationID)
    caption.receive(event(.range, end: 7, context: staleContext))
    caption.receive(event(.range, end: 7, token: UUID()))
    caption.receive(event(.cancelled, token: UUID()))
    #expect(caption.visibleText.isEmpty)
    #expect(!caption.cancelled)
    caption.receive(event(.range, end: 7))
    #expect(caption.visibleText == "Current")
    caption.receive(event(.cancelled))
    caption.receive(event(.range, end: "Current caption".utf16.count))
    #expect(caption.cancelled)
    #expect(caption.visibleText == "Current")
  }

  @Test func nativeFinishDoesNotPretendThatItIsLocalCompletion() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "Complete answer", context: context, nativeSpeech: true))
    caption.receive(event(.range, end: 8))
    caption.receive(event(.finished, end: "Complete answer".utf16.count))
    #expect(caption.visibleText == "Complete")
    #expect(caption.text == "Complete answer")
    #expect(caption.takeLocalCompletion(at: 0, force: true) == nil)
  }

  @Test func localCompletionWaitsForTheLastPacedWordAndIsTakenOnlyOnce() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "One two three.", context: context, nativeSpeech: false))
    #expect(caption.takeLocalCompletion(at: 0) == nil)
    let first = caption.advance(by: 0.01, reduceMotion: false)
    #expect(first)
    #expect(caption.visibleText == "One")
    #expect(caption.takeLocalCompletion(at: 0) == nil)
    var deliveries = 0
    for index in 0..<100 {
      _ = caption.advance(by: 0.1, reduceMotion: false)
      let now = Double(index) / 10
      caption.didSubmitCaption(at: now, reduceMotion: false)
      if let completed = caption.takeLocalCompletion(at: now) {
        #expect(completed == context)
        #expect(caption.visibleText == "One two three.")
        deliveries += 1
      }
    }
    #expect(deliveries == 1)
    #expect(caption.takeLocalCompletion(at: 0, force: true) == nil)
  }

  @Test func reducedMotionFallbackSettlesWithoutWaitingForAudioOrAReadingHold() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "All words 👋🏽", context: context, nativeSpeech: false))
    let changed = caption.advance(by: 0, reduceMotion: true)
    #expect(changed)
    #expect(caption.visibleText == caption.text)
    caption.didSubmitCaption(at: 0, reduceMotion: true)
    #expect(caption.takeLocalCompletion(at: 0) == context)
    #expect(caption.takeLocalCompletion(at: 0) == nil)
  }

  @Test func finalWordMustBeSubmittedAndRetainItsFadeBeforeLocalCompletion() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "Last", context: context, nativeSpeech: false))
    _ = caption.advance(by: 0.01, reduceMotion: false)
    #expect(caption.visibleText == "Last")
    #expect(caption.needsLocalCompletionTick)
    #expect(caption.takeLocalCompletion(at: 100) == nil)
    caption.didSubmitCaption(at: 10, reduceMotion: false)
    #expect(caption.takeLocalCompletion(at: 10 + CursorCaptionWord.fadeDuration / 2) == nil)
    // Re-rendering must not extend the deadline indefinitely.
    caption.didSubmitCaption(at: 10 + CursorCaptionWord.fadeDuration / 2, reduceMotion: false)
    #expect(caption.takeLocalCompletion(at: 10 + CursorCaptionWord.fadeDuration) == context)
    #expect(!caption.needsLocalCompletionTick)
    #expect(caption.takeLocalCompletion(at: 100) == nil)
  }

  @Test func reducedMotionOrSurfaceLossCanReleaseAnAlreadySubmittedFinalFade() throws {
    for force in [false, true] {
      var caption = try #require(
        CursorNarrationCaption(text: "Tail", context: context, nativeSpeech: false))
      _ = caption.advance(by: 0.01, reduceMotion: false)
      caption.didSubmitCaption(at: 10, reduceMotion: false)
      #expect(caption.takeLocalCompletion(at: 10) == nil)
      if !force { caption.didSubmitCaption(at: 10, reduceMotion: true) }
      #expect(caption.takeLocalCompletion(at: 10, force: force) == context)
      #expect(caption.takeLocalCompletion(at: 100, force: true) == nil)
    }
  }

  @Test func unavailablePresentationDrainsLocalGateEvenBeforeTheFirstWord() throws {
    var caption = try #require(
      CursorNarrationCaption(text: "Not shown while asleep", context: context, nativeSpeech: false))
    #expect(caption.visibleText.isEmpty)
    #expect(caption.takeLocalCompletion(at: 0, force: true) == context)
    #expect(caption.takeLocalCompletion(at: 0, force: true) == nil)
    caption.receive(event(.range, end: 3))
    #expect(caption.visibleText.isEmpty)
  }

  @Test func emptyAndOversizedNarrationAreRejectedBeforeOwnership() {
    #expect(CursorNarrationCaption(text: "", context: context, nativeSpeech: true) == nil)
    #expect(
      CursorNarrationCaption(
        text: String(repeating: "é", count: 16_001), context: context, nativeSpeech: false) == nil)
    #expect(
      CursorNarrationCaption(
        text: String(repeating: "x", count: 32_000), context: context, nativeSpeech: true) != nil)
  }
}
