import Foundation
import Testing

@testable import OpenCompanion

struct ScreenGuidancePolicyTests {
  @Test func quartzMouseUpConvertsToGlobalAppKitAcrossDisplays() throws {
    let point = try #require(
      ScreenGuidancePolicy.appKitPoint(quartz: CGPoint(x: -1_300, y: 300), mainTop: 900))
    #expect(point == CGPoint(x: -1_300, y: 600))
    let target = ProviderTarget(x: 0.25, y: 0.1, width: 0.2, height: 0.3, instruction: "Review")
    let rect = try #require(
      ScreenGuidancePolicy.targetRect(
        target, in: CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080)))
    #expect(rect.contains(point))
    #expect(
      ScreenGuidancePolicy.appKitPoint(quartz: CGPoint(x: -300, y: -200), mainTop: 900)
        == CGPoint(x: -300, y: 1_100))
    #expect(
      ScreenGuidancePolicy.appKitPoint(quartz: CGPoint(x: 100, y: 1_000), mainTop: 900)
        == CGPoint(x: 100, y: -100))
  }

  @Test func absentNonfiniteAndOverflowingEventCoordinatesFailClosed() {
    #expect(ScreenGuidancePolicy.appKitPoint(quartz: nil, mainTop: 900) == nil)
    #expect(ScreenGuidancePolicy.appKitPoint(quartz: .zero, mainTop: nil) == nil)
    for invalid in [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
      #expect(
        ScreenGuidancePolicy.appKitPoint(quartz: CGPoint(x: invalid, y: 0), mainTop: 900) == nil)
      #expect(
        ScreenGuidancePolicy.appKitPoint(quartz: CGPoint(x: 0, y: invalid), mainTop: 900) == nil)
      #expect(ScreenGuidancePolicy.appKitPoint(quartz: .zero, mainTop: invalid) == nil)
    }
    #expect(
      ScreenGuidancePolicy.appKitPoint(
        quartz: CGPoint(x: 0, y: -CGFloat.greatestFiniteMagnitude),
        mainTop: CGFloat.greatestFiniteMagnitude) == nil)
  }

  @Test func normalizedTopLeftTargetMapsToNegativeOriginDisplay() throws {
    let display = CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080)
    let target = ProviderTarget(x: 0.25, y: 0.1, width: 0.2, height: 0.3, instruction: "Review")
    let rect = try #require(ScreenGuidancePolicy.targetRect(target, in: display))
    #expect(abs(rect.minX - (-1_440)) < 0.000_001)
    #expect(abs(rect.minY - 448) < 0.000_001)
    #expect(abs(rect.width - 384) < 0.000_001)
    #expect(abs(rect.height - 324) < 0.000_001)
    #expect(rect.contains(CGPoint(x: -1_300, y: 600)))
    #expect(!rect.contains(CGPoint(x: 1_300, y: 600)))
  }

  @Test func targetUsesTheEvidenceRegionRatherThanTheWholeDisplay() throws {
    let source = CGRect(x: -320, y: 450, width: 400, height: 200)
    let target = ProviderTarget(x: 0.5, y: 0.25, width: 0.25, height: 0.5, instruction: "Review")
    let rect = try #require(ScreenGuidancePolicy.targetRect(target, in: source))
    #expect(rect == CGRect(x: -120, y: 500, width: 100, height: 100))
  }

  @Test func invalidNormalizedTargetsAndUnusableEvidenceFailClosed() {
    let display = CGRect(x: 0, y: 0, width: 1_000, height: 700)
    for target in [
      ProviderTarget(x: .nan, y: 0, width: 0.1, height: 0.1, instruction: "Review"),
      ProviderTarget(x: 0, y: .infinity, width: 0.1, height: 0.1, instruction: "Review"),
      ProviderTarget(x: -0.1, y: 0, width: 0.1, height: 0.1, instruction: "Review"),
      ProviderTarget(x: 0, y: 0, width: 0, height: 0.1, instruction: "Review"),
      ProviderTarget(x: 0, y: 0, width: 0.1, height: -.infinity, instruction: "Review"),
      ProviderTarget(x: 0.9, y: 0, width: 0.2, height: 0.1, instruction: "Review"),
      ProviderTarget(x: 0, y: 0.95, width: 0.1, height: 0.1, instruction: "Review"),
    ] {
      #expect(ScreenGuidancePolicy.targetRect(target, in: display) == nil)
    }
    let valid = ProviderTarget(x: 0, y: 0, width: 1, height: 1, instruction: "Review")
    for source in [
      CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 10),
      CGRect(x: 0, y: 0, width: 10, height: -1),
      CGRect(x: -400, y: -200, width: -10, height: -20),
      CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
      CGRect(x: 10_000_001, y: 0, width: 10, height: 10),
    ] {
      #expect(ScreenGuidancePolicy.targetRect(valid, in: source) == nil)
    }
    #expect(ScreenGuidancePolicy.targetRect(valid, in: display) == display)
  }

  @Test func admissionNeedsAFreshFrameAndABoundedRequest() {
    #expect(
      ScreenGuidancePolicy.permitsAdmission(
        step: 0, requestExpires: 280, capturedAt: 86, now: 100))
    #expect(
      !ScreenGuidancePolicy.permitsAdmission(
        step: 0, requestExpires: 280, capturedAt: 85, now: 100))
    #expect(
      !ScreenGuidancePolicy.permitsAdmission(
        step: 0, requestExpires: 280, capturedAt: 101, now: 100))
    #expect(
      !ScreenGuidancePolicy.permitsAdmission(
        step: 0, requestExpires: 280.1, capturedAt: 99, now: 100))
    #expect(
      !ScreenGuidancePolicy.permitsAdmission(
        step: 0, requestExpires: 100, capturedAt: 99, now: 100))
  }

  @Test func admittedTargetCanWaitForTheUserWithoutReusingItBeyond45Seconds() {
    #expect(
      ScreenGuidancePolicy.permitsClick(
        step: 5, requestExpires: 280, admittedAt: 100, now: 144.99))
    #expect(
      !ScreenGuidancePolicy.permitsClick(
        step: 5, requestExpires: 280, admittedAt: 100, now: 145))
    #expect(
      !ScreenGuidancePolicy.permitsClick(
        step: 5, requestExpires: 120, admittedAt: 100, now: 120))
    #expect(
      !ScreenGuidancePolicy.permitsClick(
        step: 5, requestExpires: 280, admittedAt: 100, now: 99))
  }

  @Test func boundedChecksAndFiniteMonotonicDeadlinesAreMandatory() {
    for step in [-1, ScreenGuidancePolicy.maximumChecks, Int.max] {
      #expect(
        !ScreenGuidancePolicy.permitsAdmission(
          step: step, requestExpires: 280, capturedAt: 99, now: 100))
      #expect(
        !ScreenGuidancePolicy.permitsClick(
          step: step, requestExpires: 280, admittedAt: 100, now: 101))
    }
    for value in [Double.nan, .infinity, -.infinity] {
      #expect(
        !ScreenGuidancePolicy.permitsAdmission(
          step: 0, requestExpires: value, capturedAt: 99, now: 100))
      #expect(
        !ScreenGuidancePolicy.permitsAdmission(
          step: 0, requestExpires: 280, capturedAt: value, now: 100))
      #expect(
        !ScreenGuidancePolicy.permitsClick(
          step: 0, requestExpires: 280, admittedAt: 100, now: value))
    }
  }
}
