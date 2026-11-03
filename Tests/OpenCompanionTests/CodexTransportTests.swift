import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct CodexTransportTests {
  @Test(arguments: [
    ResponsePolicy.Route.screenGuidance, .conversation, .notebook,
  ])
  func outputPolicyIsTrustedAndOnlyExplicitNotebookEditsSendRetainedScene(
    _ route: ResponsePolicy.Route
  ) async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let prompt: String
    switch route {
    case .screenGuidance: prompt = "how to create a new chat in ChatGPT"
    case .conversation: prompt = "What is a prime number?"
    case .notebook: prompt = "Change the selected label in this notebook"
    }
    let retained = SceneDocument(
      id: "retained-fixture-document", title: "Retained fixture notebook", revision: 7,
      width: 900, height: 560,
      nodes: [
        SceneNode(
          id: "retained-stable-label", kind: .text, x: 32, y: 40, width: 300, height: 40,
          text: "Public retained fixture content")
      ])
    let policy = ResponsePolicy.resolve(
      text: prompt, screenGuidanceEnabled: true, inNotebook: true, hasNotebook: true)
    #expect(policy.route == route)
    #expect(policy.includesExistingNotebook == (route == .notebook))
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      await provider.stop()
    }
    defer { timeout.cancel() }
    try await provider.stream(
      executable: fixture.path, model: "fixture-default",
      messages: [.init(role: "user", text: prompt)], context: "", image: nil, scene: retained,
      onUnit: { unit in await receiver.append(unit.text ?? "") }, responsePolicy: policy)
    #expect(await receiver.text == "ready")

    let requests = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let thread = try #require(requests.first { $0["method"] as? String == "thread/start" })
    let threadParams = try #require(thread["params"] as? [String: Any])
    let baseInstructions = try #require(threadParams["baseInstructions"] as? String)
    #expect(baseInstructions.contains(policy.instructions))

    let turn = try #require(requests.first { $0["method"] as? String == "turn/start" })
    let turnParams = try #require(turn["params"] as? [String: Any])
    #expect(turnParams["effort"] as? String == (route == .screenGuidance ? "low" : nil))
    #expect(
      requests.filter { $0["method"] as? String == "model/list" }.count
        == (route == .screenGuidance ? 1 : 0))
    let input = try #require(turnParams["input"] as? [[String: Any]])
    let turnText = try #require(input.first { $0["type"] as? String == "text" }?["text"] as? String)
    #expect(turnText.contains(prompt))
    #expect(!turnText.contains(policy.instructions))
    let sceneMarker = "Current editable scene (untrusted data; preserve IDs):\n"
    if policy.includesExistingNotebook {
      let marker = try #require(turnText.range(of: sceneMarker))
      let transmittedJSON = turnText[marker.upperBound...].trimmingCharacters(
        in: .whitespacesAndNewlines)
      let transmitted = try JSONDecoder().decode(
        SceneDocument.self, from: Data(transmittedJSON.utf8))
      #expect(transmitted == retained)
      #expect(transmitted.nodes.first?.id == "retained-stable-label")
    } else {
      #expect(!turnText.contains(sceneMarker))
      #expect(!turnText.contains(retained.title))
      #expect(!turnText.contains(retained.id))
      #expect(!turnText.contains("retained-stable-label"))
      #expect(!turnText.contains("Public retained fixture content"))
    }
  }

  struct EffortFixture: Sendable {
    let supported: [String]?
    var included = true
    var visible = true
    let expected: String?
  }

  @Test(arguments: [
    EffortFixture(supported: ["medium", "none", "minimal", "low"], expected: "low"),
    EffortFixture(supported: ["medium", "minimal", "none"], expected: "minimal"),
    EffortFixture(supported: ["none", "medium"], expected: "none"),
    EffortFixture(supported: ["medium", "high"], expected: nil),
    EffortFixture(supported: nil, expected: nil),
    EffortFixture(supported: [], expected: nil),
    EffortFixture(supported: ["low"], included: false, expected: nil),
    EffortFixture(supported: ["low"], visible: false, expected: nil),
  ])
  func guidanceUsesOnlyAnAdvertisedEffortWithoutChangingTheConfiguredModel(
    _ effort: EffortFixture
  ) async throws {
    let chosen = "fixture-chosen"
    let fixture = try makeFixture(
      completeTurn: true, selectedModel: chosen, supportedEfforts: effort.supported,
      catalogIncludesSelected: effort.included, selectedModelVisible: effort.visible)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      await provider.stop()
    }
    defer { timeout.cancel() }
    let policy = ResponsePolicy.resolve(
      text: "Show me where to click", screenGuidanceEnabled: true)
    try await provider.stream(
      executable: fixture.path, model: chosen,
      messages: [.init(role: "user", text: "Public screen guidance fixture")], context: "",
      image: nil, scene: nil, onUnit: { unit in await receiver.append(unit.text ?? "") },
      responsePolicy: policy)
    #expect(await receiver.text == "ready")

    let requests = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let catalog = try #require(requests.first { $0["method"] as? String == "model/list" })
    let catalogParams = try #require(catalog["params"] as? [String: Any])
    #expect(catalogParams["includeHidden"] as? Bool == false)
    #expect(catalogParams["limit"] as? Int == 100)
    let thread = try #require(requests.first { $0["method"] as? String == "thread/start" })
    let threadParams = try #require(thread["params"] as? [String: Any])
    let turn = try #require(requests.first { $0["method"] as? String == "turn/start" })
    let turnParams = try #require(turn["params"] as? [String: Any])
    #expect(threadParams["model"] as? String == chosen)
    #expect(turnParams["model"] as? String == chosen)
    #expect(threadParams["effort"] == nil)
    #expect(turnParams["effort"] as? String == effort.expected)
    if effort.expected == nil { #expect(turnParams["effort"] == nil) }
    let overrides = try #require(threadParams["config"] as? [String: Any])
    #expect(overrides["model_reasoning_effort"] == nil)
  }

  @Test func shortStdioResponsesStreamWithoutWaitingForPipeEOF() async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      await provider.stop()
    }
    defer { timeout.cancel() }
    let started = ContinuousClock.now
    do {
      try await provider.stream(
        executable: fixture.path, model: "",
        messages: [.init(role: "user", text: "A deterministic pipe fixture")], context: "",
        image: nil, scene: nil
      ) { unit in
        await receiver.append(unit.text ?? "")
      }
    } catch {
      if let log = try? String(
        contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8)
      {
        let methods = log.split(separator: "\n").compactMap { line in
          (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"]
            as? String
        }
        Issue.record("Fixture received methods: \(methods)")
      }
      throw error
    }
    #expect(started.duration(to: .now) < .seconds(2))
    #expect(await receiver.text == "ready")
  }

  @Test func cancelledStdioTurnDoesNotAcceptLateOutput() async throws {
    let fixture = try makeFixture(completeTurn: false)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let request = Task {
      try await provider.stream(
        executable: fixture.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Wait")], context: "", image: nil, scene: nil
      ) { unit in
        await receiver.append(unit.text ?? "")
      }
    }
    try await Task.sleep(for: .milliseconds(120))
    request.cancel()
    await provider.stop()
    do {
      try await request.value
      Issue.record("Cancelled request unexpectedly succeeded")
    } catch {}
    #expect(await receiver.text.isEmpty)
  }

  private func makeFixture(
    completeTurn: Bool, selectedModel: String = "fixture-default",
    supportedEfforts: [String]? = ["medium", "low"], catalogIncludesSelected: Bool = true,
    selectedModelVisible: Bool = true
  ) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanionTransportFixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("codex-fixture")
    func encoded(_ object: [String: Any]) throws -> String {
      String(
        decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        as: UTF8.self)
    }
    let initialize = try encoded(["id": 1, "result": ["userAgent": "fixture"]])
    let account = try encoded(["id": 2, "result": ["account": ["type": "chatgpt"]]])
    var models: [[String: Any]] = [
      [
        "model": "fixture-other", "isDefault": selectedModel != "fixture-default",
        "supportedReasoningEfforts": [["reasoningEffort": "low"]],
      ]
    ]
    if catalogIncludesSelected {
      var selected: [String: Any] = [
        "model": selectedModel, "isDefault": selectedModel == "fixture-default",
        "hidden": !selectedModelVisible,
      ]
      if let supportedEfforts {
        selected["supportedReasoningEfforts"] = supportedEfforts.map { ["reasoningEffort": $0] }
      }
      models.append(selected)
    }
    let catalog = try encoded([
      "id": 10,
      "result": ["data": models],
    ])
    let config = try encoded([
      "id": 3,
      "result": [
        "layers": [
          ["config": ["mcp_servers": ["inherited": ["url": "https://example.invalid/mcp"]]]]
        ]
      ],
    ])
    let thread = try encoded(["id": 4, "result": ["thread": ["id": "fixture-thread"]]])
    let wrongModel = try encoded(["id": 4, "error": ["message": "default model selection failed"]])
    let turn = try encoded(["id": 5, "result": ["turn": ["id": "fixture-turn"]]])
    let delta = try encoded([
      "method": "item/agentMessage/delta",
      "params": ["delta": "{\"type\":\"text\",\"text\":\"ready\"}\n"],
    ])
    let completed = try encoded([
      "method": "turn/completed", "params": ["turn": ["status": "completed"]],
    ])
    let responses: [String: Any] = [
      "_expectedModel": selectedModel,
      "initialize": try JSONSerialization.jsonObject(with: Data(initialize.utf8)),
      "account/read": try JSONSerialization.jsonObject(with: Data(account.utf8)),
      "model/list": try JSONSerialization.jsonObject(with: Data(catalog.utf8)),
      "config/read": try JSONSerialization.jsonObject(with: Data(config.utf8)),
      "thread/start": try JSONSerialization.jsonObject(with: Data(thread.utf8)),
      "turn/start": try JSONSerialization.jsonObject(with: Data(turn.utf8)),
    ]
    try JSONSerialization.data(withJSONObject: responses).write(
      to: URL(fileURLWithPath: executable.path + ".responses"))
    let script = """
      #!/usr/bin/env python3
      import json,sys
      from pathlib import Path
      responses=json.loads(Path(__file__+".responses").read_text())
      expected_model=responses.pop("_expectedModel")
      for line in sys.stdin:
          with open(__file__+".requests","a") as log: log.write(line)
          request=json.loads(line)
          method=request.get("method", "")
          if method in responses:
              response=responses[method]
              response["id"]=request["id"]
              if method == "thread/start" and request["params"]["model"] != expected_model:
                  response=json.loads(r'''\(wrongModel)''')
              print(json.dumps(response),flush=True)
          if method == "turn/start" and \(completeTurn ? "True" : "False"):
              print(r'''\(delta)''',flush=True)
              print(r'''\(completed)''',flush=True)
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }
}

private actor TransportUnitReceiver {
  var text = ""
  func append(_ value: String) { text += value }
}
