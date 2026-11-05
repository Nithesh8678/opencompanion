import AppKit
import CompanionCore
import Testing

@testable import OpenCompanion

struct SpatialLabelRevealTests {
  private func label(_ text: String, id: String = "label", target: String = "rotor")
    -> SpatialLabelReveal.Label
  {
    .init(id: id, text: text, anchor: .init(targetID: target))
  }

  @Test func wordsUseTheExistingCalmCadenceWithoutLongFrameBursts() {
    var state = SpatialLabelReveal()
    state.reconcile(
      documentID: "scene", generation: 1, labels: [label("Rotating magnetic field")],
      reduceMotion: false)
    #expect(state.visibleText(id: "label") == "")
    #expect(state.hasRevealableText)
    let firstWord = state.advance(by: 10)
    #expect(firstWord)
    #expect(state.visibleText(id: "label") == "Rotating")
    let earlyWord = state.advance(by: 0.1)
    #expect(!earlyWord)
    #expect(state.visibleText(id: "label") == "Rotating")
    let secondWord = state.advance(by: 0.121)
    #expect(secondWord)
    #expect(state.visibleText(id: "label") == "Rotating magnetic")
    let finalWord = state.advance(by: 0.221)
    #expect(finalWord)
    #expect(state.visibleText(id: "label") == "Rotating magnetic field")
    #expect(!state.hasRevealableText)
    let settledChange = state.advance(by: 100)
    #expect(!settledChange)
  }

  @Test func replacementAndDocumentIdentityInvalidateOnlyTheirOwnPrefixes() {
    var state = SpatialLabelReveal()
    state.reconcile(
      documentID: "scene", generation: 1,
      labels: [label("Copper coil"), label("Outer housing", id: "other")], reduceMotion: false)
    state.advance(by: 0.01)
    state.reconcile(
      documentID: "scene", generation: 1,
      labels: [label("Magnetic rotor"), label("Outer housing", id: "other")], reduceMotion: false)
    #expect(state.visibleText(id: "label") == "")
    #expect(state.visibleText(id: "other") == "Outer")
    state.advance(by: 0.01)
    #expect(state.visibleText(id: "label") == "Magnetic")
    state.reconcile(
      documentID: "scene", generation: 1,
      labels: [label("Magnetic rotor", target: "different-part")], reduceMotion: false)
    #expect(state.visibleText(id: "label") == "")
    #expect(state.visibleText(id: "other") == nil)
    state.reconcile(
      documentID: "new-scene", generation: 1, labels: [label("Magnetic rotor")],
      reduceMotion: false)
    #expect(state.visibleText(id: "label") == "")
  }

  @Test func newerGenerationSettlesOldLabelsAndRejectsStaleRewrites() {
    var state = SpatialLabelReveal()
    state.reconcile(
      documentID: "scene", generation: 7, labels: [label("Copper winding assembly")],
      reduceMotion: false)
    state.advance(by: 0.01)
    state.reconcile(
      documentID: "scene", generation: 8, labels: [label("Copper winding assembly")],
      reduceMotion: false)
    #expect(state.visibleText(id: "label") == "Copper winding assembly")
    #expect(!state.hasRevealableText)
    state.reconcile(
      documentID: "scene", generation: 7, labels: [label("Stale replacement")],
      reduceMotion: false)
    #expect(state.visibleText(id: "label") == "Copper winding assembly")
    state.reset()
    #expect(!state.hasRevealableText)
    #expect(state.visibleText(id: "label") == nil)
  }

  @Test func reduceMotionIsImmediateAndUnicodeClustersStayWhole() {
    let text = "Copper 👨‍👩‍👧‍👦 coil"
    var state = SpatialLabelReveal()
    state.reconcile(
      documentID: "scene", generation: 1, labels: [label(text)], reduceMotion: false)
    state.advance(by: 0.01)
    state.advance(by: 0.221)
    #expect(state.visibleText(id: "label") == "Copper 👨‍👩‍👧‍👦")
    state.advance(by: 0, reduceMotion: true)
    #expect(state.visibleText(id: "label") == text)
    #expect(!state.hasRevealableText)
    state.reconcile(
      documentID: "next", generation: 1, labels: [label("Immediate full label")],
      reduceMotion: true)
    #expect(state.visibleText(id: "label") == "Immediate full label")
    #expect(!state.hasRevealableText)
  }

  @Test func emptyAndOversizedLabelsCannotLeaveAnIdleClockRunning() {
    var state = SpatialLabelReveal()
    state.reconcile(
      documentID: "scene", generation: 1, labels: [label("")], reduceMotion: false)
    state.advance(by: 0.01)
    #expect(!state.hasRevealableText)
    let canonical = String(repeating: "a", count: CursorTextReveal.maximumUnitUTF8Bytes + 1)
    state.reconcile(
      documentID: "scene", generation: 1, labels: [label(canonical)], reduceMotion: false)
    #expect(state.visibleText(id: "label") == canonical)
    #expect(!state.hasRevealableText)
  }
}

