import Foundation

/// Durable semantic progress only. Native frames, targets, permissions, input
/// leases, generations and deadlines remain the host's separate authority.
public struct GuidanceWorkflow: Codable, Equatable, Sendable {
  public static let maximumActions = 15
  public static let maximumChecks = 46
  public static let maximumEncodedBytes = 128 * 1_024

  public enum Phase: String, Codable, Sendable {
    case ready, checking, awaitingUser, loading, paused, needsAttention
    case modelReportedComplete, independentlyVerified, abandoned
  }

  public enum ActionKind: String, Codable, Sendable { case click, manual }
  public enum ObservationKind: String, Codable, Sendable { case click, manualContinue }
  public enum AssessmentOutcome: String, Codable, Sendable {
    case progress, unchanged, loading, uncertain, goalComplete
  }

  public struct ActionObservation: Codable, Equatable, Sendable {
    public let id: UUID
    public let actionID: UUID
    public let kind: ObservationKind

    public init(id: UUID = UUID(), actionID: UUID, kind: ObservationKind) {
      self.id = id
      self.actionID = actionID
      self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, actionID, kind }
    public init(from decoder: any Decoder) throws {
      try WorkflowCoding.keys(decoder, allowing: ["id", "actionID", "kind"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        id: try c.decode(UUID.self, forKey: .id),
        actionID: try c.decode(UUID.self, forKey: .actionID),
        kind: try c.decode(ObservationKind.self, forKey: .kind))
    }
  }

  public struct ActionRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let checkID: UUID
    public let instruction: String
    public let label: String?
    public let kind: ActionKind
    public fileprivate(set) var observation: ActionObservation?

    private enum CodingKeys: String, CodingKey {
      case id, checkID, instruction, label, kind, observation
    }
    public init(from decoder: any Decoder) throws {
      try WorkflowCoding.keys(
        decoder, allowing: ["id", "checkID", "instruction", "label", "kind", "observation"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(UUID.self, forKey: .id)
      checkID = try c.decode(UUID.self, forKey: .checkID)
      instruction = try c.decode(String.self, forKey: .instruction)
      label = try c.decodeIfPresent(String.self, forKey: .label)
      kind = try c.decode(ActionKind.self, forKey: .kind)
      observation = try c.decodeIfPresent(ActionObservation.self, forKey: .observation)
    }

    fileprivate init(id: UUID, checkID: UUID, instruction: String, label: String?, kind: ActionKind)
    {
      self.id = id
      self.checkID = checkID
      self.instruction = instruction
      self.label = label
      self.kind = kind
    }
  }

  /// A host verifier's assertion, never decoded from a model assessment.
  /// This is historical evidence; it does not authorize a later screen target.
  public struct IndependentVerification: Codable, Equatable, Sendable {
    public let verifierID: String
    public let summary: String

    private enum CodingKeys: String, CodingKey { case verifierID, summary }
    public init(from decoder: any Decoder) throws {
      try WorkflowCoding.keys(decoder, allowing: ["verifierID", "summary"])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      verifierID = try c.decode(String.self, forKey: .verifierID)
      summary = try c.decode(String.self, forKey: .summary)
    }

    fileprivate init(verifierID: String, summary: String) {
      self.verifierID = verifierID
      self.summary = summary
    }
  }

  public struct CheckRecord: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable {
      case pending, nextActionProposed, assessed, interrupted
    }

    public let id: UUID
    /// The action being checked, not an assertion that it succeeded. Nil for
    /// the initial screen. Resume and loading checks retain this association.
    public let actionID: UUID?
    public fileprivate(set) var disposition: Disposition
    public fileprivate(set) var proposedActionID: UUID?
    public fileprivate(set) var outcome: AssessmentOutcome?
    public fileprivate(set) var summary: String?
    public fileprivate(set) var verification: IndependentVerification?

    private enum CodingKeys: String, CodingKey {
      case id, actionID, disposition, proposedActionID, outcome, summary, verification
    }
    public init(from decoder: any Decoder) throws {
      try WorkflowCoding.keys(
        decoder,
        allowing: [
          "id", "actionID", "disposition", "proposedActionID", "outcome", "summary", "verification",
        ])
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(UUID.self, forKey: .id)
      actionID = try c.decodeIfPresent(UUID.self, forKey: .actionID)
      disposition = try c.decode(Disposition.self, forKey: .disposition)
      proposedActionID = try c.decodeIfPresent(UUID.self, forKey: .proposedActionID)
      outcome = try c.decodeIfPresent(AssessmentOutcome.self, forKey: .outcome)
      summary = try c.decodeIfPresent(String.self, forKey: .summary)
      verification = try c.decodeIfPresent(IndependentVerification.self, forKey: .verification)
    }

    fileprivate init(id: UUID, actionID: UUID?) {
      self.id = id
      self.actionID = actionID
      disposition = .pending
    }
  }

