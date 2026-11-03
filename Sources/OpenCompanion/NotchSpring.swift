import Foundation

/// Closed-form critically damped motion. It is stable at uneven display
/// intervals and preserves velocity when the target reverses mid-flight.
struct NotchSpring: Sendable {
  private(set) var value: Double
  private(set) var velocity: Double = 0
  var target: Double
  let frequency: Double

  init(_ value: Double, frequency: Double = 24) {
    self.value = value
    target = value
    self.frequency = frequency
  }

  mutating func advance(by delta: Double) {
    guard delta.isFinite, delta > 0 else { return }
    let offset = value - target
    let c = velocity + frequency * offset
    let decay = exp(-frequency * delta)
    value = target + (offset + c * delta) * decay
    velocity = (velocity - frequency * c * delta) * decay
  }

  var isSettled: Bool { abs(value - target) < 0.08 && abs(velocity) < 1.5 }
}
