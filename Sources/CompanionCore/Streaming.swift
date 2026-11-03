import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
    public func decoded<T: Decodable>(as type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

public struct StreamEnvelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case turnStarted = "turn.started", surfaceCreate = "surface.create", sceneTransaction = "scene.transaction"
        case beatCommit = "beat.commit", interactionWait = "interaction.wait", toolRequest = "tool.request"
        case turnCompleted = "turn.completed", turnError = "turn.error"
    }
    public var protocolVersion: String
    public var sessionID, turnID, eventID: String
    public var taskGeneration, sequence: Int
    public var kind: Kind
    public var payload: JSONValue
    public init(sessionID: String, turnID: String, taskGeneration: Int, sequence: Int, eventID: String = UUID().uuidString,
                kind: Kind, payload: JSONValue = .object([:])) {
        protocolVersion = "opencompanion.stream/1"; self.sessionID = sessionID; self.turnID = turnID; self.taskGeneration = taskGeneration
        self.sequence = sequence; self.eventID = eventID; self.kind = kind; self.payload = payload
    }
    public func validated() throws -> Self {
        guard protocolVersion == "opencompanion.stream/1", !sessionID.isEmpty, !turnID.isEmpty, !eventID.isEmpty,
              sessionID.utf8.count <= 256, turnID.utf8.count <= 256, eventID.utf8.count <= 256,
              taskGeneration >= 0, sequence >= 0 else { throw CoreError.invalidEvent("envelope identity/version") }
        return self
    }
}

