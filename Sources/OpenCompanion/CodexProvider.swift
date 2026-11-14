import CompanionCore
import Darwin
import Foundation

struct CodexModel: Sendable {
  var id: String
  var displayName: String
}
struct CodexAccountStatus: Sendable {
  var authType: String
  var models: [CodexModel]
}

/// Documented stdio integration. Codex owns its managed ChatGPT credentials and renewal.
/// This adapter never reads auth.json, copies tokens, or turns a subscription into an API key.
actor CodexProvider {
  private var activeSession: CodexRPCSession?
  private var activeRequestID: UUID?
  private var activeGuidanceSessionID: UUID?
  private let sessionPolicy = CodexGuidanceSessionPolicy()
  private let now: @Sendable () -> TimeInterval
  private var idleTask: Task<Void, Never>?
  private struct GuidanceConnection: Sendable {
    let id: UUID
    let executable: CodexGuidanceExecutableIdentity
    let session: CodexRPCSession
    let createdAt: TimeInterval
    var lastUsedAt: TimeInterval
    var initialized = false
    var cachedAt: TimeInterval?
    var metadataEpoch: UInt64?
    var models: [CodexRoutingModel] = []
    var hardenedConfig: JSONValue?
    var nextRPCBase = 0
    var turnCount = 0
    var threadIDs = Set<String>()
  }
  private var guidanceConnection: GuidanceConnection?

  init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
  }

  /// Full explicit teardown. Turn replacement should cancel its Task instead;
  /// its cancellation handler is scoped to that request's immutable UUID.
  func stop() {
    idleTask?.cancel()
    idleTask = nil
    activeSession?.close()
    guidanceConnection?.session.close()
    guidanceConnection = nil
    activeSession = nil
    activeRequestID = nil
    activeGuidanceSessionID = nil
  }

  func endGuidanceSession(id: UUID) {
    if guidanceConnection?.id == id {
      idleTask?.cancel()
      idleTask = nil
      guidanceConnection?.session.close()
      guidanceConnection = nil
    }
    if activeGuidanceSessionID == id {
      activeSession?.close()
      activeSession = nil
      activeRequestID = nil
      activeGuidanceSessionID = nil
    }
  }

  /// Handshake/account/catalog only. No thread, turn or model request is sent.
  func prepareGuidanceSession(
    executable: String, model: String, guidanceModel: GuidanceModelPreference = .terra,
    sessionID: UUID, onTiming: (@Sendable (CodexTimingEvent) async -> Void)? = nil
  ) async throws {
    let requestID = UUID()
    let acquired = try acquire(
      executable: executable, guidanceSessionID: sessionID,
      requestID: requestID)
    let session = acquired.session
    let timing = CodexTimingReporter(onEvent: onTiming)
    var succeeded = false
    defer { release(session: session, requestID: requestID, keepWarm: succeeded) }
    try await withTaskCancellationHandler {
      await timing.mark(.requestStarted)
      await timing.mark(acquired.reused ? .sessionReused : .sessionStarted)
      var iterator = session.messages.makeAsyncIterator()
      let bootstrapped = try await Self.bootstrap(
        session: session, requestID: requestID, snapshot: bootstrapSnapshot(session: session),
        rpcBase: acquired.rpcBase, needsCatalog: true, timing: timing, iterator: &iterator)
      try commitBootstrap(bootstrapped, session: session, requestID: requestID)
      let catalog = bootstrapped.models
      _ = try CodexModelRouting.select(
        configuredModel: model,
        policy: .init(route: .screenGuidance, includesExistingNotebook: false),
        preference: guidanceModel, catalog: catalog)
      try requireActive(session: session, requestID: requestID)
      succeeded = true
    } onCancel: {
      session.close(requestID: requestID)
    }
  }

  func inspect(executable: String) async throws -> CodexAccountStatus {
    let session = try CodexRPCSession(executable: executable)
    let requestID = UUID()
    try session.beginRequest(id: requestID)
    defer { session.close() }
    return try await withTaskCancellationHandler {
      var iterator = session.messages.makeAsyncIterator()
      try session.send(method: "initialize", id: 1, params: Self.clientInfo)
      _ = try await Self.response(id: 1, iterator: &iterator, session: session)
      try session.send(method: "initialized", params: .object([:]))
      try session.send(
        method: "account/read", id: 2, params: .object(["refreshToken": .bool(false)]))
      let account = try await Self.response(id: 2, iterator: &iterator, session: session)
      let authType = account["account"]?["type"]?.string ?? "signedOut"
      let catalog = try await Self.modelCatalog(
        session: session, firstRequestID: 3, iterator: &iterator)
      let models = catalog.compactMap { entry -> CodexModel? in
        guard entry["hidden"]?.boolean != true,
          let id = entry["model"]?.string ?? entry["id"]?.string,
          !id.isEmpty, id.utf8.prefix(201).count <= 200
        else { return nil }
        return .init(id: id, displayName: entry["displayName"]?.string ?? id)
      }
      return CodexAccountStatus(authType: authType, models: models)
    } onCancel: {
      session.close()
    }
  }

  func test(executable: String, model: String) async throws -> String {
    let account = try await inspect(executable: executable)
    guard account.authType == "chatgpt" else {
      throw ProviderError.message(
        "Codex is not signed in with ChatGPT. Run ‘codex login’ in Terminal, then test again.")
    }
    let receiver = CodexSmokeReceiver()
    try await stream(
      executable: executable, model: model,
      messages: [
        .init(
          role: "user",
          text: "Output exactly one NDJSON unit: {\"type\":\"text\",\"text\":\"ready\"}")
      ], context: "", image: nil, scene: nil
    ) { unit in
      await receiver.accept(unit.text ?? "")
    }
    let text = await receiver.value
    guard text.lowercased().contains("ready") else {
      throw ProviderError.message(
        "Codex completed, but the teaching protocol check was not accepted.")
    }
    return
      "Live ChatGPT subscription request completed using \(model.isEmpty ? "the Codex default model" : model). \(account.models.count) catalog models reported; only this completed request verifies access."
  }

  func stream(
    executable: String, model: String, messages: [ChatLine], context: String, image: Data?,
    scene: SceneDocument?,
    guidanceModel: GuidanceModelPreference = .terra,
    onRouting: (@Sendable (CodexRoutingSelection) async -> Void)? = nil,
    onTiming: (@Sendable (CodexTimingEvent) async -> Void)? = nil,
    onStructuredProgress: (@Sendable (StructuredSpatialStageProgress) async -> Void)? = nil,
    onUnit: @escaping @Sendable (ProviderUnit) async throws -> Void,
    onText: (@Sendable (ProviderTextPreview) async throws -> Void)? = nil,
    responsePolicy: ResponsePolicy? = nil,
    outputMode: CodexOutputMode = .ndjson,
    sceneStart: CodexSceneStartMode = .introductionFirst,
    measureSceneLatency: Bool = false,
    onRejectedLine: (@Sendable (Data) async -> Void)? = nil,
    onNDJSONAudit: (@Sendable (CodexNDJSONAudit) async -> Void)? = nil,
    guidanceSessionID: UUID? = nil
  ) async throws {
    let requestPolicy =
      responsePolicy
      ?? ResponsePolicy.resolve(
        text: messages.last(where: { $0.role == "user" })?.text ?? "",
        screenGuidanceEnabled: image != nil, inNotebook: scene != nil, hasNotebook: scene != nil)
    let permittedImage = requestPolicy.permitsScreenEvidence ? image : nil
    try outputMode.validate(
      policy: requestPolicy, hasImage: permittedImage != nil, hasScene: scene != nil)
    try sceneStart.validate(
      policy: requestPolicy, hasImage: permittedImage != nil, hasScene: scene != nil,
      outputMode: outputMode)
    let warmID =
      requestPolicy.route == .screenGuidance && outputMode == .ndjson
      ? guidanceSessionID : nil
    let requestID = UUID()
    let timing = CodexTimingReporter(onEvent: onTiming)
    let acquired = try acquire(
      executable: executable, guidanceSessionID: warmID,
      requestID: requestID)
    let session = acquired.session
    let rpcBase = acquired.rpcBase
    let turnRequestID = rpcBase + 5
    var succeeded = false
    defer { release(session: session, requestID: requestID, keepWarm: succeeded && warmID != nil) }
    try await withTaskCancellationHandler {
      await timing.mark(.requestStarted)
      await timing.mark(acquired.reused ? .sessionReused : .sessionStarted)
      var iterator = session.messages.makeAsyncIterator()
      let bootstrapped = try await Self.bootstrap(
        session: session, requestID: requestID, snapshot: bootstrapSnapshot(session: session),
        rpcBase: rpcBase,
        needsCatalog: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || requestPolicy.route == .screenGuidance || requestPolicy.route == .notebook,
        timing: timing, iterator: &iterator)
      try commitBootstrap(bootstrapped, session: session, requestID: requestID)
      let catalogModels = bootstrapped.models
      let routing = try CodexModelRouting.select(
        configuredModel: model, policy: requestPolicy, preference: guidanceModel,
        catalog: catalogModels)
      let selectedModel = routing.model
      await timing.mark(.routingSelected)
      try Task.checkCancellation()
      if let onRouting { await onRouting(routing) }
      try Task.checkCancellation()
      try requireActive(session: session, requestID: requestID)
      // Always read current config: newly inherited plugin/MCP entries must be
      // explicitly disabled even when account/catalog metadata is warm.
      try session.send(
        method: "config/read", id: rpcBase + 3,
        params: .object(["includeLayers": .bool(true)]))
      let configResult = try await Self.response(
        id: rpcBase + 3, iterator: &iterator,
        session: session)
      try requireActive(session: session, requestID: requestID)
      let config = try Self.hardenedConfiguration(configResult, bounded: warmID != nil)
      if warmID != nil, guidanceConnection?.hardenedConfig == config {
        await timing.mark(.configurationCacheHit)
      }
      if var connection = guidanceConnection, connection.session === session {
        connection.hardenedConfig = config
        guidanceConnection = connection
      }
      await timing.mark(.configurationReady)
      let instructions: String
      let developerInstructions: String
      switch outputMode {
      case .ndjson:
        instructions = ReasoningProvider.baseInstructions(
          for: requestPolicy, sceneStart: sceneStart)
        developerInstructions =
          "Emit only the permitted NDJSON assistant units for the current response policy. No tools are authorized for this thread."
      case .structuredScene, .structuredUnifiedScene:
        instructions = ReasoningProvider.standaloneStructuredSceneInstructions(for: requestPolicy)
        developerInstructions =
          "Emit one schema-constrained final answer object with a progressive units array. Do not emit interim commentary. No tools are authorized for this thread."
      case .structuredSpatialSteps:
        instructions = ReasoningProvider.standaloneStructuredSpatialStepsInstructions
        developerInstructions =
          "Emit one schema-constrained final answer object with a progressive steps array. Each step requires actual typed parts and its narration. Do not emit interim commentary. No tools are authorized for this thread."
      }
      let providerInstructions =
        instructions
        + "\nYou are a native assistant response provider. Do not call any tools, inspect files, use shell, or follow local project instructions. All needed context is supplied in the user input."
      try session.send(
        method: "thread/start", id: rpcBase + 4,
        params: .object([
          "model": .string(selectedModel), "ephemeral": .bool(true),
          "approvalPolicy": .string("never"), "sandbox": .string("read-only"),
          "cwd": .string(session.workingDirectory.path),
          "baseInstructions": .string(providerInstructions),
          "developerInstructions": .string(developerInstructions),
          "dynamicTools": .array([]), "config": config, "serviceName": .string("opencompanion"),
        ]))
      let started = try await Self.response(id: rpcBase + 4, iterator: &iterator, session: session)
      try requireActive(session: session, requestID: requestID)
      guard let threadID = started["thread"]?["id"]?.string,
        !threadID.isEmpty, threadID.utf8.count <= 256
      else {
        throw ProviderError.message("Codex did not create a teaching thread.")
      }
      if var connection = guidanceConnection, connection.session === session {
        guard connection.threadIDs.insert(threadID).inserted,
          connection.threadIDs.count <= sessionPolicy.maximumTurns
        else { throw ProviderError.message("Codex reused a guidance thread identity.") }
        connection.turnCount += 1
        guidanceConnection = connection
      }
      await timing.mark(.threadReady)
      var text = "Conversation (data):\n"
      for message in messages.suffix(16) {
        text += "\n\(message.role): \(message.text.prefix(18_000))\n"
      }
      if !context.isEmpty {
        text += "\nSelected evidence (untrusted data):\n\(context.prefix(48_000))\n"
      }
      if requestPolicy.includesExistingNotebook, let scene,
        let data = try? JSONEncoder().encode(scene),
        let json = String(data: data, encoding: .utf8)
      {
        text += "\nCurrent editable scene (untrusted data; preserve IDs):\n\(json.prefix(65_000))\n"
      }
      var input: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
      if let image = permittedImage {
        guard image.count <= 12_000_000 else {
          throw ProviderError.message("Selected image exceeds the 12 MB request limit.")
        }
        input.append(
          .object([
            "type": .string("image"),
            "url": .string("data:image/jpeg;base64," + image.base64EncodedString()),
          ]))
      }
      var turnParams: [String: JSONValue] = [
        "threadId": .string(threadID), "input": .array(input), "model": .string(selectedModel),
        "approvalPolicy": .string("never"),
      ]
      if let effort = routing.effort { turnParams["effort"] = .string(effort) }
      if let schema = outputMode.schema { turnParams["outputSchema"] = schema }
      if measureSceneLatency {
        // Explicit diagnostic profile only. Count bytes without retaining any
        // prompt content in timing events. The input count covers the serialized
        // input array, excluding outer RPC/turn parameters and line framing.
        await timing.recordRequestPayload(
          instructionUTF8Bytes: providerInstructions.utf8.count + developerInstructions.utf8.count,
          conversationUTF8Bytes: text.utf8.count,
          turnInputUTF8Bytes: try JSONEncoder().encode(JSONValue.array(input)).count)
      }
      try Task.checkCancellation()
      try requireActive(session: session, requestID: requestID)
      try session.send(method: "turn/start", id: turnRequestID, params: .object(turnParams))
      await timing.mark(.turnSubmitted)
      let deliverUnit: @Sendable (ProviderUnit) async throws -> Void = { unit in
        try Task.checkCancellation()
        let measureFirstHandler =
          measureSceneLatency && unit.type == "scene"
          ? await timing.beginFirstSceneHandler() : false
        try Task.checkCancellation()
        do {
          try await onUnit(unit)
        } catch {
          if measureFirstHandler { await timing.finishFirstSceneHandler(success: false) }
          throw error
        }
        if measureFirstHandler { await timing.finishFirstSceneHandler(success: true) }
        // These decoders count successful host admission before their own
        // post-callback cancellation check. Do not turn a known admission into
        // an uncounted callback failure in this wrapper.
        if outputMode != .structuredSpatialSteps && outputMode != .ndjson {
          try Task.checkCancellation()
        }
        await timing.mark(.firstUnitAccepted)
        if unit.type == "scene" { await timing.mark(.firstSceneAccepted) }
      }
      var ndjson = CodexNDJSONOutput(
        threadID: threadID, allowSceneBraceRecovery: requestPolicy.allowsNotebook)
      let onSceneLineDecoded: (@Sendable (ProviderLineWireSample) async -> Void)?
      if measureSceneLatency {
        onSceneLineDecoded = { sample in await timing.recordSceneLine(sample) }
      } else {
        onSceneLineDecoded = nil
      }
      var structured = CodexStructuredOutput(threadID: threadID, outputMode: outputMode)
      var lastSpatialProgress: StructuredSpatialStageProgress?
      var totalBytes = 0
      var sawCompleted = false
      do {
        while let message = try await iterator.next() {
          try requireActive(session: session, requestID: requestID)
          if let id = message["id"]?.integer, id != turnRequestID,
            message["method"] == nil
          {
            continue
          }
          if let error = message["error"] {
            throw ProviderError.message(
              "Codex app-server error: \(error["message"]?.string ?? "request rejected")")
          }
          if message["id"]?.integer == turnRequestID,
            let turnID = message["result"]?["turn"]?["id"]?.string
          {
            session.setTurn(threadID: threadID, turnID: turnID)
            if outputMode.isStructured {
              try structured.bind(turnID: turnID)
            } else {
              try ndjson.bind(turnID: turnID)
            }
            await timing.mark(.turnAccepted)
          }
          guard let method = message["method"]?.string else { continue }
          let params = message["params"]
          if message["id"] != nil {
            try session.rejectToolRequest(message)
            throw ProviderError.message(
              "Codex requested an interactive capability. Teaching mode permits no external actions."
            )
          }
          if method == "item/started",
            outputMode != .ndjson || ndjson.matchesTurn(params),
            let itemType = params?["item"]?["type"]?.string,
            [
              "commandExecution", "mcpToolCall", "dynamicToolCall", "fileChange", "webSearch",
              "imageGeneration", "collabAgentToolCall",
            ].contains(itemType)
          {
            throw ProviderError.message(
              "Codex attempted a tool call outside the teaching response scope.")
          }
          if method == "item/agentMessage/delta", let delta = params?["delta"]?.string,
            outputMode == .ndjson ? ndjson.matchesTurn(params) : structured.matchesTurn(params)
          {
            if !delta.isEmpty { await timing.mark(.firstTextDelta) }
            totalBytes += delta.utf8.count
            guard totalBytes <= 2_000_000 else {
              throw ProviderError.message("Codex output exceeded the bounded response budget.")
            }
          }
          if outputMode == .ndjson {
            try await ndjson.receive(
              method: method, params: params, onUnit: deliverUnit, onText: onText,
              onRejectedLine: onRejectedLine, onSceneLineDecoded: onSceneLineDecoded)
          }
          if outputMode.isStructured {
            do {
              try await structured.receive(
                method: method, params: params, onUnit: deliverUnit, onText: onText)
            } catch {
              if let progress = structured.spatialProgress, progress != lastSpatialProgress {
                await onStructuredProgress?(progress)
              }
              throw error
            }
            if let progress = structured.spatialProgress, progress != lastSpatialProgress {
              await onStructuredProgress?(progress)
              lastSpatialProgress = progress
            }
            if structured.finalMessageStarted { await timing.mark(.finalMessageStarted) }
            if structured.finalMessageCompleted { await timing.mark(.finalMessageCompleted) }
          }
          if method == "turn/completed" {
            if outputMode.isStructured {
              if !structured.matchesTurn(params) { continue }
            } else if !ndjson.matchesTurn(params) {
              continue
            }
            guard params?["turn"]?["status"]?.string == "completed" else {
              throw ProviderError.message(
                "Codex turn did not complete: \(params?["turn"]?["error"]?["message"]?.string ?? params?["turn"]?["status"]?.string ?? "unknown status")"
              )
            }
            sawCompleted = true
            break
          }
        }
        if outputMode.isStructured {
          guard sawCompleted else {
            throw ProviderError.message("Codex ended before the structured turn completed.")
          }
          do {
            try await structured.finishTurn(onUnit: deliverUnit, onText: onText)
          } catch {
            if let progress = structured.spatialProgress, progress != lastSpatialProgress {
              await onStructuredProgress?(progress)
            }
            throw error
          }
          if let progress = structured.spatialProgress, progress != lastSpatialProgress {
            await onStructuredProgress?(progress)
          }
          if structured.usedPhaseCompatibilityFallback {
            await timing.mark(.phaseCompatibilityFallback)
            await timing.mark(.finalMessageCompleted)
          }
        } else {
          try ndjson.finishTurn()
        }
        let acceptedUnits =
          outputMode.isStructured ? structured.acceptedUnits : ndjson.acceptedUnits
        guard sawCompleted, acceptedUnits > 0 else {
          throw ProviderError.message(
            "Codex ended before a complete teaching response was accepted.")
        }
        try Task.checkCancellation()
        await timing.mark(.responseCompleted)
      } catch {
        if outputMode == .ndjson, let onNDJSONAudit {
          await onNDJSONAudit(
            ndjson.audit(
              outcome: Task.isCancelled || error is CancellationError ? .cancelled : .failed))
        }
        throw error
      }
      if outputMode == .ndjson, let onNDJSONAudit {
        await onNDJSONAudit(ndjson.audit(outcome: .completed))
        try Task.checkCancellation()
      }
      try requireActive(session: session, requestID: requestID)
      succeeded = true
    } onCancel: {
      session.close(requestID: requestID)
    }
  }

  private struct Acquired: Sendable {
    let session: CodexRPCSession
    let rpcBase: Int
    let reused: Bool
  }

  private func acquire(executable: String, guidanceSessionID: UUID?, requestID: UUID) throws
    -> Acquired
  {
    try Task.checkCancellation()
    if let activeSession, activeSession.isOpen {
      throw ProviderError.message(
        "A Codex request is already active. Stop it before starting another.")
    }
    // A cancelled lease may still be unwinding its actor continuation. Its
    // scoped defer cannot clear the newer request installed below.
    activeSession = nil
    activeRequestID = nil
    activeGuidanceSessionID = nil
    idleTask?.cancel()
    idleTask = nil
    let session: CodexRPCSession
    let rpcBase: Int
    let reused: Bool
    if let guidanceSessionID {
      let identity = try CodexGuidanceExecutableIdentity.read(executable)
      let time = now()
      if let connection = guidanceConnection,
        connection.id == guidanceSessionID, connection.executable == identity,
        connection.session.isHealthy,
        connection.metadataEpoch.map({ $0 == connection.session.metadataEpoch }) ?? true,
        connection.nextRPCBase <= sessionPolicy.maximumTurns * 20,
        sessionPolicy.permitsReuse(
          createdAt: connection.createdAt,
          lastUsedAt: connection.lastUsedAt, turnCount: connection.turnCount, now: time)
      {
      } else {
        guidanceConnection?.session.close()
        guidanceConnection = nil
      }
      if guidanceConnection == nil {
        let created = try CodexRPCSession(executable: executable)
        guidanceConnection = .init(
          id: guidanceSessionID, executable: identity,
          session: created, createdAt: time, lastUsedAt: time)
      }
      guard var connection = guidanceConnection else { throw CancellationError() }
      session = connection.session
      rpcBase = connection.nextRPCBase
      connection.nextRPCBase += 20
      reused = connection.initialized
      guidanceConnection = connection
    } else {
      guidanceConnection?.session.close()
      guidanceConnection = nil
      session = try CodexRPCSession(executable: executable)
      rpcBase = 0
      reused = false
    }
    do { try session.beginRequest(id: requestID) } catch {
      session.close()
      if guidanceConnection?.session === session { guidanceConnection = nil }
      throw error
    }
    activeSession = session
    activeRequestID = requestID
    activeGuidanceSessionID = guidanceSessionID
    return .init(session: session, rpcBase: rpcBase, reused: reused)
  }

  private func requireActive(session: CodexRPCSession, requestID: UUID) throws {
    try Task.checkCancellation()
    guard activeRequestID == requestID, activeSession === session, session.isOpen else {
      throw CancellationError()
    }
    if let connection = guidanceConnection, connection.session === session,
      let verified = connection.metadataEpoch, verified != session.metadataEpoch
    {
      throw ProviderError.message(
        "The managed Codex account changed. Start a fresh guidance check.")
    }
  }

  private func release(session: CodexRPCSession, requestID: UUID, keepWarm: Bool) {
    guard activeRequestID == requestID, activeSession === session else {
      session.close(requestID: requestID)
      return
    }
    activeSession = nil
    activeRequestID = nil
    activeGuidanceSessionID = nil
    let time = now()
    if keepWarm, var connection = guidanceConnection, connection.session === session,
      session.isHealthy,
      sessionPolicy.permitsReuse(
        createdAt: connection.createdAt,
        lastUsedAt: time, turnCount: connection.turnCount, now: time)
    {
      session.endRequest(id: requestID)
      connection.lastUsedAt = time
      guidanceConnection = connection
      let idleOwner = connection.id
      let idleStamp = connection.lastUsedAt
      let remaining = min(
        sessionPolicy.idleLifetime,
        max(0, sessionPolicy.maximumLifetime - (time - connection.createdAt)))
      idleTask = Task { [weak self, weak session] in
        do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
        guard let self, let session else { return }
        await self.expireIdle(session: session, id: idleOwner, lastUsedAt: idleStamp)
      }
    } else {
      session.close()
      if guidanceConnection?.session === session { guidanceConnection = nil }
    }
  }

  private func expireIdle(session: CodexRPCSession, id: UUID, lastUsedAt: TimeInterval) {
    guard activeSession !== session, guidanceConnection?.session === session,
      guidanceConnection?.id == id, guidanceConnection?.lastUsedAt == lastUsedAt
    else { return }
    session.close()
    guidanceConnection = nil
    idleTask = nil
  }

  private struct BootstrapSnapshot: Sendable {
    let initialized: Bool
    let cachedModels: [CodexRoutingModel]?
    let metadataEpoch: UInt64?
  }

  private struct BootstrapResult: Sendable {
    let models: [CodexRoutingModel]
    let metadataEpoch: UInt64
  }

  /// Only immutable Sendable values cross the actor boundary. The request's
  /// non-Sendable iterator never becomes part of actor-owned mutable state.
  private func bootstrapSnapshot(session: CodexRPCSession) -> BootstrapSnapshot {
    guard var connection = guidanceConnection, connection.session === session else {
      return .init(initialized: false, cachedModels: nil, metadataEpoch: nil)
    }
    if connection.metadataEpoch == session.metadataEpoch,
      sessionPolicy.permitsMetadata(cachedAt: connection.cachedAt, now: now())
    {
      return .init(
        initialized: connection.initialized, cachedModels: connection.models,
        metadataEpoch: connection.metadataEpoch)
    }
    connection.cachedAt = nil
    connection.metadataEpoch = nil
    connection.models = []
    guidanceConnection = connection
    return .init(initialized: connection.initialized, cachedModels: nil, metadataEpoch: nil)
  }

  private func commitBootstrap(
    _ result: BootstrapResult, session: CodexRPCSession, requestID: UUID
  ) throws {
    try requireActive(session: session, requestID: requestID)
    guard result.metadataEpoch == session.metadataEpoch else {
      throw ProviderError.message("The managed Codex account changed during discovery.")
    }
    guard var connection = guidanceConnection, connection.session === session else { return }
    guard result.models.count <= 400,
      result.models.allSatisfy({
        $0.model.utf8.count <= 200 && ($0.alias?.utf8.count ?? 0) <= 200
      })
    else { throw ProviderError.message("Codex guidance metadata exceeded its bounded cache.") }
    connection.initialized = true
    connection.models = result.models
    // A metadata cache hit must not extend the original freshness deadline.
    if connection.cachedAt == nil { connection.cachedAt = now() }
    connection.metadataEpoch = result.metadataEpoch
    guidanceConnection = connection
  }

  private static func bootstrap(
    session: CodexRPCSession, requestID: UUID, snapshot: BootstrapSnapshot, rpcBase: Int,
    needsCatalog: Bool, timing: CodexTimingReporter,
    iterator: inout AsyncThrowingStream<JSONValue, any Error>.Iterator
  ) async throws -> BootstrapResult {
    func requireLease() throws {
      try Task.checkCancellation()
      guard session.ownsRequest(requestID) else { throw CancellationError() }
    }
    try requireLease()
    if !snapshot.initialized {
      try session.send(method: "initialize", id: rpcBase + 1, params: Self.clientInfo)
      _ = try await Self.response(id: rpcBase + 1, iterator: &iterator, session: session)
      try requireLease()
      try session.send(method: "initialized", params: .object([:]))
      await timing.mark(.initialized)
      try requireLease()
    }
    if let cachedModels = snapshot.cachedModels, let epoch = snapshot.metadataEpoch {
      guard epoch == session.metadataEpoch else {
        throw ProviderError.message("The managed Codex account changed during discovery.")
      }
      await timing.mark(.metadataCacheHit)
      try requireLease()
      guard epoch == session.metadataEpoch else {
        throw ProviderError.message("The managed Codex account changed during discovery.")
      }
      return .init(models: cachedModels, metadataEpoch: epoch)
    }
    try session.send(
      method: "account/read", id: rpcBase + 2,
      params: .object(["refreshToken": .bool(false)]))
    let account = try await Self.response(id: rpcBase + 2, iterator: &iterator, session: session)
    try requireLease()
    guard account["account"]?["type"]?.string == "chatgpt" else {
      throw ProviderError.message(
        "Sign in to the Codex CLI with ChatGPT before using subscription mode.")
    }
    let accountEpoch = session.metadataEpoch
    await timing.mark(.accountVerified)
    try requireLease()
    let models: [CodexRoutingModel]
    if needsCatalog {
      let catalog = try await Self.modelCatalog(
        session: session,
        firstRequestID: rpcBase + 10, iterator: &iterator)
      models = Self.routingModels(catalog)
    } else {
      models = []
    }
    try requireLease()
    guard accountEpoch == session.metadataEpoch else {
      throw ProviderError.message("The managed Codex account changed during discovery.")
    }
    return .init(models: models, metadataEpoch: accountEpoch)
  }

  private static func hardenedConfiguration(_ result: JSONValue, bounded: Bool) throws -> JSONValue
  {
    let layers = result["layers"]?.array ?? []
    if bounded, result["layers"]?.array == nil || layers.count > 32 {
      throw ProviderError.message("Codex returned an invalid guidance configuration snapshot.")
    }
    var servers: [String: JSONValue] = [:]
    var plugins: [String: JSONValue] = [:]
    var keyBytes = 0
    for layer in layers {
      if bounded, layer["config"]?.object == nil {
        throw ProviderError.message("Codex returned an invalid guidance configuration layer.")
      }
      for table in ["mcp_servers", "plugins"] {
        let raw = layer["config"]?[table]
        if bounded, raw != nil, raw?.object == nil {
          throw ProviderError.message("Codex returned an invalid guidance capability table.")
        }
        for name in raw?.object?.keys ?? [String: JSONValue]().keys {
          keyBytes += name.utf8.count
          if bounded, name.isEmpty || name.utf8.count > 256 || keyBytes > 131_072 {
            throw ProviderError.message("Codex guidance configuration exceeded its bounded cache.")
          }
          if table == "mcp_servers" {
            servers[name] = .object(["enabled": .bool(false)])
          } else {
            plugins[name] = .object(["enabled": .bool(false)])
          }
          if bounded, servers.count + plugins.count > 512 {
            throw ProviderError.message(
              "Codex guidance configuration exceeded its capability limit.")
          }
        }
      }
    }
    return .object([
      "mcp_servers": .object(servers), "plugins": .object(plugins),
      "web_search": .string("disabled"),
      "features": .object([
        "shell_tool": .bool(false), "apply_patch_freeform": .bool(false),
        "unified_exec": .bool(false), "multi_agent": .bool(false), "apps": .bool(false),
        "hooks": .bool(false),
      ]),
      "apps": .object(["_default": .object(["enabled": .bool(false)])]),
    ])
  }

  private static let clientInfo: JSONValue = .object([
    "clientInfo": .object([
      "name": .string("opencompanion"), "title": .string("OpenCompanion"),
      "version": .string("0.1.0"),
    ]),
    "capabilities": .object(["experimentalApi": .bool(true)]),
  ])

  /// Discover the complete bounded visible catalog before making a selection.
  /// Never silently choose from a truncated page or an unfinished cursor chain.
  /// Cursor contents are opaque and are not included in errors or diagnostics.
  private static func modelCatalog(
    session: CodexRPCSession, firstRequestID: Int,
    iterator: inout AsyncThrowingStream<JSONValue, any Error>.Iterator
  ) async throws -> [JSONValue] {
    var catalog: [JSONValue] = []
    var cursor: String?
    var seenCursors = Set<Data>()
    for page in 0..<4 {
      try Task.checkCancellation()
      var params: [String: JSONValue] = [
        "includeHidden": .bool(false), "limit": .number(100),
      ]
      if let cursor { params["cursor"] = .string(cursor) }
      let requestID = firstRequestID + page
      try session.send(method: "model/list", id: requestID, params: .object(params))
      let result = try await response(id: requestID, iterator: &iterator, session: session)
      try Task.checkCancellation()
      guard let entries = result["data"]?.array, entries.count <= 100,
        entries.count <= 400 - catalog.count
      else {
        throw ProviderError.message("Codex returned a malformed or oversized model catalog page.")
      }
      catalog.append(contentsOf: entries)
      let next: String
      switch result["nextCursor"] {
      // Older app-server responses omit this nullable terminal field.
      case nil, .null: return catalog
      case .string(let value):
        guard !value.isEmpty, value.utf8.prefix(4_097).count <= 4_096,
          seenCursors.insert(Data(value.utf8)).inserted
        else {
          throw ProviderError.message("Codex returned an invalid or repeated model catalog cursor.")
        }
        next = value
      default:
        throw ProviderError.message("Codex returned a malformed model catalog cursor.")
      }
      guard page < 3 else {
        throw ProviderError.message(
          "Codex model discovery exceeded four pages or 400 entries. No partial catalog was selected."
        )
      }
      cursor = next
    }
    throw ProviderError.message("Codex model discovery ended without a complete catalog.")
  }

  private static func routingModels(_ entries: [JSONValue]) -> [CodexRoutingModel] {
    entries.prefix(400).compactMap { entry in
      guard entry["hidden"]?.boolean != true,
        let model = entry["model"]?.string ?? entry["id"]?.string,
        !model.isEmpty, model.utf8.prefix(201).count <= 200
      else { return nil }
      let modalities = entry["inputModalities"]
      // Official older catalogs omit this field; that legacy contract supports
      // text and image. An explicitly present non-image capability is excluded.
      let supportsImages =
        modalities == nil || (modalities?.array ?? []).prefix(8).contains { $0.string == "image" }
      let supported = Set(
        (entry["supportedReasoningEfforts"]?.array ?? []).prefix(32).compactMap {
          $0["reasoningEffort"]?.string
        }.filter { ["low", "minimal", "none"].contains($0) })
      return CodexRoutingModel(
        model: model, alias: entry["id"]?.string, isDefault: entry["isDefault"]?.boolean == true,
        supportsImages: supportsImages, supportedEfforts: supported)
    }
  }
  private static func response(
    id: Int, iterator: inout AsyncThrowingStream<JSONValue, any Error>.Iterator,
    session: CodexRPCSession? = nil
  ) async throws -> JSONValue {
    while let message = try await iterator.next() {
      try Task.checkCancellation()
      if message["method"] != nil, message["id"] != nil, let session {
        try session.rejectToolRequest(message)
        throw ProviderError.message("Codex requested an external capability during setup.")
      }
      guard message["id"]?.integer == id else { continue }
      if let error = message["error"] {
        throw ProviderError.message(
          "Codex app-server: \(error["message"]?.string ?? "request failed")")
      }
      guard let result = message["result"] else {
        throw ProviderError.message("Codex returned an empty RPC response.")
      }
      return result
    }
    throw ProviderError.message("Codex app-server disconnected before initialization finished.")
  }
}

