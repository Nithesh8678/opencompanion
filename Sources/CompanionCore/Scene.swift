import Foundation

public struct SceneNode: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Hashable, CaseIterable, Sendable {
    case rectangle, ellipse, line, arrow, text, path, mesh, group
  }
  public var id: String
  public var kind: Kind
  public var x, y, width, height: Double
  public var text, color, fill: String
  public var strokeWidth, fontSize, rotation, opacity, scaleX, scaleY: Double
  public var points: [Point2D]
  public var subpaths: [[Point2D]]
  public var parentID: String?
  public var bindings: [String: SafeExpression]
  public var accessibilityLabel: String
  public var spatial3D: SceneSpatial3D?
  public init(
    id: String, kind: Kind, x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0,
    text: String = "", color: String = "#27382F", fill: String = "transparent",
    strokeWidth: Double = 2,
    fontSize: Double = 18, points: [Point2D] = [], subpaths: [[Point2D]] = [], rotation: Double = 0,
    opacity: Double = 1, scaleX: Double = 1, scaleY: Double = 1, parentID: String? = nil,
    bindings: [String: SafeExpression] = [:], accessibilityLabel: String = "",
    spatial3D: SceneSpatial3D? = nil
  ) {
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.text = text
    self.color = color
    self.fill = fill
    self.strokeWidth = strokeWidth
    self.fontSize = fontSize
    self.points = points
    self.subpaths = subpaths
    self.rotation = rotation
    self.opacity = opacity
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.parentID = parentID
    self.bindings = bindings
    self.accessibilityLabel = accessibilityLabel
    self.spatial3D = spatial3D
  }
  private enum CodingKeys: String, CodingKey {
    case id, kind, x, y, width, height, text, color, fill, strokeWidth, fontSize, points, subpaths
    case rotation, opacity, scaleX, scaleY, parentID, bindings, accessibilityLabel, spatial3D
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(String.self, forKey: .id), kind: try c.decode(Kind.self, forKey: .kind),
      x: try c.decodeIfPresent(Double.self, forKey: .x) ?? 0,
      y: try c.decodeIfPresent(Double.self, forKey: .y) ?? 0,
      width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 0,
      height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 0,
      text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
      color: try c.decodeIfPresent(String.self, forKey: .color) ?? "#27382F",
      fill: try c.decodeIfPresent(String.self, forKey: .fill) ?? "transparent",
      strokeWidth: try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 2,
      fontSize: try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18,
      points: try c.decodeIfPresent([Point2D].self, forKey: .points) ?? [],
      subpaths: try c.decodeIfPresent([[Point2D]].self, forKey: .subpaths) ?? [],
      rotation: try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0,
      opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
      scaleX: try c.decodeIfPresent(Double.self, forKey: .scaleX) ?? 1,
      scaleY: try c.decodeIfPresent(Double.self, forKey: .scaleY) ?? 1,
      parentID: try c.decodeIfPresent(String.self, forKey: .parentID),
      bindings: try c.decodeIfPresent([String: SafeExpression].self, forKey: .bindings) ?? [:],
      accessibilityLabel: try c.decodeIfPresent(String.self, forKey: .accessibilityLabel) ?? "",
      spatial3D: try c.decodeIfPresent(SceneSpatial3D.self, forKey: .spatial3D))
  }
}

public struct SceneParameter: Codable, Equatable, Sendable {
  public var name: String
  public var value, minimum, maximum: Double
  public var unit: String
  public init(
    name: String, value: Double, minimum: Double = -1_000_000, maximum: Double = 1_000_000,
    unit: String = ""
  ) {
    self.name = name
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
    self.unit = unit
  }
}

public struct SceneAnimation: Codable, Equatable, Identifiable, Sendable {
  public enum Behavior: String, Codable, Sendable { case rotate, pulse, flow }
  public var id, targetID: String
  public var behavior: Behavior
  public var speed: Double
  public var amplitude: Double
  public var axis3D: Axis3D?
  public init(
    id: String, targetID: String, behavior: Behavior = .rotate, speed: Double = 45,
    amplitude: Double = 1, axis3D: Axis3D? = nil
  ) {
    self.id = id
    self.targetID = targetID
    self.behavior = behavior
    self.speed = speed
    self.amplitude = amplitude
    self.axis3D = axis3D
  }
}

