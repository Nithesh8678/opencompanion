import CompanionCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import OpenCompanion

// Each case starts a real Python subprocess. Bound fixture concurrency so cold
// interpreter startup does not consume another case's protocol watchdog.
@Suite(.serialized) struct CodexTransportTests {
  @Test(arguments: [ResponsePolicy.Route.notebook, .conversation, .screenGuidance])
  func sceneBraceRecoveryIsRestrictedToNotebookPolicy(route: ResponsePolicy.Route) async throws {
    let malformed =
      #"{"type":"scene","nodes":[{"id":"body","kind":"mesh","spatial3D":{"geometry":{"type":"sphere","radius":1}}]}"#
    let fixture = try makeFixture(completeTurn: true, responseText: malformed + "\n")
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await receiver.markWatchdogFired()
      await provider.stop()
    }
    defer { timeout.cancel() }
    let policy = ResponsePolicy(route: route, includesExistingNotebook: false)
    do {
      try await provider.stream(
        executable: fixture.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Public scene fixture")], context: "",
        image: nil, scene: nil, onUnit: { await receiver.append($0.type) }, responsePolicy: policy)
      #expect(route == .notebook)
    } catch {
      #expect(route != .notebook)
    }
    #expect(await receiver.text == (route == .notebook ? "scene" : ""))
    #expect(await receiver.watchdogFired == false)
  }

  @Test func currentScreenAndItsQuestionReachTheSameCodexTurnWithImageBytesIntact() async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let question = "check screen and tell me how to create a new table"
    let context = "PUBLIC_SCREEN_CONTEXT_MARKER: authored 4 by 3 pixel screen fixture"
    let image = try authoredScreenJPEG()
    // Exercise multimodal transport after the host has granted guidance. The
    // separate routing tests own whether a particular phrase grants capture.
    let policy = ResponsePolicy.resolve(
      text: question, screenGuidanceEnabled: true, explicitGuidance: true)
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await receiver.markWatchdogFired()
      await provider.stop()
    }
    defer { timeout.cancel() }
    try await provider.stream(
      executable: fixture.path, model: "fixture-default",
      messages: [.init(role: "user", text: question)], context: context, image: image, scene: nil,
      onUnit: { unit in await receiver.append(unit.text ?? "") }, responsePolicy: policy)
    #expect(await receiver.watchdogFired == false)
    #expect(await receiver.text == "ready")

    // This file is written by the subprocess from its actual stdin, after the
    // production adapter's JSON encoding and pipe delivery, not by a mock builder.
    let requests = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let turns = requests.filter { $0["method"] as? String == "turn/start" }
    #expect(turns.count == 1)
    let turn = try #require(turns.first)
    let params = try #require(turn["params"] as? [String: Any])
    let input = try #require(params["input"] as? [[String: Any]])
    let text = input.compactMap { item in
      item["type"] as? String == "text" ? item["text"] as? String : nil
    }.joined(separator: "\n")
    #expect(text.contains(question))
    #expect(text.contains(context))
    let images = input.filter { $0["type"] as? String == "image" }
    #expect(images.count == 1)
    let imageInput = try #require(images.first)
    let uri = try #require(imageInput["url"] as? String)
    let prefix = "data:image/jpeg;base64,"
    #expect(uri.hasPrefix(prefix))
    let transmitted = try #require(Data(base64Encoded: String(uri.dropFirst(prefix.count))))
    #expect(transmitted == image)
    let source = try #require(CGImageSourceCreateWithData(transmitted as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 1)
    let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(decoded.width == 4 && decoded.height == 3)
  }

  @Test(arguments: [true, false])
  func screenOptOutDropsSuppliedImageButKeepsQuestionAndIndependentContext(
    _ suppliedPolicy: Bool
  ) async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let question = "Do not look at my screen. Tell me how to create a new table in text only."
    let context = "PUBLIC_INDEPENDENT_DOCUMENT_CONTEXT: table-creation notes"
    let policy = ResponsePolicy.resolve(text: question, screenGuidanceEnabled: true)
    #expect(policy.route == .conversation && !policy.permitsScreenEvidence)
    let image = try authoredScreenJPEG()
    let provider = CodexProvider()
    let receiver = TransportUnitReceiver()
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await receiver.markWatchdogFired()
      await provider.stop()
    }
    defer { timeout.cancel() }
    // Deliberately supply a real image despite the opt-out: the transport must
    // protect the boundary for both explicit and locally resolved policies.
    try await provider.stream(
      executable: fixture.path, model: "fixture-default",
      messages: [.init(role: "user", text: question)], context: context, image: image, scene: nil,
      onUnit: { unit in await receiver.append(unit.text ?? "") },
      responsePolicy: suppliedPolicy ? policy : nil)
    #expect(await receiver.watchdogFired == false)
    #expect(await receiver.text == "ready")
    let requests = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let turns = requests.filter { $0["method"] as? String == "turn/start" }
    #expect(turns.count == 1)
    let params = try #require(turns.first?["params"] as? [String: Any])
    let input = try #require(params["input"] as? [[String: Any]])
    let text = input.compactMap { item in
      item["type"] as? String == "text" ? item["text"] as? String : nil
    }.joined(separator: "\n")
    #expect(text.contains(question) && text.contains(context))
    #expect(!input.contains { $0["type"] as? String == "image" })
    let serializedInput = try JSONSerialization.data(withJSONObject: input)
    let wireText = String(decoding: serializedInput, as: UTF8.self)
    #expect(!wireText.contains("data:image/") && !wireText.contains(image.base64EncodedString()))
  }

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

  @Test func ambiguousTerraEntriesAreExcluded() async throws {
    var models = [
      catalogModel("gpt-5.6-sol", isDefault: true),
      catalogModel("gpt-5.6-terra"), catalogModel("gpt-5.6-terra"),
    ]
    models += (0..<97).map { catalogModel("public-fixture-\($0)") }
    #expect(models.count == 100)
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

  @Test func timingsSeparateHandshakeFromAcceptedContentAndContainNoRequestData() async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let receiver = TransportTimingReceiver()
    let provider = CodexProvider()
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await provider.stop()
    }
    defer { timeout.cancel() }
    try await provider.stream(
      executable: fixture.path, model: "fixture-default",
      messages: [.init(role: "user", text: "PUBLIC_TIMING_CONTENT_CANARY")],
      context: "PUBLIC_CONTEXT_CANARY", image: nil, scene: nil,
      onTiming: { await receiver.append($0) }, onUnit: { _ in },
      responsePolicy: .init(route: .conversation, includesExistingNotebook: false))
    let events = await receiver.events
    #expect(
      events.map(\.stage) == [
        .requestStarted, .sessionStarted, .initialized, .accountVerified, .routingSelected,
        .configurationReady, .threadReady, .turnSubmitted, .turnAccepted,
        .firstTextDelta, .firstUnitAccepted, .responseCompleted,
      ])
    #expect(events.first?.elapsedMS == 0)
    #expect(events.allSatisfy { $0.elapsedMS.isFinite && $0.elapsedMS >= 0 })
    #expect(zip(events, events.dropFirst()).allSatisfy { $0.elapsedMS <= $1.elapsedMS })
    let data = try JSONEncoder().encode(events)
    let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(rows.allSatisfy { Set($0.keys) == ["stage", "elapsedMS"] })
    #expect(!String(decoding: data, as: UTF8.self).contains("CANARY"))
  }

  @Test func rejectedUnitsDoNotReportAcceptanceOrResponseCompletion() async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let receiver = TransportTimingReceiver()
    let provider = CodexProvider()
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await provider.stop()
    }
    defer { timeout.cancel() }
    do {
      try await provider.stream(
        executable: fixture.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Public rejected-unit fixture")],
        context: "", image: nil, scene: nil, onTiming: { await receiver.append($0) },
        onUnit: { _ in throw ProviderError.message("Public fixture rejected the decoded unit.") },
        responsePolicy: .init(route: .conversation, includesExistingNotebook: false))
      Issue.record("Rejected content unexpectedly completed")
    } catch {}
    let stages = await receiver.events.map(\.stage)
    #expect(stages.contains(.firstTextDelta))
    #expect(!stages.contains(.firstUnitAccepted))
    #expect(!stages.contains(.responseCompleted))
  }

  @Test(arguments: [0, 1, 2])
  func explicitSceneDiagnosticsSeparateDecodeAndOnlyTheFirstHandlerOutcome(
    rejectAt: Int
  ) async throws {
    let line =
      ##"{"type":"scene","nodes":[{"id":"PUBLIC_PART_NAME_CANARY","kind":"rectangle","width":100,"height":50,"fill":"#112233"}],"narration":"PUBLIC_NARRATION_CANARY"}"##
    let fixture = try makeFixture(completeTurn: true, responseText: line + "\n" + line + "\n")
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let receiver = TransportTimingReceiver()
    let handler = TransportSceneHandler(rejectAt: rejectAt)
    let provider = CodexProvider()
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await provider.stop()
    }
    defer { timeout.cancel() }
    var failed = false
    do {
      try await provider.stream(
        executable: fixture.path, model: "fixture-default",
        messages: [.init(role: "user", text: "PUBLIC_REQUEST_CANARY")],
        context: "PUBLIC_CONTEXT_CANARY", image: nil, scene: nil,
        onTiming: { await receiver.append($0) },
        onUnit: { _ in
          let observed = await receiver.events.map(\.stage)
          try await handler.accept(observedStages: observed)
        },
        responsePolicy: .init(route: .notebook, includesExistingNotebook: false),
        sceneStart: .geometryFirst, measureSceneLatency: true)
    } catch { failed = true }
    #expect(failed == (rejectAt != 0))
    let events = await receiver.events
    let stages = events.map(\.stage)
    #expect(stages.filter { $0 == .firstSceneLineDecoded }.count == 1)
    #expect(stages.filter { $0 == .firstSceneHandlerStarted }.count == 1)
    #expect(stages.contains(.firstSceneHandlerFailed) == (rejectAt == 1))
    #expect(stages.contains(.firstSceneHandlerCompleted) == (rejectAt != 1))
    #expect(stages.contains(.firstSceneAccepted) == (rejectAt != 1))
    #expect(stages.contains(.responseCompleted) == (rejectAt == 0))
    #expect(await handler.firstCallSawStartedWithoutCompletion)
    let decoded = try #require(events.first { $0.stage == .firstSceneLineDecoded })
    #expect(decoded.lineUTF8Bytes == line.utf8.count)
    #expect(decoded.lineTermination == .newline)
    let start = try #require(decoded.lineStartMS)
    let end = try #require(decoded.lineEndMS)
    #expect(start >= 0 && start <= end && end <= decoded.elapsedMS)
    let handlerStart = try #require(events.first { $0.stage == .firstSceneHandlerStarted })
    #expect(decoded.elapsedMS <= handlerStart.elapsedMS)

    let requests = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    let thread = try #require(requests.first { $0["method"] as? String == "thread/start" })
    let threadParams = try #require(thread["params"] as? [String: Any])
    let base = try #require(threadParams["baseInstructions"] as? String)
    let developer = try #require(threadParams["developerInstructions"] as? String)
    #expect(!base.contains("Start with one brief text unit"))
    #expect(!base.contains("Start with one brief useful text unit"))
    let turn = try #require(requests.first { $0["method"] as? String == "turn/start" })
    let params = try #require(turn["params"] as? [String: Any])
    let input = try #require(params["input"] as? [[String: Any]])
    let text = try #require(input.first?["text"] as? String)
    let inputValue = try JSONDecoder().decode(
      JSONValue.self, from: JSONSerialization.data(withJSONObject: input))
    let sizes = try #require(events.first { $0.stage == .requestPayloadPrepared })
    #expect(sizes.instructionUTF8Bytes == base.utf8.count + developer.utf8.count)
    #expect(sizes.conversationUTF8Bytes == text.utf8.count)
    let encodedInputBytes = try JSONEncoder().encode(inputValue).count
    #expect(sizes.turnInputUTF8Bytes == encodedInputBytes)
    let encoded = try JSONEncoder().encode(events)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("CANARY"))
    #expect(events.allSatisfy { $0.elapsedMS.isFinite && $0.elapsedMS >= 0 })
  }

  @Test func geometryFirstUnsupportedScopeRejectsBeforeStartingTheFixture() async throws {
    let fixture = try makeFixture(completeTurn: true)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    do {
      try await CodexProvider().stream(
        executable: fixture.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Hello")], context: "", image: nil, scene: nil,
        onUnit: { _ in },
        responsePolicy: .init(route: .conversation, includesExistingNotebook: false),
        sceneStart: .geometryFirst, measureSceneLatency: true)
      Issue.record("Unsupported geometry-first request unexpectedly started.")
    } catch {
      #expect(error.localizedDescription.contains("Geometry-first output supports only"))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.path + ".requests"))
  }

  @Test func cancellationAtPayloadObserverPreventsTurnSubmission() async throws {
    try await assertDiagnosticObserverCancellation(at: .requestPayloadPrepared)
  }

  @Test func cancellationAtHandlerStartObserverPreventsSemanticDelivery() async throws {
    try await assertDiagnosticObserverCancellation(at: .firstSceneHandlerStarted)
  }

  private func assertDiagnosticObserverCancellation(at cancelledStage: CodexTimingEvent.Stage)
    async throws
  {
    let fixture = try makeFixture(
      completeTurn: true, responseText: "{\"type\":\"scene\",\"nodes\":[]}\n")
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let provider = CodexProvider()
    let receiver = TransportTimingReceiver()
    let delivery = TransportUnitReceiver()
    let request = Task {
      try await provider.stream(
        executable: fixture.path, model: "fixture-default",
        messages: [.init(role: "user", text: "Public diagnostic cancellation fixture")],
        context: "", image: nil, scene: nil,
        onTiming: { event in
          await receiver.append(event)
          if event.stage == cancelledStage {
            // The observer shares this request's Task across actor hops. Cancel
            // that nested request, never the surrounding Swift Testing task.
            withUnsafeCurrentTask { task in
              guard let task else {
                Issue.record("A diagnostic observer had no current request task.")
                return
              }
              task.cancel()
            }
          }
        },
        onUnit: { _ in await delivery.append("SEMANTIC_HANDLER_CALLED") },
        responsePolicy: .init(route: .notebook, includesExistingNotebook: false),
        sceneStart: .geometryFirst, measureSceneLatency: true)
    }
    let timeout = Task {
      try await Task.sleep(for: .seconds(5))
      await delivery.markWatchdogFired()
      request.cancel()
      await provider.stop()
    }
    defer {
      timeout.cancel()
      request.cancel()
    }
    do {
      try await request.value
      Issue.record("A request cancelled by its diagnostic observer unexpectedly succeeded.")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(await delivery.watchdogFired == false)
    #expect(await delivery.text.isEmpty)
    let stages = await receiver.events.map(\.stage)
    #expect(stages.contains(cancelledStage))
    #expect(!stages.contains(.firstSceneHandlerFailed))
    #expect(!stages.contains(.firstSceneHandlerCompleted))
    #expect(!stages.contains(.firstSceneAccepted))
    #expect(!stages.contains(.firstUnitAccepted))
    #expect(!stages.contains(.responseCompleted))
    let methods = try String(
      contentsOf: URL(fileURLWithPath: fixture.path + ".requests"), encoding: .utf8
    ).split(separator: "\n").map { line in
      let request = try #require(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      return try #require(request["method"] as? String)
    }
    #expect(methods.contains("thread/start"))
    if cancelledStage == .requestPayloadPrepared {
      #expect(!methods.contains("turn/start"))
      #expect(!stages.contains(.firstSceneLineDecoded))
      #expect(!stages.contains(.firstSceneHandlerStarted))
    } else {
      #expect(methods.contains("turn/start"))
      #expect(stages.contains(.firstSceneLineDecoded))
    }
    // These are decoder/wrapper observation points. Awaited timing observers
    // remain part of wall elapsed time; they are not isolated model-work clocks.
  }

  private func authoredScreenJPEG() throws -> Data {
    let bitmap = try #require(
      CGContext(
        data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    bitmap.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
    bitmap.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
    bitmap.fill(CGRect(x: 2, y: 0, width: 2, height: 3))
    let image = try #require(bitmap.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    let completed = CGImageDestinationFinalize(destination)
    #expect(completed)
    return data as Data
  }

  private func makeFixture(
    completeTurn: Bool, selectedModel: String = "fixture-default",
    supportedEfforts: [String]? = ["medium", "low"], catalogIncludesSelected: Bool = true,
    selectedModelVisible: Bool = true, modelCatalog: [[String: Any]]? = nil,
    expectedRequestModel: String? = nil,
    responseText: String = "{\"type\":\"text\",\"text\":\"ready\"}\n"
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
    let itemStarted = try encoded([
      "method": "item/started",
      "params": [
        "threadId": "fixture-thread", "turnId": "fixture-turn",
        "item": ["id": "fixture-answer", "type": "agentMessage", "phase": "final_answer"],
      ],
    ])
    let delta = try encoded([
      "method": "item/agentMessage/delta",
      "params": [
        "threadId": "fixture-thread", "turnId": "fixture-turn",
        "itemId": "fixture-answer", "delta": responseText,
      ],
    ])
    let itemCompleted = try encoded([
      "method": "item/completed",
      "params": [
        "threadId": "fixture-thread", "turnId": "fixture-turn",
        "item": [
          "id": "fixture-answer", "type": "agentMessage", "phase": "final_answer",
          "text": responseText,
        ],
      ],
    ])
    let completed = try encoded([
      "method": "turn/completed",
      "params": [
        "threadId": "fixture-thread",
        "turn": ["id": "fixture-turn", "status": "completed"],
      ],
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
              print(r'''\(itemStarted)''',flush=True)
              print(r'''\(delta)''',flush=True)
              print(r'''\(itemCompleted)''',flush=True)
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

private actor TransportSceneHandler {
  let rejectAt: Int
  private var calls = 0
  private(set) var firstCallSawStartedWithoutCompletion = false

  init(rejectAt: Int) { self.rejectAt = rejectAt }

  func accept(observedStages: [CodexTimingEvent.Stage]) throws {
    calls += 1
    if calls == 1 {
      firstCallSawStartedWithoutCompletion =
        observedStages.contains(.firstSceneHandlerStarted)
        && !observedStages.contains(.firstSceneHandlerCompleted)
        && !observedStages.contains(.firstSceneHandlerFailed)
    }
    if calls == rejectAt {
      throw ProviderError.message("Public fixture refused the decoded scene.")
    }
  }
}

private actor TransportRoutingReceiver {
  var selections: [CodexRoutingSelection] = []
  func append(_ selection: CodexRoutingSelection) { selections.append(selection) }
}

private actor TransportTimingReceiver {
  var events: [CodexTimingEvent] = []
  func append(_ value: CodexTimingEvent) { events.append(value) }
}
