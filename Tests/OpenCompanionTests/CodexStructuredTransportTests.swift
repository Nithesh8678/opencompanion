import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// Public authored responses over a real bounded subprocess pipe. No Codex
/// account, model request, screen capture or application model is involved.
@Suite(.serialized) struct CodexStructuredTransportTests: Sendable {
  @Test func rawSchemaAndTeachingScopePreserveProgressBeforeTurnCompletion() async throws {
    let fixture = try makeFixture(.progress)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure == nil && !outcome.watchdogFired)
    #expect(outcome.units == expectedUnits)
    #expect(fixture.exists("text-observed") && fixture.exists("scene-observed"))
    let requests = try fixture.requests()
    let thread = try #require(requests.first { $0["method"] as? String == "thread/start" })
    let parameters = try #require(thread["params"] as? [String: Any])
    #expect(parameters["ephemeral"] as? Bool == true)
    #expect(parameters["approvalPolicy"] as? String == "never")
    #expect(parameters["sandbox"] as? String == "read-only")
    #expect((parameters["dynamicTools"] as? [Any])?.isEmpty == true)
    let configuration = try #require(parameters["config"] as? [String: Any])
    #expect(configuration["web_search"] as? String == "disabled")
    let servers = try #require(configuration["mcp_servers"] as? [String: [String: Any]])
    let plugins = try #require(configuration["plugins"] as? [String: [String: Any]])
    #expect(servers["public-fixture-server"]?["enabled"] as? Bool == false)
    #expect(plugins["public-fixture-plugin"]?["enabled"] as? Bool == false)
    let turn = try #require(requests.first { $0["method"] as? String == "turn/start" })
    let turnParameters = try #require(turn["params"] as? [String: Any])
    let schema = try #require(turnParameters["outputSchema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(schema["required"] as? [String] == ["units"])
    #expect(schema["schema"] == nil && schema["json_schema"] == nil)
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(properties["units"]?["type"] as? String == "array")
    #expect(properties["units"]?["items"] != nil)
    #expect(requests.filter { $0["method"] as? String == "turn/start" }.count == 1)
  }

  @Test(arguments: [
    Scenario.commentary, .foreignIdentity, .completedOnly, .duplicateCompletion,
    .unknownCompletedFinal, .unknownAtTurnEnd,
  ])
  func authoritativeMessagesDeliverOnceAndIgnoreUnrelatedContent(_ scenario: Scenario) async throws
  {
    let fixture = try makeFixture(scenario)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure == nil && !outcome.watchdogFired)
    #expect(outcome.units == expectedUnits)
    #expect(!outcome.unknownPhaseDeliveredEarly)
  }

  struct RejectedScenario: Sendable {
    let scenario: Scenario
    let accepted: Int
  }

  @Test(arguments: [
    RejectedScenario(scenario: .deltaBeforeStart, accepted: 0),
    RejectedScenario(scenario: .duplicateStart, accepted: 0),
    RejectedScenario(scenario: .changedItemType, accepted: 0),
    RejectedScenario(scenario: .secondFinal, accepted: 2),
    RejectedScenario(scenario: .finalMismatch, accepted: 2),
    RejectedScenario(scenario: .duplicateCompletionUnknown, accepted: 2),
    RejectedScenario(scenario: .missingItemCompletion, accepted: 2),
    RejectedScenario(scenario: .interrupted, accepted: 1),
    RejectedScenario(scenario: .failedTurn, accepted: 1),
    RejectedScenario(scenario: .incompleteEnvelope, accepted: 1),
    RejectedScenario(scenario: .twoUnknownMessages, accepted: 0),
    RejectedScenario(scenario: .unknownInterrupted, accepted: 0),
  ])
  func invalidCurrentIdentityOrTerminalStateFailsWithoutReplayingAcceptedUnits(
    _ item: RejectedScenario
  ) async throws {
    let fixture = try makeFixture(item.scenario)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure != nil && !outcome.watchdogFired)
    #expect(outcome.units == Array(expectedUnits.prefix(item.accepted)))
  }

  struct UnsupportedInput: Sendable {
    let route: ResponsePolicy.Route
    var includesExistingNotebook = false
    var image: Data? = nil
    var retainedScene = false
  }

  @Test(arguments: [
    UnsupportedInput(route: .conversation),
    UnsupportedInput(route: .screenGuidance),
    UnsupportedInput(route: .notebook, includesExistingNotebook: true),
    UnsupportedInput(route: .notebook, image: Data([0xFF])),
    UnsupportedInput(route: .notebook, retainedScene: true),
  ])
  func unsupportedScopesRefuseBeforeStartingAnySubprocess(_ input: UnsupportedInput) async throws {
    let fixture = try makeFixture(.progress)
    defer { fixture.remove() }
    let scene = input.retainedScene ? SceneDocument(id: "public-retained-document") : nil
    let outcome = await run(
      fixture,
      policy: .init(route: input.route, includesExistingNotebook: input.includesExistingNotebook),
      image: input.image, scene: scene)
    #expect(outcome.failure != nil && !outcome.watchdogFired)
    #expect(outcome.units.isEmpty)
    #expect(!fixture.exists("started"))
    #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".requests"))
  }

  @Test func cancellationRetainsOnlyTheAlreadyAcceptedAtomicUnit() async throws {
    let fixture = try makeFixture(.awaitCancellation)
    defer { fixture.remove() }
    let provider = CodexProvider()
    let receiver = StructuredTransportReceiver()
    let request = Task {
      try await provider.stream(
        executable: fixture.executable.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Draw a public sphere")], context: "",
        image: nil, scene: nil,
        onUnit: { unit in try await receive(unit, fixture: fixture, receiver: receiver) },
        responsePolicy: standalonePolicy, outputMode: .structuredScene)
    }
    let watchdog = Task {
      try await Task.sleep(for: .seconds(5))
      await receiver.markWatchdog()
      request.cancel()
      await provider.stop()
    }
    defer { watchdog.cancel() }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !fixture.exists("text-observed"), ProcessInfo.processInfo.systemUptime < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.exists("text-observed"))
    request.cancel()
    await provider.stop()
    do {
      try await request.value
      Issue.record("A cancelled structured response completed successfully.")
    } catch {}
    #expect(await receiver.units == Array(expectedUnits.prefix(1)))
    #expect(await receiver.watchdogFired == false)
  }

  enum Scenario: String, Sendable {
    case progress, commentary, foreignIdentity, completedOnly, duplicateCompletion
    case unknownCompletedFinal, unknownAtTurnEnd, deltaBeforeStart, duplicateStart, changedItemType
    case secondFinal, finalMismatch, duplicateCompletionUnknown, missingItemCompletion, interrupted
    case failedTurn
    case incompleteEnvelope, twoUnknownMessages, unknownInterrupted, awaitCancellation
  }

  private var standalonePolicy: ResponsePolicy {
    .init(route: .notebook, includesExistingNotebook: false)
  }

  private var expectedUnits: [StructuredTransportUnit] {
    [
      .init(type: "text", text: "A sphere is round.", nodeIDs: []),
      .init(type: "scene", text: nil, nodeIDs: ["ball"]),
    ]
  }

  private struct Outcome: Sendable {
    let units: [StructuredTransportUnit]
    let failure: String?
    let watchdogFired: Bool
    let unknownPhaseDeliveredEarly: Bool
  }

  private func run(
    _ fixture: Fixture, policy: ResponsePolicy? = nil, image: Data? = nil,
    scene: SceneDocument? = nil
  ) async -> Outcome {
    let provider = CodexProvider()
    let receiver = StructuredTransportReceiver()
    let watchdog = Task {
      try await Task.sleep(for: .seconds(5))
      await receiver.markWatchdog()
      await provider.stop()
    }
    defer { watchdog.cancel() }
    var failure: String?
    do {
      try await provider.stream(
        executable: fixture.executable.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Draw a public sphere")], context: "",
        image: image, scene: scene,
        onUnit: { unit in try await receive(unit, fixture: fixture, receiver: receiver) },
        responsePolicy: policy ?? standalonePolicy, outputMode: .structuredScene)
    } catch { failure = error.localizedDescription }
    return await Outcome(
      units: receiver.units, failure: failure, watchdogFired: receiver.watchdogFired,
      unknownPhaseDeliveredEarly: receiver.unknownPhaseDeliveredEarly)
  }

  private func receive(
    _ unit: ProviderUnit, fixture: Fixture, receiver: StructuredTransportReceiver
  ) async throws {
    let premature = fixture.scenario == .unknownAtTurnEnd && !fixture.exists("turn-ready")
    await receiver.append(
      .init(type: unit.type, text: unit.text, nodeIDs: unit.nodes?.map(\.id) ?? []),
      premature: premature)
    try Data().write(to: fixture.marker(unit.type == "scene" ? "scene-observed" : "text-observed"))
  }

  private struct Fixture: Sendable {
    let executable: URL
    let scenario: Scenario
    var directory: URL { executable.deletingLastPathComponent() }
    func marker(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func exists(_ name: String) -> Bool {
      FileManager.default.fileExists(atPath: marker(name).path)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func requests() throws -> [[String: Any]] {
      try String(contentsOf: URL(fileURLWithPath: executable.path + ".requests"), encoding: .utf8)
        .split(separator: "\n").map {
          try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
  }

  private func makeFixture(_ scenario: Scenario) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanionStructuredTransport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("codex-fixture")
    let script = #"""
      #!/usr/bin/env python3
      import json,sys,time
      from pathlib import Path
      root=Path(__file__).parent
      (root/"started").touch()
      mode=(root/"scenario").read_text()
      thread="fixture-thread"
      turn="fixture-turn"
      text={"type":"text","text":"A sphere is round."}
      scene={"type":"scene","title":"Public sphere","nodes":[{
          "id":"ball","kind":"mesh","parentID":None,"fill":"#4488CC","opacity":None,
          "spatial3D":{"transform":None,"geometry":{"type":"sphere","radius":1,"segments":24}}
      }],"removeIDs":[],"animations":[]}
      prefix='{"units":['+json.dumps(text,separators=(',',':'))+','
      scene_fragment=json.dumps(scene,separators=(',',':'))
      suffix=scene_fragment+']}'
      envelope=prefix+suffix
      def emit(value): print(json.dumps(value,separators=(',',':')),flush=True)
      def notify(method,params): emit({"method":method,"params":params})
      def started(item="answer",phase="final_answer",kind="agentMessage",t=thread,u=turn):
          value={"id":item,"type":kind,"text":""}
          if phase is not None: value["phase"]=phase
          notify("item/started",{"threadId":t,"turnId":u,"item":value})
      def delta(value,item="answer",t=thread,u=turn):
          notify("item/agentMessage/delta",{"threadId":t,"turnId":u,"itemId":item,"delta":value})
      def completed(value=envelope,item="answer",phase="final_answer",t=thread,u=turn):
          result={"id":item,"type":"agentMessage","text":value}
          if phase is not None: result["phase"]=phase
          notify("item/completed",{"threadId":t,"turnId":u,"item":result})
      def finish(status="completed",t=thread,u=turn):
          (root/"turn-ready").touch()
          notify("turn/completed",{"threadId":t,"turn":{"id":u,"status":status,"error":None}})
      def await_marker(name):
          end=time.monotonic()+2.5
          while not (root/name).exists():
              if time.monotonic()>end:
                  emit({"error":{"message":"fixture observed no progressive "+name}})
                  return False
              time.sleep(.005)
          return True
      def output():
          if mode=="commentary":
              started("commentary","commentary")
              delta("This is deliberately not JSON.","commentary")
              completed("This is deliberately not JSON.","commentary","commentary")
          if mode=="foreignIdentity":
              for t,u in [("unrelated-thread",turn),(thread,"unrelated-turn")]:
                  notify("turn/started",{"threadId":t,"turn":{"id":u,"status":"inProgress"}})
                  started(t=t,u=u)
                  delta("not JSON",t=t,u=u)
                  completed("not JSON",t=t,u=u)
                  finish("failed",t=t,u=u)
          if mode=="deltaBeforeStart":
              delta(envelope)
              finish()
              return
          if mode=="completedOnly":
              completed()
              finish()
              return
          unknown=mode in ("unknownCompletedFinal","unknownAtTurnEnd","twoUnknownMessages","unknownInterrupted")
          started(phase=None if unknown else "final_answer")
          if mode=="duplicateStart": started()
          if mode=="changedItemType": started(kind="userMessage")
          delta(prefix)
          if mode in ("interrupted","failedTurn","incompleteEnvelope","awaitCancellation"):
              if mode=="awaitCancellation": return
              if mode=="incompleteEnvelope": completed(prefix)
              finish("interrupted" if mode=="interrupted" else ("failed" if mode=="failedTurn" else "completed"))
              return
          if mode=="progress" and not await_marker("text-observed"): return
          if mode=="progress":
              delta(scene_fragment)
              if not await_marker("scene-observed"): return
              delta(']}')
          else: delta(suffix)
          if mode=="missingItemCompletion":
              finish()
              return
          authoritative=envelope.replace("round.","changed.") if mode=="finalMismatch" else envelope
          completed(authoritative,phase=None if mode in ("unknownAtTurnEnd","twoUnknownMessages","unknownInterrupted") else "final_answer")
          if mode=="duplicateCompletion": completed()
          if mode=="duplicateCompletionUnknown": completed(phase=None)
          if mode=="secondFinal":
              started("second-answer")
              completed(item="second-answer")
          if mode=="twoUnknownMessages":
              started("second-unknown",None)
              delta(envelope,"second-unknown")
              completed(envelope,"second-unknown",None)
          finish("interrupted" if mode=="unknownInterrupted" else "completed")
      for line in sys.stdin:
          with open(__file__+".requests","a") as log: log.write(line)
          request=json.loads(line)
          method=request.get("method")
          result=None
          if method=="initialize": result={"userAgent":"public fixture"}
          elif method=="account/read": result={"account":{"type":"chatgpt"}}
          elif method=="model/list": result={"data":[{"model":"fixture-default","isDefault":True,
              "inputModalities":["text","image"],"supportedReasoningEfforts":[{"reasoningEffort":"low"}]}]}
          elif method=="config/read": result={"layers":[{"config":{
              "mcp_servers":{"public-fixture-server":{"enabled":True}},
              "plugins":{"public-fixture-plugin":{"enabled":True}}}}]}
          elif method=="thread/start": result={"thread":{"id":thread}}
          elif method=="turn/start": result={"turn":{"id":turn,"status":"inProgress","items":[],"error":None}}
          if result is not None: emit({"id":request["id"],"result":result})
          if method=="turn/start": output()
      """#
    try Data(scenario.rawValue.utf8).write(to: directory.appendingPathComponent("scenario"))
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return Fixture(executable: executable, scenario: scenario)
  }
}

private struct StructuredTransportUnit: Sendable, Equatable {
  let type: String
  let text: String?
  let nodeIDs: [String]
}

private actor StructuredTransportReceiver {
  var units: [StructuredTransportUnit] = []
  var watchdogFired = false
  var unknownPhaseDeliveredEarly = false
  func append(_ unit: StructuredTransportUnit, premature: Bool) {
    units.append(unit)
    unknownPhaseDeliveredEarly = unknownPhaseDeliveredEarly || premature
  }
  func markWatchdog() { watchdogFired = true }
}
