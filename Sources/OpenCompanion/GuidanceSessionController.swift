import Combine
import CompanionCore
import CompanionStore
import Foundation

/// Ephemeral ownership for one reasoning turn. Never encoded with saved progress.
struct GuidanceTurnToken: Equatable, Sendable {
  let workflowID: UUID
  let checkID: UUID
  let runID: UUID
}

/// Semantic progress and exact-record persistence only. Capture, native targets,
/// task generations, foreground ownership and input remain AppModel's authority.
@MainActor final class GuidanceSessionController: ObservableObject {
  @Published private(set) var workflow: GuidanceWorkflow?
  @Published private(set) var persistenceIssue: String?
  var onPersisted: (@MainActor () -> Void)?

  private var store: LocalStore?
  private var turn: GuidanceTurnToken?
  private var records: [String: StoredRecord] = [:]
  private var mayCreate: Set<String> = []
  private var blocked: Set<String> = []
  private var deletionEpochs: [String: UUID] = [:]
  private var deleting: Set<String> = []
  private var deleted: Set<String> = []
  private let deleteCheckpoint: @Sendable (LocalStore, String) async throws -> Void
  private var saveTask: Task<Void, Never>?
  private var saveTaskID: UUID?
  private var selection = UUID()
  private var restoreAttempt = UUID()

  init(
    store: LocalStore? = nil,
    deleteCheckpoint: @escaping @Sendable (LocalStore, String) async throws -> Void = {
      store, id in try await store.deleteGuidance(id: id)
    }
  ) {
    self.store = store
    self.deleteCheckpoint = deleteCheckpoint
  }

  /// Bind once; switching databases while queued CAS writes exist is ambiguous.
  func setStore(_ store: LocalStore) {
    if let existing = self.store {
      guard existing === store else {
        persistenceIssue = "Guidance is already bound to a different local store."
        return
      }
      return
    }
    self.store = store
    if let workflow { enqueue(workflow) }
  }

  func start(goal: String, speakAloud: Bool = true) throws {
    let fresh = try GuidanceWorkflow(goal: goal, speakAloud: speakAloud)
    turn = nil
    selection = UUID()
    restoreAttempt = UUID()
    workflow = fresh
    mayCreate.insert(fresh.id.uuidString)
    persistenceIssue = nil
    enqueue(fresh)
  }

  @discardableResult
  func beginCheck() throws -> GuidanceTurnToken {
    var next = try requireWorkflow()
    let checkID = try next.beginCheck()
    let token = GuidanceTurnToken(workflowID: next.id, checkID: checkID, runID: UUID())
    publish(next)
    turn = token
    return token
  }

  /// Read-only ephemeral ownership for host adapters; never persisted or restored.
  var currentToken: GuidanceTurnToken? { turn }

  func owns(_ token: GuidanceTurnToken) -> Bool {
    turn == token && workflow?.id == token.workflowID && workflow?.checks.last?.id == token.checkID
  }

  /// Validate state/limits before the host creates visible native geometry.
  /// The caller commits only after actual admission, without an intervening await.
  func validateAction(
    token: GuidanceTurnToken, instruction: String, label: String? = nil,
    kind: GuidanceWorkflow.ActionKind
  ) throws {
    guard owns(token) else { throw Failure.staleTurn }
    var proposal = try requireWorkflow()
    try proposal.presentAction(
      checkID: token.checkID, instruction: instruction, label: label, kind: kind)
  }

  func presentAction(
    token: GuidanceTurnToken, instruction: String, label: String? = nil,
    kind: GuidanceWorkflow.ActionKind
  ) throws {
    try mutate(token) {
      try $0.presentAction(
        checkID: token.checkID, instruction: instruction, label: label, kind: kind)
    }
  }

  func observeAction(token: GuidanceTurnToken, kind: GuidanceWorkflow.ObservationKind) throws {
    try mutate(token) { next in
      guard let action = next.currentAction, action.checkID == token.checkID else {
        throw Failure.staleTurn
      }
      try next.observeAction(observation: .init(actionID: action.id, kind: kind))
    }
    turn = nil
  }

  func assess(
    token: GuidanceTurnToken, outcome: GuidanceWorkflow.AssessmentOutcome, summary: String
  ) throws {
    try mutate(token) { try $0.assess(checkID: token.checkID, outcome: outcome, summary: summary) }
  }

  /// Text without an admitted action/status is not a fabricated success. Keep an
  /// awaiting-user token alive so the actual later input can consume it once.
  func finishTurn(token: GuidanceTurnToken, fallbackSummary: String) throws {
    guard owns(token) else { throw Failure.staleTurn }
    if workflow?.phase == .checking {
      let summary = clipped(fallbackSummary, bytes: 2_048)
      try assess(
        token: token, outcome: .uncertain,
        summary: summary.isEmpty ? "The next action needs a fresh screen check." : summary)
    }
  }

