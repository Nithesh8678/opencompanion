import Foundation
import Testing

@testable import OpenCompanion

/// Real local subprocesses, authored protocol only. No managed account, model,
/// capture, application activation, or external input is used by these tests.
@Suite(.serialized) struct CodexGuidanceSessionTests {
  @Test func sequentialGuidanceReusesConnectionButNeverThreadOrTurnState() async throws {
    try await withFixture { fixture, provider in
      let id = UUID()
      let first = try await send(provider, fixture, id: id)
      let second = try await send(provider, fixture, id: id)
      #expect(first.text == ["public response 1"])
      #expect(second.text == ["public response 2"])
      #expect(first.previews.allSatisfy { $0.unitID == 0 })
      #expect(second.previews.allSatisfy { $0.unitID == 0 })
      #expect(second.stages.contains(.sessionReused))
      #expect(second.stages.contains(.metadataCacheHit))
      #expect(second.stages.contains(.configurationCacheHit))
      let requests = try fixture.requests()
      #expect(fixture.count("initialize", in: requests) == 1)
      #expect(fixture.count("account/read", in: requests) == 1)
      #expect(fixture.count("model/list", in: requests) == 1)
      #expect(fixture.count("config/read", in: requests) == 2)
      let starts = fixture.parameters("thread/start", in: requests)
      #expect(starts.count == 2)
      #expect(starts.allSatisfy { $0["ephemeral"] as? Bool == true })
      #expect(starts.allSatisfy { ($0["dynamicTools"] as? [Any])?.isEmpty == true })
      #expect(starts.allSatisfy { $0["approvalPolicy"] as? String == "never" })
      #expect(starts.allSatisfy { $0["sandbox"] as? String == "read-only" })
      let turns = fixture.parameters("turn/start", in: requests)
      #expect(Set(turns.compactMap { $0["threadId"] as? String }).count == 2)
      let rpcIDs = requests.compactMap { ($0["request"] as? [String: Any])?["id"] as? Int }
      #expect(Set(rpcIDs).count == rpcIDs.count)
      #expect(
        first.audits.first?.items.first?.completedSHA256
          == first.audits.first?.items.first?.streamedSHA256)
      #expect(second.audits.first?.acceptedUnits == 1)
    }
  }

  @Test func prewarmHasNoThreadTurnOrModelRequest() async throws {
    try await withFixture { fixture, provider in
      let id = UUID()
      try await provider.prepareGuidanceSession(
        executable: fixture.executable.path, model: "fixture-default", sessionID: id)
      let before = try fixture.requests()
      #expect(fixture.count("initialize", in: before) == 1)
      #expect(fixture.count("account/read", in: before) == 1)
      #expect(fixture.count("model/list", in: before) == 1)
      #expect(fixture.count("config/read", in: before) == 0)
      #expect(fixture.count("thread/start", in: before) == 0)
      #expect(fixture.count("turn/start", in: before) == 0)
      let result = try await send(provider, fixture, id: id)
      #expect(result.stages.contains(.sessionReused) && result.stages.contains(.metadataCacheHit))
      let after = try fixture.requests()
      #expect(fixture.count("initialize", in: after) == 1)
      #expect(fixture.count("config/read", in: after) == 1)
      #expect(fixture.count("turn/start", in: after) == 1)
    }
  }

  @Test func metadataExpiresWithoutReinitializingHealthyConnection() async throws {
    let clock = GuidanceFixtureClock(1_000)
    try await withFixture(clock: clock) { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      clock.advance(20)
      let cached = try await send(provider, fixture, id: id)
      clock.advance(20)
      let refreshed = try await send(provider, fixture, id: id)
      #expect(cached.stages.contains(.metadataCacheHit))
      #expect(!refreshed.stages.contains(.metadataCacheHit))
      #expect(
        refreshed.stages.contains(.accountVerified) && refreshed.stages.contains(.sessionReused))
      let requests = try fixture.requests()
      #expect(fixture.count("initialize", in: requests) == 1)
      #expect(fixture.count("account/read", in: requests) == 2)
      #expect(fixture.count("model/list", in: requests) == 2)
      #expect(fixture.count("config/read", in: requests) == 3)
    }
  }

  @Test func scopedEndCannotCloseDifferentOrNewerSession() async throws {
    try await withFixture { fixture, provider in
      let old = UUID()
      let newer = UUID()
      _ = try await send(provider, fixture, id: old)
      await provider.endGuidanceSession(id: newer)
      #expect(try await send(provider, fixture, id: old).stages.contains(.sessionReused))
      await provider.endGuidanceSession(id: old)
      #expect(try await !send(provider, fixture, id: newer).stages.contains(.sessionReused))
      await provider.endGuidanceSession(id: old)
      #expect(try await send(provider, fixture, id: newer).stages.contains(.sessionReused))
      #expect(fixture.count("initialize", in: try fixture.requests()) == 2)
    }
  }

  @Test(arguments: [ResponsePolicy.Route.conversation, .notebook, .screenGuidance])
  func reuseRequiresExplicitGuidanceOwnership(_ route: ResponsePolicy.Route) async throws {
    try await withFixture { fixture, provider in
      // A supplied ID cannot promote another route, and a guidance request with
      // no ID retains the existing cold behavior.
      let id = route == .screenGuidance ? nil : UUID()
      let first = try await send(provider, fixture, id: id, route: route)
      let second = try await send(provider, fixture, id: id, route: route)
      #expect(!first.stages.contains(.sessionReused) && !second.stages.contains(.sessionReused))
      #expect(!second.stages.contains(.metadataCacheHit))
      #expect(fixture.count("initialize", in: try fixture.requests()) == 2)
    }
  }

  @Test func everyThreadDisablesNewlyInheritedCapabilities() async throws {
    try await withFixture(mode: "new-config") { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      let second = try await send(provider, fixture, id: id)
      #expect(!second.stages.contains(.configurationCacheHit))
      let requests = try fixture.requests()
      #expect(fixture.count("config/read", in: requests) == 2)
      let thread = try #require(fixture.parameters("thread/start", in: requests).last)
      let config = try #require(thread["config"] as? [String: Any])
      let servers = try #require(config["mcp_servers"] as? [String: [String: Any]])
      let plugins = try #require(config["plugins"] as? [String: [String: Any]])
      #expect(servers["new-server"]?["enabled"] as? Bool == false)
      #expect(plugins["new-plugin"]?["enabled"] as? Bool == false)
    }
  }

  @Test func oldRemoteTailCannotContaminateNextFreshTurn() async throws {
    try await withFixture(mode: "stale-tail") { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      let result = try await send(provider, fixture, id: id)
      #expect(result.text == ["public response 2"])
      #expect(result.audits.first?.ignoredScopeEvents == 2)
      #expect(result.audits.first?.items.count == 1)
    }
  }

  @Test func repeatedRemoteThreadIdentityFailsWithoutReplayingTurn() async throws {
    try await withFixture(mode: "duplicate-thread") { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      do {
        _ = try await send(provider, fixture, id: id)
        Issue.record("A reused remote thread must not receive another turn")
      } catch { #expect(error is ProviderError) }
      let requests = try fixture.requests()
      #expect(fixture.count("thread/start", in: requests) == 2)
      #expect(fixture.count("turn/start", in: requests) == 1)
    }
  }

  @Test func cancelledTurnCannotLeaveWarmStateOrCancelItsReplacement() async throws {
    try await withFixture { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      let rejected = GuidanceFixtureReceiver()
      let cancelled = Task {
        try await send(provider, fixture, id: id, receiver: rejected, cancelAt: .turnSubmitted)
      }
      do {
        _ = try await cancelled.value
        Issue.record("Cancelled guidance must fail")
      } catch { #expect(error is CancellationError) }
      #expect(await rejected.snapshot().text.isEmpty)
      let newer = UUID()
      let result = try await send(provider, fixture, id: newer)
      await provider.endGuidanceSession(id: id)
      let next = try await send(provider, fixture, id: newer)
      #expect(!result.stages.contains(.sessionReused))
      #expect(next.stages.contains(.sessionReused))
      #expect(fixture.count("initialize", in: try fixture.requests()) == 2)
    }
  }

  @Test func accountChangeFailsCurrentCheckAndReconnectsOnlyForNextRequest() async throws {
    try await withFixture(mode: "account-change") { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      do {
        _ = try await send(provider, fixture, id: id)
        Issue.record("A changed managed account must invalidate a warm turn")
      } catch { #expect(error is ProviderError) }
      let failed = try fixture.requests()
      #expect(fixture.count("turn/start", in: failed) == 1)
      let result = try await send(provider, fixture, id: id)
      #expect(result.text == ["public response 1"])
      #expect(!result.stages.contains(.sessionReused))
      #expect(fixture.count("initialize", in: try fixture.requests()) == 2)
    }
  }

  @Test func processDeathDoesNotDiscardBufferedCompletionOrReplayItsTurn() async throws {
    try await withFixture(mode: "exit-after-turn") { fixture, provider in
      let id = UUID()
      let first = try await send(provider, fixture, id: id)
      #expect(first.text == ["public response 1"])
      // Allow the fixture's immediate EOF to reach the independent pipe reader.
      try await Task.sleep(for: .milliseconds(100))
      let second = try await send(provider, fixture, id: id)
      #expect(second.text == ["public response 1"])
      #expect(!second.stages.contains(.sessionReused))
      let requests = try fixture.requests()
      #expect(fixture.count("initialize", in: requests) == 2)
      #expect(fixture.count("turn/start", in: requests) == 2)
    }
  }

  @Test func idleExpiryAndExecutableReplacementCreateNewConnections() async throws {
    let clock = GuidanceFixtureClock(1_000)
    try await withFixture(clock: clock) { fixture, provider in
      let id = UUID()
      _ = try await send(provider, fixture, id: id)
      clock.advance(30)
      #expect(try await !send(provider, fixture, id: id).stages.contains(.sessionReused))
      let handle = try FileHandle(forWritingTo: fixture.executable)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("\n# replaced public fixture\n".utf8))
      try handle.close()
      #expect(try await !send(provider, fixture, id: id).stages.contains(.sessionReused))
      #expect(fixture.count("initialize", in: try fixture.requests()) == 3)
    }
  }

  private func send(
    _ provider: CodexProvider, _ fixture: GuidanceProcessFixture, id: UUID?,
    route: ResponsePolicy.Route = .screenGuidance,
    receiver: GuidanceFixtureReceiver = GuidanceFixtureReceiver(),
    cancelAt: CodexTimingEvent.Stage? = nil
  ) async throws -> GuidanceFixtureSnapshot {
    try await provider.stream(
      executable: fixture.executable.path, model: "fixture-default",
      messages: [.init(role: "user", text: "Public authored task")], context: "", image: nil,
      scene: nil,
      onTiming: { event in
        await receiver.record(event)
        if event.stage == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
      },
      onUnit: { await receiver.accept($0) }, onText: { await receiver.preview($0) },
      responsePolicy: .init(route: route, includesExistingNotebook: false),
      onNDJSONAudit: { await receiver.audit($0) }, guidanceSessionID: id)
    return await receiver.snapshot()
  }

  private func withFixture(
    mode: String = "normal", clock: GuidanceFixtureClock? = nil,
    body: @Sendable (GuidanceProcessFixture, CodexProvider) async throws -> Void
  ) async throws {
    let fixture = try GuidanceProcessFixture(mode: mode)
    let provider = CodexProvider(now: { clock?.read() ?? ProcessInfo.processInfo.systemUptime })
    let deadline = Task {
      try await Task.sleep(for: .seconds(10))
      await provider.stop()
      Issue.record("Public subprocess fixture exceeded its ten-second watchdog")
    }
    defer { deadline.cancel() }
    do { try await body(fixture, provider) } catch {
      await provider.stop()
      try? FileManager.default.removeItem(at: fixture.directory)
      throw error
    }
    await provider.stop()
    try FileManager.default.removeItem(at: fixture.directory)
  }
}

private struct GuidanceFixtureSnapshot: Sendable {
  let text: [String]
  let previews: [ProviderTextPreview]
  let stages: [CodexTimingEvent.Stage]
  let audits: [CodexNDJSONAudit]
}

private actor GuidanceFixtureReceiver {
  private var text: [String] = []
  private var previews: [ProviderTextPreview] = []
  private var stages: [CodexTimingEvent.Stage] = []
  private var audits: [CodexNDJSONAudit] = []
  func accept(_ unit: ProviderUnit) { if let value = unit.text { text.append(value) } }
  func preview(_ value: ProviderTextPreview) { previews.append(value) }
  func record(_ value: CodexTimingEvent) { stages.append(value.stage) }
  func audit(_ value: CodexNDJSONAudit) { audits.append(value) }
  func snapshot() -> GuidanceFixtureSnapshot {
    .init(text: text, previews: previews, stages: stages, audits: audits)
  }
}

private final class GuidanceFixtureClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval
  init(_ value: TimeInterval) { self.value = value }
  func read() -> TimeInterval { lock.withLock { value } }
  func advance(_ delta: TimeInterval) { lock.withLock { value += delta } }
}

