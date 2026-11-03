import CompanionCore
import Foundation

/// Runs only on explicit command-line request. It consumes the signed-in Codex plan like any turn.
enum CodexIntegrationSmoke {
  static func run(
    executable: String, model: String = "", onProgress: @escaping @Sendable (String) async -> Void
  ) async throws {
    let provider = CodexProvider()
    let account = try await provider.inspect(executable: executable)
    guard account.authType == "chatgpt" else {
      throw ProviderError.message("Smoke test requires managed ChatGPT sign-in in Codex CLI.")
    }
    await onProgress("account/read: managed ChatGPT sign-in; catalog count \(account.models.count)")
    let motorReceiver = LiveSceneReceiver()
    try await provider.stream(
      executable: executable, model: model,
      messages: [
        .init(
          role: "user",
          text:
            "Create a compact diagram explaining a simplified brushed DC motor. Show labeled N/S magnetic poles, a current-carrying coil, and force arrows relating the forces to rotation. Use 6 to 12 nodes and a short explanation. Emit NDJSON only."
        )
      ],
      context: "", image: nil, scene: nil
    ) { try await motorReceiver.accept($0) }
    let motor = try await motorReceiver.document()
    try requireUseful(motor)
    await onProgress("completed motor turn: \(motor.nodes.count) validated retained nodes")
    let unrelatedReceiver = LiveSceneReceiver()
    try await provider.stream(
      executable: executable, model: model,
      messages: [
        .init(
          role: "user",
          text:
            "Explain photosynthesis with a compact labeled diagram: light, water, and carbon dioxide lead to sugar and oxygen in a leaf. Use 6 to 12 nodes and causal arrows, plus one short explanatory paragraph. Emit NDJSON only."
        )
      ],
      context: "", image: nil, scene: nil
    ) { try await unrelatedReceiver.accept($0) }
    let unrelated = try await unrelatedReceiver.document()
    try requireUseful(unrelated)
    guard unrelated.nodes != motor.nodes else {
      throw ProviderError.message("Unrelated lesson repeated the previous scene.")
    }
    await onProgress(
      "completed photosynthesis turn: \(unrelated.nodes.count) validated retained nodes")
    guard let target = motor.nodes.first(where: { $0.kind != .text && $0.kind != .group }) else {
      throw ProviderError.message("Motor lesson has no editable visible shape.")
    }
    let editReceiver = LiveSceneReceiver(initial: motor)
    try await provider.stream(
      executable: executable, model: model,
      messages: [
        .init(
          role: "user",
          text:
            "Edit only existing node \(target.id). Set its color to #7E57C2. Keep its other fields exactly unchanged. Output one scene unit containing only that updated node. Do not remove or recreate any other nodes. Preserve the current document."
        )
      ],
      context: "", image: nil, scene: motor
    ) { try await editReceiver.accept($0) }
    let edited = try await editReceiver.document()
    guard edited.nodes.count == motor.nodes.count,
      Set(edited.nodes.map(\.id)) == Set(motor.nodes.map(\.id)),
      edited.nodes.first(where: { $0.id == target.id })?.color.uppercased() == "#7E57C2",
      edited.nodes.filter({ $0.id != target.id }) == motor.nodes.filter({ $0.id != target.id })
    else { throw ProviderError.message("Stable-ID follow-up changed unrelated retained content.") }
    await onProgress(
      "completed follow-up turn: stable node IDs and unrelated content preserved; requested color accepted"
    )
  }
  private static func requireUseful(_ scene: SceneDocument) throws {
    guard scene.nodes.count >= 4,
      scene.nodes.filter({ $0.kind == .text && !$0.text.isEmpty }).count >= 2,
      scene.nodes.contains(where: { $0.kind == .arrow || $0.kind == .line || $0.kind == .path })
    else {
      let labels = scene.nodes.filter { $0.kind == .text && !$0.text.isEmpty }.count
      let connectors = scene.nodes.filter {
        $0.kind == .arrow || $0.kind == .line || $0.kind == .path
      }.count
      throw ProviderError.message(
        "Completed turn did not provide a substantive labeled diagram (nodes=\(scene.nodes.count), visible labels=\(labels), connectors=\(connectors))."
      )
    }
  }
}

private actor LiveSceneReceiver {
  private var scene: SceneDocument
  private var sawScene = false
  init(initial: SceneDocument = SceneDocument(id: "codex-live-smoke", width: 900, height: 560)) {
    scene = initial
  }
  func accept(_ unit: ProviderUnit) throws {
    guard unit.type == "scene" else { return }
    scene = try ProviderSceneBoundary.applying(unit, to: scene, baseRevision: scene.revision)
    sawScene = true
  }
  func document() throws -> SceneDocument {
    guard sawScene else { throw ProviderError.message("Live model turn returned no scene unit.") }
    return scene
  }
}