  public let version: Int
  public let id: UUID
  public private(set) var revision: UInt64
  public let goal: String
  public let speakAloud: Bool
  public private(set) var phase: Phase
  public private(set) var actions: [ActionRecord]
  public private(set) var checks: [CheckRecord]
  public private(set) var pendingCheckID: UUID?

  public init(goal: String, speakAloud: Bool = true) throws {
    version = 1
    id = UUID()
    revision = 0
    self.goal = goal
    self.speakAloud = speakAloud
    phase = .ready
    actions = []
    checks = []
    pendingCheckID = nil
    _ = try validated()
  }

  /// Bounds raw input before decoding as well as validating the resulting
  /// versioned value. Use this entry point for stored/imported workflow data.
  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= maximumEncodedBytes else { throw Failure.limitExceeded("encoded bytes") }
    return try JSONDecoder().decode(Self.self, from: data)
  }

  public var currentAction: ActionRecord? { actions.last }

  /// Checks, including interrupted checks, consume their budget. Pausing or
  /// restoring cannot reset the two additional checks available to an action.
  public var canBeginCheck: Bool {
    guard [.ready, .loading, .paused, .needsAttention, .modelReportedComplete].contains(phase),
      pendingCheckID == nil, checks.count < Self.maximumChecks
    else { return false }
    return checks.filter { $0.actionID == actions.last?.id }.count < 3
  }

  @discardableResult
  public mutating func beginCheck() throws -> UUID {
    guard canBeginCheck else { throw Failure.invalidTransition("cannot begin another check") }
    let checkID = UUID()
    try commit { next in
      next.checks.append(.init(id: checkID, actionID: next.actions.last?.id))
      next.pendingCheckID = checkID
      next.phase = .checking
    }
    return checkID
  }

  /// Call only after the host has admitted the current native target. One
  /// check may propose one action; secondary explanatory marks are not actions.
  public mutating func presentAction(
    checkID: UUID, instruction: String, label: String? = nil, kind: ActionKind
  ) throws {
    try commit { next in
      let index = try next.currentCheck(checkID)
      let check = next.checks[index]
      guard
        check.disposition == .pending
          || (check.disposition == .assessed
            && (check.outcome == .progress || check.outcome == .unchanged
              || check.outcome == .uncertain))
      else { throw Failure.invalidTransition("check cannot propose an action") }
      guard next.actions.count < Self.maximumActions else { throw Failure.limitExceeded("actions") }
      try Self.semantic(instruction, named: "instruction", required: true)
      if let label { try Self.semantic(label, named: "label", required: true) }
      let actionID = UUID()
      next.actions.append(
        .init(id: actionID, checkID: checkID, instruction: instruction, label: label, kind: kind))
      next.checks[index].disposition = .nextActionProposed
      next.checks[index].proposedActionID = actionID
      next.pendingCheckID = nil
      next.phase = .awaitingUser
    }
  }