private struct GuidanceProcessFixture: Sendable {
  let directory: URL
  let executable: URL

  init(mode: String) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanion-WarmGuidance-\(UUID().uuidString)", isDirectory: true)
    executable = directory.appendingPathComponent("codex-fixture")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = #"""
      #!/usr/bin/env python3
      import json,os,sys
      mode = "\#(mode)"
      thread_count = 0
      config_count = 0
      turn_count = 0
      old = None
      def emit(value):
          print(json.dumps(value), flush=True)
      def event(method,params):
          emit({"method":method,"params":params})
      for line in sys.stdin:
          request=json.loads(line)
          with open(__file__+".requests","a") as log:
              log.write(json.dumps({"pid":os.getpid(),"request":request})+"\n")
          method=request.get("method", "")
          rid=request.get("id")
          result=None
          if method == "initialize": result={"userAgent":"public fixture"}
          elif method == "account/read": result={"account":{"type":"chatgpt"}}
          elif method == "model/list":
              result={"data":[{"model":"fixture-default","isDefault":True},
                  {"model":"gpt-5.6-terra","inputModalities":["text","image"],
                  "supportedReasoningEfforts":[{"reasoningEffort":"low"}]}]}
          elif method == "config/read":
              config_count += 1
              servers={"inherited-server":{"enabled":True}}
              plugins={"inherited-plugin":{"enabled":True}}
              if mode == "new-config" and config_count > 1:
                  servers["new-server"]={"enabled":True}
                  plugins["new-plugin"]={"enabled":True}
              if mode == "account-change" and config_count > 1:
                  event("account/updated",{"authMode":"chatgpt"})
              result={"layers":[{"config":{"mcp_servers":servers,"plugins":plugins}}]}
          elif method == "thread/start":
              thread_count += 1
              thread="thread-fixed" if mode == "duplicate-thread" else "thread-"+str(thread_count)
              result={"thread":{"id":thread}}
          elif method == "turn/start":
              turn_count += 1
              turn="turn-"+str(turn_count)
              item="item-"+str(turn_count)
              thread=request["params"]["threadId"]
              result={"turn":{"id":turn}}
          if result is not None: emit({"id":rid,"result":result})
          if method == "turn/start":
              if mode == "stale-tail" and old is not None:
                  event("item/agentMessage/delta",dict(old,itemId="stale",delta="untrusted old tail"))
                  event("item/completed",dict(old,item={"id":"stale","type":"agentMessage","text":"old"}))
                  event("turn/completed",{"threadId":old["threadId"],"turn":{"id":old["turnId"],"status":"completed"}})
              scope={"threadId":thread,"turnId":turn}
              text=json.dumps({"type":"text","text":"public response "+str(turn_count)},separators=(",",":"))+"\n"
              event("item/started",dict(scope,item={"id":item,"type":"agentMessage","phase":"final_answer"}))
              event("item/agentMessage/delta",dict(scope,itemId=item,delta=text))
              event("item/completed",dict(scope,item={"id":item,"type":"agentMessage","phase":"final_answer","text":text}))
              event("turn/completed",{"threadId":thread,"turn":{"id":turn,"status":"completed"}})
              old=scope
              if mode == "exit-after-turn": sys.exit(0)
      """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func requests() throws -> [[String: Any]] {
    let url = URL(fileURLWithPath: executable.path + ".requests")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }
  func count(_ method: String, in records: [[String: Any]]) -> Int {
    records.filter { ($0["request"] as? [String: Any])?["method"] as? String == method }.count
  }
  func parameters(_ method: String, in records: [[String: Any]]) -> [[String: Any]] {
    records.compactMap { record in
      guard let request = record["request"] as? [String: Any],
        request["method"] as? String == method
      else { return nil }
      return request["params"] as? [String: Any]
    }
  }
}
