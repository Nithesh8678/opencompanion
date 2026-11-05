import CompanionCore
import Foundation
import simd

/// Opt-in public-prompt transport/admission check. It neither captures the
/// desktop nor initializes an AppModel, modifies a library or records audio.
enum SpatialSceneLiveAcceptance {
  private struct Case {
    let id: String
    let prompt: String
    let minimumMeshes: Int
    let minimumLabels: Int
    let concepts: [String]
  }

  @MainActor static func run(output: URL, executable: String, model: String) async throws {
    try Task.checkCancellation()
    let outputMode = try SpatialSceneOutputSelection.select(
      arguments: ProcessInfo.processInfo.arguments)
    let cases = [
      Case(
        id: "brushed-dc-motor",
        prompt:
          "Create a small interactive 3D cutaway lesson explaining a simplified brushed DC motor. Show its curved housing, fixed magnets, copper coil, rotor, output shaft and commutator, with useful labels attached to the actual parts. Build the explanation progressively and distinguish illustrative rotation from a physical simulation.",
        minimumMeshes: 6, minimumLabels: 4,
        concepts: ["magnet", "coil", "shaft", "commutator"]),
      Case(
        id: "water-molecule",
        prompt:
          "Create a small interactive 3D ball-and-stick explanation of a water molecule. Show one oxygen atom, two hydrogen atoms and the two bonds in a bent arrangement, with short labels attached to the atoms. Explain that the sizes and bond lengths are illustrative. Build it progressively.",
        minimumMeshes: 5, minimumLabels: 3, concepts: ["oxygen", "hydrogen"]),
      Case(
        id: "simple-pendulum",
        prompt:
          "Create a small static 3D lesson explaining a simple pendulum in an illustrative rest pose. Show a rectangular fixed support, a solid round bob and a slender solid rod connecting the support to the bob. Attach short Support, Rod and Bob labels to the actual parts. Build the lesson progressively. Keep the geometry static and explain that the dimensions and rest pose are illustrative, not a physical simulation or a measured dynamics result.",
        minimumMeshes: 3, minimumLabels: 3, concepts: ["support", "rod", "bob"]),
    ]
    let selectedIDs = try SpatialSceneCaseSelection.select(
      arguments: ProcessInfo.processInfo.arguments, knownIDs: cases.map(\.id))
    let selectedCases = cases.filter { selectedIDs.contains($0.id) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var results: [[String: Any]] = []
    for fixture in selectedCases {
      try Task.checkCancellation()
      let directory = output.appendingPathComponent(fixture.id, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let policy = ResponsePolicy.resolve(text: fixture.prompt, screenGuidanceEnabled: true)
      guard policy.allowsNotebook, !policy.includesExistingNotebook,
        policy.route != .screenGuidance
      else {
        throw ProviderError.message("The public 3D request did not acquire new-scene capability.")
      }
      let started = ProcessInfo.processInfo.systemUptime
      let collector = SpatialSceneAcceptanceCollector(started: started)
      var failure: String?
      do {
        try await CodexProvider().stream(
          executable: executable, model: model,
          messages: [.init(role: "user", text: fixture.prompt)], context: "", image: nil,
          scene: nil, onRouting: { await collector.route($0) },
          onTiming: { await collector.timing($0) },
          onStructuredProgress: { await collector.structuredProgress($0) },
          onUnit: { try await collector.receive($0) }, responsePolicy: policy,
          outputMode: outputMode,
          onRejectedLine: { await collector.recordRejectedLine($0) })
      } catch {
        failure = error.localizedDescription
      }
      let providerFinishedMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
      let snapshot = await collector.snapshot()
      let document = snapshot.document
      let meshes = document.nodes.filter { $0.kind == .mesh && $0.spatial3D?.geometry != nil }
      let labels = document.nodes.filter { $0.kind == .text && $0.spatial3D?.labelAnchor != nil }
      let geometryTypes = Set(meshes.compactMap { $0.spatial3D?.geometry }.map(geometryName))
      let labelText = labels.map(\.text).joined(separator: " ").lowercased()
      let concepts = fixture.concepts.filter { labelText.contains($0) }
      let schemaPassed = (try? document.validated()) != nil
      var unmet: [String] = []
      if !schemaPassed { unmet.append("schema-validation") }
      if snapshot.progressiveGeometryUnits < 2 { unmet.append("progressive-geometry") }
      if snapshot.textUnits == 0 { unmet.append("narration") }
      if meshes.count < fixture.minimumMeshes { unmet.append("typed-mesh-count") }
      if labels.count < fixture.minimumLabels { unmet.append("anchored-label-count") }
      if geometryTypes.count < 2 { unmet.append("geometry-variety") }
      if concepts.count != fixture.concepts.count { unmet.append("requested-label-concepts") }
      let geometryUnmet = SpatialSceneContentOracle.unmetChecks(
        caseID: fixture.id, document: document)
      unmet.append(contentsOf: geometryUnmet)
      let passed = failure == nil && unmet.isEmpty
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(document).write(to: directory.appendingPathComponent("public-scene.json"))
      // This helper supplies only its fixed public prompts, without screen,
      // history or selected evidence. Normal application requests never opt in.
      if let rejectedLine = snapshot.rejectedLine {
        try rejectedLine.write(
          to: directory.appendingPathComponent("public-rejected-unit.txt"), options: .atomic)
      }
      var result: [String: Any] = [
        "id": fixture.id, "result": passed ? "passed" : "failed",
        "failure": failure ?? "", "unmetChecks": unmet, "publicPromptOnly": true,
        "outputMode": outputMode.rawValue,
        "model": snapshot.routing?.model ?? "unreported",
        "effort": snapshot.routing?.effort ?? "provider-default",
        "routingReason": snapshot.routing?.reason.rawValue ?? "unreported",
        "sceneUnits": snapshot.sceneUnits, "textUnits": snapshot.textUnits,
        "connectorUnits": snapshot.connectorUnits,
        "compiledConnectorCount": snapshot.compiledConnectorCount,
        "rejectedPublicUnitRecorded": snapshot.rejectedLine != nil,
        "rejectedPublicUnitUTF8Bytes": snapshot.rejectedLine?.count ?? 0,
        "narrationPreview": snapshot.narrationPreview,
        "narrationPreviewUTF8Bytes": snapshot.narrationPreviewUTF8Bytes,
        "narrationPreviewTruncated": snapshot.narrationPreviewTruncated,
        "lastRejectedScene": NSNull(),
        "structuredStageProgress": NSNull(),
        "progressiveGeometryUnits": snapshot.progressiveGeometryUnits,
        "typedMeshCount": meshes.count, "anchoredLabelCount": labels.count,
        "geometryTypes": geometryTypes.sorted(), "matchedLabelConcepts": concepts,
        "schemaValidationPassed": schemaPassed,
        "illustrativeGeometryChecksPassed": geometryUnmet.isEmpty,
        "firstSceneUnitMS": snapshot.firstSceneMS ?? -1,
        "firstTypedGeometryMS": snapshot.firstTypedMS ?? -1,
        "providerFinishedMS": providerFinishedMS, "providerCompletedSuccessfully": failure == nil,
        "providerTimingEvents": snapshot.timings.map {
          ["stage": $0.stage.rawValue, "elapsedMS": $0.elapsedMS] as [String: Any]
        },
        "desktopCaptured": false, "microphoneUsed": false,
        "nativeRenderVerified": false, "acousticTimingVerified": false,
        "physicalAccuracyVerified": false,
      ]
      if let rejection = snapshot.lastRejectedScene {
        result["lastRejectedScene"] = try JSONSerialization.jsonObject(
          with: encoder.encode(rejection))
      }
      if let progress = snapshot.structuredStageProgress {
        result["structuredStageProgress"] = try JSONSerialization.jsonObject(
          with: encoder.encode(progress))
      }
      results.append(result)
      try write(result, to: directory.appendingPathComponent("result.json"))
      try FileHandle.standardOutput.write(
        contentsOf: Data("SPATIAL_SCENE_CASE \(fixture.id) \(passed ? "passed" : "failed")\n".utf8))
    }
    let passed = results.allSatisfy { $0["result"] as? String == "passed" }
    try write(
      [
        "result": passed ? "passed" : "failed", "cases": results,
        "outputMode": outputMode.rawValue,
        "selectedCases": selectedIDs,
        "scope":
          "Real provider units and strict native semantic admission; no rendering, capture, audio or physical-task proof.",
      ], to: output.appendingPathComponent("spatial-scene-live-acceptance.json"))
    guard passed else {
      throw ProviderError.message("One or more public typed-3D provider/admission cases failed.")
    }
  }

  private static func geometryName(_ geometry: Geometry3D) -> String {
    switch geometry {
    case .box: "box"
    case .sphere: "sphere"
    case .cylinder: "cylinder"
    case .torus: "torus"
    case .tube: "tube"
    }
  }

  private static func write(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      .write(to: url, options: .atomic)
  }
}

/// Selection applies only to the explicit public acceptance helper. Invalid
/// arguments cannot start a provider turn or change normal app preferences.
enum SpatialSceneOutputSelection {
  static func select(arguments: [String]) throws -> CodexOutputMode {
    let originalFlag = "--structured-scene-output"
    let unifiedFlag = "--structured-unified-output"
    let stepsFlag = "--structured-spatial-steps"
    let formatFlags = [originalFlag, unifiedFlag, stepsFlag]
    guard
      !arguments.contains(where: {
        argument in formatFlags.contains { argument.hasPrefix($0 + "=") }
      })
    else {
      throw ProviderError.message("Structured output flags do not accept a value.")
    }
    for index in arguments.indices where formatFlags.contains(arguments[index]) {
      guard index + 1 == arguments.count || arguments[index + 1].hasPrefix("--") else {
        throw ProviderError.message("Structured output flags do not accept a value.")
      }
    }
    let selected = arguments.filter { formatFlags.contains($0) }
    guard selected.count <= 1 else {
      throw ProviderError.message("Specify one structured output format at most once.")
    }
    switch selected.first {
    case originalFlag: return .structuredScene
    case unifiedFlag: return .structuredUnifiedScene
    case stepsFlag: return .structuredSpatialSteps
    default: return .ndjson
    }
  }
}

enum SpatialSceneCaseSelection {
  static func select(arguments: [String], knownIDs: [String]) throws -> [String] {
    guard !arguments.contains(where: { $0.hasPrefix("--spatial-scene-case=") }) else {
      throw ProviderError.message("Use --spatial-scene-case followed by one known case ID.")
    }
    let flags = arguments.indices.filter { arguments[$0] == "--spatial-scene-case" }
    guard flags.count <= 1 else {
      throw ProviderError.message("Specify --spatial-scene-case at most once.")
    }
    guard let index = flags.first else { return knownIDs }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
      throw ProviderError.message("--spatial-scene-case requires a known case ID.")
    }
    let id = arguments[index + 1]
    guard knownIDs.contains(id) else {
      throw ProviderError.message(
        "Unknown spatial scene acceptance case; use a documented case ID.")
    }
    return [id]
  }
}

/// Fixture-specific visual-content checks, never runtime shape inference or a physics oracle.
/// Semantic roles come from anchored labels; IDs are a fallback, not a renderer convention.
enum SpatialSceneContentOracle {
  static func unmetChecks(caseID: String, document: SceneDocument) -> [String] {
    guard (try? document.validated()) != nil,
      let poses = try? document.spatialWorldPoses(at: 0)
    else { return ["content-schema"] }
    switch caseID {
    case "water-molecule": return water(document: document, poses: poses)
    case "brushed-dc-motor": return motor(document: document, poses: poses)
    case "simple-pendulum": return pendulum(document: document, poses: poses)
    default: return ["unknown-content-fixture"]
    }
  }