public struct SceneControl: Codable, Equatable, Identifiable, Sendable {
  public enum Action: String, Codable, Sendable { case playPause, replay, step, setParameter }
  public var id, label: String
  public var action: Action
  public var parameter: String?
  public var value: Double?
  public init(
    id: String, label: String, action: Action, parameter: String? = nil, value: Double? = nil
  ) {
    self.id = id
    self.label = label
    self.action = action
    self.parameter = parameter
    self.value = value
  }
}

public struct SceneLimits: Sendable {
  public var maximumNodes = 1_024
  public var maximumPoints = 32_768
  public var maximumTextBytes = 128_000
  public var maximumDepth = 32
  public var maximumOperations = 2_048
  public var maximumCoordinate = 100_000.0
  public var maximumSpatialNodes = 128
  public var maximumSpatialVertices = 32_768
  public var maximumSpatialTriangles = 65_536
  public var maximumSpatialSegments = 64
  public var maximumSpatialDimension = 1_000.0
  public init() {}
}

public struct SceneDocument: Codable, Equatable, Identifiable, Sendable {
  public static let schemaVersion = "opencompanion.scene/1"
  public static let spatialSchemaVersion = "opencompanion.scene/2"
  public var id, title: String
  public var revision: Int
  public var width, height: Double
  public var nodes: [SceneNode]
  public var parameters: [String: SceneParameter]
  public var expressions: [String: SafeExpression]
  public var animations: [SceneAnimation]
  public var controls: [SceneControl]
  public var notes: String
  public var citations: [String]
  public init(
    id: String = UUID().uuidString, title: String = "Untitled lesson", revision: Int = 0,
    width: Double = 1_000, height: Double = 680, nodes: [SceneNode] = [],
    parameters: [String: SceneParameter] = [:],
    expressions: [String: SafeExpression] = [:], animations: [SceneAnimation] = [],
    controls: [SceneControl] = [],
    notes: String = "", citations: [String] = []
  ) {
    self.id = id
    self.title = title
    self.revision = revision
    self.width = width
    self.height = height
    self.nodes = nodes
    self.parameters = parameters
    self.expressions = expressions
    self.animations = animations
    self.controls = controls
    self.notes = notes
    self.citations = citations
  }
  private enum CodingKeys: String, CodingKey {
    case specVersion, id, title, revision, width, height, nodes, parameters, expressions,
      animations, controls, notes, citations
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decodeIfPresent(String.self, forKey: .specVersion)
    if let version, ![Self.schemaVersion, Self.spatialSchemaVersion].contains(version) {
      throw CoreError.invalidDocument("unsupported schema \(version)")
    }
    self.init(
      id: try c.decode(String.self, forKey: .id),
      title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled lesson",
      revision: try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0,
      width: try c.decodeIfPresent(Double.self, forKey: .width) ?? 1_000,
      height: try c.decodeIfPresent(Double.self, forKey: .height) ?? 680,
      nodes: try c.decode([SceneNode].self, forKey: .nodes),
      parameters: try c.decodeIfPresent([String: SceneParameter].self, forKey: .parameters) ?? [:],
      expressions: try c.decodeIfPresent([String: SafeExpression].self, forKey: .expressions)
        ?? [:],
      animations: try c.decodeIfPresent([SceneAnimation].self, forKey: .animations) ?? [],
      controls: try c.decodeIfPresent([SceneControl].self, forKey: .controls) ?? [],
      notes: try c.decodeIfPresent(String.self, forKey: .notes) ?? "",
      citations: try c.decodeIfPresent([String].self, forKey: .citations) ?? [])
    if usesSpatial3D, version != Self.spatialSchemaVersion {
      throw CoreError.invalidDocument("typed 3D requires scene schema version 2")
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(
      usesSpatial3D ? Self.spatialSchemaVersion : Self.schemaVersion, forKey: .specVersion)
    try c.encode(id, forKey: .id)
    try c.encode(title, forKey: .title)
    try c.encode(revision, forKey: .revision)
    try c.encode(width, forKey: .width)
    try c.encode(height, forKey: .height)
    try c.encode(nodes, forKey: .nodes)
    try c.encode(parameters, forKey: .parameters)
    try c.encode(expressions, forKey: .expressions)
    try c.encode(animations, forKey: .animations)
    try c.encode(controls, forKey: .controls)
    try c.encode(notes, forKey: .notes)
    try c.encode(citations, forKey: .citations)
  }

