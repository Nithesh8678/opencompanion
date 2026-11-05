import CompanionCore
import Foundation

/// Compiles only the bundled, fixed-role spatial-stage format. No callbacks,
/// document mutation, model calls, external schemas or executable content.
enum StructuredSpatialStageCompiler {
  struct Stage: Sendable {
    let scene: ProviderUnit
    let text: ProviderUnit
  }
  static let maximumStageBytes = 262_144
  static let maximumTextBytes = 32_000
  static let maximumNesting = 32

  private struct Bundle: Sendable {
    let definitions: [String: JSONValue]
    let step: JSONValue
  }
  private static let bundle: Bundle = {
    guard case .object(let root) = StructuredSpatialStageSchema.value,
      case .object(let definitions) = root["$defs"], let step = definitions["step"]
    else { preconditionFailure("The bundled spatial-stage schema is incomplete.") }
    return .init(definitions: definitions, step: step)
  }()

  static func compile(_ data: Data) throws -> Stage {
    try Task.checkCancellation()
    guard !data.isEmpty, data.count <= maximumStageBytes else {
      throw invalid("A stage exceeds its byte bound or is empty.")
    }
    try rejectDuplicateKeys(data)
    let value: JSONValue
    do { value = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
      throw invalid("A stage is not valid JSON.")
    }
    guard case .object(let step) = value, case .string(let text) = step["text"],
      !text.isEmpty, text.utf8.count <= maximumTextBytes
    else { throw invalid("Narration must be nonempty and at most 32000 UTF-8 bytes.") }
    var validator = Validator(definitions: bundle.definitions)
    do {
      try validator.check(value, schema: bundle.step)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ProviderError {
      throw error
    } catch {
      throw invalid("A required field, nested key, type or value violates the bundled format.")
    }
    try Task.checkCancellation()

    var nodes: [JSONValue] = []
    var nodeIDs = Set<String>()
    for (role, kind) in [("groups", "group"), ("parts", "mesh"), ("labels", "text")] {
      guard case .array(let proposals) = step[role] else {
        throw invalid("A required role array is missing.")
      }
      for proposal in proposals {
        try Task.checkCancellation()
        guard case .object(let fields) = proposal else {
          throw invalid("A role entry must be an object.")
        }
        guard case .string(let id) = fields["id"], nodeIDs.insert(id).inserted else {
          throw invalid("Node IDs must be unique across all role arrays in a stage.")
        }
        var node: [String: JSONValue] = ["id": fields["id"]!, "kind": .string(kind)]
        if role == "labels" {
          for key in ["text", "color", "width", "height", "fontSize"] { node[key] = fields[key] }
          node["spatial3D"] = .object(["labelAnchor": fields["labelAnchor"]!])
        } else {
          node["parentID"] = fields["parentID"]
          var spatial = ["transform": fields["transform"]!]
          if role == "parts" {
            node["fill"] = fields["fill"]
            node["opacity"] = fields["opacity"]
            spatial["geometry"] = fields["geometry"]
          }
          node["spatial3D"] = .object(spatial)
        }
        nodes.append(.object(node))
      }
    }
    if case .array(let animations) = step["animations"] {
      var ids = Set<String>()
      for animation in animations {
        guard case .object(let fields) = animation, case .string(let id) = fields["id"],
          ids.insert(id).inserted
        else { throw invalid("Animation IDs must be unique within a stage.") }
      }
    }
    if case .array(let removals) = step["removeIDs"] {
      var ids = Set<String>()
      for removal in removals {
        guard case .string(let id) = removal, ids.insert(id).inserted else {
          throw invalid("removeIDs must be unique within a stage.")
        }
      }
      // IDs intentionally removed then recreated may also occur in nodes.
    }
    let sceneValue = JSONValue.object([
      "type": .string("scene"), "title": step["title"]!, "nodes": .array(nodes),
      "animations": step["animations"]!, "removeIDs": step["removeIDs"]!,
    ])
    let scene: ProviderUnit
    let narration: ProviderUnit
    do {
      scene = try sceneValue.decoded(as: ProviderUnit.self)
      narration = try JSONValue.object(["type": .string("text"), "text": .string(text)]).decoded(
        as: ProviderUnit.self)
    } catch { throw invalid("A stage did not decode to the native scene protocol.") }
    try Task.checkCancellation()
    return .init(scene: scene, text: narration)
  }

  /// JSONDecoder tolerates duplicate keys. Detect them in every raw object,
  /// including escaped spellings, before decoding loses that information.
  private static func rejectDuplicateKeys(_ data: Data) throws {
    struct Frame {
      let opening: UInt8
      var expectingKey = true
      var keys = Set<String>()
    }
    let bytes = Array(data)
    var stack: [Frame] = []
    var inString = false
    var escaped = false
    var keyStart: Int?
    var began = false
    var closed = false
    for (index, byte) in bytes.enumerated() {
      if index & 4_095 == 0 { try Task.checkCancellation() }
      if inString {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          inString = false
          if let start = keyStart {
            let key: String
            do {
              key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
            } catch {
              throw invalid("An object key is invalid JSON.")
            }
            guard !stack.isEmpty, stack[stack.count - 1].keys.insert(key).inserted else {
              throw invalid("Duplicate object keys are forbidden.")
            }
            stack[stack.count - 1].expectingKey = false
            keyStart = nil
          }
        }
        continue
      }
      if whitespace(byte) { continue }
      guard !closed else { throw invalid("Trailing content after a stage is forbidden.") }
      if !began {
        guard byte == 123 else { throw invalid("A stage must be one object.") }
        began = true
      }
      switch byte {
      case 34:
        inString = true
        if let top = stack.last, top.opening == 123, top.expectingKey { keyStart = index }
      case 123, 91:
        guard stack.count < maximumNesting else {
          throw invalid("Stage nesting exceeds its bound.")
        }
        stack.append(.init(opening: byte))
      case 125, 93:
        guard stack.last?.opening == (byte == 125 ? 123 : 91) else {
          throw invalid("Stage object and array delimiters do not match.")
        }
        stack.removeLast()
        if stack.isEmpty { closed = true }
      case 44:
        if stack.last?.opening == 123 { stack[stack.count - 1].expectingKey = true }
      default: break
      }
    }
    guard began, closed, !inString, stack.isEmpty else { throw invalid("A stage was truncated.") }
  }

