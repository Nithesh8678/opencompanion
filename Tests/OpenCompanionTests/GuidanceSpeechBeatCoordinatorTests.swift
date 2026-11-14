import Foundation
import Testing

@testable import OpenCompanion

@Suite @MainActor struct GuidanceSpeechBeatCoordinatorTests {
  @Test func actualSpeechStartReleasesOneMarkAndRangesRemainGraphemeSafe() throws {
    let h = Harness()
    let context = h.context()
    let family = "👨‍👩‍👧‍👦"
    let text = "A" + family + "Z"
    let began = h.owner.begin(context: context, text: text, nativeSpeech: true)
    #expect(began && h.marks.isEmpty && h.prefixes.isEmpty)
    h.owner.receive(h.update(.enqueued, context))
    h.owner.receive(h.update(.range, context, end: 1))
    #expect(h.marks.isEmpty && h.prefixes.isEmpty)
    h.owner.receive(h.update(.started, context))
    h.owner.receive(h.update(.started, context))
    #expect(h.marks == [context])
    h.owner.receive(h.update(.range, context, end: 2))
    #expect(h.prefixes == ["A"])
    h.owner.receive(h.update(.range, context, end: 1 + family.utf16.count))
    h.owner.receive(h.update(.range, context, end: 1))
    h.owner.receive(h.update(.range, context, end: Int.max))
    #expect(h.prefixes == ["A", "A" + family])
    #expect(h.updates.last?.revealedUTF16End == 1 + family.utf16.count)
    h.owner.receive(h.update(.finished, context))
    h.owner.receive(h.update(.finished, context))
    #expect(h.prefixes.last == text && h.captionFinishes == [context])
    #expect(h.ends == [.speechFinished] && h.owner.currentContext == nil)
  }

  @Test func wrongUtteranceAndRevokedEvidenceCannotReleaseOldPresentation() {
    let h = Harness()
    let context = h.context()
    _ = h.owner.begin(context: context, text: "Open the menu", nativeSpeech: true)
    h.owner.receive(h.update(.enqueued, context))
    h.owner.receive(h.update(.started, h.context(generation: 9)))
    h.owner.receive(h.update(.started, context, token: UUID()))
    #expect(h.marks.isEmpty)
    h.permits = false
    h.owner.receive(h.update(.started, context))
    #expect(h.marks.isEmpty && h.ends == [.ownershipLost])
    h.owner.receive(h.update(.finished, context))
    #expect(h.prefixes.isEmpty && h.captionFinishes.isEmpty)
  }

  @Test func cancellationWatermarkPreventsRevivalAndCannotCancelANewerBeat() {
    let h = Harness()
    let old = h.context(generation: 8)
    _ = h.owner.begin(context: old, text: "Old", nativeSpeech: true)
    h.owner.cancel(generation: 9)
    let revived = h.owner.begin(
      context: h.context(generation: 9), text: "Stale", nativeSpeech: false)
    #expect(!revived)
    let current = h.context(generation: 10)
    let began = h.owner.begin(context: current, text: "Current", nativeSpeech: true)
    #expect(began)
    h.owner.cancel(generation: 8)
    h.owner.receive(h.update(.started, old))
    h.owner.receive(h.update(.finished, old))
    #expect(h.owner.currentContext == current && h.marks.isEmpty)
    h.owner.receive(h.update(.started, current))
    #expect(h.marks == [current])
  }

  @Test func enqueueRefusalUsesExplicitFallbackWithoutFakeNativeEventsOrNewLease() {
    let h = Harness()
    let context = h.context()
    _ = h.owner.begin(context: context, text: "Select this item", nativeSpeech: true)
    let changed = h.owner.fallBackToText(context: context)
    #expect(changed && h.starts == [true, false] && h.marks == [context])
    h.owner.receive(h.update(.started, context))
    h.owner.receive(h.update(.range, context, end: 6))
    #expect(h.updates.isEmpty && h.prefixes.isEmpty)
    #expect(h.owner.currentContext == context && h.ends.isEmpty)
    h.owner.finishTextFallback(context: h.context())
    #expect(h.ends.isEmpty)
    h.owner.finishTextFallback(context: context)
    h.owner.finishTextFallback(context: context)
    #expect(h.ends == [.textFallbackFinished] && h.captionFinishes == [context])
  }