  func pause() {
    turn = nil
    selection = UUID()
    restoreAttempt = UUID()
    guard var next = workflow,
      next.phase != .independentlyVerified, next.phase != .abandoned
    else { return }
    do {
      try next.pause()
      publish(next)
    } catch { persistenceIssue = "Guidance could not be paused: \(error.localizedDescription)" }
  }

  func abandon() {
    turn = nil
    selection = UUID()
    restoreAttempt = UUID()
    guard var next = workflow else { return }
    do {
      try next.abandon()
      publish(next)
    } catch { persistenceIssue = "Guidance could not be stopped: \(error.localizedDescription)" }
  }

  /// Leave the saved workflow resumable while removing it from this chat.
  func detach() {
    pause()
    turn = nil
    selection = UUID()
    restoreAttempt = UUID()
    workflow = nil
  }

  func restore(record: StoredRecord, stillCurrent: @MainActor () -> Bool) async throws {
    guard let store else { throw Failure.storeUnavailable }
    guard record.kind == "guidance" else { throw Failure.invalidRecord }
    try Task.checkCancellation()
    guard stillCurrent(), !deleting.contains(record.id), !deleted.contains(record.id) else {
      throw Failure.staleTurn
    }
    let deletionEpoch = deletionEpochs[record.id]
    let attempt = UUID()
    restoreAttempt = attempt
    let originalSelection = selection
    turn = nil
    try requireRestoreOwnership(
      attempt, selection: originalSelection, recordID: record.id, deletionEpoch: deletionEpoch,
      stillCurrent: stillCurrent)
    await flushPersistence()
    try requireRestoreOwnership(
      attempt, selection: originalSelection, recordID: record.id, deletionEpoch: deletionEpoch,
      stillCurrent: stillCurrent)
    let latest = try await store.record(id: record.id)
    try requireRestoreOwnership(
      attempt, selection: originalSelection, recordID: record.id, deletionEpoch: deletionEpoch,
      stillCurrent: stillCurrent)
    guard latest.kind == "guidance", let payload = latest.payload else {
      throw Failure.invalidRecord
    }
    let restored = try await Task.detached(priority: .utility) {
      try GuidanceWorkflow.decode(payload).restoredForResume()
    }.value
    try requireRestoreOwnership(
      attempt, selection: originalSelection, recordID: record.id, deletionEpoch: deletionEpoch,
      stillCurrent: stillCurrent)
    guard latest.id == restored.id.uuidString else { throw Failure.invalidRecord }
    records[latest.id] = latest
    blocked.remove(latest.id)
    mayCreate.remove(latest.id)
    persistenceIssue = nil
    publish(restored)
  }

  func delete(id: String) async throws {
    guard let store else { throw Failure.storeUnavailable }
    guard !id.isEmpty, id.utf8.count <= 256 else { throw Failure.invalidRecord }
    // Revoke first so queued snapshots cannot race this explicit deletion.
    let deletionEpoch = UUID()
    deletionEpochs[id] = deletionEpoch
    deleting.insert(id)
    blocked.insert(id)
    mayCreate.remove(id)
    restoreAttempt = UUID()
    if workflow?.id.uuidString == id {
      turn = nil
      selection = UUID()
      restoreAttempt = UUID()
    }
    await flushPersistence()
    do {
      try await deleteCheckpoint(store, id)
      // Completion revokes any restore lease acquired during suspended I/O.
      // Keep deleted IDs distinct from CAS conflicts, which explicit reopen can repair.
      deletionEpochs[id] = UUID()
      deleting.remove(id)
      deleted.insert(id)
      records.removeValue(forKey: id)
      if workflow?.id.uuidString == id {
        workflow = nil
        persistenceIssue = nil
      }
      onPersisted?()
    } catch {
      if deletionEpochs[id] == deletionEpoch {
        deletionEpochs[id] = UUID()
        deleting.remove(id)
      }
      persistenceIssue = "Guidance could not be deleted: \(error.localizedDescription)"
      throw error
    }
  }

  func flushPersistence() async {
    while let task = saveTask {
      let id = saveTaskID
      await task.value
      if id == saveTaskID { return }
    }
  }