  private static func pendulum(document: SceneDocument, poses: [ScenePose3D]) -> [String] {
    guard document.animations.isEmpty else { return ["pendulum-static"] }
    let support = parts(
      words: ["support"], document: document, poses: poses,
      matching: {
        if case .box = $0 { return true }
        return false
      })
    let rod = parts(
      words: ["rod"], document: document, poses: poses,
      matching: {
        if case .cylinder = $0 { return true }
        return false
      })
    let bob = parts(words: ["bob"], document: document, poses: poses, matching: isSphere)
    guard support.count == 1, rod.count == 1, bob.count == 1,
      Set([support[0].node.id, rod[0].node.id, bob[0].node.id]).count == 3
    else { return ["pendulum-part-roles"] }
    guard [support[0], rod[0], bob[0]].allSatisfy(pendulumMaterialIsVisible) else {
      return ["pendulum-visible-parts"]
    }
    guard let segment = cylinderSegment(rod[0]) else { return ["pendulum-rod-connects-parts"] }
    let connected =
      (pendulumSupport(support[0], contains: segment.0)
        && pendulumBob(bob[0], contains: segment.1))
      || (pendulumSupport(support[0], contains: segment.1)
        && pendulumBob(bob[0], contains: segment.0))
    return connected ? [] : ["pendulum-rod-connects-parts"]
  }

