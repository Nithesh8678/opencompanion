import Testing

@testable import OpenCompanion

@Suite struct NotchActivityStateTests {
  @Test func unrelatedTextAndManualVoiceCannotOpenActivity() {
    var activity = NotchActivityState()
    #expect(
      activity.update(
        generation: 8, inputPhase: "Listening", pushToTalkActive: false,
        busy: false, state: "Listening") == .idle)
    #expect(
      activity.update(
        generation: 9, inputPhase: "Ready", pushToTalkActive: false,
        busy: true, state: "Speaking", hasPendingSpeech: true) == .idle)
    #expect(activity.begin(generation: 8) == false)
  }

  @Test func realInputPhasesAreDistinctFromGenericListeningBoolean() {
    var activity = NotchActivityState()
    #expect(activity.begin(generation: 10) == true)
    #expect(activity.phase == .preparing)
    #expect(
      activity.update(
        generation: 10, inputPhase: "Preparing microphone", pushToTalkActive: true,
        busy: false, state: "Preparing microphone") == .preparing)
    #expect(
      activity.update(
        generation: 10, inputPhase: "Listening", pushToTalkActive: true,
        busy: false, state: "Listening") == .listening)
    #expect(
      activity.update(
        generation: 10, inputPhase: "Release Control+Option to send", pushToTalkActive: true,
        busy: false, state: "Release Control+Option to send") == .thinking)
    #expect(
      activity.update(
        generation: 10, inputPhase: "Finishing speech", pushToTalkActive: false,
        busy: false, state: "Finishing speech") == .thinking)
  }

  @Test func voiceSubmissionMustExplicitlyTransferGenerationOwnership() {
    var activity = NotchActivityState()
    activity.begin(generation: 10)
    #expect(activity.handoff(from: 10, to: 12) == true)
    #expect(activity.generation == 12)
    #expect(
      activity.update(
        generation: 12, inputPhase: "Ready", pushToTalkActive: false,
        busy: true, state: "Thinking") == .thinking)
    #expect(activity.handoff(from: 12, to: 14) == false)
    #expect(activity.handoff(from: 10, to: 12) == false)
  }

  @Test func aTypedTurnWithTheSameGenerationIncrementCannotInheritVoiceActivity() {
    var activity = NotchActivityState()
    activity.begin(generation: 10)
    #expect(
      activity.update(
        generation: 12, inputPhase: "Ready", pushToTalkActive: false,
        busy: true, state: "Thinking") == .idle)
    #expect(activity.handoff(from: 10, to: 12) == false)
    #expect(activity.begin(generation: 12) == false)
  }

  @Test func queuedSpeechSurvivesProviderCompletionBeforeDidStart() {
    var activity = NotchActivityState()
    activity.begin(generation: 1)
    activity.handoff(from: 1, to: 3)
    #expect(
      activity.update(
        generation: 3, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Ready", hasPendingSpeech: true) == .thinking)
    #expect(
      activity.update(
        generation: 3, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Speaking", hasPendingSpeech: true) == .speaking)
    #expect(
      activity.update(
        generation: 3, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Ready", hasPendingSpeech: false) == .idle)
    #expect(activity.generation == nil)
    #expect(
      activity.update(
        generation: 3, inputPhase: "Ready", pushToTalkActive: false,
        busy: true, state: "Speaking", hasPendingSpeech: true) == .idle)
    #expect(activity.begin(generation: 3) == false)
  }

  @Test func anOldSpeakingLabelWithoutQueuedAudioDoesNotPinActivity() {
    var activity = NotchActivityState()
    activity.begin(generation: 1)
    activity.handoff(from: 1, to: 2)
    #expect(
      activity.update(
        generation: 2, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Speaking", hasPendingSpeech: false) == .idle)
  }

  @Test func emptyReleaseAndPermissionFailureTerminateWithoutForeverPinning() {
    for phase in ["Ready", "Voice unavailable", "Cancelled", "Unexpected input state"] {
      var activity = NotchActivityState()
      activity.begin(generation: 20)
      #expect(
        activity.update(
          generation: 20, inputPhase: phase, pushToTalkActive: false,
          busy: false, state: "Ready") == .idle)
      #expect(activity.begin(generation: 20) == false)
      #expect(activity.begin(generation: 21) == true)
    }
  }

  @Test func failureClosesEvenWhenAnAudioQueueHasNotDrained() {
    var activity = NotchActivityState()
    activity.begin(generation: 30)
    activity.handoff(from: 30, to: 32)
    #expect(
      activity.update(
        generation: 32, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Ready", hasPendingSpeech: true, failed: true) == .idle)
    #expect(
      activity.update(
        generation: 32, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Speaking", hasPendingSpeech: true) == .idle)
  }

  @Test func newHotkeyPressRejectsOldUpdatesAndCancellation() {
    var activity = NotchActivityState()
    activity.begin(generation: 40)
    activity.cancel(generation: 41)
    #expect(activity.phase == .idle)
    #expect(activity.begin(generation: 40) == false)
    #expect(activity.begin(generation: 41) == false)
    #expect(activity.begin(generation: 42) == true)
    #expect(
      activity.update(
        generation: 40, inputPhase: "Ready", pushToTalkActive: false,
        busy: false, state: "Ready") == .preparing)
    activity.cancel(generation: 41)
    #expect(activity.phase == .preparing)
    #expect(activity.begin(generation: 42) == false)
    activity.cancel(generation: 42)
    #expect(activity.phase == .idle)
  }

  @Test func handoffDoesNotAssumeAnIncrementOrOverflowAtMaximumGeneration() {
    var activity = NotchActivityState()
    #expect(activity.begin(generation: UInt64.max - 10) == true)
    #expect(activity.handoff(from: UInt64.max - 10, to: UInt64.max) == true)
    activity.cancel(generation: UInt64.max)
    #expect(activity.phase == .idle)
    #expect(activity.begin(generation: 0) == false)
    #expect(activity.begin(generation: UInt64.max) == false)
  }
}
