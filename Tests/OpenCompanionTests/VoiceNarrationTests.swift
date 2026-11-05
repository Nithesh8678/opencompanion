import AVFoundation
import Foundation
import Testing

@testable import OpenCompanion

@MainActor struct VoiceNarrationTests {
  @Test func typedAdmissionReturnsIdentityAndLegacySpeechKeepsItsOriginalCallbacks() throws {
    let fixture = NarrationFixture()
    let context = VoiceNarrationContext(generation: 7, narrationID: UUID())
    let admitted = fixture.service.speak("Public typed narration.", context: context)
    #expect(admitted && fixture.service.hasPendingSpeech)
    let queued = try #require(fixture.updates.first)
    #expect(queued.context == context && queued.kind == .enqueued)
    #expect(queued.revealedUTF16End == 0 && queued.cancellationReason == nil)
    #expect(queued.observedUptime.isFinite && queued.observedUptime >= 0)
    let typedID = ObjectIdentifier(try #require(fixture.utterances.first))
    fixture.deliver(.started, id: typedID, token: queued.token)
    fixture.deliver(.finished, id: typedID, token: queued.token)
    #expect(fixture.updates.map(\.kind) == [.enqueued, .started, .finished])
    #expect(fixture.states == ["Speaking", "Ready"])
    #expect(fixture.diagnostics == ["audio.synthesizerDidStart", "audio.synthesizerDidFinish"])
    let legacyAdmitted = fixture.service.speak("Public legacy narration.")
    #expect(legacyAdmitted && fixture.utterances.count == 2)
    #expect(fixture.updates.count == 3)
    fixture.service.stop()
    #expect(!fixture.service.hasPendingSpeech && fixture.updates.count == 3)
  }

  @Test func boundedNativeAdmissionHasNoReceiptForRejectedRequests() throws {
    let fixture = NarrationFixture()
    let context = VoiceNarrationContext(generation: 8, narrationID: UUID())
    let empty = fixture.service.speak("", context: context)
    let tooLong = fixture.service.speak(String(repeating: "😀", count: 8_001), context: context)
    #expect(!empty && !tooLong && fixture.updates.isEmpty && fixture.utterances.isEmpty)
    let exact = fixture.service.speak(String(repeating: "😀", count: 8_000), context: context)
    #expect(exact)
    for _ in 1..<24 {
      let admitted = fixture.service.speak(
        "Public bounded queue entry.", context: .init(generation: 8, narrationID: UUID()))
      #expect(admitted)
    }
    let overflow = fixture.service.speak("Public overflow.", context: context)
    #expect(!overflow && fixture.utterances.count == 24 && fixture.updates.count == 24)
    let first = try #require(fixture.updates.first)
    let id = ObjectIdentifier(try #require(fixture.utterances.first))
    fixture.deliver(.finished, id: id, token: first.token)
    let capacityReturned = fixture.service.speak("Public replacement.", context: context)
    #expect(capacityReturned)
    #expect(fixture.updates.filter { $0.kind == .enqueued }.count == 25)
    fixture.service.stop()
  }

  @Test func utf16RangesRevealOnlyCompleteGraphemesAndNeverRewind() throws {
    let fixture = NarrationFixture()
    let text = "A 👩🏽‍💻 e\u{301} 終"
    let context = VoiceNarrationContext(generation: 9, narrationID: UUID())
    _ = fixture.service.speak(text, context: context)
    let queued = try #require(fixture.updates.first)
    let id = ObjectIdentifier(try #require(fixture.utterances.first))
    let layout = try #require(VoiceNarrationText(text))
    fixture.deliver(.started, id: id, token: queued.token)
    fixture.deliver(.range(location: 0, length: 1), id: id, token: queued.token)
    let firstEnd = try #require(fixture.updates.last).revealedUTF16End
    #expect(layout.prefix(throughUTF16End: firstEnd) == "A")
    fixture.deliver(.range(location: 2, length: 1), id: id, token: queued.token)
    let secondEnd = try #require(fixture.updates.last).revealedUTF16End
    #expect(layout.prefix(throughUTF16End: secondEnd) == "A ")
    let emojiEnd = "A 👩🏽‍💻".utf16.count
    fixture.deliver(.range(location: 2, length: emojiEnd - 2), id: id, token: queued.token)
    #expect(fixture.updates.last?.revealedUTF16End == emojiEnd)
    let count = fixture.updates.count
    for range in [
      NSRange(location: -1, length: 2), NSRange(location: Int.max, length: Int.max),
      NSRange(location: 0, length: Int.max), NSRange(location: 0, length: 1),
      NSRange(location: emojiEnd, length: 0), NSRange(location: layout.utf16Count, length: 1),
    ] {
      fixture.deliver(
        .range(location: range.location, length: range.length), id: id, token: queued.token)
    }
    #expect(fixture.updates.count == count)
    fixture.deliver(.finished, id: id, token: queued.token)
    #expect(fixture.updates.last?.revealedUTF16End == text.utf16.count)
    #expect(fixture.updates.last?.kind == .finished)
    #expect(layout.prefix(throughUTF16End: emojiEnd + 2) == "A 👩🏽‍💻 ")
    #expect(layout.prefix(throughUTF16End: Int.max) == text)
    #expect(layout.prefix(throughUTF16End: -1).isEmpty)
  }

  @Test func earlyRangeWaitsForStartAndDuplicateEventsCannotRepeatProgress() throws {
    let fixture = NarrationFixture()
    _ = fixture.service.speak("First second.", context: .init(generation: 10, narrationID: UUID()))
    let queued = try #require(fixture.updates.first)
    let id = ObjectIdentifier(try #require(fixture.utterances.first))
    fixture.deliver(.range(location: 0, length: 5), id: id, token: queued.token)
    #expect(fixture.updates.map(\.kind) == [.enqueued])
    fixture.deliver(.started, id: id, token: queued.token)
    #expect(fixture.updates.map(\.kind) == [.enqueued, .started, .range])
    #expect(fixture.updates.last?.revealedUTF16End == 5)
    fixture.deliver(.started, id: id, token: queued.token)
    fixture.deliver(.range(location: 0, length: 5), id: id, token: queued.token)
    #expect(fixture.updates.count == 3)
    fixture.deliver(.cancelled, id: id, token: queued.token)
    fixture.deliver(.finished, id: id, token: queued.token)
    fixture.deliver(.started, id: id, token: queued.token)
    #expect(fixture.updates.count == 4)
    #expect(fixture.updates.last?.kind == .cancelled)
    #expect(fixture.updates.last?.cancellationReason == .delegate)
    #expect(fixture.updates.last?.revealedUTF16End == 5)
    #expect(!fixture.service.hasPendingSpeech)
  }

  @Test func finishingOneQueuedUtteranceDoesNotReleaseAnotherOrChangeItsIdentity() throws {
    let fixture = NarrationFixture()
    let a = VoiceNarrationContext(generation: 11, narrationID: UUID())
    let b = VoiceNarrationContext(generation: 11, narrationID: UUID())
    _ = fixture.service.speak("Public first.", context: a)
    _ = fixture.service.speak("Public second.", context: b)
    let queuedA = try #require(fixture.updates.first { $0.context == a })
    let queuedB = try #require(fixture.updates.first { $0.context == b })
    #expect(queuedA.token != queuedB.token)
    let idA = ObjectIdentifier(fixture.utterances[0])
    let idB = ObjectIdentifier(fixture.utterances[1])
    fixture.deliver(.started, id: idA, token: queuedA.token)
    fixture.deliver(.finished, id: idA, token: queuedA.token)
    #expect(fixture.service.hasPendingSpeech && fixture.states == ["Speaking"])
    fixture.deliver(.started, id: idB, token: queuedB.token)
    fixture.deliver(.finished, id: idB, token: queuedB.token)
    #expect(!fixture.service.hasPendingSpeech && fixture.states.last == "Ready")
    #expect(fixture.updates.filter { $0.kind == .finished }.map(\.context) == [a, b])
  }

  @Test func stopRevokesBeforeNativeStopAndEmitsOneHostTerminalPerOwnedUtterance() throws {
    let fixture = NarrationFixture()
    _ = fixture.service.speak(
      "Public stopped.", context: .init(generation: 12, narrationID: UUID()))
    let queued = try #require(fixture.updates.first)
    let oldID = ObjectIdentifier(try #require(fixture.utterances.first))
    fixture.nativeStopHook = {
      fixture.deliver(.started, id: oldID, token: queued.token)
      fixture.deliver(.cancelled, id: oldID, token: queued.token)
    }
    fixture.service.stop()
    #expect(fixture.updates.map(\.kind) == [.enqueued, .cancelled])
    #expect(fixture.updates.last?.cancellationReason == .stop)
    #expect(fixture.diagnostics.isEmpty)
    _ = fixture.service.speak(
      "Public new generation.", context: .init(generation: 13, narrationID: UUID()))
    let current = try #require(fixture.updates.last)
    let newID = ObjectIdentifier(try #require(fixture.utterances.last))
    fixture.deliver(.finished, id: oldID, token: queued.token)
    fixture.deliver(.started, id: newID, token: queued.token)
    #expect(fixture.updates.last == current && fixture.service.hasPendingSpeech)
    fixture.deliver(.started, id: newID, token: current.token)
    #expect(fixture.updates.last?.context.generation == 13)
    #expect(fixture.updates.last?.token == current.token)
    fixture.nativeStopHook = nil
    fixture.service.stop()
  }

  @Test func reentrantStopCannotEmitAStartOrTerminalForRevokedOwnership() throws {
    let fixture = NarrationFixture()
    fixture.onUpdate = { update in
      if update.kind == .enqueued || update.kind == .cancelled { fixture.service.stop() }
    }
    let admitted = fixture.service.speak(
      "Public reentrant stop.", context: .init(generation: 14, narrationID: UUID()))
    #expect(admitted && !fixture.service.hasPendingSpeech)
    #expect(fixture.updates.map(\.kind) == [.enqueued, .cancelled])
    let queued = try #require(fixture.updates.first)
    fixture.deliver(.started, id: ObjectIdentifier(fixture.utterances[0]), token: queued.token)
    #expect(fixture.updates.count == 2)
    fixture.onUpdate = nil
  }

  @Test func nativeValueBridgeCanReceiveBackgroundStartRangeAndFinish() async throws {
    let fixture = NarrationFixture()
    _ = fixture.service.speak("Public bridge.", context: .init(generation: 15, narrationID: UUID()))
    let id = ObjectIdentifier(try #require(fixture.utterances.first))
    for (event, expected): (VoiceSpeechEvent, VoiceUtteranceUpdate.Kind) in [
      (.started, .started), (.range(location: 0, length: 6), .range), (.finished, .finished),
    ] {
      let update: VoiceUtteranceUpdate = await withCheckedContinuation { continuation in
        fixture.onUpdate = { update in
          MainActor.preconditionIsolated()
          if update.kind == expected { continuation.resume(returning: update) }
        }
        let service = fixture.service
        DispatchQueue.global().async {
          dispatchPrecondition(condition: .notOnQueue(.main))
          service.forwardSpeechEvent(event, utteranceID: id)
        }
      }
      #expect(update.kind == expected && update.observedUptime.isFinite)
    }
    fixture.onUpdate = nil
    #expect(fixture.updates.map(\.kind) == [.enqueued, .started, .range, .finished])
  }

  @Test func narrationTextBoundsAndIncompleteUnicodeRangesFailClosed() throws {
    #expect(VoiceNarrationText(String(repeating: "x", count: 32_001)) == nil)
    let text = try #require(VoiceNarrationText("e\u{301}👨‍👩‍👧‍👦"))
    #expect(text.revealedEnd(for: NSRange(location: 0, length: 1)) == 0)
    #expect(text.revealedEnd(for: NSRange(location: 0, length: 2)) == 2)
    #expect(text.revealedEnd(for: NSRange(location: NSNotFound, length: 1)) == nil)
    #expect(text.revealedEnd(for: NSRange(location: 0, length: Int.max)) == nil)
    #expect(text.prefix(throughUTF16End: 3) == "e\u{301}")
  }
}

@MainActor private final class NarrationFixture {
  var utterances: [AVSpeechUtterance] = []
  var updates: [VoiceUtteranceUpdate] = []
  var states: [String] = []
  var diagnostics: [String] = []
  var nativeStops = 0
  var nativeStopHook: (() -> Void)?
  var onUpdate: ((VoiceUtteranceUpdate) -> Void)?
  lazy var service = VoiceService(
    nativeSpeak: { [weak self] utterance in self?.utterances.append(utterance) },
    nativeStop: { [weak self] in
      self?.nativeStops += 1
      self?.nativeStopHook?()
    })

  init() {
    service.onState = { [weak self] in self?.states.append($0) }
    service.onSpeechEvent = { [weak self] in self?.diagnostics.append($0) }
    service.onUtteranceUpdate = { [weak self] update in
      self?.updates.append(update)
      self?.onUpdate?(update)
    }
  }

  func deliver(_ event: VoiceSpeechEvent, id: ObjectIdentifier, token: UUID) {
    service.acceptSpeechEvent(event, utteranceID: id, token: token, observedUptime: 100)
  }
}
