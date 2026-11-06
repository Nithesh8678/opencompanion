import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

struct CaptureSourceSelectionTests {
  @Test func anExplicitMissingOrZeroDisplayCannotFallBackToAnotherDisplay() {
    let available: [CGDirectDisplayID] = [42, 17]
    #expect(CaptureSourceSelection.displayID(requested: 17, available: available) == 17)
    #expect(CaptureSourceSelection.displayID(requested: 73, available: available) == nil)
    #expect(CaptureSourceSelection.displayID(requested: 0, available: available) == nil)
    #expect(CaptureSourceSelection.displayID(requested: 0, available: [0, 42]) == nil)
    #expect(CaptureSourceSelection.displayID(requested: 42, available: []) == nil)
  }

  @Test func onlyAnUnspecifiedDisplayKeepsTheExistingFirstDisplayDefault() {
    #expect(CaptureSourceSelection.displayID(requested: nil, available: [42, 17]) == 42)
    #expect(CaptureSourceSelection.displayID(requested: nil, available: [17, 42]) == 17)
    #expect(CaptureSourceSelection.displayID(requested: nil, available: []) == nil)
  }

  @Test func selectedWindowsRequireTheirCurrentPositiveExternalOwnerToMatchTheRequestedProcess() {
    let ownPID: pid_t = 900
    let selectedPID: pid_t = 421
    #expect(
      CaptureSourceSelection.permitsWindow(
        requestedPID: selectedPID, owningPID: selectedPID, ownPID: ownPID))
    // A closed/reused window ID must not inherit its former application's
    // identity merely because the caller still supplies that expected PID.
    #expect(
      !CaptureSourceSelection.permitsWindow(
        requestedPID: selectedPID, owningPID: 422, ownPID: ownPID))
    #expect(
      !CaptureSourceSelection.permitsWindow(
        requestedPID: selectedPID, owningPID: nil, ownPID: ownPID))
    #expect(
      !CaptureSourceSelection.permitsWindow(
        requestedPID: 0, owningPID: 0, ownPID: ownPID))
    #expect(
      !CaptureSourceSelection.permitsWindow(
        requestedPID: -1, owningPID: -1, ownPID: ownPID))
    #expect(
      !CaptureSourceSelection.permitsWindow(
        requestedPID: ownPID, owningPID: ownPID, ownPID: ownPID))
    #expect(
      !CaptureSourceSelection.permitsWindow(
        requestedPID: selectedPID, owningPID: ownPID, ownPID: ownPID))
  }
}
