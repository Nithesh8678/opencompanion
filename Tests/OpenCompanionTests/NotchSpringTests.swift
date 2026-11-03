import Foundation
import Testing

@testable import OpenCompanion

@Suite struct NotchSpringTests {
  @Test func unevenFrameIntervalsHaveTheSamePoseAsElapsedTime() {
    var regular = NotchSpring(185)
    var uneven = NotchSpring(185)
    regular.target = 530
    uneven.target = 530
    for _ in 0..<30 { regular.advance(by: 1.0 / 120) }
    for delta in [0.01, 0.033, 0.007, 0.06, 0.04, 0.1] { uneven.advance(by: delta) }
    #expect(abs(regular.value - uneven.value) < 0.000001)
    #expect(abs(regular.velocity - uneven.velocity) < 0.000001)
  }

  @Test func reversingTargetPreservesVelocityAndSettlesAtNewEndpoint() {
    var spring = NotchSpring(185)
    spring.target = 814
    spring.advance(by: 0.07)
    let pose = spring.value
    let velocity = spring.velocity
    spring.target = 185
    #expect(spring.value == pose && spring.velocity == velocity)
    for _ in 0..<180 { spring.advance(by: 1.0 / 120) }
    #expect(spring.isSettled)
    #expect(abs(spring.value - 185) < 0.001)
  }

  @Test func invalidAndSuspendedClockIntervalsRemainFinite() {
    var spring = NotchSpring(516)
    spring.target = 800
    for delta in [Double.nan, -Double.infinity, -1, 0] { spring.advance(by: delta) }
    #expect(spring.value == 516 && spring.velocity == 0)
    spring.advance(by: 120)
    #expect(spring.value.isFinite && spring.velocity.isFinite && spring.isSettled)
  }

  @Test func hoverAlwaysReturnsHomeAfterAnExplicitDestination() {
    var state = NotchPresentationState()
    for destination in [NotchDestination.chat, .settings] {
      state.open(destination)
      #expect(state.exposure == .interactive && state.destination == destination)
      state.tuck()
      state.revealHome()
      #expect(state.exposure == .hover && state.destination == .home)
    }
  }
}
