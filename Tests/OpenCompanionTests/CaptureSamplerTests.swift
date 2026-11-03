import Testing

@testable import OpenCompanion

@Suite struct CaptureSamplerTests {
  @MainActor @Test func colorManagedCheckerDistinguishesExclusionFromRetainedOrEmptyControl() throws
  {
    try CaptureAcceptance.samplerRegression()
  }
}
