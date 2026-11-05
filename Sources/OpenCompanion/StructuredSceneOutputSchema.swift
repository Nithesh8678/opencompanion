import CompanionCore

/// Opt-in prototype for a new, standalone explanation, never a retained edit
/// or screen-guidance response. This is the raw app-server `outputSchema`.
/// It deliberately omits bindings, parameters, expressions, operations, legacy
/// mesh inference and arbitrary assets. Native admission remains authoritative
/// for references, transactions, aggregate budgets and geometric relationships.
enum StructuredSceneOutputSchema {
  static let instructions = """
    This turn uses a standalone explanation schema. Return one JSON object with a units array, not newline-delimited objects or Markdown. Units are either text or scene; no targets, tools or desktop actions. Start with a concise text unit, then a small useful scene unit and add physical parts progressively in later units. Use stable IDs. Each scene unit is a valid atomic native transaction: referenced parents and anchored-label targets must exist in that unit or an earlier unit; remove dependent labels when removing their target. Use [] for unused nodes, removeIDs or animations and null for a genuinely unused nullable field. Omitted schema fields use native defaults; never invent properties or add null geometry keys belonging to another primitive.
    Typed 3D supports group, mesh and target-anchored text. Geometry uses exactly the keys of its selected box, sphere, cylinder, torus or tube variant. Keep spatial hierarchy, geometry, connections and label hints physically meaningful; a schema does not prove those relationships. Ordinary 2D uses a 900x560 canvas, separate text nodes and point-based directional lines/arrows. This prototype excludes bindings, parameters, expressions, operations, retained-document edits, legacy inferred mesh geometry, external assets and renderer code. Native validation and bounded transport still apply; do not claim exact physics, audio synchronization or external actions.
    """

