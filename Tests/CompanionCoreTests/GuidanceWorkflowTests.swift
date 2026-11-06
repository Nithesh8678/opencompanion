import Foundation
import Testing

@testable import CompanionCore

struct GuidanceWorkflowTests {
  @Test func alternativeActionsHaveTheSameSemanticsBeforeOrAfterAnAssessment() throws {
    for outcome in [GuidanceWorkflow.AssessmentOutcome.progress, .unchanged, .uncertain] {
      var before = try GuidanceWorkflow(goal: "Find the visible control")
      let beforeCheck = try before.beginCheck()
      try before.assess(checkID: beforeCheck, outcome: outcome, summary: "Fresh screen assessment")
      try before.presentAction(
        checkID: beforeCheck, instruction: "Use the visible alternative", kind: .click)
      var after = try GuidanceWorkflow(goal: "Find the visible control")
      let afterCheck = try after.beginCheck()
      try after.presentAction(
        checkID: afterCheck, instruction: "Use the visible alternative", kind: .click)
      try after.assess(checkID: afterCheck, outcome: outcome, summary: "Fresh screen assessment")
      #expect(before.phase == .awaitingUser && after.phase == .awaitingUser)
      #expect(before.actions.count == 1 && after.actions.count == 1)
      #expect(before.checks.last?.outcome == outcome && after.checks.last?.outcome == outcome)
      #expect(before.actions.last?.observation == nil && after.actions.last?.observation == nil)
    }
  }

