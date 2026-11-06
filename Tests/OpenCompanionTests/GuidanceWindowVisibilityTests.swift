import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

/// Authored metadata only. Never queries the WindowServer or constructs UI.
struct GuidanceWindowVisibilityTests {
  @Test func anExactVisibleWindowAllowsItsContainedNegativeOriginCrop() {
    #expect(permits([selected]))
    // The pure policy permits an authored own-process source too; external
    // capture ownership is a separate host responsibility.
    #expect(permits([selected], ownPID: source.ownerPID))
  }

  @Test func higherSiblingWindowsAndPartlyTransparentWindowsStillObscureTheTarget() {
    #expect(!permits([record(id: 20, owner: source.ownerPID), selected]))
    #expect(!permits([record(id: 20, alpha: 0.01), selected]))
    #expect(permits([selected, record(id: 20)]))
    #expect(permits([record(id: 20, alpha: 0), selected]))
    #expect(permits([record(id: 20, onScreen: false), selected]))
    #expect(
      permits([
        record(id: 20, bounds: CGRect(x: -500, y: 180, width: 20, height: 20)), selected,
      ]))
    #expect(
      !permits([
        record(id: 20, bounds: CGRect(x: -511, y: 180, width: 20, height: 20)), selected,
      ]))
  }

  @Test func exclusionsRequireBothTheExactIDAndOurOwner() {
    let own: pid_t = 900
    let overlay = record(id: 20, owner: own)
    #expect(permits([overlay, selected], ownPID: own, passive: [20]))
    #expect(!permits([overlay, selected], ownPID: own, passive: [21]))
    #expect(!permits([record(id: 20, owner: 901), selected], ownPID: own, passive: [20]))
    #expect(!permits([record(id: 21, owner: own), overlay, selected], ownPID: own, passive: [20]))
    // Declaring a passive ID cannot override the independent native hit result.
    #expect(!permits([overlay, selected], hit: 20, ownPID: own, passive: [20]))
  }

  @Test func exactHitWindowOwnerBoundsAndPresenceAreRequired() {
    #expect(!permits([selected], hit: nil))
    #expect(!permits([selected], hit: 11))
    #expect(!permits([]))
    #expect(!permits([record(id: 11)]))
    #expect(!permits([record(id: source.id, owner: 422, bounds: source.capturedBounds)]))
    var changed = source.capturedBounds
    changed.origin.x += 0.01
    #expect(!permits([record(id: source.id, bounds: changed)]))
    changed = source.capturedBounds
    changed.size.height -= 1
    #expect(!permits([record(id: source.id, bounds: changed)]))
    #expect(!permits([record(id: source.id, bounds: source.capturedBounds, onScreen: false)]))
    #expect(!permits([record(id: source.id, bounds: source.capturedBounds, alpha: 0)]))
  }

  @Test func targetAndCropMustBeFullyContainedWithoutStandardizingNegativeSizes() {
    var outsideTarget = target
    outsideTarget.origin.x = source.sourceRect.minX - 1
    #expect(!permits([selected], target: outsideTarget))
    let outsideCrop = GuidanceWindowSource(
      id: source.id, ownerPID: source.ownerPID, capturedBounds: source.capturedBounds,
      sourceRect: CGRect(x: -701, y: 100, width: 300, height: 160))
    #expect(!permits([selected], source: outsideCrop))
    for invalid in invalidRects {
      #expect(!permits([selected], target: invalid))
      #expect(
        !permits(
          [selected],
          source: .init(
            id: source.id, ownerPID: source.ownerPID,
            capturedBounds: invalid, sourceRect: source.sourceRect)))
      #expect(
        !permits(
          [selected],
          source: .init(
            id: source.id, ownerPID: source.ownerPID,
            capturedBounds: source.capturedBounds, sourceRect: invalid)))
      #expect(!permits([selected, record(id: 20, bounds: invalid)]))
    }
  }

  @Test func malformedRecordsAndDuplicateIDsFailClosedEvenBehindTheSelection() {
    #expect(!permits([selected, selected]))
    #expect(!permits([record(id: 20), selected, record(id: 20)]))
    #expect(!permits([selected, record(id: 0)]))
    #expect(!permits([selected, record(id: 20, owner: 0)]))
    for alpha in [Double.nan, .infinity, -0.1, 1.1] {
      #expect(!permits([selected, record(id: 20, alpha: alpha)]))
    }
    #expect(!permits([selected], ownPID: 0))
    #expect(
      !permits(
        [selected],
        source: .init(
          id: 0, ownerPID: source.ownerPID,
          capturedBounds: source.capturedBounds, sourceRect: source.sourceRect)))
    #expect(
      !permits(
        [selected],
        source: .init(
          id: source.id, ownerPID: -1,
          capturedBounds: source.capturedBounds, sourceRect: source.sourceRect)))
  }

  @Test func theSnapshotWorkBudgetHasAnExactBoundary() {
    let outside = CGRect(x: 1_000, y: 1_000, width: 10, height: 10)
    let higher = (1...4_095).map { offset in
      record(id: CGWindowID(100 + offset), bounds: outside)
    }
    #expect(permits(higher + [selected]))
    #expect(!permits(higher + [selected, record(id: 9_999, bounds: outside)]))
  }

  private var source: GuidanceWindowSource {
    .init(
      id: 10, ownerPID: 421,
      capturedBounds: CGRect(x: -700, y: 100, width: 500, height: 300),
      sourceRect: CGRect(x: -650, y: 150, width: 300, height: 160))
  }

  private var target: CGRect { CGRect(x: -610, y: 180, width: 100, height: 40) }

  private var selected: GuidanceWindowRecord {
    record(id: source.id, bounds: source.capturedBounds)
  }

  private var invalidRects: [CGRect] {
    [
      CGRect(x: 0, y: 0, width: -20, height: 30),
      CGRect(x: 0, y: 0, width: 20, height: 0),
      CGRect(x: CGFloat.nan, y: 0, width: 20, height: 30),
      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 30),
      CGRect(x: 10_000_001, y: 0, width: 20, height: 30),
      CGRect(x: 0, y: 0, width: 20, height: 100_001),
    ]
  }

  private func record(
    id: CGWindowID, owner: pid_t = 421, bounds: CGRect? = nil,
    alpha: Double = 1, onScreen: Bool = true
  ) -> GuidanceWindowRecord {
    .init(id: id, ownerPID: owner, bounds: bounds ?? target, alpha: alpha, isOnScreen: onScreen)
  }

  private func permits(
    _ records: [GuidanceWindowRecord], source: GuidanceWindowSource? = nil,
    target: CGRect? = nil, hit: CGWindowID? = 10, ownPID: pid_t = 900,
    passive: Set<CGWindowID> = []
  ) -> Bool {
    GuidanceWindowVisibility.permits(
      source: source ?? self.source, targetRect: target ?? self.target, frontToBack: records,
      hitWindowID: hit, ownPID: ownPID, passiveWindowIDs: passive)
  }
}
