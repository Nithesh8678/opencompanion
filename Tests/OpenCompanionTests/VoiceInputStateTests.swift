import Foundation
import Testing

@testable import OpenCompanion

@Suite struct VoiceInputStateTests {
  @Test func releaseBeforePermissionReturnsCannotReviveRecording() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .pushToTalk)
    #expect(machine.canStart(id: id))
    #expect(machine.finish(id: id) == .cancelledBeforeReady)
    #expect(!machine.canStart(id: id))
    let startedAfterRelease = machine.microphoneReady(id: id)
    #expect(!startedAfterRelease)
    #expect(machine.recognize(id: id, text: "late permission transcript", final: true) == .none)
    #expect(machine.snapshot.phase == .cancelled)
  }

  @Test func stopInvalidatesPendingStartupAndEveryOldCallback() {
    var machine = VoiceInputStateMachine()
    let old = UUID()
    let current = UUID()
    machine.begin(id: old, mode: .pushToTalk)
    machine.cancel()
    #expect(!machine.canStart(id: old))
    machine.begin(id: current, mode: .manualReview)
    #expect(machine.recognize(id: old, text: "Old result", final: true) == .none)
    let oldStarted = machine.microphoneReady(id: old)
    #expect(!oldStarted)
    #expect(machine.finish(id: old) == .none)
    #expect(machine.tailDeadline(id: old) == .none)
    let oldFailed = machine.fail(id: old)
    #expect(!oldFailed)
    #expect(machine.snapshot.sessionID == current)
    #expect(machine.snapshot.transcript.isEmpty)
    #expect(machine.canStart(id: current))
  }

  @Test func releaseWaitsForFinalTailAndSubmitsExactlyOnce() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .pushToTalk)
    let started = machine.microphoneReady(id: id)
    #expect(started)
    #expect(machine.recognize(id: id, text: "Explain", final: false) == .none)
    #expect(machine.finish(id: id) == .finishAudio)
    #expect(machine.snapshot.phase == .finishing)
    #expect(machine.recognize(id: id, text: "Explain a brushed motor", final: false) == .none)
    let effect = machine.recognize(id: id, text: "Explain a brushed motor.", final: true)
    #expect(
      effect
        == .completed(
          .init(
            sessionID: id, mode: .pushToTalk,
            transcript: "Explain a brushed motor.", isFinal: true)))
    #expect(machine.recognize(id: id, text: "Duplicate", final: true) == .none)
    #expect(machine.tailDeadline(id: id) == .none)
    #expect(machine.finish(id: id) == .none)
  }

  @Test func earlyFinalNeverSendsUntilKeyRelease() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .pushToTalk)
    machine.microphoneReady(id: id)
    #expect(machine.recognize(id: id, text: "What is torque?", final: true) == .none)
    #expect(machine.snapshot.phase == .awaitingRelease)
    #expect(machine.snapshot.isHeld)
    #expect(machine.tailDeadline(id: id) == .none)
    #expect(
      machine.finish(id: id)
        == .completed(
          .init(
            sessionID: id, mode: .pushToTalk,
            transcript: "What is torque?", isFinal: true)))
    #expect(machine.finish(id: id) == .none)
  }

  @Test func deadlineUsesOnlyRecognizedTailAndCannotFinishAnotherSession() {
    var machine = VoiceInputStateMachine()
    let first = UUID()
    let second = UUID()
    machine.begin(id: first, mode: .pushToTalk)
    machine.microphoneReady(id: first)
    _ = machine.recognize(id: first, text: "Recognized partial", final: false)
    _ = machine.finish(id: first)
    #expect(
      machine.tailDeadline(id: first)
        == .completed(
          .init(
            sessionID: first,
            mode: .pushToTalk, transcript: "Recognized partial", isFinal: false)))
    machine.begin(id: second, mode: .pushToTalk)
    machine.microphoneReady(id: second)
    #expect(machine.tailDeadline(id: first) == .none)
    #expect(machine.snapshot.phase == .listening)
  }

  @Test func cancellingAfterReleaseRejectsBothLateFinalAndTailDeadline() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .pushToTalk)
    machine.microphoneReady(id: id)
    _ = machine.recognize(id: id, text: "Do not send this cancelled utterance", final: false)
    #expect(machine.finish(id: id) == .finishAudio)
    machine.cancel()
    #expect(machine.recognize(id: id, text: "Late completed utterance", final: true) == .none)
    #expect(machine.tailDeadline(id: id) == .none)
    #expect(machine.snapshot.sessionID == nil)
    #expect(machine.snapshot.transcript.isEmpty)
  }

  @Test func newHoldAfterReleaseCannotReceiveOldFinalOrTail() {
    var machine = VoiceInputStateMachine()
    let old = UUID()
    let current = UUID()
    machine.begin(id: old, mode: .pushToTalk)
    machine.microphoneReady(id: old)
    _ = machine.recognize(id: old, text: "Old partial", final: false)
    _ = machine.finish(id: old)
    machine.begin(id: current, mode: .pushToTalk)
    machine.microphoneReady(id: current)
    _ = machine.recognize(id: current, text: "New partial", final: false)
    #expect(machine.recognize(id: old, text: "Old final", final: true) == .none)
    #expect(machine.tailDeadline(id: old) == .none)
    #expect(machine.snapshot.sessionID == current)
    #expect(machine.snapshot.transcript == "New partial")
    #expect(machine.snapshot.phase == .listening)
    _ = machine.finish(id: current)
    #expect(
      machine.recognize(id: current, text: "New final", final: true)
        == .completed(
          .init(sessionID: current, mode: .pushToTalk, transcript: "New final", isFinal: true)))
    #expect(machine.tailDeadline(id: current) == .none)
  }

  @Test func manualMicrophoneCompletesForReviewWithoutAutomaticSubmission() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .manualReview)
    machine.microphoneReady(id: id)
    _ = machine.recognize(id: id, text: "Draft", final: false)
    #expect(machine.finish(id: id) == .finishAudio)
    let effect = machine.recognize(id: id, text: "Review this draft.", final: true)
    #expect(
      effect
        == .completed(
          .init(
            sessionID: id, mode: .manualReview,
            transcript: "Review this draft.", isFinal: true)))
    #expect(!VoiceInputMode.manualReview.submitsOnCompletion)
    #expect(VoiceInputMode.pushToTalk.submitsOnCompletion)
  }

  @Test func recognitionFailureCannotSubmitOrApplyLateTranscript() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .pushToTalk)
    machine.microphoneReady(id: id)
    _ = machine.finish(id: id)
    let failed = machine.fail(id: id)
    #expect(failed)
    #expect(machine.recognize(id: id, text: "Late final after route failure", final: true) == .none)
    #expect(machine.tailDeadline(id: id) == .none)
    #expect(!machine.snapshot.isHeld)
  }

  @Test func pttNeverOverwritesTheDraftAndManualDictationRespectsTypedEdits() {
    var draft = VoiceDraftGuard(draft: "Typed unsent question")
    #expect(
      draft.replacement(
        mode: .pushToTalk, transcript: "Voice question",
        currentDraft: "Typed unsent question") == nil)
    #expect(
      draft.replacement(
        mode: .manualReview, transcript: "Partial",
        currentDraft: "Typed unsent question") == "Partial")
    #expect(
      draft.replacement(
        mode: .manualReview, transcript: "Final",
        currentDraft: "User edited Partial") == nil)
    #expect(
      draft.replacement(
        mode: .manualReview, transcript: "Still late",
        currentDraft: "User edited Partial") == nil)
  }

  @Test func emptyOrWhitespaceRecognitionNeverFallsBackToAnUnrelatedDraft() {
    var machine = VoiceInputStateMachine()
    let id = UUID()
    machine.begin(id: id, mode: .pushToTalk)
    machine.microphoneReady(id: id)
    _ = machine.recognize(id: id, text: "  \n ", final: false)
    _ = machine.finish(id: id)
    #expect(
      machine.tailDeadline(id: id)
        == .completed(
          .init(
            sessionID: id,
            mode: .pushToTalk, transcript: "", isFinal: false)))
  }
}