  private static func pendulumMaterialIsVisible(_ pose: ScenePose3D) -> Bool {
    guard pose.effectiveOpacity > 0 else { return false }
    let material = pose.node.fill == "transparent" ? pose.node.color : pose.node.fill
    if material == "transparent" { return false }
    if material.count == 9 { return (UInt8(material.suffix(2), radix: 16) ?? 0) > 0 }
    return true
  }

  private static func pendulumSupport(_ pose: ScenePose3D, contains endpoint: SIMD3<Double>) -> Bool
  {
    guard case .box(let width, let height, let depth, let chamfer)? = pose.node.spatial3D?.geometry,
      let inverse = inverseLinear(pose)
    else { return false }
    let local = inverse * (endpoint - point(.zero, in: pose))
    guard finite(local) != nil else { return false }
    let tolerance = max(width, height, depth) * 0.000_001
    let core = SIMD3<Double>(
      max(0, width / 2 - chamfer), max(0, height / 2 - chamfer), max(0, depth / 2 - chamfer))
    let offset = SIMD3<Double>(
      max(0, abs(local.x) - core.x), max(0, abs(local.y) - core.y),
      max(0, abs(local.z) - core.z))
    return simd_length(offset) <= chamfer + tolerance
  }

  private static func pendulumBob(_ pose: ScenePose3D, contains endpoint: SIMD3<Double>) -> Bool {
    guard case .sphere(let radius, _)? = pose.node.spatial3D?.geometry,
      let inverse = inverseLinear(pose)
    else { return false }
    let local = inverse * (endpoint - point(.zero, in: pose))
    return finite(local) != nil && simd_length(local) <= radius * 1.000_001
  }

