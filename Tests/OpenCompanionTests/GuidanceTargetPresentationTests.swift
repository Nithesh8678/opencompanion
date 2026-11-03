import Testing

@testable import OpenCompanion

struct GuidanceTargetPresentationTests {
  @Test(arguments: [nil, "ellipse", "roundedRectangle"] as [String?])
  func advancingControlsUseTheHostEllipseWithoutChangingTheirTarget(_ shape: String?) {
    let original = target(shape: shape, advanceOn: "click")
    let styled = GuidanceTargetPresentation.styled(original)

    #expect(styled.shape == "ellipse")
    expectUnchangedTarget(styled, original)
    #expect(original.shape == shape)
  }

  @Test(arguments: [nil, "manual", "hover", "CLICK", " click"] as [String?])
  func nonClickTargetsKeepTheirModelPresentation(_ advanceOn: String?) {
    let original = target(shape: "roundedRectangle", advanceOn: advanceOn)
    let styled = GuidanceTargetPresentation.styled(original)

    #expect(styled.shape == "roundedRectangle")
    expectUnchangedTarget(styled, original)
  }

  @Test(arguments: ["circle", "triangle", "Ellipse", "", " roundedRectangle"])
  func unsupportedShapesRemainUnsupported(_ shape: String) {
    let original = target(shape: shape, advanceOn: "click")
    let styled = GuidanceTargetPresentation.styled(original)

    #expect(styled.shape == shape)
    expectUnchangedTarget(styled, original)
  }

  @Test func stylingDoesNotRepairInvalidBoundsOrSanitizeUntrustedContent() {
    let invalid = ProviderTarget(
      x: .nan, y: -.infinity, width: -0.5, height: 0,
      instruction: String(repeating: "x", count: 32_001),
      label: String(repeating: "👨‍👩‍👧‍👦", count: 81), shape: "roundedRectangle", advanceOn: "click")
    let styled = GuidanceTargetPresentation.styled(invalid)

    #expect(styled.shape == "ellipse")
    expectUnchangedTarget(styled, invalid)
    #expect(styled.instruction.utf8.count > 32_000)
    #expect(styled.label?.count == 81)
  }

  private func target(shape: String?, advanceOn: String?) -> ProviderTarget {
    ProviderTarget(
      x: 0.127, y: 0.619, width: 0.231, height: 0.047,
      instruction: "Select the public fixture's new chat control.", label: "New chat 🧑🏽‍💻",
      shape: shape, advanceOn: advanceOn)
  }

  private func expectUnchangedTarget(_ actual: ProviderTarget, _ original: ProviderTarget) {
    // Bit equality includes invalid nonfinite values: styling cannot make them
    // valid or silently move/resize a model-grounded target.
    #expect(actual.x.bitPattern == original.x.bitPattern)
    #expect(actual.y.bitPattern == original.y.bitPattern)
    #expect(actual.width.bitPattern == original.width.bitPattern)
    #expect(actual.height.bitPattern == original.height.bitPattern)
    #expect(actual.instruction == original.instruction)
    #expect(actual.label == original.label)
    #expect(actual.advanceOn == original.advanceOn)
  }
}
