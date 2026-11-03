import CoreGraphics
import Testing

@testable import OpenCompanion

@Suite struct CursorCompanionCoreTests {
  @Test func everyRevealedPrefixEndsAtAnExtendedGraphemeBoundary() {
    var reveal = CursorTextReveal()
    let text = "A👨‍👩‍👧‍👦e\u{301}🇮🇳क्‍ष👍🏽"
    let characters = Array(text)
    #expect(reveal.append(unitID: 0, text: text, isComplete: true) == true)
    var previousCount = 0
    for _ in 0..<500 {
      reveal.advance(by: 0.01)
      let visible = Array(reveal.visibleText)
      #expect(visible.count >= previousCount)
      #expect(visible.elementsEqual(characters.prefix(visible.count)))
      previousCount = visible.count
      if !reveal.hasPending { break }
    }
    #expect(reveal.visibleText == text)
    #expect(reveal.currentUnitID == 0)
    #expect(!reveal.hasPending)
  }

  @Test func incompleteCombiningAndZWJTailsRemainProvisional() {
    var reveal = CursorTextReveal()
    #expect(reveal.append(unitID: 1, text: "e", isComplete: false) == true)
    reveal.advance(by: 1)
    #expect(reveal.visibleText.isEmpty)
    #expect(reveal.append(unitID: 1, text: "e\u{301}", isComplete: false) == true)
    reveal.fastForward()
    #expect(reveal.visibleText.isEmpty)
    #expect(reveal.append(unitID: 1, text: "e\u{301} x", isComplete: false) == true)
    reveal.advance(by: 0.01)
    #expect(reveal.visibleText == "e\u{301}")
    #expect(reveal.append(unitID: 1, text: "e\u{301} x", isComplete: true) == true)
    reveal.fastForward()
    #expect(reveal.visibleText == "e\u{301} x")

    reveal.reset()
    for partial in ["👨", "👨‍", "👨‍👩", "👨‍👩‍👧‍👦"] {
      #expect(reveal.append(unitID: 2, text: partial, isComplete: false) == true)
      reveal.fastForward()
      #expect(reveal.visibleText.isEmpty)
    }
    reveal.append(unitID: 2, text: "👨‍👩‍👧‍👦", isComplete: true)
    reveal.fastForward()
    #expect(reveal.visibleText == "👨‍👩‍👧‍👦")
  }

