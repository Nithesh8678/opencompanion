import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SceneCursorVisitTests {
  private let bounds = CGRect(x: -900, y: -300, width: 620, height: 420)
  private let target = CGPoint(x: -500, y: -100)
  private let origin = CGPoint(x: -1_100, y: -200)

  @Test func flightStartsAtPaintedBodyAndLandsItsTipOnTheVerifiedSurface() throws {
    let authority = try authority()
    let visit = try #require(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: 10))
    let first = try #require(visit.pose(at: 10))
    let last = try #require(visit.pose(at: 11))
    #expect(first.point == origin && first.travelling)
    #expect(!last.travelling && visit.target == target)
    #expect(last.point.x + SceneCursorVisit.bodyTipOffset.x == target.x)
    #expect(last.point.y + SceneCursorVisit.bodyTipOffset.y == target.y)
    #expect(last.tangent.x.isFinite && last.tangent.y.isFinite)
  }

  @Test func sameAndSubpixelProjectionCallbacksDoNotRestartArrival() throws {
    let authority = try authority()
    var visit = try #require(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: 10))
    let expected = try #require(visit.pose(at: 10.3))
    let same = visit.update(authority: authority, point: target, bounds: bounds, at: 10.2)
    let subpixel = visit.update(
      authority: authority, point: CGPoint(x: target.x + 0.02, y: target.y - 0.02),
      bounds: bounds, at: 10.25)
    #expect(same && subpixel)
    #expect(visit.target == target)
    #expect(visit.pose(at: 10.3)?.point == expected.point)
    #expect(visit.pose(at: 11)?.travelling == false)
  }

  @Test func movingProjectionRetargetsFromItsCurrentPoseWithoutJumping() throws {
    let authority = try authority()
    var visit = try #require(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: 10))
    let before = try #require(visit.pose(at: 10.2))
    let moved = CGPoint(x: -600, y: 0)
    let updated = visit.update(authority: authority, point: moved, bounds: bounds, at: 10.2)
    #expect(updated)
    #expect(visit.pose(at: 10.2)?.point == before.point)
    #expect(visit.pose(at: 11)?.point == SceneCursorVisit.bodyCenter(for: moved))
  }

  @Test func staleLeaseBeatGenerationDocumentAndNodeVersionsCannotRetargetOwner() throws {
    let document = document()
    let lease = UUID()
    let beat = UUID()
    let authority = try authority(document: document, lease: lease, beat: beat)
    var changedRevision = document
    changedRevision.revision += 1
    var changedID = document
    changedID.id = "different-document"
    var changedNode = document
    changedNode.nodes[0].fill = "#112233"
    let stale = try [
      self.authority(document: document, lease: UUID(), beat: beat),
      self.authority(document: document, lease: lease, beat: UUID()),
      self.authority(document: document, lease: lease, beat: beat, generation: 8),
      self.authority(document: changedRevision, lease: lease, beat: beat),
      self.authority(document: changedID, lease: lease, beat: beat),
      self.authority(document: changedNode, lease: lease, beat: beat),
      self.authority(document: document, lease: lease, beat: beat, focusID: "second"),
    ]
    var visit = try #require(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: 10))
    let before = visit.pose(at: 10.2)?.point
    for other in stale {
      let updated = visit.update(
        authority: other, point: CGPoint(x: -400, y: 0), bounds: bounds, at: 10.2)
      #expect(!updated)
      #expect(visit.authority == authority && visit.target == target)
      #expect(visit.pose(at: 10.2)?.point == before)
    }
  }

  @Test func invalidPointsAndRawNegativeOrOversizedBoundsFailClosed() throws {
    let authority = try authority()
    for point in [
      CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity),
      CGPoint(x: 10_000_001, y: 0), CGPoint(x: -901, y: -100),
    ] {
      #expect(!SceneCursorVisit.valid(point: point, in: bounds))
      #expect(
        SceneCursorVisit(
          authority: authority, from: origin, point: point, bounds: bounds, at: 0) == nil)
    }
    for invalid in [
      CGRect(x: -900, y: -300, width: -620, height: 420),
      CGRect(x: -900, y: -300, width: 0, height: 420),
      CGRect(x: -900, y: -300, width: 4_097, height: 420),
      CGRect(x: CGFloat.nan, y: -300, width: 620, height: 420),
    ] {
      #expect(!SceneCursorVisit.valid(point: target, in: invalid))
    }
    #expect(SceneCursorVisit.valid(point: target, in: bounds))
    #expect(
      SceneCursorVisit.valid(
        point: CGPoint(x: -0.75, y: -0.75),
        in: CGRect(x: -1, y: -1, width: 0.5, height: 0.5)))
  }

  @Test func invalidProjectionDoesNotMutateThePureVisitAndTimeNeverRunsBackwards() throws {
    let authority = try authority()
    var visit = try #require(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: 10))
    let invalidPoint = visit.update(
      authority: authority, point: CGPoint(x: 10_000, y: 10_000), bounds: bounds, at: 10.2)
    let pastTime = visit.update(authority: authority, point: target, bounds: bounds, at: 9)
    #expect(!invalidPoint && !pastTime)
    #expect(visit.target == target)
    #expect(visit.pose(at: 9) == nil)
    #expect(visit.pose(at: Double.nan) == nil)
    #expect(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: -1) == nil)
  }

  @Test func reduceMotionArrivesImmediatelyAndRetargetsWithoutAFlight() throws {
    let authority = try authority()
    var visit = try #require(
      SceneCursorVisit(
        authority: authority, from: origin, point: target, bounds: bounds, at: 10))
    #expect(
      visit.pose(at: 10, reduceMotion: true)?.point == SceneCursorVisit.bodyCenter(for: target))
    #expect(visit.pose(at: 10, reduceMotion: true)?.travelling == false)
    let moved = CGPoint(x: -400, y: 0)
    let updated = visit.update(
      authority: authority, point: moved, bounds: bounds, at: 10.1, reduceMotion: true)
    #expect(updated)
    #expect(
      visit.pose(at: 10.1, reduceMotion: true)?.point == SceneCursorVisit.bodyCenter(for: moved))
  }

  @Test func captionMovesOutsideSceneWhenItFitsWithoutMovingTheTriangle() {
    let display = CGRect(x: -1_000, y: -500, width: 1_600, height: 1_000)
    let scene = CGRect(x: -600, y: -250, width: 620, height: 420)
    let placement = CursorCompanionLayout.placement(
      anchor: CGPoint(x: -300, y: 0), bubbleSize: CGSize(width: 280, height: 60),
      display: display, visible: display)
    let adjusted = SceneCursorVisit.avoidingScene(
      placement, bounds: scene, display: display, visible: display)
    let originalBody = bodyCenter(placement)
    let adjustedBody = bodyCenter(adjusted)
    let bubble = globalBubble(adjusted)
    #expect(originalBody == adjustedBody)
    #expect(!bubble.intersects(scene.insetBy(dx: -6, dy: -6)))
    #expect(display.contains(bubble))
    #expect(bubble.size == placement.bubbleFrame.size)
  }

  @Test func noOutsideRoomKeepsReadableOriginalPlacementAndEmptyCaptionStaysEmpty() {
    let display = CGRect(x: 0, y: 0, width: 640, height: 420)
    let placement = CursorCompanionLayout.placement(
      anchor: CGPoint(x: 320, y: 210), bubbleSize: CGSize(width: 280, height: 60),
      display: display, visible: display)
    #expect(
      SceneCursorVisit.avoidingScene(
        placement, bounds: display, display: display, visible: display) == placement)
    let empty = CursorCompanionLayout.placement(
      anchor: CGPoint(x: 320, y: 210), bubbleSize: .zero,
      display: display, visible: display)
    #expect(
      SceneCursorVisit.avoidingScene(
        empty, bounds: bounds, display: display, visible: display) == empty)
  }

  @Test func sceneTipRemainsExactNearDisplayEdgeDespiteOrdinaryHaloClamping() {
    let display = CGRect(x: 0, y: 0, width: 1_280, height: 800)
    let surface = CGPoint(x: 20, y: 400)
    let desired = SceneCursorVisit.bodyCenter(for: surface)
    let ordinary = CursorCompanionLayout.placement(
      anchor: desired, bubbleSize: CGSize(width: 220, height: 60),
      display: display, visible: display)
    #expect(bodyCenter(ordinary) != desired)
    let anchored = SceneCursorVisit.anchoring(ordinary, bodyCenter: desired)
    #expect(bodyCenter(anchored) == desired)
    #expect(bodyCenter(anchored).x + SceneCursorVisit.bodyTipOffset.x == surface.x)
    #expect(bodyCenter(anchored).y + SceneCursorVisit.bodyTipOffset.y == surface.y)
    #expect(globalBubble(anchored) == globalBubble(ordinary))
    #expect(anchored.frame.minX < display.minX)
    let avoided = SceneCursorVisit.avoidingScene(
      anchored, bounds: CGRect(x: 0, y: 200, width: 620, height: 420),
      display: display, visible: display)
    #expect(bodyCenter(avoided) == desired)
  }

  private func document() -> SceneDocument {
    SceneDocument(
      id: "scene", revision: 3,
      nodes: [
        SceneNode(id: "part", kind: .rectangle, width: 100, height: 60, fill: "#4488CC"),
        SceneNode(id: "second", kind: .ellipse, width: 30, height: 30, fill: "#AABBCC"),
      ])
  }

  private func authority(
    document: SceneDocument? = nil, lease: UUID = UUID(), beat: UUID = UUID(),
    generation: UInt64 = 7, focusID: String = "part"
  ) throws -> SceneFocusAuthority {
    try .make(
      presentationLease: lease, generation: generation, beatID: beat,
      document: document ?? self.document(), focusID: focusID)
  }

  private func bodyCenter(_ placement: CursorCompanionPlacement) -> CGPoint {
    CGPoint(
      x: placement.frame.minX + placement.bodyPoint.x,
      y: placement.frame.maxY - placement.bodyPoint.y)
  }

  private func globalBubble(_ placement: CursorCompanionPlacement) -> CGRect {
    CGRect(
      x: placement.frame.minX + placement.bubbleFrame.minX,
      y: placement.frame.maxY - placement.bubbleFrame.maxY,
      width: placement.bubbleFrame.width, height: placement.bubbleFrame.height)
  }
}