private actor CodexSmokeReceiver {
  var value = ""
  func accept(_ text: String) { value += text }
}

/// Process and pipe access is synchronized. Exactly one request owns the
/// bounded stream at a time; fresh threads and RPC IDs isolate sequential turns.
private final class CodexRPCSession: @unchecked Sendable {
  let messages: AsyncThrowingStream<JSONValue, any Error>
  let workingDirectory: URL
  private let process: Process
  private let input: FileHandle
  private let continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
  private let lock = NSLock()
  private var closed = false
  private var readerEnded = false
  private var currentMetadataEpoch: UInt64 = 0
  private var activeRequestID: UUID?
  private var activeThreadID: String?
  private var activeTurnID: String?
  private var watchdog: Task<Void, Never>?

  var isHealthy: Bool { lock.withLock { !closed && !readerEnded && process.isRunning } }
  var isOpen: Bool { lock.withLock { !closed } }
  var metadataEpoch: UInt64 { lock.withLock { currentMetadataEpoch } }

  init(executable: String) throws {
    guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
      throw ProviderError.message("Choose the absolute path to an installed Codex CLI executable.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OpenCompanion-Codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    workingDirectory = directory
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = [
      "app-server", "--listen", "stdio://", "-c", "mcp_servers={}", "-c",
      "features.shell_tool=false", "-c", "features.apps=false", "-c", "web_search=\"disabled\"",
    ]
    child.currentDirectoryURL = directory
    let pipeWriter = stdin.fileHandleForWriting
    // A peer can close stdin while keeping stdout/process alive. Suppress
    // SIGPIPE on this descriptor only, so FileHandle.write throws EPIPE into
    // the existing request cleanup instead of terminating the application.
    guard Darwin.fcntl(pipeWriter.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      try? pipeWriter.close()
      try? stdin.fileHandleForReading.close()
      try? stdout.fileHandleForReading.close()
      try? stdout.fileHandleForWriting.close()
      try? FileManager.default.removeItem(at: directory)
      throw ProviderError.message("Could not safely configure the Codex request pipe.")
    }
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    process = child
    input = pipeWriter
    var streamContinuation: AsyncThrowingStream<JSONValue, any Error>.Continuation!
    messages = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) {
      streamContinuation = $0
    }
    continuation = streamContinuation
    do { try child.run() } catch {
      try? FileManager.default.removeItem(at: directory)
      throw ProviderError.message("Could not launch Codex CLI: \(error.localizedDescription)")
    }
    let output = stdout.fileHandleForReading
    let ownedContinuation = continuation
    Task.detached(priority: .utility) { [weak self] in
      var framer = JSONLineFramer(maximumFrameBytes: 2_097_152)
      do {
        while true {
          let data = output.availableData
          if data.isEmpty { break }
          for frame in try framer.append(data) {
            let message = try JSONDecoder().decode(JSONValue.self, from: frame)
            self?.observeMetadata(message)
            if case .dropped = ownedContinuation.yield(message) {
              throw ProviderError.message("Codex event queue exceeded its bounded capacity.")
            }
          }
        }
        _ = try framer.finish()
        self?.markReaderEnded()
        ownedContinuation.finish()
      } catch {
        self?.markReaderEnded()
        ownedContinuation.finish(throwing: error)
      }
      try? output.close()
    }
  }

