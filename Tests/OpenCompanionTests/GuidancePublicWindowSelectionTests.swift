import AppKit
import Testing

@testable import OpenCompanion

struct GuidancePublicWindowSelectionTests {
  private let screen = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
  private let main = CGRect(x: 118, y: 0, width: 1_324, height: 940)
  private let chrome = CGRect(x: 134, y: 904, width: 66, height: 20)
  private typealias Candidate = GuidancePublicAppAcceptance.WindowCandidate

  @Test func selectsFocusedMainInsteadOfSmallAuxiliary() throws {
    let window = try GuidancePublicAppAcceptance.selectPublicWindow(
      [
        Candidate(id: 1, pid: 42, rect: chrome, alpha: 1),
        Candidate(id: 2, pid: 42, rect: main, alpha: 1),
      ], focusedRect: main, pid: 42, screen: screen)
    #expect(window.id == 2)
    #expect(window.rect == main)
  }

  @Test func foreignAndAuxiliaryOrderingDoesNotAuthorizeOrRefuseIndependentCapture() throws {
    let selected = try GuidancePublicAppAcceptance.selectPublicWindow(
      [
        Candidate(id: 1, pid: 99, rect: main, alpha: 1),
        Candidate(id: 2, pid: 42, rect: chrome, alpha: 1),
        Candidate(id: 3, pid: 42, rect: main, alpha: 1),
      ], focusedRect: main, pid: 42, screen: screen)
    #expect(selected.id == 3)
    #expect(throws: (any Error).self) {
      try GuidancePublicAppAcceptance.selectPublicWindow(
        [Candidate(id: 1, pid: 99, rect: main, alpha: 1)],
        focusedRect: main, pid: 42, screen: screen)
    }
  }

  @Test func duplicateOrWrongGeometryCannotSelectAnArbitraryMainWindow() {
    for windows in [
      [
        Candidate(id: 1, pid: 42, rect: main, alpha: 1),
        Candidate(id: 2, pid: 42, rect: main, alpha: 1),
      ],
      [Candidate(id: 1, pid: 42, rect: main.offsetBy(dx: 2, dy: 0), alpha: 1)],
      [Candidate(id: 1, pid: 42, rect: main, alpha: 0.5)],
    ] {
      #expect(throws: (any Error).self) {
        try GuidancePublicAppAcceptance.selectPublicWindow(
          windows, focusedRect: main, pid: 42, screen: screen)
      }
    }
  }

  @Test func exactSelectionPreservesNegativeDisplayOrigins() throws {
    let shiftedScreen = screen.offsetBy(dx: -1_600, dy: -100)
    let shiftedMain = main.offsetBy(dx: -1_600, dy: -100)
    let window = try GuidancePublicAppAcceptance.selectPublicWindow(
      [
        Candidate(
          id: 1, pid: 42, rect: chrome.offsetBy(dx: -1_600, dy: -100), alpha: 1),
        Candidate(id: 2, pid: 42, rect: shiftedMain, alpha: 1),
      ], focusedRect: shiftedMain, pid: 42, screen: shiftedScreen)
    #expect(window.id == 2)
    #expect(window.rect == shiftedMain)
  }
}
