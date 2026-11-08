import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct StructuredSceneOutputSchemaTests {
  @Test(arguments: [false, true])
  func schemaGraphIsClosedRequiredBoundedAndHasOnlyLocalKnownReferences(unified: Bool) throws {
    let value =
      unified ? StructuredSceneOutputSchema.unifiedValue : StructuredSceneOutputSchema.value
    let root = try object(value)
    let definitions = try object(try #require(root["$defs"]))
    #expect(root["type"] == .string("object") && root["anyOf"] == nil)
    var objectCount = 0
    var propertyCount = 0
    var foundNames = Set<String>()
    func visit(_ value: JSONValue) throws {
      switch value {
      case .object(let schema):
        if schema["type"] == .string("object") {
          objectCount += 1
          let properties = try object(try #require(schema["properties"]))
          let required = try strings(try #require(schema["required"]))
          #expect(schema["additionalProperties"] == .bool(false))
          #expect(Set(required) == Set(properties.keys) && required.count == properties.count)
          propertyCount += properties.count
          foundNames.formUnion(properties.keys)
        }
        if case .string(let path) = schema["$ref"] {
          #expect(path.hasPrefix("#/$defs/"))
          #expect(definitions[String(path.dropFirst(8))] != nil)
        }
        if schema["type"] == .string("array") {
          guard case .number(let minimum) = schema["minItems"],
            case .number(let maximum) = schema["maxItems"]
          else {
            Issue.record("Every array needs explicit finite bounds.")
            return
          }
          #expect(minimum >= 0 && maximum >= minimum && maximum <= 4_096)
        }
        for child in schema.values { try visit(child) }
      case .array(let values): for child in values { try visit(child) }
      default: break
      }
    }
    try visit(value)
    #expect(objectCount >= (unified ? 16 : 20) && propertyCount < 300)
    #expect(foundNames.isDisjoint(with: ["target", "operations", "parameters", "bindings", "url"]))
    let data = try JSONEncoder().encode(value)
    #expect(data.count < 25_000)
    #expect(StructuredSceneOutputSchema.instructions.contains("excludes bindings"))
    #expect(StructuredSceneOutputSchema.instructions.contains("Native validation"))
  }

  @Test(arguments: [false, true])
  func geometryVariantsHaveOnlyNativeShapeKeysAndNeverNullForeignKeys(unified: Bool) throws {
    let value =
      unified ? StructuredSceneOutputSchema.unifiedValue : StructuredSceneOutputSchema.value
    let definitions = try schemaDefinitions(value)
    let expected: [String: Set<String>] = [
      "box": ["type", "width", "height", "depth", "chamferRadius"],
      "sphere": ["type", "radius", "segments"],
      "cylinder": ["type", "radius", "height", "segments"],
      "cone": ["type", "topRadius", "bottomRadius", "height", "segments"],
      "capsule": ["type", "radius", "height", "segments"],
      "lathe": ["type", "profile", "segments"],
      "extrusion": ["type", "profile", "depth"],
      "roundedExtrusion": ["type", "profile", "depth", "cornerRounding"],
      "torus": ["type", "ringRadius", "pipeRadius", "ringSegments", "pipeSegments"],
      "tube": [
        "type", "innerRadius", "outerRadius", "height", "segments", "startAngleDegrees",
        "sweepAngleDegrees",
      ],
    ]
    for (name, keys) in expected {
      let schema = try #require(definitions[name])
      let fields = try object(try #require(try object(schema)["properties"]))
      #expect(Set(fields.keys) == keys)
      for field in fields.values {
        #expect(!matches(.null, schema: field, definitions: definitions))
      }
    }
    for raw in primitiveExamples {
      let value = try json(raw)
      #expect(
        matches(value, schema: try #require(definitions["geometry"]), definitions: definitions))
      let geometry = try value.decoded(as: Geometry3D.self)
      _ = try geometry.validatedBudget()
      var mixed = try object(value)
      mixed["foreignKey"] = .null
      #expect(
        !matches(
          .object(mixed), schema: try #require(definitions["geometry"]), definitions: definitions))
      #expect(throws: (any Error).self) {
        _ = try JSONValue.object(mixed).decoded(as: Geometry3D.self)
      }
    }
  }

  @Test(arguments: [false, true])
  func roundedAndLinearExtrusionBranchesStayClosedDisjointAndShareNativeDefaults(unified: Bool)
    throws
  {
    let definitions = try schemaDefinitions(
      unified ? StructuredSceneOutputSchema.unifiedValue : StructuredSceneOutputSchema.value)
    let linear = try #require(definitions["extrusion"])
    let rounded = try #require(definitions["roundedExtrusion"])
    let base = try json(
      #"{"type":"extrusion","profile":[{"x":-1,"y":-1},{"x":1,"y":-1},{"x":1,"y":1},{"x":-1,"y":1}],"depth":0.4}"#
    )
    #expect(matches(base, schema: linear, definitions: definitions))
    #expect(!matches(base, schema: rounded, definitions: definitions))
    let ordinary = try base.decoded(as: Geometry3D.self)
    for fraction in [0.0, 0.2] {
      var fields = try object(base)
      fields["cornerRounding"] = .number(fraction)
      let value = JSONValue.object(fields)
      #expect(!matches(value, schema: linear, definitions: definitions))
      #expect(matches(value, schema: rounded, definitions: definitions))
      let shape = try value.decoded(as: Geometry3D.self)
      _ = try shape.validatedBudget()
      if fraction == 0 { #expect(shape == ordinary) }
    }
    for fraction in [-0.01, 0.26] {
      var fields = try object(base)
      fields["cornerRounding"] = .number(fraction)
      #expect(!matches(.object(fields), schema: rounded, definitions: definitions))
      let shape = try JSONValue.object(fields).decoded(as: Geometry3D.self)
      #expect(throws: CoreError.self) { try shape.validatedBudget() }
    }
  }

  @Test func publicProgressiveSpatialExampleUsesNativeDefaultsAndTransactions() throws {
    let root = try json(
      ##"""
      {"units":[
        {"type":"text","text":"A cutaway exposes the rotating shaft."},
        {"type":"scene","title":"Motor assembly","nodes":[
          {"id":"assembly","kind":"group","parentID":null,"spatial3D":{"transform":null}},
          {"id":"housing","kind":"mesh","parentID":"assembly","fill":"#667788","opacity":null,"spatial3D":{"transform":null,"geometry":{"type":"tube","innerRadius":0.9,"outerRadius":1.1,"height":1.8,"segments":32,"startAngleDegrees":120,"sweepAngleDegrees":240}}}
        ],"removeIDs":[],"animations":[]},
        {"type":"scene","title":null,"nodes":[
          {"id":"shaft","kind":"mesh","parentID":"assembly","fill":"#AABBCC","opacity":1,"spatial3D":{"transform":{"position":{"x":0,"y":0,"z":0},"rotationDegrees":null,"scale":null},"geometry":{"type":"cylinder","radius":0.12,"height":2.4,"segments":24}}}
        ],"removeIDs":[],"animations":[]},
        {"type":"scene","title":null,"nodes":[
          {"id":"housing-label","kind":"text","text":"Housing","color":"#FFFFFF","width":140,"height":36,"fontSize":18,"spatial3D":{"labelAnchor":{"targetID":"housing","point":{"x":1,"y":0.4,"z":0},"screenOffset":{"x":35,"y":-30},"leader":true}}}
        ],"removeIDs":[],"animations":[{"id":"spin","targetID":"shaft","behavior":"rotate","speed":45,"amplitude":1,"axis3D":"y"}]}
      ]}
      """##)
    let document = try admit(root)
    #expect(document.nodes.count == 4 && document.revision == 3)
    #expect(document.title == "Motor assembly")
    #expect(document.nodes.first?.spatial3D?.transform == .identity)
    #expect(document.nodes.first { $0.id == "housing" }?.opacity == 1)
    #expect(document.animations.first?.axis3D == .y)
    #expect(try document.spatialWorldPoses(at: 0.5).count == 3)
  }

  @Test func staticTwoDimensionalExampleCoversEveryOrdinaryVectorKind() throws {
    let root = try json(
      ##"""
      {"units":[{"type":"scene","title":"Lever","nodes":[
        {"id":"diagram","kind":"group","parentID":null,"x":0,"y":0,"rotation":0},
        {"id":"beam","kind":"rectangle","parentID":"diagram","x":140,"y":260,"width":420,"height":20,"rotation":0,"color":"#334455","fill":"#AABBCC","strokeWidth":2,"opacity":null},
        {"id":"pivot","kind":"ellipse","parentID":"diagram","x":330,"y":280,"width":32,"height":32,"rotation":0,"color":"#334455","fill":"#556677","strokeWidth":2,"opacity":1},
        {"id":"force","kind":"arrow","parentID":"diagram","x":170,"y":150,"points":[{"x":0,"y":0},{"x":0,"y":100}],"color":"#DD3344","strokeWidth":3,"opacity":1},
        {"id":"distance","kind":"line","parentID":"diagram","x":170,"y":340,"points":[{"x":0,"y":0},{"x":180,"y":0}],"color":"#334455","strokeWidth":2,"opacity":1},
        {"id":"effort","kind":"text","parentID":"diagram","x":140,"y":100,"width":160,"height":36,"text":"Effort","fontSize":20,"color":"#334455","rotation":0,"opacity":null},
        {"id":"support","kind":"path","parentID":"diagram","x":0,"y":0,"points":[],"subpaths":[[{"x":346,"y":300},{"x":320,"y":340},{"x":372,"y":340},{"x":346,"y":300}]],"color":"#334455","fill":"transparent","strokeWidth":2,"opacity":1}
      ],"removeIDs":[],"animations":[]}]}
      """##)
    let document = try admit(root)
    #expect(
      Set(document.nodes.map(\.kind)) == [
        .group, .rectangle, .ellipse, .arrow, .line, .text, .path,
      ])
    #expect(!document.usesSpatial3D && document.nodes.allSatisfy { $0.bindings.isEmpty })
    #expect(document.nodes.first { $0.id == "force" }?.points.last?.y == 100)
  }

  @Test func schemaCannotAuthorizeActionsOrBypassNativeRelationshipsAndReferences() throws {
    let prohibited = try json(#"{"units":[{"type":"target","target":{"x":0,"y":0}}]}"#)
    #expect(!conforms(prohibited))
    var unit = try object(
      try json(
        ##"""
        {"type":"scene","title":null,"nodes":[{"id":"shell","kind":"mesh","parentID":null,"fill":"#334455","opacity":1,"spatial3D":{"transform":null,"geometry":{"type":"tube","innerRadius":2,"outerRadius":1,"height":2,"segments":24,"startAngleDegrees":0,"sweepAngleDegrees":240}}}],"removeIDs":[],"animations":[]}
        """##))
    let invalidGeometry = JSONValue.object(["units": .array([.object(unit)])])
    #expect(conforms(invalidGeometry))
    #expect(throws: (any Error).self) { _ = try admit(invalidGeometry) }
    let encodedNodes = try #require(unit["nodes"])
    let nodes = try array(encodedNodes)
    let firstNode = try #require(nodes.first)
    var node = try object(firstNode)
    var spatial = try object(try #require(node["spatial3D"]))
    var geometry = try object(try #require(spatial["geometry"]))
    geometry["innerRadius"] = .number(0.9)
    spatial["geometry"] = .object(geometry)
    node["spatial3D"] = .object(spatial)
    node["parentID"] = .string("missing-assembly")
    unit["nodes"] = .array([.object(node)])
    #expect(throws: (any Error).self) {
      _ = try admit(.object(["units": .array([.object(unit)])]))
    }
  }

  @Test func transportShapeRejectsEmptyOversizedAndUnrelatedOutput() throws {
    let text = try json(#"{"type":"text","text":"Ready."}"#)
    #expect(!conforms(.object(["units": .array([])])))
    #expect(!conforms(.object(["units": .array(Array(repeating: text, count: 97))])))
    #expect(conforms(.object(["units": .array(Array(repeating: text, count: 96))])))
    #expect(!conforms(try json(#"{"units":[{"type":"text","text":""}]}"#)))
    #expect(!conforms(try json(#"{"units":[{"type":"text","text":"Ready.","tool":"run"}]}"#)))
  }

  @Test func unifiedNodeHasOneClosedKindObjectAndNoCompactNodeAlternatives() throws {
    let original = try schemaDefinitions()
    let unified = try schemaDefinitions(StructuredSceneOutputSchema.unifiedValue)
    let node = try object(try #require(unified["node"]))
    #expect(node["anyOf"] == nil && node["type"] == .string("object"))
    let fields = try object(try #require(node["properties"]))
    let kind = try object(try #require(fields["kind"]))
    #expect(
      Set(try strings(try #require(kind["enum"]))) == Set(SceneNode.Kind.allCases.map(\.rawValue)))
    #expect(kind["description"] != nil)
    #expect(try object(try #require(fields["parentID"]))["description"] != nil)
    #expect(try object(try #require(fields["spatial3D"]))["description"] != nil)
    for name in [
      "spatialGroup", "spatialMesh", "spatialLabel", "flatGroup", "flatShape", "flatDirection",
      "flatText", "flatPath",
    ] {
      #expect(original[name] != nil && unified[name] == nil)
    }
    for name in [
      "geometry", "box", "sphere", "cylinder", "torus", "tube", "cone", "capsule", "lathe",
      "extrusion", "roundedExtrusion", "profilePoint", "lathePoint", "sceneUnit", "animation",
    ] {
      #expect(unified[name] == original[name])
    }
  }

  @Test func handAuthoredFullNullNodeUsesActualNativeDefaults() throws {
    let encoded = try json(
      #"""
      {"id":"assembly","kind":"group","parentID":null,"x":null,"y":null,"width":null,"height":null,"text":null,"color":null,"fill":null,"strokeWidth":null,"fontSize":null,"points":null,"subpaths":null,"rotation":null,"opacity":null,"spatial3D":null}
      """#)
    let definitions = try schemaDefinitions(StructuredSceneOutputSchema.unifiedValue)
    let schema = try #require(definitions["node"])
    #expect(matches(encoded, schema: schema, definitions: definitions))
    let node = try encoded.decoded(as: SceneNode.self)
    #expect(node == SceneNode(id: "assembly", kind: .group))
    _ = try SceneDocument(nodes: [node]).validated()
    var missing = try object(encoded)
    missing.removeValue(forKey: "points")
    #expect(!matches(.object(missing), schema: schema, definitions: definitions))
    var foreign = try object(encoded)
    foreign["bindings"] = .object([:])
    #expect(!matches(.object(foreign), schema: schema, definitions: definitions))
  }

  @Test func unifiedMixedArrayDecodesGroupsPhysicalMeshesAndAnchoredTextIndependently() throws {
    let value = try json(
      ##"""
      {"units":[{"type":"scene","title":"Physical assembly","nodes":[
        {"id":"assembly","kind":"group","parentID":null,"x":null,"y":null,"width":null,"height":null,"text":null,"color":null,"fill":null,"strokeWidth":null,"fontSize":null,"points":null,"subpaths":null,"rotation":null,"opacity":null,"spatial3D":{"transform":null,"geometry":null,"labelAnchor":null}},
        {"id":"body","kind":"mesh","parentID":"assembly","x":null,"y":null,"width":null,"height":null,"text":null,"color":null,"fill":"#4488CC","strokeWidth":null,"fontSize":null,"points":null,"subpaths":null,"rotation":null,"opacity":null,"spatial3D":{"transform":null,"geometry":{"type":"sphere","radius":1,"segments":24},"labelAnchor":null}},
        {"id":"body-label","kind":"text","parentID":null,"x":null,"y":null,"width":140,"height":36,"text":"Body","color":"#FFFFFF","fill":null,"strokeWidth":null,"fontSize":18,"points":null,"subpaths":null,"rotation":null,"opacity":null,"spatial3D":{"transform":null,"geometry":null,"labelAnchor":{"targetID":"body","point":{"x":0,"y":0.5,"z":0.8},"screenOffset":{"x":35,"y":-30},"leader":true}}}
      ],"removeIDs":[],"animations":[]}]}
      """##)
    let document = try admit(value, schema: StructuredSceneOutputSchema.unifiedValue)
    #expect(document.nodes.map(\.kind) == [.group, .mesh, .text])
    #expect(document.nodes[1].parentID == "assembly")
    #expect(document.nodes[1].spatial3D?.geometry == .sphere(radius: 1, segments: 24))
    #expect(document.nodes[2].spatial3D?.labelAnchor?.targetID == "body")
    #expect(document.nodes[2].parentID == nil && document.nodes[0].text.isEmpty)
    #expect(try document.spatialWorldPoses(at: 0).count == 2)
  }

  private let primitiveExamples = [
    #"{"type":"box","width":2,"height":1,"depth":0.6,"chamferRadius":0.04}"#,
    #"{"type":"sphere","radius":0.5,"segments":24}"#,
    #"{"type":"cylinder","radius":0.12,"height":3,"segments":24}"#,
    #"{"type":"torus","ringRadius":0.6,"pipeRadius":0.08,"ringSegments":32,"pipeSegments":12}"#,
    #"{"type":"tube","innerRadius":0.9,"outerRadius":1.1,"height":1.8,"segments":32,"startAngleDegrees":120,"sweepAngleDegrees":240}"#,
    #"{"type":"cone","topRadius":0,"bottomRadius":1,"height":2,"segments":24}"#,
    #"{"type":"capsule","radius":0.5,"height":3,"segments":24}"#,
    #"{"type":"lathe","profile":[{"radius":1,"y":-1},{"radius":0.5,"y":1}],"segments":24}"#,
    #"{"type":"extrusion","profile":[{"x":0,"y":0},{"x":2,"y":0},{"x":1,"y":1}],"depth":0.4}"#,
    #"{"type":"extrusion","profile":[{"x":0,"y":0},{"x":2,"y":0},{"x":1,"y":1}],"depth":0.4,"cornerRounding":0.2}"#,
    #"{"type":"extrusion","profile":[{"x":0,"y":0},{"x":2,"y":0},{"x":1,"y":1}],"depth":0.4,"cornerRounding":0}"#,
  ]

  private func admit(_ value: JSONValue, schema: JSONValue = StructuredSceneOutputSchema.value)
    throws -> SceneDocument
  {
    #expect(conforms(value, schema: schema))
    let units = try array(try #require(try object(value)["units"]))
    var document = SceneDocument(id: "public-schema-fixture")
    for encoded in units {
      let unit = try encoded.decoded(as: ProviderUnit.self)
      if unit.type == "scene" {
        document = try ProviderSceneBoundary.applying(
          unit, to: document, baseRevision: document.revision)
      } else {
        #expect(unit.type == "text" && unit.text?.isEmpty == false)
      }
    }
    return try document.validated()
  }
  private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
  private func object(_ value: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = value else { throw TestError.expectedObject }
    return fields
  }
  private func array(_ value: JSONValue) throws -> [JSONValue] {
    guard case .array(let values) = value else { throw TestError.expectedArray }
    return values
  }
  private func strings(_ value: JSONValue) throws -> [String] {
    try array(value).map {
      guard case .string(let string) = $0 else { throw TestError.expectedString }
      return string
    }
  }
  private func schemaDefinitions(_ schema: JSONValue = StructuredSceneOutputSchema.value) throws
    -> [String: JSONValue]
  {
    try object(try #require(try object(schema)["$defs"]))
  }
  private func conforms(_ value: JSONValue, schema: JSONValue = StructuredSceneOutputSchema.value)
    -> Bool
  {
    guard let definitions = try? schemaDefinitions(schema) else { return false }
    return matches(value, schema: schema, definitions: definitions)
  }

  /// Test-only interpreter for the small emitted JSON Schema subset. Public
  /// examples must satisfy both this wire contract and the independent native
  /// decoders/admission path; production does not depend on this interpreter.
  private func matches(
    _ value: JSONValue, schema: JSONValue, definitions: [String: JSONValue], depth: Int = 0
  ) -> Bool {
    guard depth <= 32, case .object(let fields) = schema else { return false }
    if case .string(let ref) = fields["$ref"], ref.hasPrefix("#/$defs/"),
      let target = definitions[String(ref.dropFirst(8))]
    {
      return matches(value, schema: target, definitions: definitions, depth: depth + 1)
    }
    if case .array(let options) = fields["anyOf"] {
      return options.contains {
        matches(value, schema: $0, definitions: definitions, depth: depth + 1)
      }
    }
    if case .array(let allowed) = fields["enum"], !allowed.contains(value) { return false }
    switch (fields["type"], value) {
    case (.string("null"), .null), (.string("boolean"), .bool): return true
    case (.string("string"), .string(let text)):
      if case .string(let pattern) = fields["pattern"] {
        return text.range(of: pattern, options: .regularExpression) != nil
      }
      return true
    case (.string(let kind), .number(let number)) where kind == "number" || kind == "integer":
      guard number.isFinite, kind != "integer" || number.rounded() == number else { return false }
      if case .number(let minimum) = fields["minimum"], number < minimum { return false }
      if case .number(let maximum) = fields["maximum"], number > maximum { return false }
      return true
    case (.string("object"), .object(let object)):
      guard case .object(let properties) = fields["properties"],
        case .array(let required) = fields["required"],
        let requiredKeys = try? strings(.array(required)),
        Set(requiredKeys) == Set(object.keys),
        Set(object.keys) == Set(properties.keys), fields["additionalProperties"] == .bool(false)
      else { return false }
      return object.allSatisfy {
        guard let property = properties[$0.key] else { return false }
        return matches($0.value, schema: property, definitions: definitions, depth: depth + 1)
      }
    case (.string("array"), .array(let values)):
      guard let items = fields["items"], case .number(let minimum) = fields["minItems"],
        case .number(let maximum) = fields["maxItems"],
        Double(values.count) >= minimum, Double(values.count) <= maximum
      else { return false }
      return values.allSatisfy {
        matches($0, schema: items, definitions: definitions, depth: depth + 1)
      }
    default: return false
    }
  }
  private enum TestError: Error { case expectedObject, expectedArray, expectedString }
}