  @discardableResult public func validated(limits: SceneLimits = .init()) throws -> Self {
    guard !id.isEmpty, id.utf8.count <= 256, !title.isEmpty, revision >= 0, width.isFinite,
      height.isFinite, width > 0, height > 0,
      width <= limits.maximumCoordinate, height <= limits.maximumCoordinate
    else { throw CoreError.invalidDocument("identity or canvas bounds") }
    guard nodes.count <= limits.maximumNodes, parameters.count <= 256, animations.count <= 256,
      controls.count <= 256
    else { throw CoreError.budgetExceeded("scene count") }
    guard
      title.utf8.count + notes.utf8.count + citations.joined().utf8.count
        + nodes.reduce(0, { $0 + $1.text.utf8.count + $1.accessibilityLabel.utf8.count })
        <= limits.maximumTextBytes
    else { throw CoreError.budgetExceeded("text bytes") }
    guard
      nodes.reduce(0, { $0 + $1.points.count + $1.subpaths.reduce(0) { $0 + $1.count } })
        <= limits.maximumPoints
    else { throw CoreError.budgetExceeded("vertices") }
    var lookup: [String: SceneNode] = [:]
    for node in nodes {
      guard !node.id.isEmpty, node.id.utf8.count <= 256 else {
        throw CoreError.invalidDocument("node identifier")
      }
      guard lookup.updateValue(node, forKey: node.id) == nil else {
        throw CoreError.duplicateID(node.id)
      }
      let numbers = [
        node.x, node.y, node.width, node.height, node.rotation, node.strokeWidth, node.fontSize,
        node.opacity, node.scaleX, node.scaleY,
      ]
      guard numbers.allSatisfy({ $0.isFinite && abs($0) <= limits.maximumCoordinate }),
        node.width >= 0, node.height >= 0,
        node.strokeWidth >= 0, node.fontSize >= 1, node.fontSize <= 256,
        (0...1).contains(node.opacity)
      else { throw CoreError.invalidDocument("geometry for \(node.id)") }
      guard
        node.points.allSatisfy({
          $0.isFinite && abs($0.x) <= limits.maximumCoordinate
            && abs($0.y) <= limits.maximumCoordinate
        }),
        node.subpaths.joined().allSatisfy({
          $0.isFinite && abs($0.x) <= limits.maximumCoordinate
            && abs($0.y) <= limits.maximumCoordinate
        })
      else { throw CoreError.invalidDocument("points for \(node.id)") }
      guard Self.validColor(node.color), Self.validColor(node.fill) else {
        throw CoreError.invalidDocument("literal hex color required")
      }
    }
    for node in nodes {
      var current = node
      var visited: Set<String> = [node.id]
      var depth = 0
      while let parentID = current.parentID {
        guard let parent = lookup[parentID] else { throw CoreError.missingReference(parentID) }
        guard parent.kind == .group else { throw CoreError.invalidDocument("parent must be group") }
        guard visited.insert(parentID).inserted else {
          throw CoreError.invalidDocument("parent cycle")
        }
        depth += 1
        guard depth <= limits.maximumDepth else { throw CoreError.budgetExceeded("scene depth") }
        current = parent
      }
    }
    for (name, parameter) in parameters {
      guard name == parameter.name, !name.isEmpty, name.utf8.count <= 256,
        parameter.unit.utf8.count <= 64, name != "time", name != "theta",
        [parameter.value, parameter.minimum, parameter.maximum].allSatisfy(\.isFinite),
        parameter.minimum <= parameter.maximum,
        (parameter.minimum...parameter.maximum).contains(parameter.value)
      else { throw CoreError.invalidDocument("parameter \(name)") }
    }
    guard expressions.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
      throw CoreError.invalidExpression("expression identifier")
    }
    let evaluator = expressionEvaluator(at: 0)
    try evaluator.validate()
    var boundExpressions: [SafeExpression] = []
    for node in nodes {
      guard node.bindings.count <= 32 else { throw CoreError.budgetExceeded("node bindings") }
      for (property, expression) in node.bindings {
        guard Self.bindingIsValid(property, node: node) else {
          throw CoreError.invalidDocument("unsupported binding \(property)")
        }
        boundExpressions.append(expression)
      }
    }
    guard try evaluator.evaluateMany(boundExpressions).allSatisfy({ $0.number != nil }) else {
      throw CoreError.invalidExpression("numeric binding required")
    }
    _ = try resolvedNodes(at: 0)
    try validateSpatial3D(limits: limits)
    var animationIDs = Set<String>()
    var spatialFlowAmplitudes: [String: Double] = [:]
    for animation in animations {
      guard !animation.id.isEmpty, animation.id.utf8.count <= 256 else {
        throw CoreError.invalidDocument("animation identifier")
      }
      guard animationIDs.insert(animation.id).inserted else {
        throw CoreError.duplicateID(animation.id)
      }
      guard lookup[animation.targetID] != nil else {
        throw CoreError.missingReference(animation.targetID)
      }
      if animation.axis3D != nil {
        guard animation.behavior == .rotate, let target = lookup[animation.targetID],
          target.spatial3D != nil, [.mesh, .group].contains(target.kind)
        else { throw CoreError.invalidDocument("3D animation axis target") }
      }
      guard animation.speed.isFinite, animation.amplitude.isFinite, abs(animation.speed) <= 10_000,
        abs(animation.amplitude) <= limits.maximumCoordinate
      else { throw CoreError.invalidDocument("animation range") }
      if animation.behavior == .flow, let target = lookup[animation.targetID],
        let spatial = target.spatial3D, [.mesh, .group].contains(target.kind)
      {
        let amplitude = (spatialFlowAmplitudes[target.id] ?? 0) + abs(animation.amplitude)
        guard target.bindings["spatial3D.transform.position.x"] == nil,
          abs(spatial.transform.position.x) + amplitude <= 1_000
        else { throw CoreError.invalidDocument("3D flow range or position binding") }
        spatialFlowAmplitudes[target.id] = amplitude
      }
    }
    var controlIDs = Set<String>()
    for control in controls {
      guard !control.id.isEmpty, control.id.utf8.count <= 256, control.label.utf8.count <= 1_024
      else { throw CoreError.invalidDocument("control identifier/label") }
      guard controlIDs.insert(control.id).inserted else { throw CoreError.duplicateID(control.id) }
      if control.action == .setParameter {
        guard let name = control.parameter, let parameter = parameters[name],
          let value = control.value,
          value.isFinite, (parameter.minimum...parameter.maximum).contains(value)
        else { throw CoreError.invalidDocument("control parameter") }
      }
    }
    return self
  }