  /// A click or explicit Continue is an observation only. A subsequent fresh
  /// check must assess the screen; neither event marks the action completed.
  public mutating func observeAction(observation: ActionObservation) throws {
    try commit { next in
      guard next.phase == .awaitingUser, let index = next.actions.indices.last,
        next.actions[index].id == observation.actionID, next.actions[index].observation == nil,
        Self.matches(next.actions[index].kind, observation.kind)
      else { throw Failure.invalidTransition("observation does not own the current action") }
      next.actions[index].observation = observation
      next.phase = .ready
    }
  }

  public mutating func assess(
    checkID: UUID, outcome: AssessmentOutcome, summary: String
  ) throws {
    try commit { next in
      let index = try next.currentCheck(checkID)
      guard next.checks[index].outcome == nil else {
        throw Failure.invalidTransition("check already has a model assessment")
      }
      try Self.semantic(summary, named: "assessment summary", required: false)
      let proposed = next.checks[index].disposition == .nextActionProposed
      guard next.checks[index].disposition == .pending || proposed else {
        throw Failure.invalidTransition("check cannot receive an assessment")
      }
      guard !proposed || (outcome != .goalComplete && outcome != .loading) else {
        throw Failure.invalidTransition("a proposed action cannot report completion or loading")
      }
      next.checks[index].outcome = outcome
      next.checks[index].summary = summary
      if !proposed {
        next.checks[index].disposition = .assessed
        next.pendingCheckID = nil
        switch outcome {
        case .goalComplete: next.phase = .modelReportedComplete
        case .loading:
          let count = next.checks.filter { $0.actionID == next.checks[index].actionID }.count
          next.phase =
            count < 3 && next.checks.count < Self.maximumChecks ? .loading : .needsAttention
        case .progress, .unchanged, .uncertain: next.phase = .needsAttention
        }
      }
    }
  }

  /// The model-facing bridge must not call this method. The host supplies a
  /// named independent verifier after checking its own current authority.
  public mutating func verifyCompletion(checkID: UUID, verifierID: String, summary: String) throws {
    try commit { next in
      let index = try next.currentCheck(checkID, allowModelCompletion: true)
      guard next.checks[index].proposedActionID == nil,
        next.checks[index].verification == nil,
        [.pending, .assessed].contains(next.checks[index].disposition)
      else { throw Failure.invalidTransition("check cannot receive independent verification") }
      try Self.semantic(verifierID, named: "verifier identifier", required: true, limit: 256)
      try Self.semantic(summary, named: "verification summary", required: true)
      next.checks[index].verification = .init(verifierID: verifierID, summary: summary)
      next.checks[index].disposition = .assessed
      next.pendingCheckID = nil
      next.phase = .independentlyVerified
    }
  }

  public mutating func pause() throws {
    guard phase != .paused else { return }
    guard !isTerminal else { throw Failure.invalidTransition("cannot pause a finished workflow") }
    try commit { next in
      next.interruptPendingCheck()
      next.phase = .paused
    }
  }

  public mutating func abandon() throws {
    guard phase != .abandoned else { return }
    try commit { next in
      next.interruptPendingCheck()
      next.phase = .abandoned
    }
  }

  /// Restore never revives an in-flight check or a previously presented target.
  /// Finished records stay historical; all other records require a fresh check.
  public func restoredForResume() throws -> Self {
    var restored = try validated()
    if !restored.isTerminal { try restored.pause() }
    return restored
  }

  private var isTerminal: Bool {
    [.independentlyVerified, .abandoned].contains(phase)
  }

  private mutating func interruptPendingCheck() {
    if let pendingCheckID, let index = checks.firstIndex(where: { $0.id == pendingCheckID }) {
      checks[index].disposition = .interrupted
    }
    pendingCheckID = nil
  }

  private func currentCheck(_ id: UUID, allowModelCompletion: Bool = false) throws -> Int {
    guard let index = checks.indices.last, checks[index].id == id,
      phase == .checking || phase == .awaitingUser || phase == .needsAttention
        || (allowModelCompletion && phase == .modelReportedComplete)
    else { throw Failure.staleCheck }
    return index
  }

