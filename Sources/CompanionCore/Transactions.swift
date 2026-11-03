import Foundation

/// Explicit writable fields prevent model-authored patches from crossing the renderer boundary.
public struct ScenePatch: Codable, Equatable, Sendable {
    public var x, y, width, height, rotation, opacity, scaleX, scaleY, fontSize, strokeWidth: Double?
    public var text, color, fill, accessibilityLabel: String?
    public var points: [Point2D]?
    public var bindings: [String: SafeExpression]?
    public init(x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil, rotation: Double? = nil,
                opacity: Double? = nil, scaleX: Double? = nil, scaleY: Double? = nil, fontSize: Double? = nil,
                strokeWidth: Double? = nil, text: String? = nil, color: String? = nil, fill: String? = nil,
                accessibilityLabel: String? = nil, points: [Point2D]? = nil, bindings: [String: SafeExpression]? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation; self.opacity = opacity
        self.scaleX = scaleX; self.scaleY = scaleY; self.fontSize = fontSize; self.strokeWidth = strokeWidth
        self.text = text; self.color = color; self.fill = fill; self.accessibilityLabel = accessibilityLabel; self.points = points; self.bindings = bindings
    }
    fileprivate func apply(to node: inout SceneNode) {
        if let x { node.x = x }; if let y { node.y = y }; if let width { node.width = width }; if let height { node.height = height }
        if let rotation { node.rotation = rotation }; if let opacity { node.opacity = opacity }; if let scaleX { node.scaleX = scaleX }; if let scaleY { node.scaleY = scaleY }
        if let fontSize { node.fontSize = fontSize }; if let strokeWidth { node.strokeWidth = strokeWidth }
        if let text { node.text = text }; if let color { node.color = color }; if let fill { node.fill = fill }
        if let accessibilityLabel { node.accessibilityLabel = accessibilityLabel }; if let points { node.points = points }; if let bindings { node.bindings = bindings }
    }
}

public enum SceneOperation: Codable, Equatable, Sendable {
    case create(SceneNode), patch(id: String, fields: ScenePatch), remove(id: String)
    case defineParameter(SceneParameter), setParameter(name: String, value: Double)
    case defineExpression(name: String, expression: SafeExpression), defineAnimation(SceneAnimation), defineControl(SceneControl)
    private enum Keys: String, CodingKey { case op, node, id, fields, parameter, name, value, expression, animation, control }
    private enum Kind: String, Codable { case create = "node.create", patch = "node.patch", remove = "node.remove", defineParameter = "parameter.define", setParameter = "parameter.set", defineExpression = "expression.define", defineAnimation = "animation.define", defineControl = "control.define" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .op) {
        case .create: self = .create(try c.decode(SceneNode.self, forKey: .node))
        case .patch: self = .patch(id: try c.decode(String.self, forKey: .id), fields: try c.decode(ScenePatch.self, forKey: .fields))
        case .remove: self = .remove(id: try c.decode(String.self, forKey: .id))
        case .defineParameter: self = .defineParameter(try c.decode(SceneParameter.self, forKey: .parameter))
        case .setParameter: self = .setParameter(name: try c.decode(String.self, forKey: .name), value: try c.decode(Double.self, forKey: .value))
        case .defineExpression: self = .defineExpression(name: try c.decode(String.self, forKey: .name), expression: try c.decode(SafeExpression.self, forKey: .expression))
        case .defineAnimation: self = .defineAnimation(try c.decode(SceneAnimation.self, forKey: .animation))
        case .defineControl: self = .defineControl(try c.decode(SceneControl.self, forKey: .control))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .create(let node): try c.encode(Kind.create, forKey: .op); try c.encode(node, forKey: .node)
        case .patch(let id, let fields): try c.encode(Kind.patch, forKey: .op); try c.encode(id, forKey: .id); try c.encode(fields, forKey: .fields)
        case .remove(let id): try c.encode(Kind.remove, forKey: .op); try c.encode(id, forKey: .id)
        case .defineParameter(let parameter): try c.encode(Kind.defineParameter, forKey: .op); try c.encode(parameter, forKey: .parameter)
        case .setParameter(let name, let value): try c.encode(Kind.setParameter, forKey: .op); try c.encode(name, forKey: .name); try c.encode(value, forKey: .value)
        case .defineExpression(let name, let expression): try c.encode(Kind.defineExpression, forKey: .op); try c.encode(name, forKey: .name); try c.encode(expression, forKey: .expression)
        case .defineAnimation(let animation): try c.encode(Kind.defineAnimation, forKey: .op); try c.encode(animation, forKey: .animation)
        case .defineControl(let control): try c.encode(Kind.defineControl, forKey: .op); try c.encode(control, forKey: .control)
        }
    }
}

