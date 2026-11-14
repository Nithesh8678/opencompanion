import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct CursorRetargetingTests {
  @Test func analyticVelocityMatchesActualCurveMotionAndRetargetPreservesIt() {
    let original = CursorFlight(start: .init(x: -300, y: 100), end: .init(x: 500, y: -80))
    let progress = 0.4
    let velocity = original.velocity(at: progress)
    let epsilon = 0.000001
    let a = original.point(at: progress - epsilon)
    let b = original.point(at: progress + epsilon)
    let numerical = CGPoint(
      x: (b.x - a.x) / (2 * epsilon * original.duration),
      y: (b.y - a.y) / (2 * epsilon * original.duration))
    #expect(hypot(numerical.x - velocity.x, numerical.y - velocity.y) < 0.001)
    let painted = original.point(at: progress)
    let next = original.retargeted(from: painted, to: .init(x: -400, y: -100), at: progress)
    #expect(next.point(at: 0) == painted && next.velocity(at: 0) == velocity)
    #expect(next.point(at: 1) == next.end && next.velocity(at: 1) == .zero)
  }

  @Test func explicitPaintedPoseDoesNotSnapBackToTheAnalyticOldOrigin() {
    let flight = CursorFlight(start: .zero, end: .init(x: 800, y: 0))
    let painted = CGPoint(x: 210.5, y: 13)
    let retargeted = flight.retargeted(from: painted, to: .init(x: 0, y: -300), at: 0.3)
    #expect(retargeted.point(at: 0) == painted)
    #expect(retargeted.velocity(at: 0) == flight.velocity(at: 0.3))
    for step in 0...100 {
      let point = retargeted.point(at: Double(step) / 100)
      #expect(point.x.isFinite && point.y.isFinite)
    }
  }

  @Test func repeatedOwnedProjectionUpdatesPreserveVelocityAndReduceMotionSnaps() throws {
    let document = try SceneDocument(
      id: "public-motion",
      nodes: [
        .init(
          id: "body", kind: .mesh, fill: "#778899", spatial3D: .init(geometry: .sphere(radius: 1)))
      ]
    ).validated()
    let authority = try SceneFocusAuthority.make(
      presentationLease: UUID(), generation: 1,
      beatID: UUID(), document: document, focusID: "body")
    let bounds = CGRect(x: -900, y: -300, width: 800, height: 600)
    var visit = try #require(
      SceneCursorVisit(
        authority: authority, from: .init(x: -1000, y: 0),
        point: .init(x: -200, y: 0), bounds: bounds, at: 10))
    for index in 1...30 {
      let now = 10 + Double(index) / 60
      let before = try #require(visit.pose(at: now))
      let updated = visit.update(
        authority: authority,
        point: .init(x: -200 - Double(index) * 3, y: Double(index)), bounds: bounds, at: now)
      let after = try #require(visit.pose(at: now))
      #expect(updated && after.point == before.point && after.velocity == before.velocity)
    }
    let final = try #require(visit.pose(at: 12))
    #expect(!final.travelling && final.velocity == .zero)
    let snap = try #require(visit.pose(at: 10.5, reduceMotion: true))
    #expect(!snap.travelling && snap.velocity == .zero)
  }
}
