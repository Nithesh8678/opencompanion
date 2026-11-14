import AppKit
import Testing

@testable import OpenCompanion

struct GuidanceAnnotationCollisionTests {
  private let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
  private let target = CGRect(x: 250, y: 260, width: 200, height: 40)
  private let size = CGSize(width: 180, height: 26)

  @Test func labelsAvoidRetainedMarksWithoutMovingGroundedGeometry() {
    let first = GuidanceAnnotationLayout.make(target: target, labelSize: size, canvas: canvas)
    let second = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      avoiding: [first.label.insetBy(dx: -2, dy: -2)])
    #expect(second.target == target && canvas.contains(second.label))
    #expect(!second.label.intersects(first.label))
    #expect(!second.label.intersects(target))
    let third = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      avoiding: [first.label, second.label])
    #expect(!third.label.intersects(first.label) && !third.label.intersects(second.label))
  }

  @Test func safePreviousChoiceStaysStableUntilItBecomesObstructed() {
    let first = GuidanceAnnotationLayout.make(target: target, labelSize: size, canvas: canvas)
    let alternative = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      avoiding: [first.label])
    let stable = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      previousLabel: alternative.label)
    #expect(stable.label == alternative.label)
    let obstructed = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      avoiding: [alternative.label], previousLabel: alternative.label)
    #expect(!obstructed.label.intersects(alternative.label))
  }

  @Test func impossibleCrowdingAndMalformedObstaclesStayBoundedAndPreserveTarget() {
    let result = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      avoiding: [canvas, .init(x: CGFloat.nan, y: 0, width: 20, height: 20)]
        + Array(repeating: .init(x: 10, y: 10, width: -2, height: 3), count: 200))
    #expect(result.target == target && canvas.contains(result.label))
    #expect(result.label.width <= 320 && result.label.minX.isFinite && result.label.minY.isFinite)
  }

  @MainActor @Test func oneComputedLayoutDrivesNativePillAndGlobalCursorPlacement() {
    let original = GuidanceAnnotationLayout.make(target: target, labelSize: size, canvas: canvas)
    let layout = GuidanceAnnotationLayout.make(
      target: target, labelSize: size, canvas: canvas,
      avoiding: [original.label])
    let view = GuidanceAnnotationView(
      frame: canvas, target: target, shape: .ellipse,
      text: "Public control", reduceMotion: true, layout: layout)
    #expect(view.annotationLayout == layout)
    let display = CGRect(x: -1200, y: 100, width: 800, height: 600)
    let global = GuidanceAnnotationLayout.globalLabelFrame(layout, display: display)
    #expect(global.minX == display.minX + layout.label.minX)
    #expect(global.maxY == display.maxY - layout.label.minY)
    #expect(global.size == layout.label.size)
  }
}