  public func expressionEvaluator(at time: Double) -> ExpressionEvaluator {
    var values = parameters.mapValues(\.value)
    values["time"] = time
    values["theta"] = time * (parameters["angularSpeed"]?.value ?? .pi / 4)
    return ExpressionEvaluator(expressions: expressions, values: values)
  }
  /// Resolves only retained numeric properties. The retained document remains unchanged.
  public func resolvedNodes(at time: Double) throws -> [SceneNode] {
    guard time.isFinite, time >= 0 else { throw CoreError.invalidDocument("animation time") }
    let evaluator = expressionEvaluator(at: time)
    let properties = nodes.map { $0.bindings.keys.sorted() }
    let values = try evaluator.evaluateMany(
      zip(nodes, properties).flatMap { node, properties in
        properties.compactMap { node.bindings[$0] }
      })
    var valueIndex = 0
    return try zip(nodes, properties).map { original, boundProperties in
      var node = original
      for property in boundProperties {
        guard let value = values[valueIndex].number, value.isFinite else {
          throw CoreError.invalidExpression("binding result")
        }
        valueIndex += 1
        try node.setBoundProperty(property, value: value)
      }
      for animation in animations where animation.targetID == node.id {
        guard animation.speed.isFinite, animation.amplitude.isFinite else {
          throw CoreError.invalidDocument("animation values")
        }
        switch animation.behavior {
        case .rotate:
          let amount = Self.boundedPhase(time: time, speed: animation.speed, period: 360)
          if var spatial = node.spatial3D, [.mesh, .group].contains(node.kind) {
            switch animation.axis3D ?? .y {
            case .x:
              spatial.transform.rotationDegrees.x = (spatial.transform.rotationDegrees.x + amount)
                .truncatingRemainder(dividingBy: 360)
            case .y:
              spatial.transform.rotationDegrees.y = (spatial.transform.rotationDegrees.y + amount)
                .truncatingRemainder(dividingBy: 360)
            case .z:
              spatial.transform.rotationDegrees.z = (spatial.transform.rotationDegrees.z + amount)
                .truncatingRemainder(dividingBy: 360)
            }
            node.spatial3D = spatial
          } else {
            node.rotation = (node.rotation + amount).truncatingRemainder(dividingBy: 360)
          }
        case .pulse:
          node.opacity *=
            0.6 + 0.4 * sin(Self.boundedPhase(time: time, speed: animation.speed, period: .pi * 2))
        case .flow:
          let amount =
            sin(Self.boundedPhase(time: time, speed: animation.speed, period: .pi * 2))
            * animation.amplitude
          if node.spatial3D != nil, [.mesh, .group].contains(node.kind) {
            node.spatial3D?.transform.position.x += amount
          } else {
            node.x += amount
          }
        }
      }
      return node
    }
  }
  private static func boundedPhase(time: Double, speed: Double, period: Double) -> Double {
    guard speed != 0 else { return 0 }
    return time.truncatingRemainder(dividingBy: period / abs(speed)) * speed
  }
  private static func validColor(_ value: String) -> Bool {
    value == "transparent"
      || ((value.count == 7 || value.count == 9) && value.first == "#"
        && value.dropFirst().allSatisfy(\.isHexDigit))
  }
  private static func bindingIsValid(_ property: String, node: SceneNode) -> Bool {
    if property.hasPrefix("spatial3D.") {
      let pieces = property.split(separator: ".")
      return node.spatial3D != nil && [.mesh, .group].contains(node.kind)
        && pieces.count == 4 && pieces[1] == "transform"
        && ["position", "rotationDegrees", "scale"].contains(String(pieces[2]))
        && ["x", "y", "z"].contains(String(pieces[3]))
    }
    if ["x", "y", "width", "height", "rotation", "opacity", "scaleX", "scaleY"].contains(property) {
      return true
    }
    let parts = property.split(separator: ".")
    return parts.count == 3 && parts[0] == "points"
      && Int(parts[1]).map { node.points.indices.contains($0) } == true
      && ["x", "y"].contains(String(parts[2]))
  }
}

