import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

// Each case starts a real Python subprocess. Bound fixture concurrency so cold
// interpreter startup does not consume another case's protocol watchdog.
@Suite(.serialized) struct CodexTransportTests {
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
    #expect(turnParams["effort"] as? String == (route == .conversation ? nil : "low"))
    #expect(
      requests.filter { $0["method"] as? String == "model/list" }.count
        == (route == .conversation ? 0 : 1))
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

  @Test func terraGuidanceSelectsOnlyTheLatestVisibleImageCapableNumericFamily() async throws {
    let models: [[String: Any]] = [
      catalogModel("gpt-5.6-sol", isDefault: true),
      catalogModel("gpt-5.9-terra"),
      catalogModel("gpt-5.10-terra"),
      catalogModel("gpt-6-terra", modalities: ["text"]),
      catalogModel("gpt-6.1-terra", hidden: true),
      catalogModel("gpt-99-terra-fast"),
      catalogModel("gpt-9.5-sol"),
    ]
    try await assertRouting(
      models: models,
      expected: .init(model: "gpt-5.10-terra", effort: "low", reason: .terraGuidance))
  }

  @Test func theActualAvailableTerraFamilyIsSelectedWithoutInventingANewerAlias() async throws {
    try await assertRouting(
      models: [
        catalogModel("gpt-5.6-sol", isDefault: true), catalogModel("gpt-5.6-terra"),
        catalogModel("gpt-5.6-luna"),
      ],
      expected: .init(model: "gpt-5.6-terra", effort: "low", reason: .terraGuidance))
  }

  @Test func configuredGuidancePreferenceKeepsTheConversationModelWhenTerraIsAvailable()
    async throws
  {
    try await assertRouting(
      models: [catalogModel("gpt-5.6-sol", isDefault: true), catalogModel("gpt-5.6-terra")],
      preference: .conversation,
      expected: .init(model: "gpt-5.6-sol", effort: "low", reason: .configuredGuidance))
  }

  @Test(arguments: [ResponsePolicy.Route.conversation, .notebook])
  func nonGuidanceTurnsIgnoreTheTerraPreference(_ route: ResponsePolicy.Route) async throws {
    try await assertRouting(
      models: [catalogModel("gpt-5.6-sol", isDefault: true), catalogModel("gpt-5.6-terra")],
      route: route,
      expected: .init(
        model: "gpt-5.6-sol", effort: route == .notebook ? "low" : nil,
        reason: route == .notebook ? .visual : .conversation))
  }

  @Test(arguments: [
    EffortFixture(supported: ["medium", "low", "none"], expected: "low"),
    EffortFixture(supported: ["medium", "minimal"], expected: "minimal"),
    EffortFixture(supported: ["none"], expected: "none"),
    EffortFixture(supported: ["high"], expected: nil),
    EffortFixture(supported: nil, expected: nil),
  ])
  func visualTurnsUseOnlyTheSelectedModelsAdvertisedFastEffort(_ fixture: EffortFixture) throws {
    let result = try CodexModelRouting.select(
      configuredModel: "configured-visual-model",
      policy: ResponsePolicy.resolve(text: "Draw a model of a lever", screenGuidanceEnabled: true),
      preference: .terra,
      catalog: [
        .init(
          model: "configured-visual-model", alias: nil, isDefault: true, supportsImages: true,
          supportedEfforts: Set(fixture.supported ?? [])),
        .init(
          model: "gpt-99-terra", alias: nil, isDefault: false, supportsImages: true,
          supportedEfforts: ["low"]),
      ])
    #expect(result.model == "configured-visual-model" && result.reason == .visual)
    #expect(result.effort == fixture.expected)
  }

  @Test func defaultVisualTurnsPreferVisibleTerraWhileAnExplicitModelKeepsItsAuthority() throws {
    let policy = ResponsePolicy.resolve(
      text: "Create a 3D model of a bicycle", screenGuidanceEnabled: true)
    let catalog: [CodexRoutingModel] = [
      .init(
        model: "account-default", alias: nil, isDefault: true, supportsImages: true,
        supportedEfforts: ["low"]),
      .init(
        model: "gpt-5.6-terra", alias: nil, isDefault: false, supportsImages: true,
        supportedEfforts: ["low"]),
    ]
    let automatic = try CodexModelRouting.select(
      configuredModel: "", policy: policy, preference: .conversation, catalog: catalog)
    #expect(automatic == .init(model: "gpt-5.6-terra", effort: "low", reason: .terraVisual))
    let explicit = try CodexModelRouting.select(
      configuredModel: "account-default", policy: policy, preference: .terra, catalog: catalog)
    #expect(explicit == .init(model: "account-default", effort: "low", reason: .visual))
    let fallback = try CodexModelRouting.select(
      configuredModel: "", policy: policy, preference: .terra, catalog: [catalog[0]])
    #expect(fallback == .init(model: "account-default", effort: "low", reason: .visual))
  }

  @Test func unavailableTerraReportsFallbackWithoutChangingTheConfiguredModel() async throws {
    try await assertRouting(
      models: [
        catalogModel("gpt-5.6-sol", isDefault: true),
        catalogModel("gpt-6-terra", hidden: true),
        catalogModel("gpt-5.6-terra", modalities: ["text"]),
      ],
      expected: .init(model: "gpt-5.6-sol", effort: "low", reason: .terraUnavailableFallback))
  }

  @Test func legacyCatalogWithMissingModalitiesKeepsDocumentedImageCompatibility() async throws {
    try await assertRouting(
      models: [
        catalogModel("gpt-5.6-sol", isDefault: true),
        catalogModel("gpt-5.6-terra", modalities: nil),
      ],
      expected: .init(model: "gpt-5.6-terra", effort: "low", reason: .terraGuidance))
  }

  @Test(arguments: [GuidanceModelPreference.terra, .conversation])
  func knownTextOnlyGuidanceSelectionFailsBeforeStartingAProviderThread(
    _ preference: GuidanceModelPreference
  ) async throws {
    for configured in ["gpt-5.6-sol", ""] {
      let fixture = try makeFixture(
        completeTurn: true, selectedModel: "gpt-5.6-sol",
        modelCatalog: [catalogModel("gpt-5.6-sol", isDefault: true, modalities: ["text"])])
      defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
      let provider = CodexProvider()
      let timeout = Task {
        try await Task.sleep(for: .seconds(3))
        await provider.stop()
      }
      defer { timeout.cancel() }
      let routing = TransportRoutingReceiver()
      let receiver = TransportUnitReceiver()
      do {
        try await provider.stream(
          executable: fixture.path, model: configured,
          messages: [.init(role: "user", text: "Show me where to click")], context: "",
          image: nil, scene: nil, guidanceModel: preference,
          onRouting: { await routing.append($0) },
          onUnit: { await receiver.append($0.text ?? "") },
          responsePolicy: ResponsePolicy.resolve(
            text: "Show me where to click", screenGuidanceEnabled: true))
        Issue.record("An explicitly text-only model was used for screen guidance.")
      } catch let error as ProviderError {
        #expect(error.localizedDescription.contains("does not accept images"))
        #expect(error.localizedDescription.contains("Settings"))
      }
      #expect(await routing.selections.isEmpty)
      #expect(await receiver.text.isEmpty)
      let requests = try String(
        contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
      ).split(separator: "\n").map { line in
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      }
      #expect(requests.contains { $0["method"] as? String == "model/list" })
      #expect(!requests.contains { $0["method"] as? String == "thread/start" })
      #expect(!requests.contains { $0["method"] as? String == "turn/start" })
    }
  }

  @Test func configuredGuidanceKeepsLegacyCatalogImageCompatibility() async throws {
    try await assertRouting(
      models: [catalogModel("gpt-5.6-sol", isDefault: true, modalities: nil)],
      preference: .conversation,
      expected: .init(model: "gpt-5.6-sol", effort: "low", reason: .configuredGuidance))
  }

  @Test func unknownConfiguredAliasesRemainAvailableWithoutInventingCapabilityMetadata() throws {
    let selected = try CodexModelRouting.select(
      configuredModel: "configured-unknown-alias",
      policy: ResponsePolicy.resolve(text: "Show me where to click", screenGuidanceEnabled: true),
      preference: .conversation, catalog: [])
    #expect(selected.model == "configured-unknown-alias")
    #expect(selected.reason == .configuredGuidance && selected.effort == nil)
  }

  @Test func knownTextOnlyAliasRejectsGuidanceButRemainsValidForConversation() throws {
    let catalog = [
      CodexRoutingModel(
        model: "public-text-only-model", alias: "configured-alias", isDefault: true,
        supportsImages: false, supportedEfforts: ["low"])
    ]
    #expect(throws: ProviderError.self) {
      try CodexModelRouting.select(
        configuredModel: "configured-alias",
        policy: ResponsePolicy.resolve(text: "Show me where to click", screenGuidanceEnabled: true),
        preference: .conversation, catalog: catalog)
    }
    let conversation = try CodexModelRouting.select(
      configuredModel: "configured-alias",
      policy: ResponsePolicy.resolve(text: "Hello", screenGuidanceEnabled: true),
      preference: .terra, catalog: catalog)
    #expect(conversation.model == "configured-alias")
    #expect(conversation.reason == .conversation && conversation.effort == nil)
  }

  @Test func ambiguousTerraEntriesAndEntriesBeyondTheRequestedCatalogBoundAreExcluded() async throws
  {
    var models = [
      catalogModel("gpt-5.6-sol", isDefault: true),
      catalogModel("gpt-5.6-terra"), catalogModel("gpt-5.6-terra"),
    ]
    models += (0..<97).map { catalogModel("public-fixture-\($0)") }
    models.append(catalogModel("gpt-6.1-terra"))
    #expect(models.count == 101)
    try await assertRouting(
      models: models,
      expected: .init(model: "gpt-5.6-sol", effort: "low", reason: .terraUnavailableFallback))
  }

  private func catalogModel(
    _ id: String, isDefault: Bool = false, hidden: Bool = false,
    modalities: [String]? = ["text", "image"]
  ) -> [String: Any] {
    var result: [String: Any] = [
      "model": id, "id": id, "isDefault": isDefault, "hidden": hidden,
      "supportedReasoningEfforts": [["reasoningEffort": "medium"], ["reasoningEffort": "low"]],
    ]
    if let modalities { result["inputModalities"] = modalities }
    return result
  }

  private func assertRouting(
    models: [[String: Any]], preference: GuidanceModelPreference = .terra,
    route: ResponsePolicy.Route = .screenGuidance, expected: CodexRoutingSelection
  ) async throws {
    let fixture = try makeFixture(
      completeTurn: true, selectedModel: "gpt-5.6-sol", modelCatalog: models,
      expectedRequestModel: expected.model)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let routing = TransportRoutingReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      await provider.stop()
    }
    defer { timeout.cancel() }
    let prompt =
      route == .screenGuidance
      ? "Show me where to click"
      : (route == .notebook ? "Draw a diagram of a lever" : "Hello")
    let policy = ResponsePolicy.resolve(text: prompt, screenGuidanceEnabled: true)
    #expect(policy.route == route)
    try await provider.stream(
      executable: fixture.path, model: "gpt-5.6-sol",
      messages: [.init(role: "user", text: prompt)], context: "", image: nil, scene: nil,
      guidanceModel: preference, onRouting: { selection in await routing.append(selection) },
      onUnit: { unit in await receiver.append(unit.text ?? "") }, responsePolicy: policy)
    #expect(await receiver.text == "ready")
    #expect(await routing.selections == [expected])
    let requests = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let thread = try #require(requests.first { $0["method"] as? String == "thread/start" })
    let threadParams = try #require(thread["params"] as? [String: Any])
    let turn = try #require(requests.first { $0["method"] as? String == "turn/start" })
    let turnParams = try #require(turn["params"] as? [String: Any])
    #expect(threadParams["model"] as? String == expected.model)
    #expect(turnParams["model"] as? String == expected.model)
    #expect(turnParams["effort"] as? String == expected.effort)
    #expect(threadParams["serviceTier"] == nil && turnParams["serviceTier"] == nil)
    #expect(turnParams["serviceTierForTurn"] == nil)
    #expect(threadParams["sandbox"] as? String == "read-only")
    #expect(threadParams["approvalPolicy"] as? String == "never")
    #expect((threadParams["dynamicTools"] as? [Any])?.isEmpty == true)
    #expect(
      requests.filter { $0["method"] as? String == "model/list" }.count
        == (route == .conversation ? 0 : 1))
  }

  @Test func shortStdioResponsesStreamWithoutWaitingForPipeEOF() async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(3))
      await receiver.markWatchdogFired()
      await provider.stop()
    }
    defer { timeout.cancel() }
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
    // The fixture waits for more stdin and keeps stdout open indefinitely.
    // Completing before forced shutdown proves incremental pipe reading;
    // elapsed interpreter startup is not a renderer/provider latency claim.
    #expect(await receiver.watchdogFired == false)
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
    selectedModelVisible: Bool = true, modelCatalog: [[String: Any]]? = nil,
    expectedRequestModel: String? = nil
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
      "result": ["data": modelCatalog ?? models],
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
      "_expectedModel": expectedRequestModel ?? selectedModel,
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
  var watchdogFired = false
  func append(_ value: String) { text += value }
  func markWatchdogFired() { watchdogFired = true }
}

private actor TransportRoutingReceiver {
  var selections: [CodexRoutingSelection] = []
  func append(_ selection: CodexRoutingSelection) { selections.append(selection) }
}
