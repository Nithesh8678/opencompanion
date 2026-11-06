import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceFixtureStateAcceptanceTests {
  private typealias Subject = GuidanceFixtureStateAcceptance

  @Test func preservesActualStateInsteadOfAssumingTheRequestedPostcondition() throws {
    let before = try snapshot(tableMatches: false, checked: true)
    let after = try snapshot(tableMatches: true, checked: false)
    #expect(!before.tableNameMatchesReleaseQA && before.protectDataChecked)
    #expect(after.tableNameMatchesReleaseQA && !after.protectDataChecked)
    #expect(after.publicFixturePID == 42 && after.capturedAtUptime == 123)
  }

  @Test func missingDuplicateWrongRoleAndHiddenControlsCannotProduceAReceipt() {
    let field = observation(.tableName)
    let checkbox = observation(.protectData)
    #expect(throws: Subject.Failure.missingControl(.protectData)) {
      try validate([field])
    }
    #expect(throws: Subject.Failure.duplicateControl(.tableName)) {
      try validate([field, checkbox, field])
    }
    #expect(throws: Subject.Failure.invalidRole(.tableName)) {
      try validate([observation(.tableName, role: "AXSecureTextField"), checkbox])
    }
    #expect(throws: Subject.Failure.hiddenControl(.protectData)) {
      try validate([field, observation(.protectData, hidden: true)])
    }
  }

  @Test func valueTypesAndMetadataFailClosed() {
    #expect(throws: Subject.Failure.invalidValue(.protectData)) {
      try validate([
        observation(.tableName),
        .init(
          control: .protectData, role: "AXCheckBox", hidden: false, value: .tableNameMatches(true)),
      ])
    }
    #expect(throws: Subject.Failure.staleIdentity) {
      try Subject.validatedSnapshot(
        observations: [observation(.tableName), observation(.protectData)],
        capturedAtUptime: .nan, publicFixturePID: 42)
    }
    #expect(throws: Subject.Failure.staleIdentity) {
      try Subject.validatedSnapshot(
        observations: [observation(.tableName), observation(.protectData)],
        capturedAtUptime: 123, publicFixturePID: 0)
    }
  }

  @Test func traversalCannotSilentlyTruncateAndMissDuplicatesBeyondTheBudget() throws {
    var budget = Subject.TraversalBudget()
    try budget.visit(depth: 0)
    #expect(throws: Subject.Failure.traversalLimitExceeded) {
      try budget.admitChildren(128, depth: 0)
    }
    for _ in 0..<127 { try budget.visit(depth: 8) }
    #expect(budget.visited == 128 && budget.remaining == 0)
    try budget.admitChildren(0, depth: 8)
    #expect(throws: Subject.Failure.traversalLimitExceeded) {
      try budget.visit(depth: 8)
    }
    let shallow = Subject.TraversalBudget()
    #expect(throws: Subject.Failure.traversalLimitExceeded) {
      try shallow.admitChildren(1, depth: 8)
    }
    var deep = Subject.TraversalBudget()
    #expect(throws: Subject.Failure.traversalLimitExceeded) {
      try deep.visit(depth: 9)
    }
  }

  @Test func encodedSnapshotContainsOnlyApprovedChecksAndIdentityMetadata() throws {
    let data = try JSONEncoder().encode(snapshot(tableMatches: true, checked: false))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(object.keys) == [
        "tableNameMatchesReleaseQA", "protectDataChecked", "capturedAtUptime", "publicFixturePID",
      ])
    #expect(object["tableNameMatchesReleaseQA"] as? Bool == true)
    #expect(object["protectDataChecked"] as? Bool == false)
    #expect(!String(decoding: data, as: UTF8.self).contains("Release QA"))
  }

  private func observation(
    _ control: Subject.Control, role: String? = nil, hidden: Bool = false
  ) -> Subject.Observation {
    .init(
      control: control, role: role ?? (control == .tableName ? "AXTextField" : "AXCheckBox"),
      hidden: hidden,
      value: control == .tableName ? .tableNameMatches(true) : .checkboxChecked(false))
  }

  private func validate(_ observations: [Subject.Observation]) throws -> Subject.Snapshot {
    try Subject.validatedSnapshot(
      observations: observations, capturedAtUptime: 123, publicFixturePID: 42)
  }

  private func snapshot(tableMatches: Bool, checked: Bool) throws -> Subject.Snapshot {
    try validate([
      .init(
        control: .tableName, role: "AXTextField", hidden: false,
        value: .tableNameMatches(tableMatches)),
      .init(
        control: .protectData, role: "AXCheckBox", hidden: false, value: .checkboxChecked(checked)),
    ])
  }
}
