import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// Public authored steps over a real bounded subprocess pipe. No model request,
/// account, screen capture, audio or application model is involved.
@Suite(.serialized) struct CodexSpatialStepsTransportTests: Sendable {
  @Test func sceneAdmissionPrecedesNarrationBeforeTheEnvelopeCanClose() async throws {
    let fixture = try makeFixture(.progress)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure == nil && !outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.events == ["scene", "preview", "text"])
    #expect(outcome.snapshot.sceneAttempts == 1)
    #expect(outcome.snapshot.document.nodes.map(\.id) == ["ball"])
    #expect(outcome.snapshot.previews == [expectedPreview])
    #expect(outcome.snapshot.progress == completedProgress)
    #expect(outcome.snapshot.texts == ["A sphere is round."])
    #expect(!outcome.snapshot.previewBeforeScene && !outcome.snapshot.lateProgress)
    #expect(fixture.exists("text-observed") && fixture.exists("envelope-closed"))

    let requests = try fixture.requests()
    let turn = try #require(requests.first { $0["method"] as? String == "turn/start" })
    let parameters = try #require(turn["params"] as? [String: Any])
    let schema = try #require(parameters["outputSchema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(schema["required"] as? [String] == ["steps"])
    #expect(schema["additionalProperties"] as? Bool == false)
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    #expect(properties["steps"]?["type"] as? String == "array")
    #expect(properties["units"] == nil)
    let thread = try #require(requests.first { $0["method"] as? String == "thread/start" })
    let threadParameters = try #require(thread["params"] as? [String: Any])
    #expect(threadParameters["ephemeral"] as? Bool == true)
    #expect(threadParameters["approvalPolicy"] as? String == "never")
    #expect(threadParameters["sandbox"] as? String == "read-only")
    #expect((threadParameters["dynamicTools"] as? [Any])?.isEmpty == true)
    let instructions = try #require(threadParameters["baseInstructions"] as? String)
    #expect(!instructions.contains("Start with one brief useful text unit"))
    #expect(!instructions.contains("it is never mandatory"))
    #expect(!instructions.contains("it is not mandatory"))
    let developer = try #require(threadParameters["developerInstructions"] as? String)
    #expect(developer.contains("steps array") && developer.contains("No tools"))
    let config = try #require(threadParameters["config"] as? [String: Any])
    #expect(config["web_search"] as? String == "disabled")
    let features = try #require(config["features"] as? [String: Bool])
    #expect(features["shell_tool"] == false && features["unified_exec"] == false)
  }

  @Test func rejectedNativeSceneReleasesNoPreviewOrCanonicalNarration() async throws {
    let fixture = try makeFixture(.rejectScene)
    defer { fixture.remove() }
    let outcome = await run(fixture, rejectScene: true)
    #expect(outcome.failure?.contains("Public fixture native scene rejection") == true)
    #expect(!outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.sceneAttempts == 1)
    #expect(outcome.snapshot.events.isEmpty && outcome.snapshot.document.nodes.isEmpty)
    #expect(outcome.snapshot.previews.isEmpty && outcome.snapshot.texts.isEmpty)
    #expect(
      outcome.snapshot.progress
        == .init(decodedStages: 1, admittedSceneUnits: 0, admittedTextUnits: 0, completedStages: 0))
  }

  @Test func cancellationAfterSceneAdmissionRetainsOnlyThatSceneAndNeverReplaysIt() async throws {
    let fixture = try makeFixture(.cancelAfterScene)
    defer { fixture.remove() }
    let outcome = await run(fixture, cancelAfterScene: true)
    #expect(outcome.failure != nil && !outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.sceneAttempts == 1)
    #expect(outcome.snapshot.events == ["scene"])
    #expect(outcome.snapshot.document.nodes.map(\.id) == ["ball"])
    #expect(outcome.snapshot.previews.isEmpty && outcome.snapshot.texts.isEmpty)
    #expect(
      outcome.snapshot.progress
        == .init(decodedStages: 1, admittedSceneUnits: 1, admittedTextUnits: 0, completedStages: 0))
  }

  @Test(arguments: [
    Scenario.foreignIdentity, .commentary, .completedOnly, .duplicateCompletion,
    .unknownCompletedFinal, .unknownAtTurnEnd,
  ])
  func sharedIdentityAndAuthoritativeCompletionStillDeliverExactlyOnce(
    _ scenario: Scenario
  ) async throws {
    let fixture = try makeFixture(scenario)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure == nil && !outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.events == ["scene", "preview", "text"])
    #expect(outcome.snapshot.sceneAttempts == 1)
    #expect(outcome.snapshot.previews == [expectedPreview])
    #expect(outcome.snapshot.progress == completedProgress)
    #expect(!outcome.snapshot.previewBeforeScene && !outcome.snapshot.unknownDeliveredEarly)
  }

  @Test(arguments: [Scenario.finalMismatch, .missingCompletion, .changedCompletionPhase])
  func invalidAuthoritativeCompletionRetainsAcceptedContentWithoutReplay(
    _ scenario: Scenario
  ) async throws {
    let fixture = try makeFixture(scenario)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure != nil && !outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.events == ["scene", "preview", "text"])
    #expect(outcome.snapshot.sceneAttempts == 1)
    #expect(outcome.snapshot.document.nodes.map(\.id) == ["ball"])
    #expect(outcome.snapshot.previews == [expectedPreview])
  }

  @Test func currentIdentityDeltaBeforeItemStartCannotAdmitAnySceneOrNarration() async throws {
    let fixture = try makeFixture(.deltaBeforeStart)
    defer { fixture.remove() }
    let outcome = await run(fixture)
    #expect(outcome.failure != nil && !outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.sceneAttempts == 0)
    #expect(outcome.snapshot.events.isEmpty && outcome.snapshot.document.nodes.isEmpty)
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
  func unsupportedScopesRejectBeforeTheSubprocessStarts(_ input: UnsupportedInput) async throws {
    let fixture = try makeFixture(.progress)
    defer { fixture.remove() }
    let outcome = await run(
      fixture,
      policy: .init(route: input.route, includesExistingNotebook: input.includesExistingNotebook),
      image: input.image,
      scene: input.retainedScene ? SceneDocument(id: "public-retained-document") : nil)
    #expect(outcome.failure != nil && !outcome.snapshot.watchdogFired)
    #expect(outcome.snapshot.events.isEmpty && !fixture.exists("started"))
    #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".requests"))
  }

  enum Scenario: String, Sendable {
    case progress, rejectScene, cancelAfterScene, foreignIdentity, commentary
    case completedOnly, duplicateCompletion, unknownCompletedFinal, unknownAtTurnEnd
    case finalMismatch, missingCompletion, changedCompletionPhase, deltaBeforeStart
  }

  private var expectedPreview: ProviderTextPreview {
    .init(unitID: 1, text: "A sphere is round.", isComplete: true)
  }

  private var completedProgress: StructuredSpatialStageProgress {
    .init(decodedStages: 1, admittedSceneUnits: 1, admittedTextUnits: 1, completedStages: 1)
  }

  private struct Outcome: Sendable {
    let snapshot: SpatialStepsTransportSnapshot
    let failure: String?
  }

  private func run(
    _ fixture: Fixture, rejectScene: Bool = false, cancelAfterScene: Bool = false,
    policy: ResponsePolicy = .init(route: .notebook, includesExistingNotebook: false),
    image: Data? = nil, scene: SceneDocument? = nil
  ) async -> Outcome {
    let provider = CodexProvider()
    let receiver = SpatialStepsTransportReceiver()
    let request = Task {
      try await provider.stream(
        executable: fixture.executable.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Draw a public sphere")], context: "",
        image: image, scene: scene,
        onStructuredProgress: { await receiver.progress($0) },
        onUnit: { unit in
          try await receiver.receive(
            unit, rejectScene: rejectScene,
            lateProgress: fixture.scenario == .progress && fixture.exists("envelope-closed"),
            unknownDeliveredEarly: fixture.scenario == .unknownAtTurnEnd
              && !fixture.exists("turn-ready"))
          if unit.type == "scene", cancelAfterScene {
            withUnsafeCurrentTask { $0?.cancel() }
          }
          try Data().write(to: fixture.marker(unit.type + "-observed"))
        },
        onText: { preview in
          await receiver.preview(
            preview,
            lateProgress: fixture.scenario == .progress && fixture.exists("envelope-closed"),
            unknownDeliveredEarly: fixture.scenario == .unknownAtTurnEnd
              && !fixture.exists("turn-ready"))
        }, responsePolicy: policy, outputMode: .structuredSpatialSteps)
    }
    let watchdog = Task {
      try await Task.sleep(for: .seconds(5))
      await receiver.markWatchdog()
      request.cancel()
      await provider.stop()
    }
    defer { watchdog.cancel() }
    var failure: String?
    do { try await request.value } catch { failure = error.localizedDescription }
    return await Outcome(snapshot: receiver.snapshot(), failure: failure)
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
      "OpenCompanionSpatialStepsTransport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("codex-fixture")
    let script = #"""
      #!/usr/bin/env python3
      import json,sys,time
      from pathlib import Path
      root=Path(__file__).parent
      (root/"started").touch()
      mode=(root/"scenario").read_text()
      thread="public-steps-thread"
      turn="public-steps-turn"
      step={"text":"A sphere is round.","title":"Sphere","groups":[],"parts":[{
          "id":"ball","parentID":None,"fill":"#4488CC","opacity":None,"transform":None,
          "geometry":{"type":"sphere","radius":1,"segments":24}
      }],"labels":[],"animations":[],"removeIDs":[]}
      first='{"steps":['+json.dumps(step,separators=(',',':'))
      envelope=first+']}'
      def emit(value): print(json.dumps(value,separators=(',',':')),flush=True)
      def notify(method,params): emit({"method":method,"params":params})
      def started(item="answer",phase="final_answer",t=thread,u=turn):
          value={"id":item,"type":"agentMessage","text":""}
          if phase is not None: value["phase"]=phase
          notify("item/started",{"threadId":t,"turnId":u,"item":value})
      def delta(value,item="answer",t=thread,u=turn):
          notify("item/agentMessage/delta",{"threadId":t,"turnId":u,"itemId":item,"delta":value})
      def completed(value=envelope,item="answer",phase="final_answer",t=thread,u=turn):
          value={"id":item,"type":"agentMessage","text":value}
          if phase is not None: value["phase"]=phase
          notify("item/completed",{"threadId":t,"turnId":u,"item":value})
      def finish():
          (root/"turn-ready").touch()
          notify("turn/completed",{"threadId":thread,"turn":{"id":turn,"status":"completed","error":None}})
      def wait_for_text():
          deadline=time.monotonic()+2.5
          while not (root/"text-observed").exists():
              if time.monotonic()>deadline:
                  emit({"error":{"message":"fixture observed no progressive steps narration"}})
                  return False
              time.sleep(.005)
          return True
      def output():
          if mode=="commentary":
              started("commentary","commentary")
              delta("Not a JSON stage.","commentary")
              completed("Not a JSON stage.","commentary","commentary")
          if mode=="foreignIdentity":
              for t,u in [("foreign-thread",turn),(thread,"foreign-turn")]:
                  started(t=t,u=u)
                  delta("not a stage",t=t,u=u)
                  completed("not a stage",t=t,u=u)
          if mode=="deltaBeforeStart":
              delta(envelope)
              finish()
              return
          if mode=="completedOnly":
              completed()
              finish()
              return
          unknown=mode in ("unknownCompletedFinal","unknownAtTurnEnd")
          started(phase=None if unknown else "final_answer")
          delta(first)
          if mode=="progress" and not wait_for_text(): return
          (root/"envelope-closed").touch()
          delta(']}')
          if mode=="missingCompletion":
              finish()
              return
          authoritative=envelope.replace("round.","changed.") if mode=="finalMismatch" else envelope
          completed(authoritative,phase=None if mode=="unknownAtTurnEnd" else "final_answer")
          if mode=="duplicateCompletion": completed()
          if mode=="changedCompletionPhase": completed(phase=None)
          finish()
      for line in sys.stdin:
          with open(__file__+".requests","a") as log: log.write(line)
          request=json.loads(line)
          method=request.get("method")
          result=None
          if method=="initialize": result={"userAgent":"public steps fixture"}
          elif method=="account/read": result={"account":{"type":"chatgpt"}}
          elif method=="model/list": result={"data":[{"model":"fixture-default","isDefault":True,
              "inputModalities":["text","image"],"supportedReasoningEfforts":[{"reasoningEffort":"low"}]}]}
          elif method=="config/read": result={"layers":[]}
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

private struct SpatialStepsTransportSnapshot: Sendable {
  let document: SceneDocument
  let events: [String]
  let previews: [ProviderTextPreview]
  let texts: [String]
  let sceneAttempts: Int
  let previewBeforeScene: Bool
  let lateProgress: Bool
  let unknownDeliveredEarly: Bool
  let watchdogFired: Bool
  let progress: StructuredSpatialStageProgress?
}

private actor SpatialStepsTransportReceiver {
  private var document = SceneDocument(title: "Public steps fixture")
  private var events: [String] = []
  private var previews: [ProviderTextPreview] = []
  private var texts: [String] = []
  private var sceneAttempts = 0
  private var previewBeforeScene = false
  private var lateProgress = false
  private var unknownDeliveredEarly = false
  private var watchdogFired = false
  private var latestProgress: StructuredSpatialStageProgress?

  func receive(
    _ unit: ProviderUnit, rejectScene: Bool, lateProgress: Bool, unknownDeliveredEarly: Bool
  ) throws {
    self.lateProgress = self.lateProgress || lateProgress
    self.unknownDeliveredEarly = self.unknownDeliveredEarly || unknownDeliveredEarly
    if unit.type == "scene" {
      sceneAttempts += 1
      let candidate = try ProviderSceneBoundary.applying(
        unit, to: document, baseRevision: document.revision)
      if rejectScene { throw ProviderError.message("Public fixture native scene rejection") }
      document = candidate
      events.append("scene")
    } else if unit.type == "text", let text = unit.text {
      texts.append(text)
      events.append("text")
    } else {
      throw ProviderError.message("Unexpected public steps fixture unit")
    }
  }

  func preview(
    _ preview: ProviderTextPreview, lateProgress: Bool, unknownDeliveredEarly: Bool
  ) {
    previewBeforeScene = previewBeforeScene || document.nodes.isEmpty
    self.lateProgress = self.lateProgress || lateProgress
    self.unknownDeliveredEarly = self.unknownDeliveredEarly || unknownDeliveredEarly
    previews.append(preview)
    events.append("preview")
  }

  func markWatchdog() { watchdogFired = true }
  func progress(_ value: StructuredSpatialStageProgress) { latestProgress = value }

  func snapshot() -> SpatialStepsTransportSnapshot {
    .init(
      document: document, events: events, previews: previews, texts: texts,
      sceneAttempts: sceneAttempts, previewBeforeScene: previewBeforeScene,
      lateProgress: lateProgress, unknownDeliveredEarly: unknownDeliveredEarly,
      watchdogFired: watchdogFired, progress: latestProgress)
  }
}