  @Test func markCallbackCanSupersedeBeatWithoutLeakingItsStartedCaption() {
    let h = Harness()
    let old = h.context()
    let next = h.context()
    h.owner.onMarkStart = { [weak h] context in
      guard let h else { return }
      h.marks.append(context)
      _ = h.owner.begin(context: next, text: "New owner", nativeSpeech: true)
    }
    _ = h.owner.begin(context: old, text: "Old owner", nativeSpeech: true)
    h.owner.receive(h.update(.started, old))
    #expect(h.owner.currentContext == next)
    #expect(h.updates.isEmpty && h.ends == [.superseded])
    h.owner.receive(h.update(.finished, old))
    #expect(h.captionFinishes.isEmpty)
  }

  @Test func cancellationDuringTerminalCallbackCannotSettleAnOldCaption() {
    let h = Harness()
    let context = h.context()
    _ = h.owner.begin(context: context, text: "Complete", nativeSpeech: true)
    h.owner.receive(h.update(.started, context))
    h.updates.removeAll()
    h.owner.onCaptionProgress = { [weak h] _, _ in h?.owner.cancel(generation: 9) }
    h.owner.receive(h.update(.finished, context))
    #expect(h.updates.isEmpty && h.captionFinishes.isEmpty)
  }

  @Test func explicitSilentFallbackAndNativeCancellationHaveDifferentOutcomes() {
    let h = Harness()
    let silent = h.context()
    _ = h.owner.begin(context: silent, text: "Read this", nativeSpeech: false)
    #expect(h.marks == [silent] && h.updates.isEmpty && h.ends.isEmpty)
    h.owner.finishTextFallback(context: silent)
    let native = h.context()
    _ = h.owner.begin(context: native, text: "Speaking", nativeSpeech: true)
    h.owner.receive(h.update(.cancelled, native))
    #expect(h.marks == [silent])
    #expect(h.ends == [.textFallbackFinished, .speechCancelled])
    #expect(h.captionFinishes == [silent])
  }

  @Test func invalidTextAndChangedOwnedTextAreRefusedWithoutSideEffects() {
    let h = Harness()
    let context = h.context()
    let empty = h.owner.begin(context: context, text: "", nativeSpeech: true)
    let oversized = h.owner.begin(
      context: context, text: String(repeating: "a", count: 32_001), nativeSpeech: true)
    #expect(!empty && !oversized && h.starts.isEmpty)
    _ = h.owner.begin(context: context, text: "Immutable", nativeSpeech: true)
    let rewritten = h.owner.begin(context: context, text: "Rewritten", nativeSpeech: true)
    #expect(!rewritten && h.starts == [true])
  }

  @MainActor private final class Harness {
    var permits = true
    var marks: [GuidanceSpeechBeatContext] = []
    var starts: [Bool] = []
    var prefixes: [String] = []
    var updates: [VoiceUtteranceUpdate] = []
    var captionFinishes: [GuidanceSpeechBeatContext] = []
    var ends: [GuidanceSpeechBeatCoordinator.FinishReason] = []
    let token = UUID()
    lazy var owner: GuidanceSpeechBeatCoordinator = {
      let owner = GuidanceSpeechBeatCoordinator(owns: { [weak self] _ in self?.permits == true })
      owner.onCaptionStarted = { [weak self] _, _, native in self?.starts.append(native) }
      owner.onMarkStart = { [weak self] in self?.marks.append($0) }
      owner.onCaptionProgress = { [weak self] _, prefix in self?.prefixes.append(prefix) }
      owner.onCaptionUpdate = { [weak self] in self?.updates.append($0) }
      owner.onCaptionFinished = { [weak self] in self?.captionFinishes.append($0) }
      owner.onFinished = { [weak self] _, reason in self?.ends.append(reason) }
      return owner
    }()

    func context(generation: UInt64 = 8) -> GuidanceSpeechBeatContext {
      .init(
        generation: generation, leaseID: UUID(),
        evidence: ScreenEvidenceIdentity(
          .init(
            frameID: UUID(), revision: 1, capturedAt: 10, displayID: 1, foregroundPID: 2,
            foregroundName: "Public fixture",
            screenRect: CGRect(x: -800, y: 0, width: 800, height: 600),
            image: Data(), semanticText: "")))
    }
    func update(
      _ kind: VoiceUtteranceUpdate.Kind, _ context: GuidanceSpeechBeatContext,
      end: Int = 0, token: UUID? = nil
    ) -> VoiceUtteranceUpdate {
      .init(
        token: token ?? self.token, context: context.voiceContext, kind: kind,
        observedUptime: 11, revealedUTF16End: end)
    }
  }
}