  /// Interprets only the immutable bundled schema's small supported subset.
  /// It never accepts a caller-supplied schema or resolves an external ref.
  private struct Validator {
    let definitions: [String: JSONValue]
    private var visits = 0
    init(definitions: [String: JSONValue]) { self.definitions = definitions }

    mutating func check(_ value: JSONValue, schema: JSONValue, depth: Int = 0) throws {
      visits += 1
      guard depth <= 32, visits <= 16_384 else {
        throw invalid("Validation work exceeds its bound.")
      }
      if visits & 255 == 0 { try Task.checkCancellation() }
      guard case .object(let rule) = schema else { throw invalid("The bundled schema is invalid.") }
      let allowed: Set<String> = [
        "$ref", "anyOf", "type", "enum", "pattern", "minimum", "maximum", "properties",
        "required", "additionalProperties", "items", "minItems", "maxItems", "description",
      ]
      guard Set(rule.keys).isSubset(of: allowed) else {
        throw invalid("An unsupported bundled schema rule was encountered.")
      }
      if case .string(let reference) = rule["$ref"] {
        guard reference.hasPrefix("#/$defs/"),
          let target = definitions[String(reference.dropFirst(8))]
        else {
          throw invalid("Only known local schema references are permitted.")
        }
        try check(value, schema: target, depth: depth + 1)
        return
      }
      if case .array(let branches) = rule["anyOf"] {
        for branch in branches {
          do {
            try check(value, schema: branch, depth: depth + 1)
            return
          } catch Mismatch.value {}
        }
        throw Mismatch.value
      }
      if case .array(let values) = rule["enum"], !values.contains(value) { throw Mismatch.value }
      switch (rule["type"], value) {
      case (.string("null"), .null), (.string("boolean"), .bool): return
      case (.string("string"), .string(let string)):
        if case .string(let pattern) = rule["pattern"],
          string.range(of: pattern, options: .regularExpression) == nil
        {
          throw Mismatch.value
        }
      case (.string(let type), .number(let number)) where type == "number" || type == "integer":
        guard number.isFinite, type != "integer" || number.rounded() == number else {
          throw Mismatch.value
        }
        if case .number(let minimum) = rule["minimum"], number < minimum { throw Mismatch.value }
        if case .number(let maximum) = rule["maximum"], number > maximum { throw Mismatch.value }
      case (.string("object"), .object(let fields)):
        guard case .object(let properties) = rule["properties"],
          case .array(let required) = rule["required"],
          rule["additionalProperties"] == .bool(false), properties.count == required.count,
          Set(properties.keys) == Set(fields.keys)
        else { throw Mismatch.value }
        let requiredNames = required.compactMap {
          if case .string(let key) = $0 { key } else { nil }
        }
        guard Set(requiredNames) == Set(properties.keys), requiredNames.count == required.count
        else {
          throw invalid("A bundled object must require all its properties.")
        }
        for key in properties.keys.sorted() {
          try check(fields[key]!, schema: properties[key]!, depth: depth + 1)
        }
      case (.string("array"), .array(let items)):
        guard let itemRule = rule["items"], case .number(let minimum) = rule["minItems"],
          case .number(let maximum) = rule["maxItems"], Double(items.count) >= minimum,
          Double(items.count) <= maximum
        else { throw Mismatch.value }
        for item in items { try check(item, schema: itemRule, depth: depth + 1) }
      default: throw Mismatch.value
      }
    }
    private enum Mismatch: Error { case value }
  }

  private static func whitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13
  }
  private static func invalid(_ detail: String) -> ProviderError {
    .message("Invalid structured spatial stage. " + detail)
  }
}
