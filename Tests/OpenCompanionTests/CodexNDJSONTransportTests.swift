import Foundation
import Testing

@testable import OpenCompanion

/// Real bounded stdio subprocess fixtures; no account, provider request, UI or
/// application model. Each event uses the installed protocol's required IDs.
@Suite(.serialized) struct CodexNDJSONTransportTests: Sendable {
  @Test(arguments: [Scenario.missingTail, .completedOnly, .separateEOFItems, .foreignScope])
  func authoritativeOwnedMessagesCompleteWithoutLossOrReplay(_ scenario: Scenario) async throws {
    let fixture = try Fixture(scenario)
    defer { fixture.remove() }
    let result = await run(fixture)
    #expect(result.failure == nil && !result.watchdog)
    #expect(result.texts == ["First", "Second"])
    #expect(result.previews.filter(\.isComplete).map(\.unitID) == [0, 1])
    let audit = try #require(result.audit)
    #expect(audit.outcome == .completed && audit.acceptedUnits == 2)
    if scenario == .missingTail { #expect(audit.items[0].appendedSuffixUTF8Bytes > 0) }
    if scenario == .completedOnly { #expect(audit.completedOnlyItems == 1) }
    if scenario == .foreignScope { #expect(audit.ignoredScopeEvents == 3) }
    #expect(result.auditCallbacks == 1)
  }

  @Test(arguments: [Scenario.mismatch, .overlap, .missingCompletion, .lateDelta])
  func invalidItemsFailWithoutReplayingAlreadyAdmittedContent(_ scenario: Scenario) async throws {
    let fixture = try Fixture(scenario)
    defer { fixture.remove() }
    let result = await run(fixture)
    #expect(result.failure != nil && !result.watchdog)
    #expect(result.texts == ["First"])
    #expect(result.audit?.outcome == .failed && result.audit?.acceptedUnits == 1)
    #expect(result.auditCallbacks == 1)
  }

  @Test func cancellationAtHostReturnCountsSuccessButNeverDeliversFutureUnit() async throws {
    let fixture = try Fixture(.missingTail)
    defer { fixture.remove() }
    let result = await run(fixture, cancelAtFirstUnit: true)
    #expect(result.failure != nil && !result.watchdog)
    #expect(result.texts == ["First"])
    #expect(result.audit?.outcome == .cancelled && result.audit?.acceptedUnits == 1)
    #expect(result.auditCallbacks == 1)
  }

  @Test func omittedAuditCallbackDoesNotChangeCanonicalDelivery() async throws {
    let fixture = try Fixture(.completedOnly)
    defer { fixture.remove() }
    let result = await run(fixture, requestAudit: false)
    #expect(result.failure == nil && result.texts == ["First", "Second"])
    #expect(result.audit == nil && result.auditCallbacks == 0)
  }

  private struct Result: Sendable {
    let failure: String?
    let texts: [String]
    let previews: [ProviderTextPreview]
    let audit: CodexNDJSONAudit?
    let auditCallbacks: Int
    let watchdog: Bool
  }
  private func run(_ fixture: Fixture, cancelAtFirstUnit: Bool = false, requestAudit: Bool = true)
    async -> Result
  {
    let provider = CodexProvider()
    let receiver = NDJSONTransportReceiver()
    let auditCallback: (@Sendable (CodexNDJSONAudit) async -> Void)? =
      requestAudit
      ? { @Sendable value in await receiver.audit(value) } : nil
    let task = Task {
      try await provider.stream(
        executable: fixture.executable.path, model: "fixture-model",
        messages: [.init(role: "user", text: "Public fixture")], context: "", image: nil,
        scene: nil,
        onUnit: { unit in
          await receiver.unit(unit)
          if cancelAtFirstUnit { withUnsafeCurrentTask { $0?.cancel() } }
        }, onText: { await receiver.preview($0) },
        responsePolicy: .init(route: .conversation, includesExistingNotebook: false),
        onNDJSONAudit: auditCallback)
    }
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      await receiver.watchdog()
      task.cancel()
      await provider.stop()
    }
    defer { watchdog.cancel() }
    let failure: String?
    do {
      try await task.value
      failure = nil
    } catch { failure = String(describing: error) }
    return await Result(
      failure: failure, texts: receiver.texts, previews: receiver.previews,
      audit: receiver.latestAudit, auditCallbacks: receiver.auditCallbacks,
      watchdog: receiver.watchdogFired)
  }

  enum Scenario: String, Sendable {
    case missingTail, completedOnly, separateEOFItems, foreignScope
    case mismatch, overlap, missingCompletion, lateDelta
  }
  private struct Fixture: Sendable {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("fixture.py") }
    init(_ scenario: Scenario) throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ndjson-transport-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let first = #"{"type":"text","text":"First"}"#
      let second = #"{"type":"text","text":"Second"}"#
      let both = first + "\n" + second
      func event(
        _ method: String, _ content: [String: Any], thread: String = "thread", turn: String = "turn"
      ) -> [String: Any] {
        var content = content
        content["threadId"] = thread
        content["turnId"] = turn
        return ["method": method, "params": content]
      }
      func start(_ id: String = "one") -> [String: Any] {
        event(
          "item/started", ["item": ["type": "agentMessage", "id": id, "phase": "partial_answer"]])
      }
      func delta(
        _ value: String, id: String = "one", thread: String = "thread", turn: String = "turn"
      ) -> [String: Any] {
        event(
          "item/agentMessage/delta", ["itemId": id, "delta": value], thread: thread, turn: turn)
      }
      func completed(_ value: String, id: String = "one", thread: String = "thread") -> [String:
        Any]
      {
        event(
          "item/completed",
          ["item": ["type": "agentMessage", "id": id, "phase": "partial_answer", "text": value]],
          thread: thread)
      }
      let events: [[String: Any]]
      switch scenario {
      case .missingTail:
        events = [
          start(), delta(first + "\n" + String(second.dropLast(4))), completed(both),
          completed(both),
        ]
      case .completedOnly:
        events = [completed(both)]
      case .separateEOFItems:
        events = [
          start(), delta(first), completed(first), start("two"), delta(second, id: "two"),
          completed(second, id: "two"),
        ]
      case .foreignScope:
        events = [
          start(), delta("not json", thread: "other"), completed("bad", thread: "other"),
          event("turn/completed", ["turn": ["id": "old", "status": "completed"]], turn: "old"),
          delta("bad", turn: "old"), delta(both), completed(both),
        ]
      case .mismatch:
        events = [start(), delta(first + "\n"), completed(second)]
      case .overlap:
        events = [start(), delta(first + "\n"), start("two")]
      case .missingCompletion:
        events = [start(), delta(first + "\n")]
      case .lateDelta:
        events = [completed(first), delta(second)]
      }
      try JSONSerialization.data(withJSONObject: events).write(
        to: directory.appendingPathComponent("events.json"))
      let script = #"""
        #!/usr/bin/env python3
        import json,sys
        from pathlib import Path
        events=json.loads(Path(__file__).with_name("events.json").read_text())
        for line in sys.stdin:
            request=json.loads(line)
            method=request.get("method")
            if method=="initialized": continue
            result={}
            if method=="account/read": result={"account":{"type":"chatgpt"}}
            if method=="config/read": result={"layers":[]}
            if method=="thread/start": result={"thread":{"id":"thread"}}
            if method=="turn/start": result={"turn":{"id":"turn"}}
            print(json.dumps({"id":request["id"],"result":result}),flush=True)
            if method=="turn/start":
                for event in events: print(json.dumps(event),flush=True)
                print(json.dumps({"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed"}}}),flush=True)
        """#
      try Data(script.utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
  }
}

private actor NDJSONTransportReceiver {
  private(set) var texts: [String] = []
  private(set) var previews: [ProviderTextPreview] = []
  private(set) var latestAudit: CodexNDJSONAudit?
  private(set) var auditCallbacks = 0
  private(set) var watchdogFired = false
  func unit(_ value: ProviderUnit) { if let text = value.text { texts.append(text) } }
  func preview(_ value: ProviderTextPreview) { previews.append(value) }
  func audit(_ value: CodexNDJSONAudit) {
    latestAudit = value
    auditCallbacks += 1
  }
  func watchdog() { watchdogFired = true }
}
