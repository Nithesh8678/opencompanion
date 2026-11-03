import Foundation
import Speech
import Testing

@testable import OpenCompanion

@Suite struct VoiceCallbackIsolationTests {
  @Test @MainActor func authorizationCompletionCanArriveOnABackgroundQueue() async {
    let status = await VoiceService.speechAuthorization { completion in
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        completion(.authorized)
      }
    }
    MainActor.preconditionIsolated()
    #expect(status == .authorized)
  }

  @Test @MainActor func deniedAuthorizationReturnsWithoutTouchingSystemPermissions() async {
    let status = await VoiceService.speechAuthorization { completion in
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        completion(.denied)
      }
    }
    MainActor.preconditionIsolated()
    #expect(status == .denied)
  }

  @Test @MainActor func backgroundRecognitionErrorDeliversOnlyASafeSnapshotOnMainActor() async {
    let update: VoiceRecognitionUpdate = await withCheckedContinuation { continuation in
      let handler = VoiceService.recognitionHandler { update in
        MainActor.preconditionIsolated()
        continuation.resume(returning: update)
      }
      DispatchQueue.global().async {
        dispatchPrecondition(condition: .notOnQueue(.main))
        handler(
          nil,
          NSError(
            domain: "org.opencompanion.voice-callback-fixture", code: 19,
            userInfo: [NSLocalizedDescriptionKey: "Injected recognition failure"]))
      }
    }
    #expect(update.text == nil)
    #expect(!update.final)
    #expect(update.errorMessage == "Injected recognition failure")
  }

  @Test @MainActor func backgroundSpeechEventsPreserveUtteranceIdentityOnMainActor() async {
    let fixture = NSObject()
    let expectedID = ObjectIdentifier(fixture)
    for event: VoiceSpeechEvent in [.started, .finished, .cancelled] {
      let delivered: (ObjectIdentifier, VoiceSpeechEvent) = await withCheckedContinuation {
        continuation in
        DispatchQueue.global().async {
          dispatchPrecondition(condition: .notOnQueue(.main))
          VoiceService.deliverSpeechEvent(event, utteranceID: expectedID) { id, received in
            MainActor.preconditionIsolated()
            continuation.resume(returning: (id, received))
          }
        }
      }
      #expect(delivered.0 == expectedID)
      #expect(delivered.1 == event)
    }
  }

  @Test func stoppedUtteranceTokenCannotMatchOrRemoveAReplacementAtTheSameAddress() throws {
    let fixture = NSObject()
    let id = ObjectIdentifier(fixture)
    let tokens = VoiceUtteranceTokens()
    let stale = try #require(tokens.insert(id))
    tokens.removeAll()
    let current = try #require(tokens.insert(id))
    #expect(stale != current)
    #expect(!tokens.matches(id, token: stale))
    let removedByStaleCallback = tokens.remove(id, token: stale)
    #expect(!removedByStaleCallback)
    #expect(tokens.token(for: id) == current)
    #expect(tokens.matches(id, token: current))
    let removedByCurrentCallback = tokens.remove(id, token: current)
    #expect(removedByCurrentCallback)
    #expect(tokens.token(for: id) == nil)
  }

  @Test func utteranceTokenStorageIsBoundedAndCapacityReturnsAfterCompletion() throws {
    let fixtures = (0..<25).map { _ in NSObject() }
    let tokens = VoiceUtteranceTokens()
    for fixture in fixtures.prefix(24) {
      let inserted = tokens.insert(ObjectIdentifier(fixture))
      #expect(inserted != nil)
    }
    let overflowID = ObjectIdentifier(fixtures[24])
    #expect(tokens.insert(overflowID) == nil)
    let completedID = ObjectIdentifier(fixtures[0])
    let completedToken = try #require(tokens.token(for: completedID))
    let removed = tokens.remove(completedID, token: completedToken)
    #expect(removed)
    let replacement = try #require(tokens.insert(overflowID))
    #expect(tokens.matches(overflowID, token: replacement))
  }
}