/// Incremental UTF-8 NDJSON framing. Incomplete bytes are retained until a complete line arrives.
public struct JSONLineFramer: Sendable {
    private var buffer = Data()
    public var maximumFrameBytes: Int
    public init(maximumFrameBytes: Int = 1_048_576) { self.maximumFrameBytes = maximumFrameBytes }
    public mutating func append(_ data: Data) throws -> [Data] {
        var result: [Data] = []
        for byte in data {
            if byte == 10 {
                if buffer.last == 13 { buffer.removeLast() }
                if !buffer.isEmpty { result.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < maximumFrameBytes else { buffer.removeAll(); throw CoreError.budgetExceeded("stream frame bytes") }
                buffer.append(byte)
            }
        }
        return result
    }
    public mutating func finish() throws -> [Data] {
        guard buffer.isEmpty else { buffer.removeAll(); throw CoreError.invalidEvent("truncated final frame") }; return []
    }
}

/// An explicit bounded reorder window. Gaps expire into resynchronization errors; no patch is guessed.
public struct StreamOrderGate: Sendable {
    public private(set) var generation: Int
    public private(set) var nextSequence = 0
    public let sessionID, turnID: String
    public var maximumBufferedEvents = 64
    public var maximumRememberedEvents = 4_096
    public var gapTimeout: Double = 5
    private var pending: [Int: StreamEnvelope] = [:]
    private var eventIDs = Set<String>()
    private var gapStartedAt: Double?
    public init(sessionID: String, turnID: String, generation: Int) {
        self.sessionID = sessionID; self.turnID = turnID; self.generation = generation
    }
    public mutating func advanceGeneration(to generation: Int) throws {
        guard generation > self.generation else { throw CoreError.invalidEvent("generation must advance") }
        self.generation = generation; nextSequence = 0; pending.removeAll(); eventIDs.removeAll(); gapStartedAt = nil
    }
    public func checkGap(at monotonicTime: Double) throws {
        guard monotonicTime.isFinite else { throw CoreError.invalidEvent("invalid host time") }
        if let started = gapStartedAt, monotonicTime - started > gapTimeout { throw CoreError.invalidEvent("missing sequence; request snapshot resynchronization") }
    }
    public mutating func accept(_ envelope: StreamEnvelope, at monotonicTime: Double) throws -> [StreamEnvelope] {
        _ = try envelope.validated(); try checkGap(at: monotonicTime)
        guard envelope.taskGeneration == generation else { throw CoreError.staleGeneration }
        guard envelope.sessionID == sessionID, envelope.turnID == turnID else { throw CoreError.invalidEvent("wrong session/turn") }
        if eventIDs.contains(envelope.eventID) { return [] }
        guard envelope.sequence >= nextSequence else { throw CoreError.invalidEvent("sequence reused with different eventID") }
        guard pending[envelope.sequence] == nil else { throw CoreError.invalidEvent("conflicting sequence") }
        guard pending.count < maximumBufferedEvents, envelope.sequence - nextSequence <= maximumBufferedEvents,
              eventIDs.count < maximumRememberedEvents else { throw CoreError.budgetExceeded("stream reorder/dedup window") }
        pending[envelope.sequence] = envelope; eventIDs.insert(envelope.eventID)
        var accepted: [StreamEnvelope] = []
        while let next = pending.removeValue(forKey: nextSequence) {
            accepted.append(next)
            guard nextSequence < Int.max else { throw CoreError.invalidEvent("sequence exhausted") }
            nextSequence += 1
        }
        if pending.isEmpty { gapStartedAt = nil } else if gapStartedAt == nil { gapStartedAt = monotonicTime }
        return accepted
    }
}

public struct ScreenEvidence: Codable, Equatable, Sendable {
    public var frameID: String
    public var taskGeneration, perceptionSceneRevision: Int
    public var displayID: UInt32
    public var windowID: UInt32?
    public var foregroundPID: Int32
    public var observedAtMonotonic: Double
    public var transformID: String
    public init(frameID: String, taskGeneration: Int, perceptionSceneRevision: Int, displayID: UInt32,
                windowID: UInt32? = nil, foregroundPID: Int32, observedAtMonotonic: Double, transformID: String) {
        self.frameID = frameID; self.taskGeneration = taskGeneration; self.perceptionSceneRevision = perceptionSceneRevision
        self.displayID = displayID; self.windowID = windowID; self.foregroundPID = foregroundPID
        self.observedAtMonotonic = observedAtMonotonic; self.transformID = transformID
    }
    public func validate(current: Self, now: Double, maximumAge: Double = 15) throws {
        guard taskGeneration == current.taskGeneration else { throw CoreError.staleGeneration }
        guard self == current, now.isFinite, observedAtMonotonic.isFinite,
              now >= observedAtMonotonic, now - observedAtMonotonic <= maximumAge else { throw CoreError.staleEvidence }
    }
}

public struct GuidanceState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, observing, guiding, awaitingInteraction, verifying, verified, cancelled, failed }
    public private(set) var phase: Phase = .idle
    public private(set) var generation: Int = 0
    public private(set) var evidence: ScreenEvidence?
    public private(set) var target: Rect2D?
    public private(set) var instruction: String = ""
    public private(set) var expectedEffect: String = ""
    public init() {}
    public mutating func begin() throws {
        guard generation < Int.max else { throw CoreError.invalidTransition("generation exhausted") }
        generation += 1; phase = .observing; evidence = nil; target = nil; instruction = ""; expectedEffect = ""
    }
    public mutating func present(evidence: ScreenEvidence, target: Rect2D, instruction: String, expectedEffect: String) throws {
        guard phase == .observing, evidence.taskGeneration == generation, !evidence.frameID.isEmpty, !evidence.transformID.isEmpty,
              evidence.observedAtMonotonic.isFinite, evidence.perceptionSceneRevision >= 0, target.isFinite, target.width > 0, target.height > 0,
              !instruction.isEmpty, !expectedEffect.isEmpty else { throw CoreError.invalidTransition("guidance requires current observation and effect") }
        self.evidence = evidence; self.target = target; self.instruction = instruction; self.expectedEffect = expectedEffect; phase = .guiding
    }
    public mutating func awaitInteraction() throws {
        guard phase == .guiding else { throw CoreError.invalidTransition("no grounded target") }; phase = .awaitingInteraction
    }
    public mutating func observedInteraction(currentEvidence: ScreenEvidence, now: Double) throws {
        guard phase == .awaitingInteraction, let evidence else { throw CoreError.invalidTransition("not waiting") }
        try evidence.validate(current: currentEvidence, now: now); phase = .verifying
    }
    public mutating func verify(effectObserved: Bool, freshEvidence: ScreenEvidence) throws {
        guard phase == .verifying, freshEvidence.taskGeneration == generation, let evidence,
              freshEvidence.frameID != evidence.frameID, freshEvidence.observedAtMonotonic > evidence.observedAtMonotonic else { throw CoreError.invalidTransition("verification requires a fresh frame") }
        self.evidence = freshEvidence; target = nil; phase = effectObserved ? .verified : .observing
    }
    public mutating func invalidateScreen() { evidence = nil; target = nil; if phase != .idle && phase != .cancelled { phase = .observing } }
    public mutating func cancel() {
        if generation < Int.max { generation += 1 }; phase = .cancelled; evidence = nil; target = nil
    }
}