public struct SceneTransaction: Codable, Equatable, Identifiable, Sendable {
    public var transactionID: String
    public var surfaceID: String?
    public var baseDocumentRevision: Int
    public var requiresNodeIDs: [String]
    public var operations: [SceneOperation]
    public var id: String { transactionID }
    public init(baseDocumentRevision: Int, operations: [SceneOperation], transactionID: String = UUID().uuidString,
                surfaceID: String? = nil, requiresNodeIDs: [String] = []) {
        self.transactionID = transactionID; self.surfaceID = surfaceID; self.baseDocumentRevision = baseDocumentRevision
        self.requiresNodeIDs = requiresNodeIDs; self.operations = operations
    }
    private enum CodingKeys: String, CodingKey { case transactionID, surfaceID, baseDocumentRevision, requiresNodeIDs, operations }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(baseDocumentRevision: try c.decode(Int.self, forKey: .baseDocumentRevision), operations: try c.decode([SceneOperation].self, forKey: .operations),
                  transactionID: try c.decode(String.self, forKey: .transactionID), surfaceID: try c.decodeIfPresent(String.self, forKey: .surfaceID),
                  requiresNodeIDs: try c.decodeIfPresent([String].self, forKey: .requiresNodeIDs) ?? [])
    }
}

extension SceneDocument {
    /// A value copy is fully validated before it is returned. The receiver is never partially mutated.
    public func applying(_ transaction: SceneTransaction, limits: SceneLimits = .init()) throws -> Self {
        guard transaction.baseDocumentRevision == revision else { throw CoreError.revisionConflict(expected: revision, received: transaction.baseDocumentRevision) }
        guard transaction.surfaceID == nil || transaction.surfaceID == id else { throw CoreError.invalidDocument("wrong surface") }
        guard !transaction.transactionID.isEmpty, transaction.transactionID.utf8.count <= 256, !transaction.operations.isEmpty,
              transaction.requiresNodeIDs.count <= limits.maximumNodes,
              transaction.operations.count <= limits.maximumOperations else { throw CoreError.budgetExceeded("transaction operations") }
        for id in transaction.requiresNodeIDs where !nodes.contains(where: { $0.id == id }) { throw CoreError.missingReference(id) }
        var result = self
        for operation in transaction.operations {
            switch operation {
            case .create(let node):
                guard !result.nodes.contains(where: { $0.id == node.id }) else { throw CoreError.duplicateID(node.id) }
                result.nodes.append(node)
            case .patch(let id, let fields):
                guard let index = result.nodes.firstIndex(where: { $0.id == id }) else { throw CoreError.missingReference(id) }
                fields.apply(to: &result.nodes[index])
            case .remove(let id):
                guard result.nodes.contains(where: { $0.id == id }) else { throw CoreError.missingReference(id) }
                var deleted: Set<String> = [id]
                for _ in 0...limits.maximumDepth {
                    let children = result.nodes.filter { $0.parentID.map { deleted.contains($0) } ?? false }.map(\.id)
                    let previous = deleted.count; deleted.formUnion(children); if previous == deleted.count { break }
                }
                result.nodes.removeAll { deleted.contains($0.id) }
                result.animations.removeAll { deleted.contains($0.targetID) }
            case .defineParameter(let parameter):
                guard result.parameters[parameter.name] == nil else { throw CoreError.duplicateID(parameter.name) }
                result.parameters[parameter.name] = parameter
            case .setParameter(let name, let value):
                guard result.parameters[name] != nil else { throw CoreError.missingReference(name) }; result.parameters[name]?.value = value
            case .defineExpression(let name, let expression):
                guard result.expressions[name] == nil else { throw CoreError.duplicateID(name) }; result.expressions[name] = expression
            case .defineAnimation(let animation): result.animations.append(animation)
            case .defineControl(let control): result.controls.append(control)
            }
        }
        guard revision < Int.max else { throw CoreError.invalidDocument("revision exhausted") }
        result.revision += 1
        return try result.validated(limits: limits)
    }
}