  @Test func aCompletedCaptionStaysUntilTheNextUnitHasSafeVisibleText() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 1, text: "First", isComplete: true)
    reveal.fastForward()
    reveal.append(unitID: 2, text: "", isComplete: false)
    #expect(reveal.advance(by: 1) == false)
    #expect(reveal.visibleText == "First" && reveal.currentUnitID == 1)
    reveal.append(unitID: 2, text: "e", isComplete: false)
    reveal.advance(by: 1)
    #expect(reveal.visibleText == "First")
    reveal.append(unitID: 2, text: "e!", isComplete: false)
    #expect(reveal.advance(by: 1) == false)
    reveal.append(unitID: 2, text: "e! ", isComplete: false)
    #expect(reveal.advance(by: 0.3) == true)
    #expect(reveal.visibleText == "e!" && reveal.currentUnitID == 2)
  }

  @Test func pendingTransportDoesNotRequireARevealClockOrSkipTheHead() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 1, text: "one ", isComplete: false)
    #expect(reveal.hasRevealableText)
    reveal.fastForward()
    #expect(reveal.visibleText == "one")
    #expect(reveal.hasPending && !reveal.hasRevealableText)
    reveal.append(unitID: 2, text: "Later", isComplete: true)
    #expect(reveal.hasPending && !reveal.hasRevealableText)
    reveal.append(unitID: 1, text: "one two", isComplete: false)
    #expect(!reveal.hasRevealableText)
    reveal.append(unitID: 1, text: "one two ", isComplete: false)
    #expect(reveal.hasRevealableText)
    reveal.advance(by: 0.23)
    #expect(reveal.visibleText == "one two")
    #expect(reveal.hasPending && !reveal.hasRevealableText)
    reveal.append(unitID: 1, text: "one two ", isComplete: true)
    #expect(reveal.hasRevealableText)
    reveal.fastForward()
    #expect(reveal.visibleText == "one two " && reveal.hasRevealableText)

    reveal.reset()
    reveal.append(unitID: 0, text: "", isComplete: true)
    #expect(reveal.hasPending && reveal.hasRevealableText)
    #expect(reveal.advance(by: 0.01) == false)
    #expect(!reveal.hasPending && !reveal.hasRevealableText)
  }

  @Test func cumulativeUpdatesPreserveQueueOrderAndRejectRetiredOrRewrittenUnits() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 3, text: "One", isComplete: false)
    reveal.append(unitID: 4, text: "Tw", isComplete: false)
    #expect(reveal.append(unitID: 4, text: "Two", isComplete: true) == true)
    #expect(reveal.append(unitID: 3, text: "One", isComplete: true) == true)
    #expect(reveal.append(unitID: 4, text: "Two!", isComplete: true) == false)
    #expect(reveal.append(unitID: 2, text: "Old", isComplete: true) == false)
    reveal.fastForward()
    #expect(reveal.visibleText == "One" && reveal.currentUnitID == 3)
    #expect(reveal.append(unitID: 3, text: "One!", isComplete: true) == false)
    reveal.fastForward()
    #expect(reveal.visibleText == "Two" && reveal.currentUnitID == 4)
    #expect(!reveal.hasPending)
    reveal.append(unitID: 5, text: "New", isComplete: false)
    #expect(reveal.append(unitID: 5, text: "Other", isComplete: true) == false)
    #expect(reveal.append(unitID: 5, text: "Ne", isComplete: false) == false)
  }

  @Test func queuePressureIsExplicitAndFastForwardAllowsOneBoundedRetry() {
    var reveal = CursorTextReveal()
    for id in 0..<8 {
      #expect(reveal.append(unitID: id, text: "Caption\(id)", isComplete: true) == true)
    }
    #expect(reveal.pendingUnitCount == 8)
    #expect(reveal.append(unitID: 8, text: "Latest", isComplete: true) == false)
    reveal.fastForward()
    #expect(reveal.visibleText == "Caption0")
    #expect(reveal.pendingUnitCount == 7)
    #expect(reveal.append(unitID: 8, text: "Latest", isComplete: true) == true)
    for id in 1..<8 {
      reveal.fastForward()
      #expect(reveal.visibleText == "Caption\(id)")
    }
    reveal.fastForward()
    #expect(reveal.visibleText == "Latest")

    reveal.reset()
    reveal.append(unitID: 0, text: "partial", isComplete: false)
    for id in 1..<8 { reveal.append(unitID: id, text: "Queued", isComplete: true) }
    reveal.fastForward()
    #expect(reveal.pendingUnitCount == 8)
    #expect(reveal.append(unitID: 8, text: "Cannot evict partial", isComplete: true) == false)
  }

  @Test func byteBoundsDoNotCutUnicodeAndRejectedIDsCanBeRetried() {
    var reveal = CursorTextReveal()
    let atLimit = String(repeating: "🙂", count: 8192)
    #expect(atLimit.utf8.count == 32_768)
    #expect(reveal.append(unitID: 0, text: atLimit + "🙂", isComplete: true) == false)
    #expect(reveal.append(unitID: 0, text: atLimit, isComplete: true) == true)
    reveal.fastForward()
    #expect(reveal.visibleText == atLimit)
    #expect(reveal.append(unitID: -1, text: "Invalid", isComplete: true) == false)
  }

  @Test func invalidTimeDoesNotMutateAndReduceMotionDoesNotSkipQueuedCaptions() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 1, text: "First", isComplete: true)
    reveal.append(unitID: 2, text: "Second", isComplete: true)
    for time in [Double.nan, .infinity, -.infinity, -1, 0] {
      #expect(reveal.advance(by: time) == false)
      #expect(reveal.visibleText.isEmpty)
    }
    #expect(reveal.advance(by: 0, reduceMotion: true) == true)
    #expect(reveal.visibleText == "First" && reveal.pendingUnitCount == 1)
    #expect(reveal.advance(by: 0, reduceMotion: true) == true)
    #expect(reveal.visibleText == "Second" && !reveal.hasPending)
    #expect(reveal.finishSpeech(unitID: 1) == false)
  }

  @Test func wordsHaveACalmCadenceAndPunctuationAddsAShortRest() {
    var plain = CursorTextReveal()
    var paused = CursorTextReveal()
    plain.append(unitID: 1, text: "One two three", isComplete: true)
    paused.append(unitID: 1, text: "One, two three", isComplete: true)
    plain.advance(by: 0.001)
    paused.advance(by: 0.001)
    #expect(plain.visibleText == "One" && paused.visibleText == "One,")
    #expect(plain.advance(by: 0.1) == false)
    #expect(plain.advance(by: 0.13) == true)
    #expect(plain.visibleText == "One two")
    #expect(paused.advance(by: 0.23) == false)
    #expect(paused.visibleText == "One,")
    #expect(paused.advance(by: 0.10) == true)
    #expect(paused.visibleText == "One, two")
  }

  @Test func aLongFrameOrLargeBacklogReleasesOnlyOneBoundedWordGroup() {
    var long = CursorTextReveal()
    let text = String(repeating: "x", count: 10_000)
    long.append(unitID: 1, text: text, isComplete: true)
    long.advance(by: 0.5)
    #expect(long.visibleText.count == CursorTextReveal.maximumWordGroupCharacters)
    long.advance(by: 60)
    #expect(long.visibleText.count == CursorTextReveal.maximumWordGroupCharacters * 2)
    #expect(long.advance(by: 0.001) == false)
    #expect(long.hasPending)

    var words = CursorTextReveal()
    words.append(unitID: 0, text: "one two three four", isComplete: true)
    words.advance(by: 60)
    #expect(words.visibleText == "one")
    words.advance(by: 60)
    #expect(words.visibleText == "one two")
    #expect(words.advance(by: 0.001) == false)
  }

  @Test func transportWaitsForACompleteWordAndKeepsUnicodePunctuationTogether() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 1, text: "Hel", isComplete: false)
    #expect(!reveal.hasRevealableText)
    #expect(reveal.advance(by: 1) == false)
    reveal.append(unitID: 1, text: "Hello ", isComplete: false)
    #expect(reveal.hasRevealableText)
    reveal.advance(by: 0.001)
    #expect(reveal.visibleText == "Hello")
    reveal.append(unitID: 1, text: "Hello wor", isComplete: false)
    #expect(!reveal.hasRevealableText)
    reveal.advance(by: 1)
    reveal.append(unitID: 1, text: "Hello world!", isComplete: false)
    #expect(!reveal.hasRevealableText)
    reveal.append(unitID: 1, text: "Hello world! ", isComplete: false)
    #expect(reveal.hasRevealableText)
    reveal.advance(by: 0.3)
    #expect(reveal.visibleText == "Hello world!")

    reveal.reset()
    let text = "வணக்கம், दुनिया! 你好世界。 👨‍👩‍👧‍👦"
    reveal.append(unitID: 0, text: text, isComplete: true)
    for expected in [
      "வணக்கம்,", "வணக்கம், दुनिया!", "வணக்கம், दुनिया! 你好",
      "வணக்கம், दुनिया! 你好世界。", text,
    ] {
      reveal.advance(by: 1)
      #expect(reveal.visibleText == expected)
    }
    #expect(!reveal.hasPending)
  }

  @Test func aNewUnitCannotBypassThePreviousWordsInterval() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 0, text: "First", isComplete: true)
    reveal.append(unitID: 1, text: "Second", isComplete: true)
    reveal.advance(by: 0.001)
    #expect(reveal.visibleText == "First")
    #expect(reveal.advance(by: 0.01) == false)
    #expect(reveal.visibleText == "First")
    reveal.advance(by: 0.22)
    #expect(reveal.visibleText == "Second")
  }

  @Test func quotesBracketsAndInternalApostrophesStayWithTheirWords() {
    var reveal = CursorTextReveal()
    let text = "\"👨‍👩‍👧‍👦\" (hello) don't"
    reveal.append(unitID: 0, text: text, isComplete: true)
    for expected in ["\"👨‍👩‍👧‍👦\"", "\"👨‍👩‍👧‍👦\" (hello)", text] {
      reveal.advance(by: 1)
      #expect(reveal.visibleText == expected)
    }
    #expect(!reveal.hasPending)
  }

  @Test func completedWhitespaceAndOpeningPunctuationCannotPinTheQueue() {
    for text in ["   ", "((", "\"", "\n\r\n"] {
      var reveal = CursorTextReveal()
      reveal.append(unitID: 0, text: text, isComplete: true)
      #expect(reveal.hasRevealableText)
      reveal.advance(by: 1)
      #expect(reveal.visibleText == text && !reveal.hasPending)
    }
  }

  @Test func resetAndSpeechIdentityCannotReviveAnOlderCaption() {
    var reveal = CursorTextReveal()
    reveal.append(unitID: 10, text: "Old", isComplete: true)
    reveal.reset()
    #expect(reveal.visibleText.isEmpty && reveal.currentUnitID == nil && !reveal.hasPending)
    reveal.append(unitID: 0, text: "New", isComplete: true)
    #expect(reveal.finishSpeech(unitID: 10) == false)
    #expect(reveal.visibleText.isEmpty)
    #expect(reveal.finishSpeech(unitID: 0) == true)
    #expect(reveal.visibleText == "New")
  }

  @Test func layoutUsesNegativeDisplayOriginsAndFlippedLocalCoordinates() {
    let display = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    let visible = CGRect(x: -1920, y: -160, width: 1920, height: 1010)
    let anchor = CGPoint(x: -1200, y: 500)
    let placement = CursorCompanionLayout.placement(
      anchor: anchor, bubbleSize: CGSize(width: 180, height: 60), display: display, visible: visible
    )
    #expect(visible.contains(placement.frame))
    #expect(placement.frame.minX + placement.bodyPoint.x == anchor.x)
    #expect(placement.frame.maxY - placement.bodyPoint.y == anchor.y)
    #expect(placement.bubbleFrame.minX > placement.bodyPoint.x)
    #expect(placement.bubbleFrame.minY > placement.bodyPoint.y)
    #expect(placement.frame.width < 250 && placement.frame.height < 130)
  }

  @Test func edgeAndOversizedCaptionsStayInsideTheVisibleSafetyRegion() {
    let display = CGRect(x: 200, y: -800, width: 1512, height: 982)
    let visible = display.insetBy(dx: 0, dy: 30)
    for anchor in [
      CGPoint(x: display.minX, y: display.minY),
      CGPoint(x: display.maxX, y: display.maxY),
      CGPoint(x: display.minX, y: display.maxY),
      CGPoint(x: display.maxX, y: display.minY),
    ] {
      let placement = CursorCompanionLayout.placement(
        anchor: anchor, bubbleSize: CGSize(width: 2000, height: 2000),
        display: display, visible: visible)
      #expect(visible.contains(placement.frame))
      #expect(placement.bubbleFrame.width <= 320)
      #expect(CGRect(origin: .zero, size: placement.frame.size).contains(placement.bubbleFrame))
      #expect(placement.bodyPoint.x >= 9 && placement.bodyPoint.y >= 11)
    }
  }

  @Test func absentBubbleAndNonfiniteGeometryHaveFiniteTightFallbacks() {
    let placement = CursorCompanionLayout.placement(
      anchor: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
      bubbleSize: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
      display: .null, visible: .infinite)
    #expect(placement.frame.origin.x.isFinite && placement.frame.origin.y.isFinite)
    // A diagonal 18×22 body and its 8-point halo must fit even without a reply.
    let rotatedRadius = hypot(18.0, 22.0) / 2 + 8
    #expect(placement.frame.width / 2 >= rotatedRadius)
    #expect(placement.frame.height / 2 >= rotatedRadius)
    #expect(placement.frame.width <= 64 && placement.frame.height <= 64)
    #expect(placement.bubbleFrame == .zero)
    #expect(placement.bodyPoint.x.isFinite && placement.bodyPoint.y.isFinite)
    let tiny = CursorCompanionLayout.placement(
      anchor: .zero, bubbleSize: CGSize(width: 500, height: 500),
      display: CGRect(x: -2, y: -2, width: 4, height: 4), visible: .zero)
    #expect(tiny.frame.width <= 4 && tiny.frame.height <= 4)
    #expect(tiny.bubbleFrame == .zero)
  }

  @Test func guidanceFlightHasExactEndpointsAndMonotonicForwardProgress() {
    let flight = CursorFlight(start: CGPoint(x: -700, y: 400), end: CGPoint(x: 300, y: 400))
    #expect(flight.duration >= 0.18 && flight.duration <= 0.65)
    #expect(flight.point(at: 0) == flight.start && flight.point(at: 1) == flight.end)
    #expect(flight.point(at: 0.5).y > flight.start.y)
    var lastX = flight.start.x
    for index in 0...100 {
      let progress = Double(index) / 100
      let point = flight.point(at: progress)
      let tangent = flight.tangent(at: progress)
      #expect(point.x >= lastX && point.x <= flight.end.x)
      #expect(abs(hypot(tangent.x, tangent.y) - 1) < 0.000001)
      lastX = point.x
    }
  }

  @Test func degenerateAndInvalidFlightsRemainFinite() {
    let point = CGPoint(x: -30, y: 44)
    let still = CursorFlight(start: point, end: point)
    #expect(still.duration == 0.18)
    #expect(still.point(at: 0.4) == point)
    #expect(still.tangent(at: 0.4) == CGPoint(x: 1, y: 0))
    let invalid = CursorFlight(
      start: CGPoint(x: CGFloat.nan, y: 0), end: CGPoint(x: CGFloat.infinity, y: 2))
    #expect(invalid.start == .zero && invalid.end == .zero)
    #expect(invalid.point(at: .nan) == .zero)
    #expect(invalid.point(at: -1) == .zero)
    #expect(invalid.point(at: 2) == .zero)
  }
}
