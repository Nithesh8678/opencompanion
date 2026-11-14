import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceObservationFrameTests {
  @Test func selectedCropUsesExactTopLeftLocalScopeWithoutWideningOrUnboundedPixels() throws {
    let window = CGRect(x: -900, y: -300, width: 600, height: 400)
    let crop = CGRect(x: -800, y: -200, width: 240, height: 100)
    let plan = try #require(GuidanceObservationSamplingPlan(source: crop, containing: window))
    #expect(plan.sourceRect == CGRect(x: 100, y: 200, width: 240, height: 100))
    #expect(plan.width == 256)
    #expect(plan.height == 106)
    let tooWide = GuidanceObservationSamplingPlan(
      source: crop.offsetBy(dx: 600, dy: 0), containing: window)
    #expect(tooWide == nil)
    let subpixel = GuidanceObservationSamplingPlan(
      source: CGRect(x: -800, y: -200, width: 1e-300, height: 1e-300), containing: window)
    #expect(subpixel == nil)
    let huge = try #require(
      GuidanceObservationSamplingPlan(
        source: CGRect(x: -1_000, y: 0, width: 100_000, height: 1),
        containing: CGRect(x: -1_000, y: 0, width: 100_000, height: 1)))
    #expect(huge.width == 256)
    #expect(huge.height == 1)
  }

  @Test func nativeRowsAreFrozenAndFramesHaveStrictByteAndClockBounds() throws {
    var bytes = Data(repeating: 40, count: 8 * 4 * 4)
    let frame = try #require(
      GuidanceObservationFrame(
        width: 8, height: 4, contentTime: 10, receivedAt: 11, pixels: bytes))
    bytes[0] = 200
    #expect(frame.pixels[0] == 40)
    for dimensions in [(0, 4), (-1, 4), (257, 4), (8, 161), (Int.max, 4)] {
      let rejected = GuidanceObservationFrame(
        width: dimensions.0, height: dimensions.1,
        contentTime: 10, receivedAt: 11, pixels: bytes)
      #expect(rejected == nil)
    }
    for times in [(Double.nan, 11.0), (-1.0, 11.0), (12.0, 11.0), (10.0, Double.infinity)] {
      let rejected = GuidanceObservationFrame(
        width: 8, height: 4,
        contentTime: times.0, receivedAt: times.1, pixels: bytes)
      #expect(rejected == nil)
    }
    let short = GuidanceObservationFrame(
      width: 8, height: 4,
      contentTime: 10, receivedAt: 11, pixels: Data(bytes.dropLast()))
    #expect(short == nil)
  }

  @Test func equalContentAndOutOfOrderFramesCannotManufactureFreshChanges() throws {
    var state = GuidanceLatestFrameState()
    let first = try frame(time: 10, received: 11)
    let firstUpdate = state.accept(first)
    #expect(firstUpdate == .initial)
    let duplicate = state.accept(try frame(time: 10, received: 12, color: (255, 0, 0)))
    #expect(duplicate == .rejected)
    let older = state.accept(try frame(time: 9, received: 13))
    #expect(older == .rejected)
    #expect(state.latestFrame == first)
    let unchanged = state.accept(try frame(time: 11, received: 12))
    #expect(unchanged == .unchanged)
    #expect(state.latestFrame?.contentTime == 11)
    let receiptReversal = state.accept(try frame(time: 11.5, received: 11.5))
    #expect(receiptReversal == .rejected)
    #expect(state.latestFrame?.receivedAt == 12)
    state.reset()
    #expect(state.latestFrame == nil)
  }

  @Test func localChangesAndEqualBrightnessHueChangesAreObservedWithoutAlphaNoise() throws {
    var state = GuidanceLatestFrameState()
    _ = state.accept(try frame(time: 1, received: 1, color: (255, 0, 0)))
    let hue = state.accept(try frame(time: 2, received: 2, color: (0, 130, 0)))
    #expect(hue == .changed)
    var pixels = try frame(time: 3, received: 3, color: (0, 130, 0)).pixels
    for pixel in 0..<8 { pixels[pixel * 4] = 200 }
    let local = try #require(
      GuidanceObservationFrame(
        width: 32, height: 20,
        contentTime: 3, receivedAt: 3, pixels: pixels))
    let localUpdate = state.accept(local)
    #expect(localUpdate == .changed)
    for pixel in 0..<640 { pixels[pixel * 4 + 3] = 0 }
    let alpha = try #require(
      GuidanceObservationFrame(
        width: 32, height: 20,
        contentTime: 4, receivedAt: 4, pixels: pixels))
    let alphaUpdate = state.accept(alpha)
    #expect(alphaUpdate == .unchanged)
  }

  @Test func gradualSubthresholdChangesAccumulateAgainstTheLastReportedBaseline() throws {
    var state = GuidanceLatestFrameState()
    let first = try frame(time: 1, received: 1)
    let initial = state.accept(first)
    #expect(initial == .initial)
    var updates: [GuidanceLatestFrameState.Update] = []
    for step in 1...10 {
      var pixels = first.pixels
      // Each adjacent frame changes only one channel by one level in one fifth
      // of the image. Adjacent-only comparison never reports this transition.
      for pixel in 0..<128 { pixels[pixel * 4] += UInt8(step) }
      let sample = try #require(
        GuidanceObservationFrame(
          width: 32, height: 20,
          contentTime: Double(step + 1), receivedAt: Double(step + 1), pixels: pixels))
      updates.append(state.accept(sample))
    }
    #expect(updates.prefix(4).allSatisfy { $0 == .unchanged })
    #expect(updates.filter { $0 == .changed }.count == 2)
    #expect(updates.suffix(4).filter { $0 == .changed }.count == 1)
    #expect(state.latestFrame?.contentTime == 11)
    state.reset()
    let nextInitial = state.accept(first)
    #expect(nextInitial == .initial)
  }

  @Test func pendingFramesReplaceOneSlotAndDrainCannotLoseAConcurrentOffer() throws {
    let mailbox = GuidanceLatestFrameMailbox()
    let first = try frame(time: 1, received: 1)
    let latest = try frame(time: 2, received: 2)
    #expect(mailbox.offer(first))
    #expect(!mailbox.offer(latest))
    #expect(mailbox.take() == latest)
    let racing = try frame(time: 3, received: 3)
    #expect(!mailbox.offer(racing))
    #expect(mailbox.finishDrain())
    #expect(mailbox.take() == racing)
    #expect(!mailbox.finishDrain())
    #expect(mailbox.offer(first))
    mailbox.invalidate()
    #expect(mailbox.take() == nil)
    #expect(!mailbox.offer(latest))
    #expect(!mailbox.finishDrain())
  }

  @Test func independentWindowPlacementChangesWithoutNewPixelContent() {
    var state = GuidanceObservationWindowState()
    let first = CGRect(x: -900, y: -200, width: 500, height: 300)
    let initial = state.accept(first)
    let same = state.accept(first)
    let moved = state.accept(first.offsetBy(dx: 1, dy: 0))
    let invalid = state.accept(CGRect(x: 0, y: 0, width: -1, height: 20))
    #expect(!initial)
    #expect(!same)
    #expect(moved)
    #expect(!invalid)
    #expect(state.latestBounds == first.offsetBy(dx: 1, dy: 0))
  }

  private func frame(time: Double, received: Double, color: (UInt8, UInt8, UInt8) = (40, 50, 60))
    throws
    -> GuidanceObservationFrame
  {
    var pixels = Data(count: 32 * 20 * 4)
    for pixel in 0..<640 {
      pixels[pixel * 4] = color.0
      pixels[pixel * 4 + 1] = color.1
      pixels[pixel * 4 + 2] = color.2
      pixels[pixel * 4 + 3] = 255
    }
    return try #require(
      GuidanceObservationFrame(
        width: 32, height: 20,
        contentTime: time, receivedAt: received, pixels: pixels))
  }
}