  private mutating func commit(_ change: (inout Self) throws -> Void) throws {
    _ = try validated()
    guard revision < UInt64.max else { throw Failure.revisionOverflow }
    var next = self
    try change(&next)
    next.revision += 1
    _ = try next.validated()
    self = next
  }

  @discardableResult
  public func validated() throws -> Self {
    guard version == 1 else { throw Failure.unsupportedVersion }
    try Self.semantic(goal, named: "goal", required: true, limit: 32 * 1_024)
    guard actions.count <= Self.maximumActions, checks.count <= Self.maximumChecks else {
      throw Failure.limitExceeded("record count")
    }
    var allIDs: Set<UUID> = [id]
    var actionLookup: [UUID: ActionRecord] = [:]
    for action in actions {
      guard allIDs.insert(action.id).inserted else {
        throw Failure.invalidValue("duplicate identifier")
      }
      try Self.semantic(action.instruction, named: "instruction", required: true)
      if let label = action.label { try Self.semantic(label, named: "label", required: true) }
      if let observation = action.observation {
        guard allIDs.insert(observation.id).inserted, observation.actionID == action.id,
          Self.matches(action.kind, observation.kind)
        else { throw Failure.invalidValue("action observation") }
      }
      actionLookup[action.id] = action
    }
    var latestActionID: UUID?
    var proposedIDs: [UUID] = []
    var checkCounts: [UUID: Int] = [:]
    var initialChecks = 0
    var pendingIDs: [UUID] = []
    for (checkIndex, check) in checks.enumerated() {
      guard allIDs.insert(check.id).inserted, check.actionID == latestActionID else {
        throw Failure.invalidValue("check identity or action order")
      }
      if let actionID = check.actionID {
        checkCounts[actionID, default: 0] += 1
        guard checkCounts[actionID, default: 0] <= 3 else {
          throw Failure.limitExceeded("action checks")
        }
      } else {
        initialChecks += 1
        guard initialChecks <= 3 else { throw Failure.limitExceeded("initial checks") }
      }
      if let summary = check.summary {
        try Self.semantic(summary, named: "assessment summary", required: false)
      }
      guard (check.outcome == nil) == (check.summary == nil) else {
        throw Failure.invalidValue("incomplete model assessment")
      }
      if let verification = check.verification {
        try Self.semantic(
          verification.verifierID, named: "verifier identifier", required: true, limit: 256)
        try Self.semantic(verification.summary, named: "verification summary", required: true)
      }
      if check.verification != nil {
        guard checkIndex == checks.count - 1 else {
          throw Failure.invalidValue("records after completion")
        }
      }
      switch check.disposition {
      case .pending:
        guard check.proposedActionID == nil, check.outcome == nil, check.verification == nil else {
          throw Failure.invalidValue("pending check result")
        }
        pendingIDs.append(check.id)
      case .interrupted:
        guard check.proposedActionID == nil, check.outcome == nil, check.verification == nil else {
          throw Failure.invalidValue("interrupted check result")
        }
      case .assessed:
        guard check.proposedActionID == nil, check.outcome != nil || check.verification != nil
        else {
          throw Failure.invalidValue("missing assessment")
        }
      case .nextActionProposed:
        guard let proposed = check.proposedActionID, let action = actionLookup[proposed],
          action.checkID == check.id, check.verification == nil,
          check.outcome != .goalComplete, check.outcome != .loading
        else { throw Failure.invalidValue("proposed action reference") }
        proposedIDs.append(proposed)
        latestActionID = proposed
      }
    }
    guard proposedIDs == actions.map(\.id) else { throw Failure.invalidValue("unlinked action") }
    let minimumRevision =
      checks.count + actions.count
      + actions.filter({ $0.observation != nil }).count
      + checks.filter({ $0.outcome != nil }).count
      + checks.filter({ $0.verification != nil }).count
    guard revision >= UInt64(minimumRevision) else {
      throw Failure.invalidValue("revision history")
    }
    if phase == .checking {
      guard let pendingCheckID, pendingIDs == [pendingCheckID], checks.last?.id == pendingCheckID
      else {
        throw Failure.invalidValue("pending check ownership")
      }
    } else if pendingCheckID != nil || !pendingIDs.isEmpty {
      throw Failure.invalidValue("inactive pending check")
    }
    switch phase {
    case .ready:
      guard actions.isEmpty || actions.last?.observation != nil else {
        throw Failure.invalidValue("ready without an observation")
      }
    case .awaitingUser:
      guard let action = actions.last, action.observation == nil,
        checks.last?.proposedActionID == action.id
      else { throw Failure.invalidValue("missing current action") }
    case .loading:
      guard checks.last?.outcome == .loading, checks.last?.proposedActionID == nil,
        checks.last?.verification == nil
      else { throw Failure.invalidValue("missing loading assessment") }
    case .needsAttention:
      guard let outcome = checks.last?.outcome, outcome != .goalComplete,
        checks.last?.proposedActionID == nil
      else { throw Failure.invalidValue("missing attention assessment") }
    case .modelReportedComplete:
      guard checks.last?.outcome == .goalComplete, checks.last?.verification == nil,
        checks.last?.disposition == .assessed
      else { throw Failure.invalidValue("missing model completion") }
    case .independentlyVerified:
      guard checks.last?.verification != nil, checks.last?.disposition == .assessed else {
        throw Failure.invalidValue("missing independent verification")
      }
    case .checking, .paused, .abandoned: break
    }
    guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
      throw Failure.limitExceeded("encoded bytes")
    }
    return self
  }

  private static func matches(_ action: ActionKind, _ observation: ObservationKind) -> Bool {
    (action == .click && observation == .click)
      || (action == .manual && observation == .manualContinue)
  }

  private static func semantic(
    _ value: String, named: String, required: Bool, limit: Int = 2 * 1_024
  ) throws {
    guard value.utf8.count <= limit else { throw Failure.limitExceeded(named) }
    if required && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw Failure.invalidValue(named)
    }
  }

  public enum Failure: Error, Equatable, Sendable {
    case unsupportedVersion, revisionOverflow, staleCheck
    case invalidValue(String)
    case invalidTransition(String)
    case limitExceeded(String)
  }

  private enum CodingKeys: String, CodingKey {
    case version, id, revision, goal, speakAloud, phase, actions, checks, pendingCheckID
  }

  public init(from decoder: any Decoder) throws {
    try WorkflowCoding.keys(
      decoder,
      allowing: [
        "version", "id", "revision", "goal", "speakAloud", "phase", "actions", "checks",
        "pendingCheckID",
      ])
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    id = try c.decode(UUID.self, forKey: .id)
    revision = try c.decode(UInt64.self, forKey: .revision)
    goal = try c.decode(String.self, forKey: .goal)
    speakAloud = try c.decode(Bool.self, forKey: .speakAloud)
    phase = try c.decode(Phase.self, forKey: .phase)
    actions = try WorkflowCoding.array(c.superDecoder(forKey: .actions), limit: Self.maximumActions)
    checks = try WorkflowCoding.array(c.superDecoder(forKey: .checks), limit: Self.maximumChecks)
    pendingCheckID = try c.decodeIfPresent(UUID.self, forKey: .pendingCheckID)
    _ = try validated()
  }
}

private enum WorkflowCoding {
  private struct Key: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  static func keys(_ decoder: any Decoder, allowing allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: Key.self)
    guard c.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
      throw GuidanceWorkflow.Failure.invalidValue("unknown field")
    }
  }

  static func array<T: Decodable>(_ decoder: any Decoder, limit: Int) throws -> [T] {
    var c = try decoder.unkeyedContainer()
    if let count = c.count, count > limit {
      throw GuidanceWorkflow.Failure.limitExceeded("record count")
    }
    var result: [T] = []
    while !c.isAtEnd {
      guard result.count < limit else {
        throw GuidanceWorkflow.Failure.limitExceeded("record count")
      }
      result.append(try c.decode(T.self))
    }
    return result
  }
}