  private static func water(document: SceneDocument, poses: [ScenePose3D]) -> [String] {
    let oxygen = parts(words: ["oxygen"], document: document, poses: poses, matching: isSphere)
    let hydrogen = parts(words: ["hydrogen"], document: document, poses: poses, matching: isSphere)
    guard oxygen.count == 1, hydrogen.count == 2 else { return ["water-atom-roles"] }
    let oxygenAtom = oxygen[0]
    let bonds = poses.filter {
      guard $0.effectiveOpacity > 0, case .cylinder? = $0.node.spatial3D?.geometry else {
        return false
      }
      return true
    }
    let connections = hydrogen.map { atom in
      bonds.filter { bond in
        guard let segment = cylinderSegment(bond) else { return false }
        return intersects(atom: oxygenAtom, segment: segment)
          && intersects(atom: atom, segment: segment)
          && ((contains(atom: oxygenAtom, endpoint: segment.0)
            && contains(atom: atom, endpoint: segment.1))
            || (contains(atom: oxygenAtom, endpoint: segment.1)
              && contains(atom: atom, endpoint: segment.0)))
      }.map(\.node.id)
    }
    var unmet: [String] = []
    if connections[0].isEmpty || connections[1].isEmpty
      || !connections[0].contains(where: { first in connections[1].contains { $0 != first } })
    {
      unmet.append("water-bonds-connect-atoms")
    }
    let center = point(.zero, in: oxygenAtom)
    let a = point(.zero, in: hydrogen[0]) - center
    let b = point(.zero, in: hydrogen[1]) - center
    guard let directionA = normalized(a), let directionB = normalized(b) else {
      return unmet + ["water-bent-arrangement"]
    }
    let angleCosine = simd_dot(directionA, directionB)
    // Broad illustrative geometry only; this does not assert a measured molecular bond angle.
    if angleCosine <= cos(150 * Double.pi / 180)
      || angleCosine >= cos(35 * Double.pi / 180)
    {
      unmet.append("water-bent-arrangement")
    }
    return unmet
  }

