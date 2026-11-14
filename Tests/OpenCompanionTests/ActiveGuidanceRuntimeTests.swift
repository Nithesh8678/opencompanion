import Foundation
import Testing

@testable import OpenCompanion

struct ActiveGuidanceRuntimeTests {
  @Test func noStoredPreferenceCanCreateRuntimeAuthority() {
    var runtime = ActiveGuidanceRuntime()
    #expect(!runtime.isActive && runtime.settleDelay(now: 1) == nil)
    runtime.start(goal: "Find the profile", speakAloud: true, selectedScope: nil)
    let first = runtime.id
    #expect(first != nil && runtime.phase == .checking)
    runtime.stop()
    #expect(!runtime.isActive && runtime.goal.isEmpty)
    runtime.start(goal: "Another goal", speakAloud: false, selectedScope: nil)
    #expect(runtime.id != first)
  }

  @Test func changesCoalesceAndSettlementCannotStarveOnAnimation() throws {
    var runtime = ActiveGuidanceRuntime()
    runtime.start(goal: "Open settings", speakAloud: false, selectedScope: nil)
    let id = try #require(runtime.id)
    let accepted1 = runtime.change(sessionID: id, sequence: 1, at: 10)
    #expect(accepted1)
    let accepted2 = runtime.change(sessionID: id, sequence: 2, at: 10.2)
    #expect(accepted2)
    #expect(runtime.sceneEpoch == 2 && runtime.isDirty)
    #expect(abs((runtime.settleDelay(now: 10.2) ?? -1) - 0.25) < 0.0001)
    let accepted3 = runtime.change(sessionID: id, sequence: 3, at: 11.1)
    #expect(accepted3)
    #expect(abs((runtime.settleDelay(now: 11.1) ?? -1) - 0.1) < 0.0001)
    runtime.check()
    #expect(!runtime.isDirty && runtime.settleDelay(now: 12) == nil)
    runtime.wait()
    #expect(runtime.phase == .awaitingUser)
  }

  @Test func listeningDefersChecksAndStaleOrMalformedEventsCannotRearm() throws {
    var runtime = ActiveGuidanceRuntime()
    runtime.start(goal: "Guide", speakAloud: true, selectedScope: nil)
    let id = try #require(runtime.id)
    runtime.listen()
    let accepted4 = runtime.change(sessionID: id, sequence: 1, at: 10)
    #expect(accepted4)
    #expect(runtime.phase == .listening && runtime.settleDelay(now: 11) == nil)
    let accepted5 = !runtime.change(sessionID: id, sequence: 1, at: 11)
    #expect(accepted5)
    let accepted6 = !runtime.change(sessionID: UUID(), sequence: 2, at: 11)
    #expect(accepted6)
    let accepted7 = !runtime.change(sessionID: id, sequence: 2, at: .nan)
    #expect(accepted7)
    runtime.stop()
    let accepted8 = !runtime.change(sessionID: id, sequence: 3, at: 12)
    #expect(accepted8)
    #expect(!runtime.isActive)
  }

  @Test func visualHandoffKeepsUserTopicWithoutOldAssistantCapabilityDenial() {
    let history = GuidanceFollowupContext.visualHistory(
      [
        .init(role: "user", text: "Explain a rocket"),
        .init(role: "assistant", text: "This session has no renderer"),
      ], current: "Show it in 3D")
    #expect(history.map(\.text) == ["Explain a rocket", "Show it in 3D"])
    #expect(GuidanceFollowupContext.isShortContinuation("What's next?"))
    #expect(!GuidanceFollowupContext.isShortContinuation("Do not continue"))
  }

  @Test func visualProofCannotEraseLaterFramesOrHardEvents() throws {
    var runtime = ActiveGuidanceRuntime()
    runtime.start(goal: "Open settings", speakAloud: false, selectedScope: nil)
    let id = try #require(runtime.id)
    let accepted9 = runtime.change(sessionID: id, sequence: 1, at: 1, visualOnly: true)
    #expect(accepted9)
    let covered = runtime.sceneEpoch
    let hard = runtime.hardEpoch
    #expect(!runtime.hasHardChange)
    let accepted10 = runtime.change(sessionID: id, sequence: 2, at: 2, visualOnly: true)
    #expect(accepted10)
    let accepted11 = runtime.acknowledgeVisual(through: covered, hardEpoch: hard)
    #expect(accepted11)
    #expect(runtime.isDirty)
    let accepted12 = runtime.change(sessionID: id, sequence: 3, at: 3)
    #expect(accepted12)
    #expect(runtime.hasHardChange)
    let accepted13 = !runtime.acknowledgeVisual(through: runtime.sceneEpoch, hardEpoch: hard)
    #expect(accepted13)
    #expect(runtime.isDirty)
  }
}
