import Foundation

/// Translator for the original vendor-neutral fixture included with the research handoff.
/// This translates retained geometry and expressions; narration reveal timing is a host concern.
public enum OriginalSceneImporter {
  public static func importDocument(data: Data, revealAll: Bool = true) throws -> SceneDocument {
    guard data.count <= 2_097_152 else { throw CoreError.budgetExceeded("import bytes") }
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    guard fixture.specVersion == "open-explainer.scene/1", fixture.canvas.viewBox.count == 4,
      fixture.canvas.viewBox[0] == 0, fixture.canvas.viewBox[1] == 0
    else { throw CoreError.invalidDocument("unsupported original scene schema/canvas") }
    var nodes: [SceneNode] = []
    for source in fixture.nodes {
      let kind: SceneNode.Kind =
        switch source.kind {
        case "rect": .rectangle
        case "polyline": .line
        case "group": .group
        case "ellipse": .ellipse
        case "text": .text
        case "arrow": .arrow
        case "path": .path
        default: throw CoreError.invalidDocument("unsupported fixture primitive \(source.kind)")
        }
      let geometry = source.geometry
      var x = geometry.x ?? 0
      var y = geometry.y ?? 0
      var width = geometry.width ?? geometry.maxWidth ?? 0
      var height = geometry.height ?? 0
      if kind == .ellipse {
        let rx = geometry.rx ?? 0
        let ry = geometry.ry ?? 0
        x = (geometry.cx ?? 0) - rx
        y = (geometry.cy ?? 0) - ry
        width = rx * 2
        height = ry * 2
      }
      if let translate = geometry.translate {
        guard translate.count == 2 else { throw CoreError.invalidDocument("fixture translation") }
        x += translate[0]
        y += translate[1]
      }
      var bindings: [String: SafeExpression] = [:]
      for (key, expression) in source.bindings ?? [:] {
        let mapped =
          switch key {
          case "translate.x": "x"
          case "translate.y": "y"
          case "rotateDegrees": "rotation"
          default: key.hasPrefix("style.") ? String(key.dropFirst(6)) : key
          }
        bindings[mapped] = expression
      }
      let points = try decodePoints(geometry.points ?? [])
      let subpaths = try (geometry.subpaths ?? []).map { try decodePoints($0) }
      let color =
        kind == .text ? (source.style.fill ?? "#27382F") : (source.style.stroke ?? "#27382F")
      let fill = kind == .text ? "transparent" : source.style.fill ?? "transparent"
      nodes.append(
        SceneNode(
          id: source.id, kind: kind, x: x, y: y, width: width, height: height,
          text: geometry.text ?? "", color: color, fill: fill,
          strokeWidth: source.style.strokeWidth ?? 1,
          fontSize: source.style.size ?? 18, points: points, subpaths: subpaths,
          rotation: geometry.rotateDegrees ?? 0, opacity: revealAll ? 1 : source.style.opacity ?? 1,
          parentID: source.parent, bindings: bindings,
          accessibilityLabel: geometry.text ?? source.id))
    }
    let parameters = fixture.parameters.mapValues { value in SceneParameter(name: "", value: value)
    }
    var namedParameters: [String: SceneParameter] = [:]
    for (name, var parameter) in parameters {
      parameter.name = name
      parameter.unit = name == "angularSpeed" ? "radians/second" : ""
      if name == "angularSpeed" {
        parameter.minimum = -4
        parameter.maximum = 4
      }
      namedParameters[name] = parameter
    }
    let document = SceneDocument(
      id: fixture.id, title: fixture.window.title, width: fixture.canvas.viewBox[2],
      height: fixture.canvas.viewBox[3],
      nodes: nodes, parameters: namedParameters, expressions: fixture.expressions,
      controls: [
        .init(id: "play", label: "Pause / play", action: .playPause),
        .init(id: "replay", label: "Replay", action: .replay),
        .init(id: "step", label: "Next quarter turn", action: .step),
      ],
      notes:
        "Built-in original reference lesson. Simplified brushed DC motor with prescribed rotation; not an electromechanical dynamics simulation.",
      citations: [
        "https://openstax.org/books/university-physics-volume-2/pages/11-5-force-and-torque-on-a-current-loop"
      ])
    return try document.validated()
  }
  private static func decodePoints(_ source: [[Double]]) throws -> [Point2D] {
    try source.map { point in
      guard point.count == 2 else { throw CoreError.invalidDocument("fixture point") }
      return Point2D(x: point[0], y: point[1])
    }
  }
  private struct Fixture: Decodable {
    var specVersion, id: String
    var canvas: Canvas
    var window: Window
    var parameters: [String: Double]
    var expressions: [String: SafeExpression]
    var nodes: [Node]
  }
  private struct Canvas: Decodable { var viewBox: [Double] }
  private struct Window: Decodable { var title: String }
  private struct Node: Decodable {
    var id, kind: String
    var parent: String?
    var geometry: Geometry
    var style: Style
    var bindings: [String: SafeExpression]?
  }
  private struct Geometry: Decodable {
    var x, y, width, height, maxWidth, cx, cy, rx, ry, rotateDegrees: Double?
    var text: String?
    var translate: [Double]?
    var points: [[Double]]?
    var subpaths: [[[Double]]]?
  }
  private struct Style: Decodable {
    var fill, stroke: String?
    var strokeWidth, size, opacity: Double?
  }
}