extension SceneNode {
  fileprivate mutating func setBoundProperty(_ property: String, value: Double) throws {
    if property.hasPrefix("spatial3D.") {
      let pieces = property.split(separator: ".")
      guard value.isFinite, pieces.count == 4, pieces[1] == "transform", var spatial = spatial3D,
        [.mesh, .group].contains(kind), ["x", "y", "z"].contains(String(pieces[3]))
      else { throw CoreError.invalidExpression("3D binding property") }
      var vector: Vector3D
      switch pieces[2] {
      case "position":
        guard abs(value) <= 1_000 else {
          throw CoreError.invalidExpression("3D position binding range")
        }
        vector = spatial.transform.position
      case "rotationDegrees":
        vector = spatial.transform.rotationDegrees
      case "scale":
        guard (0.001...100).contains(value) else {
          throw CoreError.invalidExpression("3D scale binding range")
        }
        vector = spatial.transform.scale
      default: throw CoreError.invalidExpression("3D binding field")
      }
      let assigned =
        pieces[2] == "rotationDegrees" ? value.truncatingRemainder(dividingBy: 360) : value
      switch pieces[3] {
      case "x": vector.x = assigned
      case "y": vector.y = assigned
      default: vector.z = assigned
      }
      switch pieces[2] {
      case "position": spatial.transform.position = vector
      case "rotationDegrees": spatial.transform.rotationDegrees = vector
      default: spatial.transform.scale = vector
      }
      spatial3D = spatial
      return
    }
    if property == "rotation" {
      guard value.isFinite else { throw CoreError.invalidExpression("rotation must be finite") }
      rotation = value.truncatingRemainder(dividingBy: 360)
      return
    }
    guard abs(value) <= 100_000 else { throw CoreError.invalidExpression("binding out of bounds") }
    switch property {
    case "x": x = value
    case "y": y = value
    case "width":
      guard value >= 0 else { throw CoreError.invalidExpression("negative width") }
      width = value
    case "height":
      guard value >= 0 else { throw CoreError.invalidExpression("negative height") }
      height = value
    case "rotation": rotation = value
    case "opacity":
      guard (0...1).contains(value) else {
        throw CoreError.invalidExpression("opacity out of range")
      }
      opacity = value
    case "scaleX": scaleX = value
    case "scaleY": scaleY = value
    default:
      let parts = property.split(separator: ".")
      guard parts.count == 3, parts[0] == "points", let index = Int(parts[1]),
        points.indices.contains(index)
      else { throw CoreError.invalidExpression("unknown property") }
      if parts[2] == "x" {
        points[index].x = value
      } else if parts[2] == "y" {
        points[index].y = value
      } else {
        throw CoreError.invalidExpression("unknown point property")
      }
    }
  }
}