@Suite @MainActor struct SpatialLabelNativeTests {
  @Test func clockDiagnosticsDoNotExposeTextOrStartForAnUnmountedView() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.presentation = .passiveOverlay
    view.render(try fixture().validated(), time: 0, selectedID: nil, presentationGeneration: 1)
    let pending = view.displayClockDiagnostics
    #expect(pending.pendingLabels && pending.visibleLabelCount == 1)
    #expect(!pending.linkExists && !pending.windowBound && !pending.windowVisible)
    #expect(pending.linkPaused && pending.callbackCount == 0 && pending.acceptedCallbackCount == 0)
    #expect(pending.accumulatedDelta == 0 && pending.lastCallbackAge == nil)
    let encoded = try JSONEncoder().encode(pending)
    let decoded = try JSONDecoder().decode(CanvasDisplayClockDiagnostics.self, from: encoded)
    #expect(decoded.pendingLabels && decoded.callbackCount == 0)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("Copper winding assembly"))
    view.advanceSpatialLabels(by: 0.01)
    #expect(view.projectedLabelText(id: "label") == "Copper")
    #expect(view.displayClockDiagnostics.callbackCount == 0)
    view.stopDisplayLink()
    let stopped = view.displayClockDiagnostics
    #expect(!stopped.linkExists && stopped.linkPaused && !stopped.windowBound)
    #expect(!stopped.pendingLabels && stopped.stopCount > pending.stopCount)
  }

  @Test func passiveLabelsRevealRetainedGlyphsWithoutChangingTheirMeasuredBounds() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.presentation = .passiveOverlay
    let document = try fixture().validated()
    view.render(document, time: 0, selectedID: nil, presentationGeneration: 1)
    let fullBounds = try #require(view.projectedLabelFrame(id: "label"))
    #expect(view.projectedLabelText(id: "label") == "")
    #expect(view.hasPendingSpatialLabels && view.needsDisplayClock)
    #expect(!view.isDisplayClockRunning)  // No window is ordered in this test.
    view.advanceSpatialLabels(by: 0.01)
    #expect(view.projectedLabelText(id: "label") == "Copper")
    #expect(view.projectedLabelFrame(id: "label") == fullBounds)
    view.advanceSpatialLabels(by: 0.1)
    #expect(view.projectedLabelText(id: "label") == "Copper")
    view.advanceSpatialLabels(by: 0.121)
    #expect(view.projectedLabelText(id: "label") == "Copper winding")
    view.advanceSpatialLabels(by: 0.221)
    #expect(view.projectedLabelText(id: "label") == "Copper winding assembly")
    #expect(view.projectedLabelFrame(id: "label") == fullBounds)
    #expect(!view.hasPendingSpatialLabels && !view.needsDisplayClock)
  }

  @Test func editorLabelsAreImmediateAndStoppingUnmountedPresentationCancelsPacing() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    view.render(try fixture().validated(), time: 0, selectedID: nil)
    #expect(view.projectedLabelText(id: "label") == "Copper winding assembly")
    #expect(!view.hasPendingSpatialLabels)
    view.presentation = .passiveOverlay
    #expect(view.projectedLabelText(id: "label") == "")
    #expect(view.hasPendingSpatialLabels)
    view.advanceSpatialLabels(by: 0, reduceMotion: true)
    #expect(view.projectedLabelText(id: "label") == "Copper winding assembly")
    #expect(!view.hasPendingSpatialLabels)
    var replacement = fixture()
    replacement.nodes[1].text = "Updated rotor label"
    view.render(try replacement.validated(), time: 0, selectedID: nil)
    #expect(view.projectedLabelText(id: "label") == "")
    view.stopDisplayLink()
    #expect(!view.hasPendingSpatialLabels && !view.isDisplayClockRunning)
  }

  @Test func disabledOrUnprojectableLeadersNeverReturnStalePaths() throws {
    let view = RetainedCanvasView(frame: CGRect(x: 0, y: 0, width: 620, height: 420))
    var document = fixture()
    view.render(try document.validated(), time: 0, selectedID: nil)
    #expect(view.projectedLeaderPath(id: "label") != nil)
    document.nodes[1].spatial3D?.labelAnchor?.leader = false
    view.render(try document.validated(), time: 0, selectedID: nil)
    #expect(view.projectedLeaderPath(id: "label") == nil)
    document.nodes[1].spatial3D?.labelAnchor?.leader = true
    document.nodes[0].opacity = 0
    view.render(try document.validated(), time: 0, selectedID: nil)
    #expect(view.projectedLabelFrame(id: "label") == nil)
    #expect(view.projectedLeaderPath(id: "label") == nil)
  }

  private func fixture() -> SceneDocument {
    SceneDocument(
      id: "word-label-native", width: 900, height: 560,
      nodes: [
        .init(
          id: "rotor", kind: .mesh, color: "#DA983D",
          spatial3D: .init(geometry: .cylinder(radius: 0.5, height: 1.2))),
        .init(
          id: "label", kind: .text, text: "Copper winding assembly", color: "#FFFFFF",
          spatial3D: .init(labelAnchor: .init(targetID: "rotor"))),
      ])
  }
}