  private static func motor(document: SceneDocument, poses: [ScenePose3D]) -> [String] {
    let housing = parts(
      words: ["housing", "casing", "shell", "case"], document: document, poses: poses,
      matching: {
        if case .tube = $0 { return true }
        return false
      })
    let rotor = parts(
      words: ["rotor", "armature"], document: document, poses: poses, matching: isAxial)
    let shaft = parts(
      words: ["shaft", "axle"], document: document, poses: poses, matching: isAxial)
    let commutator = parts(
      words: ["commutator"], document: document, poses: poses, matching: isAxial)
    guard housing.count == 1, rotor.count == 1, shaft.count == 1, commutator.count == 1,
      Set([housing[0].node.id, rotor[0].node.id, shaft[0].node.id, commutator[0].node.id]).count
        == 4,
      let axis = normalized(direction(.init(x: 0, y: 1, z: 0), in: housing[0])),
      case .tube(let innerRadius, _, _, _, let start, let sweep)? = housing[0].node.spatial3D?
        .geometry
    else { return ["motor-axial-part-roles"] }
    var unmet: [String] = []
    let center = point(.zero, in: housing[0])
    let radialScale = min(
      simd_length(direction(.init(x: 1, y: 0, z: 0), in: housing[0])),
      simd_length(direction(.init(x: 0, y: 0, z: 1), in: housing[0])))
    let centerTolerance = innerRadius * radialScale * 0.25
    for part in [rotor[0], shaft[0], commutator[0]] {
      guard let partAxis = normalized(direction(.init(x: 0, y: 1, z: 0), in: part)) else {
        unmet.append("motor-coaxial-axes")
        continue
      }
      let offset = point(.zero, in: part) - center
      if abs(simd_dot(axis, partAxis)) < cos(10 * Double.pi / 180)
        || simd_length(offset - axis * simd_dot(offset, axis)) > centerTolerance
      {
        unmet.append("motor-coaxial-axes")
      }
    }
    // Parallel but remotely separated parts are not an assembled mechanism.
    for (a, b) in [(housing[0], rotor[0]), (rotor[0], shaft[0]), (shaft[0], commutator[0])] {
      guard let first = axialInterval(a, origin: center, axis: axis),
        let second = axialInterval(b, origin: center, axis: axis)
      else {
        unmet.append("motor-assembled-axial-extents")
        continue
      }
      let separation = max(first.0 - second.1, second.0 - first.1)
      let tolerance = min(first.1 - first.0, second.1 - second.0) * 0.08
      if separation > tolerance { unmet.append("motor-assembled-axial-extents") }
    }
    let gap = 360 - sweep
    let camera = SIMD3<Double>(0.55, 0.3, 1)
    if gap < 45 || sweep < 120
      || !openingFacesCamera(
        housing[0], camera: camera, start: start, sweep: sweep)
    {
      unmet.append("motor-camera-facing-cutaway")
    }
    return Array(Set(unmet)).sorted()
  }

  private static func openingFacesCamera(
    _ housing: ScenePose3D, camera: SIMD3<Double>, start: Double, sweep: Double
  ) -> Bool {
    guard let inverse = inverseLinear(housing), let local = finite(inverse * camera),
      hypot(local.x, local.z) > 1e-9
    else { return false }
    let angle = atan2(local.z, local.x) * 180 / .pi
    let gap = 360 - sweep
    let positionInGap = positiveDegrees(angle - start - sweep)
    let margin = min(10, gap * 0.15)
    return positionInGap >= margin && positionInGap <= gap - margin
  }

  private static func axialInterval(
    _ pose: ScenePose3D, origin: SIMD3<Double>, axis: SIMD3<Double>
  ) -> (Double, Double)? {
    guard let geometry = pose.node.spatial3D?.geometry else { return nil }
    let halfHeight: Double
    switch geometry {
    case .cylinder(_, let height, _), .tube(_, _, let height, _, _, _): halfHeight = height / 2
    case .torus(_, let pipe, _, _): halfHeight = pipe
    default: return nil
    }
    let a = simd_dot(point(.init(x: 0, y: -halfHeight, z: 0), in: pose) - origin, axis)
    let b = simd_dot(point(.init(x: 0, y: halfHeight, z: 0), in: pose) - origin, axis)
    return (min(a, b), max(a, b))
  }

