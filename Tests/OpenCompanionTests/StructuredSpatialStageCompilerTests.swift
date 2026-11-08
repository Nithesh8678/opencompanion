import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct StructuredSpatialStageCompilerTests {
  private static let minimal = ##"""
    {"text":"A sphere is round.","title":"Sphere","groups":[],"parts":[{"id":"ball","parentID":null,"fill":"#4488CC","opacity":null,"transform":null,"geometry":{"type":"sphere","radius":1,"segments":24}}],"labels":[],"animations":[],"removeIDs":[]}
    """##

  @Test func fixedRolesCompileToSceneThenNarrationWithoutChangingNativeDefaults() throws {
    let stage = try compile(Self.minimal)
    #expect(stage.scene.type == "scene" && stage.text.type == "text")
    #expect(stage.text.text == "A sphere is round." && stage.scene.title == "Sphere")
    let node = try #require(stage.scene.nodes?.first)
    #expect(node.kind == .mesh && node.id == "ball" && node.parentID == nil)
    #expect(node.opacity == 1 && node.x == 0 && node.fontSize == 18 && node.bindings.isEmpty)
    #expect(node.spatial3D?.transform == .identity)
    #expect(node.spatial3D?.geometry == .sphere(radius: 1, segments: 24))
    #expect(
      stage.scene.operations == nil && stage.scene.parameters == nil && stage.scene.target == nil)
    let document = try ProviderSceneBoundary.applying(
      stage.scene, to: SceneDocument(), baseRevision: 0)
    #expect(document.nodes == [node] && document.revision == 1)
    #expect(SceneNode(id: "ordinary", kind: .rectangle).fontSize == 18)
  }

  @Test func arbitraryHierarchyTransformsLabelsAndAnimationsKeepNativeMeaning() throws {
    let stage = try compile(
      ##"""
      {"text":"The labeled part belongs to a transformed assembly.","title":null,
       "groups":[
         {"id":"assembly","parentID":null,"transform":{"position":{"x":2,"y":-1,"z":3},"rotationDegrees":{"x":0,"y":35,"z":0},"scale":{"x":1.2,"y":1.2,"z":1.2}}},
         {"id":"axis","parentID":"assembly","transform":{"position":null,"rotationDegrees":{"x":90,"y":0,"z":0},"scale":null}}],
       "parts":[{"id":"part","parentID":"axis","fill":"#AABBCC","opacity":0.8,"transform":null,"geometry":{"type":"cylinder","radius":0.2,"height":2.4,"segments":24}}],
       "labels":[{"id":"annotation","text":"Shaft","color":"#FFFFFF","width":140,"height":36,"fontSize":18,"labelAnchor":{"targetID":"part","point":{"x":0.2,"y":0.7,"z":0},"screenOffset":{"x":24,"y":-18},"leader":true}}],
       "animations":[{"id":"spin","targetID":"part","behavior":"rotate","speed":45,"amplitude":1,"axis3D":"y"}],"removeIDs":[]}
      """##)
    let nodes = try #require(stage.scene.nodes)
    #expect(nodes.map(\.kind) == [.group, .group, .mesh, .text])
    #expect(nodes[3].parentID == nil && nodes[3].spatial3D?.labelAnchor?.targetID == "part")
    let document = try ProviderSceneBoundary.applying(
      stage.scene, to: SceneDocument(), baseRevision: 0)
    let poses = try document.spatialWorldPoses(at: 0)
    let part = try #require(poses.first { $0.node.id == "part" })
    let expected = try #require(nodes[0].spatial3D).transform.matrix.multiplied(
      by: try #require(nodes[1].spatial3D).transform.matrix)
    #expect(part.transform == expected && part.effectiveOpacity == 0.8)
    #expect(document.animations.first?.axis3D == .y)
  }

  @Test(arguments: [
    #"{"type":"box","width":2,"height":1,"depth":0.6,"chamferRadius":0.04}"#,
    #"{"type":"sphere","radius":0.5,"segments":24}"#,
    #"{"type":"cylinder","radius":0.12,"height":3,"segments":24}"#,
    #"{"type":"torus","ringRadius":0.6,"pipeRadius":0.08,"ringSegments":32,"pipeSegments":12}"#,
    #"{"type":"tube","innerRadius":0.9,"outerRadius":1.1,"height":1.8,"segments":32,"startAngleDegrees":120,"sweepAngleDegrees":240}"#,
    #"{"type":"cone","topRadius":0,"bottomRadius":1,"height":2,"segments":24}"#,
    #"{"type":"capsule","radius":0.5,"height":3,"segments":24}"#,
    #"{"type":"lathe","profile":[{"radius":1,"y":-1},{"radius":0.5,"y":1}],"segments":24}"#,
    #"{"type":"extrusion","profile":[{"x":0,"y":0},{"x":2,"y":0},{"x":1,"y":1}],"depth":0.4}"#,
  ])
  func allNinePrimitivesArePreservedWithoutNameBasedRepairs(_ geometry: String) throws {
    var step = try fields(Self.minimal)
    var part = try firstPart(step)
    part["id"] = .string("arbitrary-part")
    part["geometry"] = try json(geometry)
    step["parts"] = .array([.object(part)])
    let result = try compile(step)
    let native = try #require(result.scene.nodes?.first)
    #expect(native.id == "arbitrary-part" && native.kind == .mesh)
    #expect(native.spatial3D?.geometry == (try json(geometry).decoded(as: Geometry3D.self)))
    _ = try ProviderSceneBoundary.applying(result.scene, to: SceneDocument(), baseRevision: 0)
  }

  @Test func nestedUnknownKeysAndForbiddenCapabilitiesAreRejectedLocally() throws {
    for key in ["type", "kind", "bindings", "parameters", "operations", "target", "url", "extra"] {
      var step = try fields(Self.minimal)
      step[key] = .null
      #expect(throws: (any Error).self) { _ = try compile(step) }
      step.removeValue(forKey: key)
      var part = try firstPart(step)
      part[key] = .null
      step["parts"] = .array([.object(part)])
      #expect(throws: (any Error).self) { _ = try compile(step) }
    }
    for replacement in [
      #""geometry":{"type":"sphere","radius":1,"segments":24,"pipeRadius":null}"#,
      #""geometry":{"type":"sphere","radius":1,"segments":24,"extra":0}"#,
      #""geometry":{"type":"sphere","radius":1,"segments":24},"kind":"text""#,
    ] {
      let raw = Self.minimal.replacingOccurrences(
        of: #""geometry":{"type":"sphere","radius":1,"segments":24}"#, with: replacement)
      #expect(throws: (any Error).self) { _ = try compile(raw) }
    }
    let transform = #"{"position":{"x":0,"y":0,"z":0,"w":1},"rotationDegrees":null,"scale":null}"#
    let badVector = Self.minimal.replacingOccurrences(
      of: #""transform":null"#, with: #""transform":"# + transform)
    #expect(throws: (any Error).self) { _ = try compile(badVector) }
  }

  @Test func duplicateObjectKeysIncludingEscapesAreRejectedBeforeNativeDecode() throws {
    let mutations: [(String, String)] = [
      (#""title":"Sphere""#, #""title":"Sphere","\u0074itle":"Other""#),
      (#""id":"ball""#, #""id":"ball","i\u0064":"other""#),
      (#""radius":1"#, #""radius":1,"ra\u0064ius":2"#),
      (
        #""transform":null"#,
        #""transform":{"position":{"x":0,"\u0078":1,"y":0,"z":0},"rotationDegrees":null,"scale":null}"#
      ),
    ]
    for (before, after) in mutations {
      let raw = Self.minimal.replacingOccurrences(of: before, with: after)
      do {
        _ = try compile(raw)
        Issue.record("A duplicate nested key was admitted.")
      } catch {
        #expect(error.localizedDescription.contains("Duplicate object keys"))
      }
    }
    var safe = try fields(Self.minimal)
    safe["text"] = .string("Escaped quotes \"type\" and brackets { [ ] }; café 👩🏽‍💻.")
    #expect(try compile(safe).text.text == "Escaped quotes \"type\" and brackets { [ ] }; café 👩🏽‍💻.")
  }

  @Test func requiredFieldsNullableDefaultsAndCompleteReplacementGeometryAreEnforced() throws {
    let original = try fields(Self.minimal)
    for key in original.keys {
      var step = original
      step.removeValue(forKey: key)
      #expect(throws: (any Error).self) { _ = try compile(step) }
    }
    let originalPart = try firstPart(original)
    for key in originalPart.keys {
      var part = originalPart
      part.removeValue(forKey: key)
      var step = original
      step["parts"] = .array([.object(part)])
      #expect(throws: (any Error).self) { _ = try compile(step) }
    }
    var nullGeometry = originalPart
    nullGeometry["geometry"] = .null
    var step = original
    step["parts"] = .array([.object(nullGeometry)])
    #expect(throws: (any Error).self) { _ = try compile(step) }
    let first = try compile(original)
    var document = try ProviderSceneBoundary.applying(
      first.scene, to: SceneDocument(), baseRevision: 0)
    var replacement = originalPart
    replacement["geometry"] = try json(
      #"{"type":"box","width":2,"height":1,"depth":1,"chamferRadius":0}"#)
    step["parts"] = .array([.object(replacement)])
    let second = try compile(step)
    document = try ProviderSceneBoundary.applying(
      second.scene, to: document, baseRevision: document.revision)
    #expect(document.nodes.count == 1 && document.revision == 2)
    #expect(
      document.nodes[0].spatial3D?.geometry == .box(width: 2, height: 1, depth: 1, chamferRadius: 0)
    )
  }

  @Test func duplicateRoleAnimationAndRemovalIDsAreRejectedButRecreationIsAllowed() throws {
    let original = try fields(Self.minimal)
    let part = try firstPart(original)
    var duplicateParts = original
    duplicateParts["parts"] = .array([.object(part), .object(part)])
    #expect(throws: (any Error).self) { _ = try compile(duplicateParts) }
    var crossRole = original
    crossRole["groups"] = try json(#"[{"id":"ba\u006cl","parentID":null,"transform":null}]"#)
    #expect(throws: (any Error).self) { _ = try compile(crossRole) }
    var animations = original
    let animation = try json(
      #"{"id":"spin","targetID":"ball","behavior":"rotate","speed":45,"amplitude":1,"axis3D":"y"}"#)
    animations["animations"] = .array([animation, animation])
    #expect(throws: (any Error).self) { _ = try compile(animations) }
    var removals = original
    removals["removeIDs"] = .array([.string("ball"), .string("ball")])
    #expect(throws: (any Error).self) { _ = try compile(removals) }
    removals["removeIDs"] = .array([.string("ball")])
    let first = try compile(original)
    let source = try ProviderSceneBoundary.applying(
      first.scene, to: SceneDocument(), baseRevision: 0)
    let recreated = try compile(removals)
    let result = try ProviderSceneBoundary.applying(
      recreated.scene, to: source, baseRevision: source.revision)
    #expect(result.nodes == source.nodes && result.revision == 2)
  }

  @Test func deepestSupportedTransformGeometryAndAnchorPathsRemainAvailable() throws {
    var step = try fields(Self.minimal)
    var part = try firstPart(step)
    part["geometry"] = try json(
      #"{"type":"torus","ringRadius":1,"pipeRadius":0.1,"ringSegments":64,"pipeSegments":64}"#)
    part["transform"] = try json(
      #"{"position":{"x":1,"y":2,"z":3},"rotationDegrees":{"x":20,"y":30,"z":40},"scale":{"x":1,"y":0.7,"z":1.2}}"#
    )
    step["parts"] = .array([.object(part)])
    step["labels"] = try json(
      ##"[{"id":"ring-label","text":"Ring","color":"#FFFFFF","width":140,"height":36,"fontSize":18,"labelAnchor":{"targetID":"ball","point":{"x":1,"y":0.1,"z":0},"screenOffset":{"x":24,"y":-18},"leader":true}}]"##
    )
    let stage = try compile(step)
    let document = try ProviderSceneBoundary.applying(
      stage.scene, to: SceneDocument(), baseRevision: 0)
    #expect(document.nodes.count == 2)
    #expect(document.nodes.first?.spatial3D?.transform.position == .init(x: 1, y: 2, z: 3))
    #expect(document.nodes.last?.spatial3D?.labelAnchor?.targetID == "ball")
  }

  @Test func narrationByteBudgetIsDecodedUTF8AndIndependentOfWireEscapes() throws {
    for text in [String(repeating: "a", count: 32_000), String(repeating: "é", count: 16_000), " "]
    {
      var step = try fields(Self.minimal)
      step["text"] = .string(text)
      #expect(try compile(step).text.text == text)
    }
    for text in ["", String(repeating: "é", count: 16_000) + "a"] {
      var step = try fields(Self.minimal)
      step["text"] = .string(text)
      #expect(throws: (any Error).self) { _ = try compile(step) }
    }
  }

  @Test func stageBytesNestingMalformedJSONAndTrailingContentAreBounded() throws {
    let base = Data(Self.minimal.utf8)
    let padding = StructuredSpatialStageCompiler.maximumStageBytes - base.count
    var exact = base
    exact.append(contentsOf: repeatElement(UInt8(32), count: padding))
    #expect(try StructuredSpatialStageCompiler.compile(exact).scene.nodes?.count == 1)
    exact.append(32)
    #expect(throws: (any Error).self) { _ = try StructuredSpatialStageCompiler.compile(exact) }
    for raw in [
      "", "[]", "{}", Self.minimal + "{}", Self.minimal + "x", String(Self.minimal.dropLast()),
      #"{"text":"\q"}"#,
    ] {
      #expect(throws: (any Error).self) { _ = try compile(raw) }
    }
    let nested = String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)
    let deep = Self.minimal.dropLast() + ",\"extra\":" + nested + "}"
    do {
      _ = try compile(String(deep))
      Issue.record("Excessive nesting was admitted.")
    } catch { #expect(error.localizedDescription.contains("nesting")) }
  }

  @Test func roleArrayLimitsDoNotPermitEmptyOrOversizedPhysicalStages() throws {
    let base = try fields(Self.minimal)
    let part = try #require(try values(base["parts"]).first)
    for count in [0, 4] {
      var step = base
      step["parts"] = .array(Array(repeating: part, count: count))
      #expect(throws: (any Error).self) { _ = try compile(step) }
    }
    for (key, count) in [("groups", 33), ("labels", 33), ("animations", 65), ("removeIDs", 129)] {
      var step = base
      step[key] = .array(Array(repeating: .null, count: count))
      #expect(throws: (any Error).self) { _ = try compile(step) }
    }
  }

  @Test func nativeReferencesCyclesAndCrossDimensionChecksRemainAuthoritative() throws {
    var missing = try fields(Self.minimal)
    var part = try firstPart(missing)
    part["parentID"] = .string("missing")
    missing["parts"] = .array([.object(part)])
    let missingStage = try compile(missing)
    #expect(throws: (any Error).self) {
      _ = try ProviderSceneBoundary.applying(
        missingStage.scene, to: SceneDocument(), baseRevision: 0)
    }
    var cycle = try fields(Self.minimal)
    cycle["groups"] = try json(
      #"[{"id":"a","parentID":"b","transform":null},{"id":"b","parentID":"a","transform":null}]"#)
    let cycleStage = try compile(cycle)
    #expect(throws: (any Error).self) {
      _ = try ProviderSceneBoundary.applying(cycleStage.scene, to: SceneDocument(), baseRevision: 0)
    }
    var invalid = try fields(Self.minimal)
    part = try firstPart(invalid)
    part["geometry"] = try json(
      #"{"type":"tube","innerRadius":2,"outerRadius":1,"height":2,"segments":24,"startAngleDegrees":0,"sweepAngleDegrees":240}"#
    )
    invalid["parts"] = .array([.object(part)])
    let invalidStage = try compile(invalid)
    #expect(throws: (any Error).self) {
      _ = try ProviderSceneBoundary.applying(
        invalidStage.scene, to: SceneDocument(), baseRevision: 0)
    }
  }

  @Test func cancelledCompilationProducesNoStage() async throws {
    let cancelled = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try compile(Self.minimal)
        return false
      } catch is CancellationError { return true } catch { return false }
    }.value
    #expect(cancelled)
  }

  @Test func rootAndAllNestedSchemasAreClosedRequiredAndUseOnlyKnownRefs() throws {
    let root = try object(StructuredSpatialStageSchema.value)
    let definitions = try object(try #require(root["$defs"]))
    var seen = Set<String>()
    func visit(_ value: JSONValue) throws {
      switch value {
      case .object(let rule):
        if rule["type"] == .string("object") {
          let properties = try object(try #require(rule["properties"]))
          let required = try values(rule["required"]).compactMap {
            if case .string(let name) = $0 { name } else { nil }
          }
          #expect(rule["additionalProperties"] == .bool(false))
          #expect(Set(required) == Set(properties.keys) && required.count == properties.count)
          seen.formUnion(properties.keys)
        }
        if case .string(let ref) = rule["$ref"] {
          #expect(ref.hasPrefix("#/$defs/") && definitions[String(ref.dropFirst(8))] != nil)
        }
        for child in rule.values { try visit(child) }
      case .array(let children): for child in children { try visit(child) }
      default: break
      }
    }
    try visit(StructuredSpatialStageSchema.value)
    #expect(
      seen.isDisjoint(with: ["kind", "bindings", "parameters", "operations", "spatial3D", "url"]))
    #expect(StructuredSpatialStageSchema.instructions.contains("ONE physical part"))
    #expect(StructuredSpatialStageSchema.instructions.contains("before delivering its narration"))
    let source = try object(try #require(try object(StructuredSceneOutputSchema.value)["$defs"]))
    for name in ["geometry", "box", "sphere", "cylinder", "torus", "tube"] {
      #expect(definitions[name] == source[name])
    }
  }

  private func compile(_ raw: String) throws -> StructuredSpatialStageCompiler.Stage {
    try StructuredSpatialStageCompiler.compile(Data(raw.utf8))
  }
  private func compile(_ fields: [String: JSONValue]) throws -> StructuredSpatialStageCompiler.Stage
  {
    try StructuredSpatialStageCompiler.compile(JSONEncoder().encode(JSONValue.object(fields)))
  }
  private func json(_ raw: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
  }
  private func fields(_ raw: String) throws -> [String: JSONValue] { try object(json(raw)) }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let result) = value else { throw FixtureError.expectedObject }
    return result
  }
  private func values(_ value: JSONValue?) throws -> [JSONValue] {
    guard case .array(let result) = value else { throw FixtureError.expectedArray }
    return result
  }
  private func firstPart(_ step: [String: JSONValue]) throws -> [String: JSONValue] {
    let parts = try values(step["parts"])
    let part = try #require(parts.first)
    return try object(part)
  }
  private enum FixtureError: Error { case expectedObject, expectedArray }
}