  func ownsRequest(_ id: UUID) -> Bool {
    lock.withLock { !closed && activeRequestID == id }
  }

  func beginRequest(id: UUID) throws {
    try lock.withLock {
      guard !closed, !readerEnded, activeRequestID == nil else { throw CancellationError() }
      activeRequestID = id
      watchdog = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(150)) } catch { return }
        self?.close(
          requestID: id,
          error: ProviderError.message("Codex request timed out after 150 seconds."))
      }
    }
  }

  func endRequest(id: UUID) {
    lock.withLock {
      guard activeRequestID == id else { return }
      watchdog?.cancel()
      watchdog = nil
      activeRequestID = nil
      activeThreadID = nil
      activeTurnID = nil
    }
  }

  private func observeMetadata(_ message: JSONValue) {
    guard message["method"]?.string == "account/updated" else { return }
    lock.withLock {
      if currentMetadataEpoch < UInt64.max { currentMetadataEpoch += 1 }
    }
  }

  private func markReaderEnded() { lock.withLock { readerEnded = true } }

  func setTurn(threadID: String, turnID: String) {
    lock.withLock {
      activeThreadID = threadID
      activeTurnID = turnID
    }
  }

  func send(method: String, id: Int? = nil, params: JSONValue) throws {
    var object: [String: JSONValue] = ["method": .string(method), "params": params]
    if let id { object["id"] = .number(Double(id)) }
    try write(.object(object))
  }

  func rejectToolRequest(_ message: JSONValue) throws {
    guard let id = message["id"] else { return }
    try write(
      .object([
        "id": id,
        "error": .object([
          "code": .number(-32601),
          "message": .string("External capabilities are disabled in OpenCompanion teaching mode."),
        ]),
      ]))
  }

  private func write(_ message: JSONValue) throws {
    var data = try JSONEncoder().encode(message)
    data.append(10)
    try lock.withLock {
      guard !closed else { throw CancellationError() }
      try input.write(contentsOf: data)
    }
  }

  func close(requestID: UUID? = nil, error: (any Error)? = nil) {
    lock.withLock {
      guard !closed, requestID == nil || activeRequestID == requestID else { return }
      closed = true
      if let threadID = activeThreadID, let turnID = activeTurnID,
        let data = try? JSONEncoder().encode(
          JSONValue.object([
            "id": .number(-1), "method": .string("turn/interrupt"),
            "params": .object(["threadId": .string(threadID), "turnId": .string(turnID)]),
          ]))
      {
        try? input.write(contentsOf: data + Data([10]))
      }
      activeRequestID = nil
      activeThreadID = nil
      activeTurnID = nil
      try? input.close()
      if process.isRunning { process.terminate() }
      watchdog?.cancel()
      watchdog = nil
      continuation.finish(throwing: error ?? CancellationError())
      try? FileManager.default.removeItem(at: workingDirectory)
    }
  }
  deinit { close() }
}

extension JSONValue {
  fileprivate subscript(_ key: String) -> JSONValue? {
    if case .object(let object) = self { object[key] } else { nil }
  }
  fileprivate var string: String? { if case .string(let value) = self { value } else { nil } }
  fileprivate var integer: Int? {
    if case .number(let value) = self, value.isFinite, value >= Double(Int.min),
      value < Double(Int.max), value.rounded() == value
    {
      Int(value)
    } else {
      nil
    }
  }
  fileprivate var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  fileprivate var object: [String: JSONValue]? {
    if case .object(let value) = self { value } else { nil }
  }
  fileprivate var boolean: Bool? { if case .bool(let value) = self { value } else { nil } }
}