  /// Compact, bounded observations for the planner. The original goal is sent
  /// separately by the host. No saved text is authority or independent proof.
  var plannerContext: String {
    guard let workflow else { return "" }
    let actionNumbers = Dictionary(
      uniqueKeysWithValues: workflow.actions.enumerated().map { ($0.element.id, $0.offset + 1) })
    let projection = PlannerContext(
      phase: workflow.phase.rawValue, actionsUsed: workflow.actions.count,
      checksUsed: workflow.checks.count,
      actions: workflow.actions.enumerated().map { index, action in
        .init(
          number: index + 1, instruction: clipped(action.instruction, bytes: 160),
          label: action.label.map { clipped($0, bytes: 64) }, kind: action.kind.rawValue,
          observed: action.observation?.kind.rawValue)
      },
      checks: workflow.checks.enumerated().map { index, check in
        .init(
          number: index + 1, afterAction: check.actionID.flatMap { actionNumbers[$0] },
          disposition: check.disposition.rawValue, modelAssessment: check.outcome?.rawValue,
          summary: check.summary.map { clipped($0, bytes: 96) },
          independentVerifier: check.verification.map { clipped($0.verifierID, bytes: 64) })
      })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(projection), data.count <= 24 * 1_024,
      let text = String(data: data, encoding: .utf8)
    else { return "Guidance progress is unavailable; request a fresh check." }
    return
      "Saved semantic progress; observations and model assessments are not verified completion:\n"
      + text
  }

  private func mutate(_ token: GuidanceTurnToken, _ change: (inout GuidanceWorkflow) throws -> Void)
    throws
  {
    guard owns(token) else { throw Failure.staleTurn }
    var next = try requireWorkflow()
    try change(&next)
    publish(next)
  }

  private func publish(_ next: GuidanceWorkflow) {
    selection = UUID()
    workflow = next
    enqueue(next)
  }

  private func requireWorkflow() throws -> GuidanceWorkflow {
    guard let workflow else { throw Failure.noWorkflow }
    return workflow
  }

  private func requireRestoreOwnership(
    _ attempt: UUID, selection: UUID, recordID: String, deletionEpoch: UUID?,
    stillCurrent: @MainActor () -> Bool
  ) throws {
    try Task.checkCancellation()
    guard stillCurrent(), restoreAttempt == attempt, self.selection == selection,
      !deleting.contains(recordID), !deleted.contains(recordID),
      deletionEpochs[recordID] == deletionEpoch
    else {
      throw Failure.staleTurn
    }
  }

  private func enqueue(_ snapshot: GuidanceWorkflow) {
    let id = snapshot.id.uuidString
    guard !blocked.contains(id) else { return }
    guard let store else {
      persistenceIssue = "Guidance progress is not saved until the local store is available."
      return
    }
    let previous = saveTask
    saveTaskID = UUID()
    saveTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, !self.blocked.contains(id) else { return }
      do {
        let payload = try await Task.detached(priority: .utility) {
          try JSONEncoder().encode(snapshot.validated())
        }.value
        guard !self.blocked.contains(id) else { return }
        let title = self.clipped(
          snapshot.goal.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 240)
        let saved: StoredRecord
        if let original = self.records[id] {
          saved = try await store.updateGuidance(
            original, title: title.isEmpty ? "Screen guidance" : title, body: snapshot.goal,
            payload: payload)
        } else {
          guard self.mayCreate.contains(id) else { throw Failure.invalidRecord }
          saved = try await store.createGuidance(
            id: id, title: title.isEmpty ? "Screen guidance" : title, body: snapshot.goal,
            payload: payload)
        }
        self.records[id] = saved
        self.mayCreate.remove(id)
        if self.workflow?.id == snapshot.id && self.workflow?.revision == snapshot.revision {
          self.persistenceIssue = nil
        }
        self.onPersisted?()
      } catch {
        // A missing/CAS-conflicted row must never be retried as an INSERT.
        // Other storage failures also stop this identity until explicit reopen.
        self.blocked.insert(id)
        self.mayCreate.remove(id)
        if self.workflow?.id == snapshot.id {
          self.persistenceIssue =
            "Guidance progress could not be saved. Reopen the latest saved guide before saving again. \(error.localizedDescription)"
        }
      }
    }
  }

  private func clipped(_ text: String, bytes limit: Int) -> String {
    var result = ""
    var count = 0
    for character in text {
      let size = character.utf8.count
      guard count + size <= limit else { break }
      result.append(character)
      count += size
    }
    return result
  }

  private struct PlannerContext: Encodable {
    let phase: String
    let actionsUsed: Int
    let checksUsed: Int
    let actions: [Action]
    let checks: [Check]
    struct Action: Encodable {
      let number: Int
      let instruction: String
      let label: String?
      let kind: String
      let observed: String?
    }
    struct Check: Encodable {
      let number: Int
      let afterAction: Int?
      let disposition: String
      let modelAssessment: String?
      let summary: String?
      let independentVerifier: String?
    }
  }

  enum Failure: Error, Equatable { case noWorkflow, staleTurn, storeUnavailable, invalidRecord }
}