  private static func parts(
    words: Set<String>, document: SceneDocument, poses: [ScenePose3D],
    matching: (Geometry3D) -> Bool
  ) -> [ScenePose3D] {
    var ids = Set(
      document.nodes.compactMap { node -> String? in
        guard node.kind == .text, node.opacity > 0,
          !tokens(node.text).isDisjoint(with: words)
        else { return nil }
        return node.spatial3D?.labelAnchor?.targetID
      })
    if ids.isEmpty {
      ids = Set(poses.filter { !tokens($0.node.id).isDisjoint(with: words) }.map(\.node.id))
    }
    let lookup = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
    return poses.filter { pose in
      guard pose.node.kind == .mesh, pose.effectiveOpacity > 0,
        let geometry = pose.node.spatial3D?.geometry, matching(geometry)
      else { return false }
      var id: String? = pose.node.id
      for _ in 0...32 {
        guard let current = id else { break }
        if ids.contains(current) { return true }
        id = lookup[current]?.parentID
      }
      return false
    }.sorted { $0.node.id < $1.node.id }
  }

  private static func tokens(_ text: String) -> Set<String> {
    Set(text.lowercased().split { !$0.isLetter }.map(String.init))
  }
  private static func isSphere(_ geometry: Geometry3D) -> Bool {
    if case .sphere = geometry { return true }
    return false
  }
  private static func isAxial(_ geometry: Geometry3D) -> Bool {
    switch geometry {
    case .cylinder, .tube, .torus: return true
    default: return false
    }
  }
  private static func point(_ value: Vector3D, in pose: ScenePose3D) -> SIMD3<Double> {
    let result = pose.transform.applying(to: value)
    return SIMD3(result.x, result.y, result.z)
  }
  private static func direction(_ value: Vector3D, in pose: ScenePose3D) -> SIMD3<Double> {
    point(value, in: pose) - point(.zero, in: pose)
  }
  private static func normalized(_ value: SIMD3<Double>) -> SIMD3<Double>? {
    let length = simd_length(value)
    guard length.isFinite, length > 1e-12 else { return nil }
    return finite(value / length)
  }
  private static func finite(_ value: SIMD3<Double>) -> SIMD3<Double>? {
    value.x.isFinite && value.y.isFinite && value.z.isFinite ? value : nil
  }
  private static func inverseLinear(_ pose: ScenePose3D) -> simd_double3x3? {
    let matrix = simd_double3x3(
      columns: (
        direction(.init(x: 1, y: 0, z: 0), in: pose),
        direction(.init(x: 0, y: 1, z: 0), in: pose),
        direction(.init(x: 0, y: 0, z: 1), in: pose)
      ))
    let determinant = simd_determinant(matrix)
    guard determinant.isFinite, abs(determinant) > 1e-30 else { return nil }
    return simd_inverse(matrix)
  }
  private static func cylinderSegment(_ pose: ScenePose3D) -> (SIMD3<Double>, SIMD3<Double>)? {
    guard case .cylinder(_, let height, _)? = pose.node.spatial3D?.geometry else { return nil }
    return (
      point(.init(x: 0, y: -height / 2, z: 0), in: pose),
      point(.init(x: 0, y: height / 2, z: 0), in: pose)
    )
  }
  private static func intersects(
    atom: ScenePose3D, segment: (SIMD3<Double>, SIMD3<Double>)
  ) -> Bool {
    guard case .sphere(let radius, _)? = atom.node.spatial3D?.geometry,
      let inverse = inverseLinear(atom)
    else { return false }
    let origin = point(.zero, in: atom)
    let a = inverse * (segment.0 - origin)
    let b = inverse * (segment.1 - origin)
    let delta = b - a
    let squaredLength = simd_length_squared(delta)
    guard squaredLength.isFinite, squaredLength > 1e-24 else { return false }
    let t = min(1, max(0, -simd_dot(a, delta) / squaredLength))
    // Small geometric tolerance, independent of any chemistry/physics constants.
    return simd_length(a + t * delta) <= radius * 1.04
  }
  private static func contains(atom: ScenePose3D, endpoint: SIMD3<Double>) -> Bool {
    guard case .sphere(let radius, _)? = atom.node.spatial3D?.geometry,
      let inverse = inverseLinear(atom)
    else { return false }
    return simd_length(inverse * (endpoint - point(.zero, in: atom))) <= radius * 1.04
  }
  private static func positiveDegrees(_ angle: Double) -> Double {
    let remainder = angle.truncatingRemainder(dividingBy: 360)
    return remainder < 0 ? remainder + 360 : remainder
  }
}

struct SpatialSceneAcceptanceSnapshot: Sendable {
  let document: SceneDocument
  let textUnits: Int
  let narrationPreview: [String]
  let narrationPreviewUTF8Bytes: Int
  let narrationPreviewTruncated: Bool
  let lastRejectedScene: SpatialRejectedSceneSummary?
  let structuredStageProgress: StructuredSpatialStageProgress?
  let sceneUnits: Int
  let connectorUnits: Int
  let compiledConnectorCount: Int
  let rejectedLine: Data?
  let progressiveGeometryUnits: Int
  let firstSceneMS: Double?
  let firstTypedMS: Double?
  let routing: CodexRoutingSelection?
  let timings: [CodexTimingEvent]
}

/// A public-fixture failure graph, not raw scene/narration persistence. Counts
/// cover the complete proposal; only bounded identity/reference rows are kept.
struct SpatialRejectedSceneSummary: Codable, Sendable, Equatable {
  struct Node: Codable, Sendable, Equatable {
    let id: String
    let kind: String
    let parentID: String?
    let targetID: String?
  }
  let error: String
  let nodeCount: Int
  let meshCount: Int
  let nodes: [Node]
  let truncated: Bool