  static let value: JSONValue = {
    let coordinate = number(-100_000, 100_000)
    let dimension = number(0, 100_000)
    let spatialDimension = number(0.001, 1_000)
    let identifier = string(pattern: "^[A-Za-z][A-Za-z0-9_.:-]{0,127}$")
    let color = string(pattern: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")
    let fill = union([color, literal("transparent")])
    let opacity = nullable(number(0, 1))
    let parent = nullable(reference("identifier"))
    let geometry: [String: JSONValue] = [
      "box": described(
        object([
          "type": literal("box"), "width": spatialDimension, "height": spatialDimension,
          "depth": spatialDimension, "chamferRadius": number(0, 500),
        ]),
        "A solid rectangular block; chamferRadius rounds its edges. It has no hollow interior."
      ),
      "sphere": described(
        object([
          "type": literal("sphere"), "radius": spatialDimension, "segments": integer(3, 64),
        ]),
        "A solid round ball with radius equal in every direction. It has no bore or cutaway opening."
      ),
      "cylinder": described(
        object([
          "type": literal("cylinder"), "radius": spatialDimension, "height": spatialDimension,
          "segments": integer(3, 64),
        ]),
        "A solid rod or disk along local +Y, with filled circular ends. It has no bore or open sector."
      ),
      "torus": described(
        object([
          "type": literal("torus"), "ringRadius": spatialDimension, "pipeRadius": spatialDimension,
          "ringSegments": integer(3, 64), "pipeSegments": integer(3, 64),
        ]),
        "A closed ring around local +Y in the XZ plane, with a circular solid cross-section and a central hole."
      ),
      "tube": described(
        object([
          "type": literal("tube"), "innerRadius": spatialDimension, "outerRadius": spatialDimension,
          "height": spatialDimension, "segments": integer(3, 64),
          "startAngleDegrees": number(-360_000, 360_000), "sweepAngleDegrees": number(1, 360),
        ]),
        "A hollow cylindrical shell along local +Y. Its bore is empty; sweepAngleDegrees below 360 also removes an angular sector. Use for a hollow shell or requested cutaway, never as a solid ball or rod."
      ),
    ]
    var definitions: [String: JSONValue] = [
      "identifier": identifier,
      "point": object(["x": coordinate, "y": coordinate]),
      "position": vector(number(-1_000, 1_000)),
      "rotation": vector(number(-360_000, 360_000)),
      "scale": vector(number(0.001, 100)),
      "transform": object([
        "position": nullable(reference("position")),
        "rotationDegrees": nullable(reference("rotation")),
        "scale": nullable(reference("scale")),
      ]),
      "anchor": object([
        "targetID": reference("identifier"), "point": reference("position"),
        "screenOffset": reference("point"), "leader": .object(["type": .string("boolean")]),
      ]),
      "geometry": union(geometry.keys.sorted().map { reference($0) }),
      "spatialGroup": object([
        "id": reference("identifier"), "kind": literal("group"), "parentID": parent,
        "spatial3D": object(["transform": nullable(reference("transform"))]),
      ]),
      "spatialMesh": object([
        "id": reference("identifier"), "kind": literal("mesh"), "parentID": parent,
        "fill": color, "opacity": opacity,
        "spatial3D": object([
          "transform": nullable(reference("transform")), "geometry": reference("geometry"),
        ]),
      ]),
      "spatialLabel": object([
        "id": reference("identifier"), "kind": literal("text"), "text": text(240, minimum: 1),
        "color": color, "width": number(1, 900), "height": number(1, 560),
        "fontSize": number(1, 256),
        "spatial3D": object(["labelAnchor": reference("anchor")]),
      ]),
      "flatGroup": object([
        "id": reference("identifier"), "kind": literal("group"), "parentID": parent,
        "x": coordinate, "y": coordinate, "rotation": coordinate,
      ]),
      "flatShape": object([
        "id": reference("identifier"), "kind": enumeration(["rectangle", "ellipse"]),
        "parentID": parent, "x": coordinate, "y": coordinate,
        "width": dimension, "height": dimension, "rotation": coordinate,
        "color": color, "fill": fill, "strokeWidth": number(0, 1_000), "opacity": opacity,
      ]),
      "flatDirection": object([
        "id": reference("identifier"), "kind": enumeration(["line", "arrow"]),
        "parentID": parent, "x": coordinate, "y": coordinate,
        "points": array(reference("point"), minimum: 2, maximum: 4_096),
        "color": color, "strokeWidth": number(0, 1_000), "opacity": opacity,
      ]),
      "flatText": object([
        "id": reference("identifier"), "kind": literal("text"), "parentID": parent,
        "x": coordinate, "y": coordinate, "width": dimension, "height": dimension,
        "text": text(4_000), "fontSize": number(1, 256), "color": color,
        "rotation": coordinate, "opacity": opacity,
      ]),
      "flatPath": object([
        "id": reference("identifier"), "kind": literal("path"), "parentID": parent,
        "x": coordinate, "y": coordinate,
        "points": array(reference("point"), maximum: 4_096),
        "subpaths": array(array(reference("point"), maximum: 1_024), maximum: 32),
        "color": color, "fill": fill, "strokeWidth": number(0, 1_000), "opacity": opacity,
      ]),
      "animation": object([
        "id": reference("identifier"), "targetID": reference("identifier"),
        "behavior": enumeration(["rotate", "pulse", "flow"]),
        "speed": number(-10_000, 10_000), "amplitude": coordinate,
        "axis3D": nullable(enumeration(["x", "y", "z"])),
      ]),
      "textUnit": object(["type": literal("text"), "text": text(8_000, minimum: 1)]),
      "sceneUnit": object([
        "type": literal("scene"), "title": nullable(text(200)),
        "nodes": array(reference("node"), maximum: 128),
        "removeIDs": array(reference("identifier"), maximum: 128),
        "animations": array(reference("animation"), maximum: 64),
      ]),
      "node": union(
        [
          "spatialGroup", "spatialMesh", "spatialLabel", "flatGroup", "flatShape", "flatDirection",
          "flatText", "flatPath",
        ].map(reference)),
    ]
    definitions.merge(geometry) { _, primitive in primitive }
    guard
      case .object(var root) = object([
        "units": array(
          union([reference("textUnit"), reference("sceneUnit")]), minimum: 1, maximum: 96)
      ])
    else { preconditionFailure("The structured explanation root must be an object.") }
    root["$defs"] = .object(definitions)
    return .object(root)
  }()

  /// Controlled alternative to the compact node union. It exposes the same
  /// native feature families through one node object with nullable unused
  /// fields. It is an experiment, not evidence that a service union caused a
  /// generation failure. The original schema remains unchanged.
  static let unifiedValue: JSONValue = {
    guard case .object(var root) = value,
      case .object(var definitions) = root["$defs"]
    else { preconditionFailure("The standalone schema needs local definitions.") }
    let coordinate = number(-100_000, 100_000)
    let color = string(pattern: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$")
    definitions["node"] = object([
      "id": reference("identifier"),
      "kind": described(
        enumeration(["rectangle", "ellipse", "line", "arrow", "text", "path", "mesh", "group"]),
        "Choose the actual native node kind. An assembly is group, a physical 3D part is mesh, and only text draws a label. Unused fields are null."
      ),
      "parentID": described(
        nullable(reference("identifier")),
        "An existing group node ID, or null when unparented. Typed 3D parents must be typed groups. Anchored text always has null parentID."
      ),
      "x": nullable(coordinate), "y": nullable(coordinate),
      "width": nullable(number(0, 100_000)), "height": nullable(number(0, 100_000)),
      "text": nullable(text(4_000)), "color": nullable(color),
      "fill": nullable(union([color, literal("transparent")])),
      "strokeWidth": nullable(number(0, 1_000)), "fontSize": nullable(number(1, 256)),
      "points": nullable(array(reference("point"), maximum: 4_096)),
      "subpaths": nullable(array(array(reference("point"), maximum: 1_024), maximum: 32)),
      "rotation": nullable(coordinate), "opacity": nullable(number(0, 1)),
      "spatial3D": described(
        nullable(reference("spatial")),
        "Null for ordinary 2D nodes. A typed group uses a transform with null geometry and labelAnchor. A mesh requires actual typed geometry with null labelAnchor. Anchored text uses labelAnchor, null geometry and null transform. This object never changes the node kind."
      ),
    ])
    definitions["spatial"] = object([
      "transform": nullable(reference("transform")),
      "geometry": nullable(reference("geometry")),
      "labelAnchor": nullable(reference("anchor")),
    ])
    for name in [
      "spatialGroup", "spatialMesh", "spatialLabel", "flatGroup", "flatShape", "flatDirection",
      "flatText", "flatPath",
    ] {
      definitions.removeValue(forKey: name)
    }
    root["$defs"] = .object(definitions)
    return .object(root)
  }()

  private static func object(_ properties: [String: JSONValue]) -> JSONValue {
    .object([
      "type": .string("object"), "properties": .object(properties),
      "required": .array(properties.keys.sorted().map(JSONValue.string)),
      "additionalProperties": .bool(false),
    ])
  }
  private static func reference(_ name: String) -> JSONValue {
    .object(["$ref": .string("#/$defs/" + name)])
  }
  private static func described(_ value: JSONValue, _ description: String) -> JSONValue {
    guard case .object(var schema) = value else {
      preconditionFailure("A schema description needs an object.")
    }
    schema["description"] = .string(description)
    return .object(schema)
  }
  private static func union(_ values: [JSONValue]) -> JSONValue {
    .object(["anyOf": .array(values)])
  }
  private static func nullable(_ value: JSONValue) -> JSONValue {
    union([value, .object(["type": .string("null")])])
  }
  private static func string(pattern: String) -> JSONValue {
    .object(["type": .string("string"), "pattern": .string(pattern)])
  }
  private static func text(_ maximum: Int, minimum: Int = 0) -> JSONValue {
    string(pattern: "^[\\s\\S]{\(minimum),\(maximum)}$")
  }
  private static func enumeration(_ values: [String]) -> JSONValue {
    .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
  }
  private static func literal(_ value: String) -> JSONValue { enumeration([value]) }
  private static func number(_ minimum: Double, _ maximum: Double) -> JSONValue {
    .object([
      "type": .string("number"), "minimum": .number(minimum), "maximum": .number(maximum),
    ])
  }
  private static func integer(_ minimum: Int, _ maximum: Int) -> JSONValue {
    .object([
      "type": .string("integer"), "minimum": .number(Double(minimum)),
      "maximum": .number(Double(maximum)),
    ])
  }
  private static func vector(_ component: JSONValue) -> JSONValue {
    object(["x": component, "y": component, "z": component])
  }
  private static func array(_ items: JSONValue, minimum: Int = 0, maximum: Int) -> JSONValue {
    .object([
      "type": .string("array"), "items": items, "minItems": .number(Double(minimum)),
      "maxItems": .number(Double(maximum)),
    ])
  }
}
