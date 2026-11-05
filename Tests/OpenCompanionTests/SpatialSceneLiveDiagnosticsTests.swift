import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SpatialSceneLiveDiagnosticsTests {
  private let known = ["brushed-dc-motor", "water-molecule"]

  @Test func formatSelectionIsExplicitAndConflictsNeverPromoteAnExperiment() throws {
    #expect(try SpatialSceneOutputSelection.select(arguments: ["app"]) == .ndjson)
    #expect(
      try SpatialSceneOutputSelection.select(arguments: ["app", "structuredUnifiedScene"])
        == .ndjson)
    #expect(
      try SpatialSceneOutputSelection.select(arguments: ["app", "structuredSpatialSteps"])
        == .ndjson)
    #expect(
      try SpatialSceneOutputSelection.select(arguments: ["app", "--structured-scene-output"])
        == .structuredScene)
    #expect(
      try SpatialSceneOutputSelection.select(arguments: ["app", "--structured-unified-output"])
        == .structuredUnifiedScene)
    #expect(
      try SpatialSceneOutputSelection.select(arguments: ["app", "--structured-spatial-steps"])
        == .structuredSpatialSteps)
    for arguments in [
      ["app", "--structured-scene-output", "--structured-unified-output"],
      ["app", "--structured-scene-output", "--structured-spatial-steps"],
      ["app", "--structured-spatial-steps", "--structured-unified-output"],
      [
        "app", "--structured-scene-output", "--structured-unified-output",
        "--structured-spatial-steps",
      ],
      ["app", "--structured-scene-output", "--structured-scene-output"],
      ["app", "--structured-unified-output", "--structured-unified-output"],
      ["app", "--structured-spatial-steps", "--structured-spatial-steps"],
      ["app", "--structured-scene-output=true"],
      ["app", "--structured-unified-output=water-molecule"],
      ["app", "--structured-spatial-steps=true"],
      ["app", "--structured-spatial-steps="],
      ["app", "--structured-scene-output", "true"],
      ["app", "--structured-unified-output", "false"],
      ["app", "--structured-spatial-steps", "water-molecule"],
    ] {
      #expect(throws: ProviderError.self) {
        try SpatialSceneOutputSelection.select(arguments: arguments)
      }
    }
  }

  @Test func absentFilterRetainsBothCasesAndKnownFilterSelectsOnlyThatCase() throws {
    #expect(try SpatialSceneCaseSelection.select(arguments: ["app"], knownIDs: known) == known)
    #expect(
      try SpatialSceneCaseSelection.select(
        arguments: ["app", "--structured-scene-output", "--spatial-scene-case", "water-molecule"],
        knownIDs: known) == ["water-molecule"])
    #expect(
      try SpatialSceneCaseSelection.select(
        arguments: ["app", "--spatial-scene-case", "brushed-dc-motor"], knownIDs: known)
        == ["brushed-dc-motor"])
    #expect(
      try SpatialSceneCaseSelection.select(
        arguments: ["app", "--structured-spatial-steps", "--spatial-scene-case", "water-molecule"],
        knownIDs: known) == ["water-molecule"])
  }

  @Test(arguments: [
    ["app", "--spatial-scene-case"],
    ["app", "--spatial-scene-case", "--structured-scene-output"],
    ["app", "--spatial-scene-case", ""],
    ["app", "--spatial-scene-case", "invented-case"],
    ["app", "--spatial-scene-case=water-molecule"],
    ["app", "--spatial-scene-case", "water-molecule", "--spatial-scene-case", "water-molecule"],
    ["app", "--spatial-scene-case", "brushed-dc-motor", "--spatial-scene-case"],
  ])
  func missingUnknownAndRepeatedCaseArgumentsReject(_ arguments: [String]) {
    #expect(throws: ProviderError.self) {
      try SpatialSceneCaseSelection.select(arguments: arguments, knownIDs: known)
    }
  }

  @Test func narrationIsRetainedOnlyAsAnExplicitlyBoundedPublicPreview() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(text("A public explanation."))
    let snapshot = await collector.snapshot()
    #expect(snapshot.narrationPreview == ["A public explanation."])
    #expect(snapshot.narrationPreviewUTF8Bytes == "A public explanation.".utf8.count)
    #expect(!snapshot.narrationPreviewTruncated)
    #expect(snapshot.textUnits == 1 && snapshot.sceneUnits == 0)
    #expect(snapshot.structuredStageProgress == nil)
  }

  @Test func stageProgressRetainsSeparatePartialAdmissionCounters() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    #expect(await collector.snapshot().structuredStageProgress == nil)
    let partial = StructuredSpatialStageProgress(
      decodedStages: 1, admittedSceneUnits: 1, admittedTextUnits: 0, completedStages: 0)
    await collector.structuredProgress(partial)
    let snapshot = await collector.snapshot()
    #expect(snapshot.structuredStageProgress == partial)
    #expect(snapshot.textUnits == 0 && snapshot.narrationPreview.isEmpty)
    let data = try JSONEncoder().encode(try #require(snapshot.structuredStageProgress))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
    #expect(
      object == [
        "decodedStages": 1, "admittedSceneUnits": 1,
        "admittedTextUnits": 0, "completedStages": 0,
      ])
  }

  @Test func truncationNeverSplitsAUnicodeScalarOrResumesAfterAnOmittedSuffix() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    let ascii = String(repeating: "a", count: 16_381)
    let original = ascii + "😀public suffix"
    try await collector.receive(text(original))
    try await collector.receive(text("Later text must not replace the omitted suffix."))
    let snapshot = await collector.snapshot()
    #expect(snapshot.narrationPreview == [ascii])
    #expect(snapshot.narrationPreviewUTF8Bytes == 16_381)
    #expect(snapshot.narrationPreviewTruncated)
    #expect(snapshot.textUnits == 2)
    #expect(original.hasPrefix(snapshot.narrationPreview[0]))
    #expect(!snapshot.narrationPreview[0].contains("\u{FFFD}"))
  }

  @Test func byteBudgetIsSharedAcrossEntriesAndNotResetForEachParagraph() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    let first = String(repeating: "p", count: 8_000)
    let second = String(repeating: "界", count: 8_000)
    try await collector.receive(text(first))
    try await collector.receive(text(second))
    let snapshot = await collector.snapshot()
    #expect(snapshot.narrationPreview == [first, String(repeating: "界", count: 2_794)])
    #expect(snapshot.narrationPreviewUTF8Bytes == 16_382)
    #expect(snapshot.narrationPreview.reduce(0) { $0 + $1.utf8.count } == 16_382)
    #expect(snapshot.narrationPreviewTruncated)
  }

  @Test func entryLimitRemains64AndExcessNarrationDoesNotMutateThePreview() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    for index in 0..<64 { try await collector.receive(text("Public paragraph \(index).")) }
    let before = await collector.snapshot()
    #expect(before.narrationPreview.count == 64)
    #expect(before.narrationPreviewUTF8Bytes <= 16_384 && !before.narrationPreviewTruncated)
    do {
      try await collector.receive(text("Excess paragraph."))
      Issue.record("More than 64 public narration units were accepted.")
    } catch {}
    let after = await collector.snapshot()
    #expect(after.narrationPreview == before.narrationPreview)
    #expect(after.textUnits == 64)
  }

  @Test func rejectedDepthProposalRetainsTheAcceptedDocumentAndRecordsOnlyItsGraph() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(
      .init(
        type: "scene",
        nodes: [
          .init(id: "accepted-ball", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 1)))
        ])
    )
    let before = await collector.snapshot()
    var nodes: [SceneNode] = []
    for index in 0..<35 {
      nodes.append(
        .init(
          id: "depth-\(index)", kind: .group,
          parentID: index == 0 ? nil : "depth-\(index - 1)", spatial3D: .init()))
    }
    do {
      try await collector.receive(.init(type: "scene", nodes: nodes))
      Issue.record("An excessive native group depth was accepted.")
    } catch {
      #expect(error.localizedDescription.contains("scene depth"))
    }
    let after = await collector.snapshot()
    #expect(after.document == before.document)
    #expect(after.sceneUnits == before.sceneUnits)
    #expect(after.progressiveGeometryUnits == before.progressiveGeometryUnits)
    let rejected = try #require(after.lastRejectedScene)
    #expect(rejected.error.contains("scene depth"))
    #expect(rejected.nodeCount == 35 && rejected.meshCount == 0)
    #expect(rejected.nodes.count == 35 && !rejected.truncated)
    #expect(rejected.nodes.last?.parentID == "depth-33")
    #expect(rejected.nodes.allSatisfy { $0.kind == "group" && $0.targetID == nil })
  }

  @Test func rejectedGraphBoundsRowsIdentifiersAndCountsTheEntireProposedUnit() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    let longIdentifier = String(repeating: "😀", count: 1_000)
    var nodes: [SceneNode] = [
      .init(
        id: longIdentifier, kind: .text, text: "PUBLIC_DIAGNOSTIC_TEXT_MUST_NOT_BE_COPIED",
        parentID: longIdentifier,
        spatial3D: .init(labelAnchor: .init(targetID: longIdentifier)))
    ]
    for index in 1..<128 { nodes.append(.init(id: "public-group-\(index)", kind: .group)) }
    for index in 0..<2 { nodes.append(.init(id: "uncaptured-mesh-\(index)", kind: .mesh)) }
    do {
      try await collector.receive(.init(type: "scene", nodes: nodes))
      Issue.record("The invalid native identifiers were accepted.")
    } catch {}
    let snapshot = await collector.snapshot()
    #expect(snapshot.document.nodes.isEmpty && snapshot.sceneUnits == 0)
    let rejected = try #require(snapshot.lastRejectedScene)
    #expect(rejected.nodeCount == 130 && rejected.meshCount == 2)
    #expect(rejected.nodes.count == 128 && rejected.truncated)
    #expect(
      rejected.nodes.allSatisfy {
        $0.id.utf8.count <= 256 && ($0.parentID?.utf8.count ?? 0) <= 256
          && ($0.targetID?.utf8.count ?? 0) <= 256
      })
    #expect(rejected.nodes.first?.id == String(repeating: "😀", count: 64))
    #expect(rejected.error.utf8.count <= 2_048)
    let encoded = try JSONEncoder().encode(rejected)
    #expect(encoded.count < 1_000_000)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("PUBLIC_DIAGNOSTIC_TEXT"))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let rows = try #require(object["nodes"] as? [[String: Any]])
    #expect(rows.allSatisfy { Set($0.keys).isSubset(of: ["id", "kind", "parentID", "targetID"]) })
  }

  private func text(_ value: String) -> ProviderUnit {
    ProviderUnit(type: "text", text: value)
  }
}