  init(unit: ProviderUnit, error: String) {
    let proposed = unit.nodes ?? []
    let boundedError = Self.prefix(error, maximumUTF8Bytes: 2_048)
    self.error = boundedError
    nodeCount = proposed.count
    meshCount = proposed.reduce(0) { $0 + ($1.kind == .mesh ? 1 : 0) }
    var shortened = boundedError.utf8.count < error.utf8.count || proposed.count > 128
    var rows: [Node] = []
    for node in proposed.prefix(128) {
      let id = Self.prefix(node.id, maximumUTF8Bytes: 256)
      let parent = node.parentID.map { Self.prefix($0, maximumUTF8Bytes: 256) }
      let originalTarget = node.spatial3D?.labelAnchor?.targetID
      let target = originalTarget.map { Self.prefix($0, maximumUTF8Bytes: 256) }
      if id != node.id || parent != node.parentID || target != originalTarget { shortened = true }
      rows.append(.init(id: id, kind: node.kind.rawValue, parentID: parent, targetID: target))
    }
    nodes = rows
    truncated = shortened
  }

  private static func prefix(_ value: String, maximumUTF8Bytes: Int) -> String {
    var result = String.UnicodeScalarView()
    var count = 0
    for scalar in value.unicodeScalars {
      guard scalar.utf8.count <= maximumUTF8Bytes - count else { break }
      result.append(scalar)
      count += scalar.utf8.count
    }
    return String(result)
  }
}

actor SpatialSceneAcceptanceCollector {
  private var document = SceneDocument(title: "Public generated 3D lesson", width: 900, height: 560)
  private var textUnits = 0
  private var narrationPreview: [String] = []
  private var narrationPreviewUTF8Bytes = 0
  private var narrationPreviewTruncated = false
  private var lastRejectedScene: SpatialRejectedSceneSummary?
  private var structuredStageProgress: StructuredSpatialStageProgress?
  private var sceneUnits = 0
  private var connectorUnits = 0
  private var compiledConnectorCount = 0
  private var rejectedLine: Data?
  private var progressiveGeometryUnits = 0
  private var encounteredMeshIDs: Set<String> = []
  private var firstSceneMS: Double?
  private var firstTypedMS: Double?
  private var routing: CodexRoutingSelection?
  private var timings: [CodexTimingEvent] = []
  private let started: TimeInterval

  init(started: TimeInterval) { self.started = started }
  func route(_ value: CodexRoutingSelection) { routing = value }
  func structuredProgress(_ value: StructuredSpatialStageProgress) {
    structuredStageProgress = value
  }
  func timing(_ event: CodexTimingEvent) {
    guard timings.count < CodexTimingEvent.Stage.allCases.count else { return }
    timings.append(event)
  }
  func recordRejectedLine(_ data: Data) {
    guard rejectedLine == nil, !data.isEmpty,
      data.count <= ProviderTextStreamDecoder.maximumLineBytes
    else { return }
    rejectedLine = data
  }
  func receive(_ unit: ProviderUnit) throws {
    try Task.checkCancellation()
    switch unit.type {
    case "text":
      guard let text = unit.text, !text.isEmpty, text.utf8.count <= 32_000, textUnits < 64 else {
        throw ProviderError.message("Invalid or excessive public narration units.")
      }
      textUnits += 1
      let remaining = 16_384 - narrationPreviewUTF8Bytes
      if !narrationPreviewTruncated, narrationPreview.count < 64, remaining > 0 {
        let preview = Self.unicodePrefix(text, maximumUTF8Bytes: remaining)
        if !preview.isEmpty {
          narrationPreview.append(preview)
          narrationPreviewUTF8Bytes += preview.utf8.count
        }
        if preview.utf8.count < text.utf8.count { narrationPreviewTruncated = true }
      } else {
        narrationPreviewTruncated = true
      }
    case "scene":
      guard sceneUnits < 96 else { throw ProviderError.message("Excessive public scene units.") }
      let accepted: SceneDocument
      do {
        accepted = try ProviderSceneBoundary.applying(
          unit, to: document, baseRevision: document.revision)
      } catch {
        lastRejectedScene = .init(unit: unit, error: error.localizedDescription)
        throw error
      }
      document = accepted
      // Count construction only after the whole native transaction succeeds.
      let connectorCount = unit.connectors?.count ?? 0
      if connectorCount > 0 { connectorUnits += 1 }
      compiledConnectorCount += connectorCount
      let meshIDs = Set(
        document.nodes.compactMap { node in
          node.kind == .mesh && node.spatial3D?.geometry != nil ? node.id : nil
        })
      // Progress means adding a previously unseen physical part. Removing,
      // moving or re-adding an earlier mesh cannot turn one finished assembly
      // into evidence of progressive construction.
      if !meshIDs.subtracting(encounteredMeshIDs).isEmpty { progressiveGeometryUnits += 1 }
      encounteredMeshIDs.formUnion(meshIDs)
      let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
      if firstSceneMS == nil { firstSceneMS = elapsed }
      if firstTypedMS == nil, document.nodes.contains(where: { $0.spatial3D?.geometry != nil }) {
        firstTypedMS = elapsed
      }
      sceneUnits += 1
    default:
      throw ProviderError.message("The 3D response emitted a non-scene capability.")
    }
  }
  func snapshot() -> SpatialSceneAcceptanceSnapshot {
    .init(
      document: document, textUnits: textUnits,
      narrationPreview: narrationPreview, narrationPreviewUTF8Bytes: narrationPreviewUTF8Bytes,
      narrationPreviewTruncated: narrationPreviewTruncated,
      lastRejectedScene: lastRejectedScene,
      structuredStageProgress: structuredStageProgress,
      sceneUnits: sceneUnits,
      connectorUnits: connectorUnits, compiledConnectorCount: compiledConnectorCount,
      rejectedLine: rejectedLine,
      progressiveGeometryUnits: progressiveGeometryUnits,
      firstSceneMS: firstSceneMS, firstTypedMS: firstTypedMS, routing: routing, timings: timings)
  }

  private static func unicodePrefix(_ text: String, maximumUTF8Bytes: Int) -> String {
    var result = String.UnicodeScalarView()
    var count = 0
    for scalar in text.unicodeScalars {
      let next = scalar.utf8.count
      guard next <= maximumUTF8Bytes - count else { break }
      result.append(scalar)
      count += next
    }
    return String(result)
  }
}
