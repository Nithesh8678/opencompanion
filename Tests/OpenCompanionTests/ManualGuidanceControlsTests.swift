import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

struct ManualGuidanceControlsTests {
  @Test func controlsStayOnNegativeOriginAndSmallDisplays() throws {
    for display in [
      CGRect(x: -1512, y: -982, width: 1512, height: 950),
      CGRect(x: 0, y: 600, width: 400, height: 300),
    ] {
      for target in [
        CGRect(x: display.minX, y: display.minY, width: 40, height: 30),
        CGRect(x: display.maxX - 60, y: display.maxY - 40, width: 60, height: 40),
      ] {
        let controls = try #require(
          ManualGuidanceControlsLayout.frame(target: target, visibleFrame: display))
        #expect(display.contains(controls))
        #expect(!target.intersects(controls))
      }
    }
    #expect(ManualGuidanceControlsLayout.frame(target: .zero, visibleFrame: .zero) == nil)
  }

  @Test func onlyAnExplicitBooleanAsksToWaitForAManualAction() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(
      ProviderTarget.self,
      from: Data(
        #"{"x":0.1,"y":0.2,"width":0.2,"height":0.05,"instruction":"Explain","advanceOn":"manual"}"#
          .utf8))
    #expect(legacy.awaitUser == nil)
    let action = try decoder.decode(
      ProviderTarget.self,
      from: Data(
        #"{"pixelBounds":{"x":20,"y":30,"width":200,"height":40},"instruction":"Type here","advanceOn":"manual","awaitUser":true}"#
          .utf8))
    #expect(action.awaitUser == true)
    #expect(throws: (any Error).self) {
      try decoder.decode(
        ProviderTarget.self,
        from: Data(
          #"{"pixelBounds":{"x":20,"y":30,"width":200,"height":40},"instruction":"Type here","advanceOn":"manual","awaitUser":"yes"}"#
            .utf8))
    }
  }
}
