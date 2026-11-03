import Foundation

public enum ExpressionValue: Equatable, Sendable {
    case number(Double), boolean(Bool)
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var boolean: Bool? { if case .boolean(let value) = self { value } else { nil } }
}

/// A closed AST. It deliberately cannot evaluate source code, access files, or call native methods.
public indirect enum SafeExpression: Codable, Equatable, Sendable {
    case number(Double), boolean(Bool), reference(String), operation(Operator, [SafeExpression])
    public enum Operator: String, Codable, CaseIterable, Sendable { case add, mul, sin, cos, abs, lt, gt, select }
    private enum Keys: String, CodingKey { case ref, op, args }
    public init(from decoder: any Decoder) throws {
        let scalar = try decoder.singleValueContainer()
        if let value = try? scalar.decode(Double.self) { self = .number(value); return }
        if let value = try? scalar.decode(Bool.self) { self = .boolean(value); return }
        let container = try decoder.container(keyedBy: Keys.self)
        if let ref = try container.decodeIfPresent(String.self, forKey: .ref) {
            guard !container.contains(.op), !container.contains(.args) else {
                throw DecodingError.dataCorruptedError(forKey: .ref, in: container, debugDescription: "Expression mixes reference and operation.")
            }
            self = .reference(ref)
        } else {
            self = .operation(try container.decode(Operator.self, forKey: .op), try container.decode([Self].self, forKey: .args))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .number(let value): var scalar = encoder.singleValueContainer(); try scalar.encode(value)
        case .boolean(let value): var scalar = encoder.singleValueContainer(); try scalar.encode(value)
        case .reference(let name): var object = encoder.container(keyedBy: Keys.self); try object.encode(name, forKey: .ref)
        case .operation(let op, let args):
            var object = encoder.container(keyedBy: Keys.self); try object.encode(op, forKey: .op); try object.encode(args, forKey: .args)
        }
    }
}

public struct ExpressionLimits: Sendable {
    public var maximumDepth = 32
    public var maximumSteps = 8_192
    public var maximumExpressions = 256
    public init(maximumDepth: Int = 32, maximumSteps: Int = 8_192, maximumExpressions: Int = 256) {
        self.maximumDepth = maximumDepth; self.maximumSteps = maximumSteps; self.maximumExpressions = maximumExpressions
    }
}

public struct ExpressionEvaluator: Sendable {
    public var expressions: [String: SafeExpression]
    public var values: [String: Double]
    public var limits: ExpressionLimits
    public init(expressions: [String: SafeExpression] = [:], values: [String: Double] = [:], limits: ExpressionLimits = .init()) {
        self.expressions = expressions; self.values = values; self.limits = limits
    }
    public func evaluate(_ expression: SafeExpression) throws -> ExpressionValue {
        try evaluateMany([expression])[0]
    }
    /// A shared step budget and memoization table bounds the whole retained binding batch.
    public func evaluateMany(_ batch: [SafeExpression]) throws -> [ExpressionValue] {
        guard expressions.count <= limits.maximumExpressions else { throw CoreError.budgetExceeded("expression count") }
        var context = Context(evaluator: self)
        return try batch.map { try context.evaluate($0, depth: 0) }
    }
    /// Visits every branch, including inactive select arms, to reject cycles and ill-typed retained graphs.
    public func validate() throws {
        guard expressions.count <= limits.maximumExpressions else { throw CoreError.budgetExceeded("expression count") }
        guard Set(expressions.keys).isDisjoint(with: values.keys) else { throw CoreError.invalidExpression("expression shadows parameter") }
        var context = Context(evaluator: self)
        for name in expressions.keys.sorted() { _ = try context.evaluate(.reference(name), depth: 0) }
        for value in values.values where !value.isFinite { throw CoreError.invalidExpression("nonfinite input") }
    }
    private struct Context {
        let evaluator: ExpressionEvaluator
        var steps = 0
        var visiting = Set<String>()
        var cache: [String: ExpressionValue] = [:]
        mutating func evaluate(_ expression: SafeExpression, depth: Int) throws -> ExpressionValue {
            steps += 1
            guard depth <= evaluator.limits.maximumDepth else { throw CoreError.budgetExceeded("expression depth") }
            guard steps <= evaluator.limits.maximumSteps else { throw CoreError.budgetExceeded("expression steps") }
            switch expression {
            case .number(let value):
                guard value.isFinite else { throw CoreError.invalidExpression("nonfinite literal") }; return .number(value)
            case .boolean(let value): return .boolean(value)
            case .reference(let name):
                if let value = evaluator.values[name] {
                    guard value.isFinite else { throw CoreError.invalidExpression("nonfinite input") }; return .number(value)
                }
                if let value = cache[name] { return value }
                guard let referenced = evaluator.expressions[name] else { throw CoreError.missingReference(name) }
                guard visiting.insert(name).inserted else { throw CoreError.invalidExpression("cycle at \(name)") }
                defer { visiting.remove(name) }
                let value = try evaluate(referenced, depth: depth + 1); cache[name] = value; return value
            case .operation(let op, let args):
                let arity: Int = switch op { case .add, .mul, .lt, .gt: 2; case .sin, .cos, .abs: 1; case .select: 3 }
                let validArity = (op == .add || op == .mul) ? (2...16).contains(args.count) : args.count == arity
                guard validArity else { throw CoreError.invalidExpression("\(op.rawValue) has invalid argument count") }
                let evaluated = try args.map { try evaluate($0, depth: depth + 1) }
                if op == .select {
                    guard let condition = evaluated[0].boolean else { throw CoreError.invalidExpression("select requires boolean condition") }
                    switch (evaluated[1], evaluated[2]) {
                    case (.number, .number), (.boolean, .boolean): return evaluated[condition ? 1 : 2]
                    default: throw CoreError.invalidExpression("select arms must share a type")
                    }
                }
                let numbers = try evaluated.map { value -> Double in
                    guard let number = value.number else { throw CoreError.invalidExpression("\(op.rawValue) requires numeric arguments") }; return number
                }
                let value: Double
                switch op {
                case .lt: return .boolean(numbers[0] < numbers[1])
                case .gt: return .boolean(numbers[0] > numbers[1])
                case .add: value = numbers.reduce(0, +)
                case .mul: value = numbers.reduce(1, *)
                case .sin: value = sin(numbers[0])
                case .cos: value = cos(numbers[0])
                case .abs: value = abs(numbers[0])
                case .select: throw CoreError.invalidExpression("unreachable select")
                }
                guard value.isFinite else { throw CoreError.invalidExpression("nonfinite result") }; return .number(value)
            }
        }
    }
}