  @Test func aClickAndContinueAreObservationsRatherThanCompletion() throws {
    for kind: GuidanceWorkflow.ActionKind in [.click, .manual] {
      var workflow = try GuidanceWorkflow(goal: "Update the document", speakAloud: false)
      let checkID = try workflow.beginCheck()
      try workflow.presentAction(
        checkID: checkID, instruction: "Update this field", label: "Name", kind: kind)
      let action = try #require(workflow.currentAction)
      #expect(
        workflow.phase == .awaitingUser && workflow.checks.last?.disposition == .nextActionProposed)
      #expect(workflow.checks.last?.outcome == nil && workflow.checks.last?.verification == nil)
      try workflow.observeAction(
        observation: .init(actionID: action.id, kind: kind == .click ? .click : .manualContinue))
      #expect(workflow.phase == .ready && workflow.currentAction?.observation != nil)
      #expect(workflow.checks.last?.outcome == nil && workflow.checks.last?.verification == nil)
      #expect(workflow.speakAloud == false)
      try rejectsWithoutMutation(&workflow) {
        try $0.observeAction(observation: .init(actionID: action.id, kind: .click))
      }
    }
  }

  @Test func wrongActionOrObservationKindCannotConsumeTheCurrentAction() throws {
    var workflow = try awaitingAction(kind: .manual)
    let actionID = try #require(workflow.currentAction?.id)
    for observation in [
      GuidanceWorkflow.ActionObservation(actionID: UUID(), kind: .manualContinue),
      .init(actionID: actionID, kind: .click),
    ] {
      try rejectsWithoutMutation(&workflow) { try $0.observeAction(observation: observation) }
    }
    #expect(workflow.phase == .awaitingUser && workflow.currentAction?.observation == nil)
  }

  @Test func targetProposalCanReceiveOneSeparateModelAssessment() throws {
    var workflow = try awaitingAction()
    let checkID = try #require(workflow.checks.last?.id)
    try workflow.assess(
      checkID: checkID, outcome: .progress, summary: "The next control is visible")
    #expect(workflow.phase == .awaitingUser)
    #expect(workflow.checks.last?.disposition == .nextActionProposed)
    #expect(workflow.checks.last?.outcome == .progress)
    #expect(workflow.checks.last?.verification == nil)
    try rejectsWithoutMutation(&workflow) {
      try $0.assess(checkID: checkID, outcome: .goalComplete, summary: "Done")
    }
    try rejectsWithoutMutation(&workflow) {
      try $0.presentAction(checkID: checkID, instruction: "Another primary", kind: .click)
    }
    var unassessed = try awaitingAction()
    let unassessedID = try #require(unassessed.checks.last?.id)
    try rejectsWithoutMutation(&unassessed) {
      try $0.assess(checkID: unassessedID, outcome: .goalComplete, summary: "Done")
    }
    try rejectsWithoutMutation(&unassessed) {
      try $0.assess(checkID: unassessedID, outcome: .loading, summary: "Still loading")
    }
  }

  @Test func fifteenActionsStillAllowTheFinalFreshCheckAndNeverASixteenthAction() throws {
    var workflow = try GuidanceWorkflow(goal: "Finish a fifteen-action public task")
    var checkID = try workflow.beginCheck()
    for index in 0..<15 {
      try workflow.presentAction(checkID: checkID, instruction: "Action \(index + 1)", kind: .click)
      let actionID = try #require(workflow.currentAction?.id)
      try workflow.observeAction(observation: .init(actionID: actionID, kind: .click))
      for _ in 0..<2 {
        let loadingID = try workflow.beginCheck()
        try workflow.assess(checkID: loadingID, outcome: .loading, summary: "The page is loading")
        #expect(workflow.phase == .loading)
      }
      checkID = try workflow.beginCheck()
    }
    #expect(workflow.actions.count == 15 && workflow.checks.count == 46)
    try rejectsWithoutMutation(&workflow) {
      try $0.presentAction(checkID: checkID, instruction: "Sixteenth action", kind: .click)
    }
    try workflow.assess(
      checkID: checkID, outcome: .goalComplete, summary: "The model reports the goal complete")
    #expect(workflow.phase == .modelReportedComplete && !workflow.canBeginCheck)
    #expect(workflow.checks.last?.verification == nil)
    #expect(try workflow.validated() == workflow)
  }

  @Test func loadingConsumesAtMostTwoExtraChecksWithoutRepeatingAnAction() throws {
    var workflow = try observedAction()
    let actionID = try #require(workflow.currentAction?.id)
    for index in 0..<3 {
      let checkID = try workflow.beginCheck()
      try workflow.assess(checkID: checkID, outcome: .loading, summary: "Still loading")
      #expect(workflow.phase == (index < 2 ? .loading : .needsAttention))
    }
    #expect(workflow.actions.count == 1 && workflow.currentAction?.id == actionID)
    #expect(workflow.currentAction?.observation?.kind == .click)
    #expect(!workflow.canBeginCheck)
    try workflow.pause()
    let restored = try workflow.restoredForResume()
    #expect(restored.checks.count == 4 && !restored.canBeginCheck)
    try rejectsWithoutMutation(&workflow) { _ = try $0.beginCheck() }
  }

  @Test func unchangedAndUncertainWithoutAnAlternativeRequireAnExplicitNewCheck() throws {
    for outcome: GuidanceWorkflow.AssessmentOutcome in [.unchanged, .uncertain] {
      var workflow = try observedAction()
      let checkID = try workflow.beginCheck()
      try workflow.assess(checkID: checkID, outcome: outcome, summary: "No verified progress")
      #expect(workflow.phase == .needsAttention && workflow.actions.count == 1)
      let previousAction = try #require(workflow.currentAction)
      try rejectsWithoutMutation(&workflow) {
        try $0.observeAction(observation: .init(actionID: previousAction.id, kind: .click))
      }
      let newCheck = try workflow.beginCheck()
      #expect(newCheck != checkID && workflow.phase == .checking)
    }
  }

  @Test func pauseAndRestoreInvalidateChecksButPreserveIdentityAndBudgets() throws {
    var workflow = try observedAction()
    let interrupted = try workflow.beginCheck()
    let originalID = workflow.id
    try workflow.pause()
    #expect(workflow.pendingCheckID == nil && workflow.checks.last?.disposition == .interrupted)
    try rejectsWithoutMutation(&workflow) {
      try $0.assess(checkID: interrupted, outcome: .goalComplete, summary: "Late callback")
    }
    let encoded = try JSONEncoder().encode(workflow)
    var restored = try GuidanceWorkflow.decode(encoded).restoredForResume()
    #expect(restored.id == originalID && restored.actions == workflow.actions)
    #expect(restored.checks == workflow.checks && restored.phase == .paused)
    let resumed = try restored.beginCheck()
    #expect(resumed != interrupted && restored.pendingCheckID == resumed)
    try rejectsWithoutMutation(&restored) {
      try $0.assess(checkID: interrupted, outcome: .progress, summary: "Old result")
    }
    let activeRestored = try restored.restoredForResume()
    #expect(activeRestored.phase == .paused && activeRestored.pendingCheckID == nil)
    #expect(activeRestored.checks.last?.disposition == .interrupted)
    #expect(activeRestored.actions.count == 1 && activeRestored.checks.count == 3)
  }

  @Test func restorationOfAnOfferedActionRequiresARecheckNotAnOldInput() throws {
    let original = try awaitingAction(kind: .manual)
    var restored = try original.restoredForResume()
    let actionID = try #require(restored.currentAction?.id)
    #expect(restored.phase == .paused && restored.actions == original.actions)
    try rejectsWithoutMutation(&restored) {
      try $0.observeAction(observation: .init(actionID: actionID, kind: .manualContinue))
    }
    let checkID = try restored.beginCheck()
    #expect(restored.checks.last?.actionID == actionID && restored.pendingCheckID == checkID)
  }

  @Test func modelCompletionAndIndependentVerificationRemainDifferentDurableFacts() throws {
    var workflow = try GuidanceWorkflow(goal: "Verify the public task")
    let checkID = try workflow.beginCheck()
    try workflow.assess(checkID: checkID, outcome: .goalComplete, summary: "The model says done")
    #expect(workflow.phase == .modelReportedComplete && workflow.checks.last?.verification == nil)
    try rejectsWithoutMutation(&workflow) {
      try $0.verifyCompletion(checkID: checkID, verifierID: "", summary: "Invalid verifier")
    }
    try workflow.verifyCompletion(
      checkID: checkID, verifierID: "public-fixture-v1", summary: "Fixture postconditions match")
    #expect(workflow.phase == .independentlyVerified)
    #expect(workflow.checks.last?.outcome == .goalComplete)
    #expect(workflow.checks.last?.verification?.verifierID == "public-fixture-v1")
    let restored = try GuidanceWorkflow.decode(JSONEncoder().encode(workflow)).restoredForResume()
    #expect(restored == workflow && !restored.canBeginCheck)
  }

  @Test func aModelCompletionCanBeRecheckedWithoutErasingItsHistoricalAssessment() throws {
    var workflow = try observedAction()
    let completedCheck = try workflow.beginCheck()
    try workflow.assess(checkID: completedCheck, outcome: .goalComplete, summary: "Looks complete")
    #expect(workflow.phase == .modelReportedComplete && workflow.canBeginCheck)
    var restored = try workflow.restoredForResume()
    #expect(restored.phase == .paused && restored.checks.last?.outcome == .goalComplete)
    let recheck = try restored.beginCheck()
    try restored.assess(
      checkID: recheck, outcome: .unchanged, summary: "The final setting is not confirmed")
    #expect(restored.phase == .needsAttention)
    #expect(restored.checks.contains { $0.id == completedCheck && $0.outcome == .goalComplete })
    #expect(restored.actions == workflow.actions && restored.checks.count == 3)
    let finalCheck = try restored.beginCheck()
    try restored.verifyCompletion(
      checkID: finalCheck, verifierID: "public-fixture", summary: "Verified setting")
    #expect(restored.phase == .independentlyVerified && !restored.canBeginCheck)
    try rejectsWithoutMutation(&restored) { _ = try $0.beginCheck() }
  }

  @Test func abandonmentRevokesThePendingCheckWithoutInventingAResult() throws {
    var workflow = try GuidanceWorkflow(goal: "A task that is stopped")
    let checkID = try workflow.beginCheck()
    try workflow.abandon()
    #expect(workflow.phase == .abandoned && workflow.pendingCheckID == nil)
    #expect(
      workflow.checks.last?.disposition == .interrupted && workflow.checks.last?.outcome == nil)
    try rejectsWithoutMutation(&workflow) {
      try $0.assess(checkID: checkID, outcome: .goalComplete, summary: "Late result")
    }
    let revision = workflow.revision
    try workflow.abandon()
    #expect(workflow.revision == revision)
  }

  @Test func byteBudgetsUnknownFieldsAndForgedDurableReferencesReject() throws {
    #expect(throws: GuidanceWorkflow.Failure.self) { try GuidanceWorkflow(goal: " \n ") }
    #expect(throws: GuidanceWorkflow.Failure.self) {
      try GuidanceWorkflow(goal: String(repeating: "é", count: 16_385))
    }
    #expect(throws: GuidanceWorkflow.Failure.self) {
      try GuidanceWorkflow.decode(
        Data(repeating: 32, count: GuidanceWorkflow.maximumEncodedBytes + 1))
    }
    var workflow = try awaitingAction()
    let checkID = try #require(workflow.checks.last?.id)
    try rejectsWithoutMutation(&workflow) {
      try $0.assess(
        checkID: checkID, outcome: .progress, summary: String(repeating: "a", count: 2_049))
    }
    let data = try JSONEncoder().encode(workflow)
    let source = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var variants: [[String: Any]] = []
    var unknown = source
    unknown["frameID"] = UUID().uuidString
    variants.append(unknown)
    var version = source
    version["version"] = 2
    variants.append(version)
    var phase = source
    phase["phase"] = "independentlyVerified"
    variants.append(phase)
    var revision = source
    revision["revision"] = 0
    variants.append(revision)
    var pending = source
    pending["pendingCheckID"] = UUID().uuidString
    variants.append(pending)
    var records = try #require(source["actions"] as? [[String: Any]])
    records[0]["x"] = 0
    var nestedUnknown = source
    nestedUnknown["actions"] = records
    variants.append(nestedUnknown)
    records = try #require(source["actions"] as? [[String: Any]])
    var duplicates = source
    duplicates["actions"] = records + records
    variants.append(duplicates)
    var checks = try #require(source["checks"] as? [[String: Any]])
    checks[0]["proposedActionID"] = UUID().uuidString
    var brokenReference = source
    brokenReference["checks"] = checks
    variants.append(brokenReference)
    for invalid in variants {
      let malformed = try JSONSerialization.data(withJSONObject: invalid)
      #expect(throws: (any Error).self) { try GuidanceWorkflow.decode(malformed) }
    }
    #expect(try GuidanceWorkflow.decode(data) == workflow)
  }

  @Test func revisionOverflowCannotPartiallyMutateAValidRestoredValue() throws {
    let workflow = try GuidanceWorkflow(goal: "Bound revision mutation")
    let data = try JSONEncoder().encode(workflow)
    let text = try #require(String(data: data, encoding: .utf8))
    let maximum = text.replacingOccurrences(
      of: "\"revision\":0", with: "\"revision\":18446744073709551615")
    var restored = try GuidanceWorkflow.decode(Data(maximum.utf8))
    #expect(restored.revision == UInt64.max)
    try rejectsWithoutMutation(&restored) { _ = try $0.beginCheck() }
    try rejectsWithoutMutation(&restored) { try $0.pause() }
  }

  private func awaitingAction(kind: GuidanceWorkflow.ActionKind = .click) throws -> GuidanceWorkflow
  {
    var workflow = try GuidanceWorkflow(goal: "Complete a public document task")
    let checkID = try workflow.beginCheck()
    try workflow.presentAction(
      checkID: checkID, instruction: "Use the indicated control", kind: kind)
    return workflow
  }

  private func observedAction() throws -> GuidanceWorkflow {
    var workflow = try awaitingAction()
    let actionID = try #require(workflow.currentAction?.id)
    try workflow.observeAction(observation: .init(actionID: actionID, kind: .click))
    return workflow
  }

  private func rejectsWithoutMutation(
    _ workflow: inout GuidanceWorkflow, _ operation: (inout GuidanceWorkflow) throws -> Void
  ) throws {
    let original = workflow
    #expect(throws: (any Error).self) { try operation(&workflow) }
    #expect(workflow == original)
  }
}
