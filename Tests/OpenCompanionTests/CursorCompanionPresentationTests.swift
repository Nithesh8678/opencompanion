import Testing

@testable import OpenCompanion

@Suite struct CursorCompanionPresentationTests {
  @Test @MainActor func rollingCaptionKeepsNewestGraphemeWithinTheNativeViewBudget() {
    let text = String(repeating: "a", count: 300) + "👨‍👩‍👧‍👦"
    let caption = CursorCompanionCoordinator.captionWindow(text)
    #expect(caption.count == 220)
    #expect(caption.hasPrefix("…"))
    #expect(caption.hasSuffix("👨‍👩‍👧‍👦"))
    #expect(CursorCompanionCoordinator.captionWindow("Short answer") == "Short answer")
  }
}
