import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

struct SpatialSceneLiveDiagnosticsTests {
  private let known = ["brushed-dc-motor", "water-molecule", "simple-pendulum"]

  @Test func geometryFirstIsExplicitAndCannotMixWithStructuredFormats() throws {
    #expect(
      try SpatialSceneStartSelection.select(arguments: ["app"], outputMode: .ndjson)
        == .introductionFirst)
    #expect(
      try SpatialSceneStartSelection.select(
        arguments: ["app", "geometryFirst"], outputMode: .ndjson) == .introductionFirst)
    #expect(
      try SpatialSceneStartSelection.select(
        arguments: ["app", "--geometry-first"], outputMode: .ndjson) == .geometryFirst)
    #expect(
      try SpatialSceneStartSelection.select(
        arguments: ["app", "--geometry-first", "--spatial-scene-case", "water-molecule"],
        outputMode: .ndjson) == .geometryFirst)
    for mode in [CodexOutputMode.structuredScene, .structuredUnifiedScene, .structuredSpatialSteps]
    {
      #expect(
        try SpatialSceneStartSelection.select(arguments: ["app"], outputMode: mode)
          == .introductionFirst)
      #expect(throws: ProviderError.self) {
        try SpatialSceneStartSelection.select(
          arguments: ["app", "--geometry-first"], outputMode: mode)
      }
    }
  }

  @Test(arguments: [
    ["app", "--geometry-first", "--geometry-first"],
    ["app", "--geometry-first=true"], ["app", "--geometry-first="],
    ["app", "--geometry-first", "true"], ["app", "--geometry-first", "false"],
    ["app", "--geometry-first", "introductionFirst"],
    ["app", "--geometry-first", "water-molecule"], ["app", "--geometry-first-unsafe"],
  ])
  func malformedGeometryFirstFlagCannotSelectACandidate(_ arguments: [String]) {
    #expect(throws: ProviderError.self) {
      try SpatialSceneStartSelection.select(arguments: arguments, outputMode: .ndjson)
    }
  }

  @Test func firstAcceptedMetadataDistinguishesIntroductionFromLaterRealGeometry() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(text("A public introduction."))
    try await collector.receive(
      .init(
        type: "scene",
        nodes: [
          .init(id: "assembly", kind: .group, spatial3D: .init()),
          .init(
            id: "ball", kind: .mesh, parentID: "assembly",
            spatial3D: .init(geometry: .sphere(radius: 1))),
        ]))
    let snapshot = await collector.snapshot()
    let first = try #require(snapshot.firstAdmission)
    let scene = try #require(snapshot.firstSceneAdmission)
    #expect(first.unitType == "text" && first.nodeCount == 0 && first.typedMeshCount == 0)
    #expect(scene.unitType == "scene" && scene.nodeCount == 2 && scene.groupCount == 1)
    #expect(scene.typedMeshCount == 1 && scene.drawableTypedMeshCount == 1)
    #expect(
      SpatialSceneStartSelection.unmetChecks(
        mode: .geometryFirst, firstAdmission: first, firstSceneAdmission: scene) == [
          "geometry-first-unit"
        ])
    #expect(
      SpatialSceneStartSelection.unmetChecks(
        mode: .introductionFirst, firstAdmission: first, firstSceneAdmission: scene
      ).isEmpty)
  }

  @Test func geometryFirstRequiresActualDrawableGeometryRatherThanAnEmptyGroupOrTransparentMesh()
    async throws
  {
    for style in ["group", "opacity", "material"] {
      let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
      var nodes = [SceneNode(id: "assembly", kind: .group, spatial3D: .init())]
      if style != "group" {
        nodes.append(
          .init(
            id: "ball", kind: .mesh,
            fill: style == "material" ? "#4488CC00" : "#4488CC",
            opacity: style == "opacity" ? 0 : 1,
            parentID: "assembly", spatial3D: .init(geometry: .sphere(radius: 1))))
      }
      try await collector.receive(.init(type: "scene", nodes: nodes))
      let snapshot = await collector.snapshot()
      let first = try #require(snapshot.firstAdmission)
      #expect(first.unitType == "scene" && first.drawableTypedMeshCount == 0)
      #expect(first.typedMeshCount == (style == "group" ? 0 : 1))
      #expect(
        SpatialSceneStartSelection.unmetChecks(
          mode: .geometryFirst, firstAdmission: first,
          firstSceneAdmission: snapshot.firstSceneAdmission)
          == ["geometry-first-drawable-mesh"])
    }
  }

  @Test func successfulFirstSceneCountsStayImmutableAcrossARejectedLaterProposal() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(
      .init(
        type: "scene",
        nodes: [
          .init(id: "public-ball", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 1)))
        ]))
    let before = await collector.snapshot()
    #expect(
      SpatialSceneStartSelection.unmetChecks(
        mode: .geometryFirst, firstAdmission: before.firstAdmission,
        firstSceneAdmission: before.firstSceneAdmission
      ).isEmpty)
    do {
      try await collector.receive(
        .init(
          type: "scene",
          nodes: [
            .init(
              id: "invalid", kind: .text, spatial3D: .init(labelAnchor: .init(targetID: "missing")))
          ]))
      Issue.record("A missing label target was accepted.")
    } catch {}
    let after = await collector.snapshot()
    #expect(after.document == before.document && after.sceneUnits == before.sceneUnits)
    #expect(
      after.firstAdmission == before.firstAdmission
        && after.firstSceneAdmission == before.firstSceneAdmission)
    let encoded = try JSONEncoder().encode(try #require(after.firstSceneAdmission))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(
      Set(object.keys) == [
        "unitType", "nodeCount", "groupCount", "typedMeshCount", "drawableTypedMeshCount",
      ])
    #expect(!String(decoding: encoded, as: UTF8.self).contains("public-ball"))
  }

  @Test func rejectedFirstProposalCannotClaimAnyAdmittedUnit() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    do {
      try await collector.receive(
        .init(
          type: "scene",
          nodes: [
            .init(id: "invalid", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: -1)))
          ]))
      Issue.record("An invalid primitive was accepted.")
    } catch {}
    let snapshot = await collector.snapshot()
    #expect(snapshot.firstAdmission == nil && snapshot.firstSceneAdmission == nil)
    #expect(snapshot.document.nodes.isEmpty && snapshot.sceneUnits == 0)
  }

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

  @Test func absentFilterRetainsSuppliedCasesAndKnownFilterSelectsOnlyThatCase() throws {
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
        arguments: ["app", "--spatial-scene-case", "simple-pendulum"], knownIDs: known)
        == ["simple-pendulum"])
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

  @Test func attachedNarrationCountsOnlyAfterAnAtomicAcceptedScene() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    let unit = ProviderUnit(
      type: "scene", nodes: [.init(id: "part", kind: .rectangle, width: 20, height: 20)],
      narration: "Public scene narration.", focusID: "part")
    try await collector.receive(unit)
    let accepted = await collector.snapshot()
    #expect(accepted.attachedNarrationUnits == 1 && accepted.textUnits == 1)
    #expect(accepted.focusedSceneUnits == 1)
    #expect(accepted.focusTargets == ["part"])
    #expect(accepted.narrationPreview == ["Public scene narration."])
    var invalid = unit
    invalid.narration = String(repeating: "a", count: 32_001)
    do {
      try await collector.receive(invalid)
      Issue.record("Oversized attached narration was accepted.")
    } catch {}
    let after = await collector.snapshot()
    #expect(after.document == accepted.document && after.attachedNarrationUnits == 1)
    #expect(after.focusedSceneUnits == 1)
    #expect(after.focusTargets == accepted.focusTargets)
    #expect(after.narrationPreview == accepted.narrationPreview && after.sceneUnits == 1)
  }

  @Test func publicRejectedUnitDiagnosticIsBoundedFirstOnlyAndDoesNotAdmitContent() async {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    await collector.recordRejectedLine(
      Data(repeating: 65, count: ProviderTextStreamDecoder.maximumLineBytes + 1))
    #expect(await collector.snapshot().rejectedLine == nil)
    let publicUnit = Data(#"{"type":"scene","connectors":[{"unexpected":true}]}"#.utf8)
    await collector.recordRejectedLine(publicUnit)
    await collector.recordRejectedLine(Data("later".utf8))
    let snapshot = await collector.snapshot()
    #expect(snapshot.rejectedLine == publicUnit)
    #expect(snapshot.sceneUnits == 0 && snapshot.textUnits == 0)
    #expect(snapshot.compiledConnectorCount == 0 && snapshot.connectorUnits == 0)
    #expect(snapshot.document.nodes.isEmpty && snapshot.document.revision == 0)
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

  @Test func deliveryAuditIsAbsentUntilTheExplicitTerminalCallbackArrives() async throws {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(text("An ordinary accepted public paragraph."))
    try await collector.receive(
      .init(
        type: "scene",
        nodes: [
          .init(id: "public-ball", kind: .mesh, spatial3D: .init(geometry: .sphere(radius: 1)))
        ]))
    let snapshot = await collector.snapshot()
    #expect(snapshot.ndjsonAudit == nil)
    #expect(snapshot.textUnits == 1 && snapshot.sceneUnits == 1)
    #expect(snapshot.firstAdmission?.unitType == "text")
  }

  @Test func failedTerminalAuditSurvivesARejectedSceneWithoutChangingEarlierAdmission()
    async throws
  {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    try await collector.receive(
      .init(
        type: "scene",
        nodes: [
          .init(
            id: "PUBLIC_NODE_ID_NOT_IN_AUDIT", kind: .mesh,
            spatial3D: .init(geometry: .sphere(radius: 1)))
        ], narration: "PUBLIC_NARRATION_NOT_IN_AUDIT"))
    let before = await collector.snapshot()
    do {
      try await collector.receive(
        .init(
          type: "scene",
          nodes: [
            .init(
              id: "invalid-label", kind: .text,
              spatial3D: .init(labelAnchor: .init(targetID: "missing-part")))
          ]))
      Issue.record("A scene with a missing label target was admitted.")
    } catch {}
    let failed = deliveryAudit(outcome: .failed, acceptedUnits: 1)
    await collector.recordNDJSONAudit(failed)
    let after = await collector.snapshot()
    #expect(after.ndjsonAudit == failed && after.ndjsonAudit?.outcome == .failed)
    #expect(after.document == before.document && after.sceneUnits == before.sceneUnits)
    #expect(after.textUnits == before.textUnits && after.firstAdmission == before.firstAdmission)
    #expect(after.lastRejectedScene != nil)
    let encoded = try JSONEncoder().encode(try #require(after.ndjsonAudit))
    let roundTripped = try JSONDecoder().decode(CodexNDJSONAudit.self, from: encoded)
    #expect(roundTripped == failed)
    let payload = String(decoding: encoded, as: UTF8.self)
    #expect(!payload.contains("PUBLIC_NODE_ID_NOT_IN_AUDIT"))
    #expect(!payload.contains("PUBLIC_NARRATION_NOT_IN_AUDIT"))
    #expect(!payload.contains("missing-part"))
  }

  @Test func cancelledTerminalAuditCannotBeReplacedByALateSuccessOrClaimAdmission() async {
    let collector = SpatialSceneAcceptanceCollector(started: ProcessInfo.processInfo.systemUptime)
    let cancelled = deliveryAudit(outcome: .cancelled, acceptedUnits: 0)
    await collector.recordNDJSONAudit(cancelled)
    await collector.recordNDJSONAudit(deliveryAudit(outcome: .completed, acceptedUnits: 1))
    let snapshot = await collector.snapshot()
    #expect(snapshot.ndjsonAudit == cancelled)
    #expect(snapshot.ndjsonAudit?.acceptedUnits == 0)
    #expect(snapshot.document.nodes.isEmpty && snapshot.document.revision == 0)
    #expect(snapshot.sceneUnits == 0 && snapshot.textUnits == 0)
    #expect(snapshot.firstAdmission == nil && snapshot.firstSceneAdmission == nil)
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

  private func deliveryAudit(outcome: CodexNDJSONAudit.Outcome, acceptedUnits: Int)
    -> CodexNDJSONAudit
  {
    .init(
      outcome: outcome,
      items: [
        .init(
          ordinal: 0, phase: "final_answer", started: true, deltaEvents: 2,
          deltaUTF8Bytes: 120, completedUTF8Bytes: nil, appendedSuffixUTF8Bytes: 0,
          streamedSHA256: String(repeating: "a", count: 64), completedSHA256: nil)
      ],
      acceptedUnits: acceptedUnits, deltaUTF8Bytes: 120, completedUTF8Bytes: 0,
      completedOnlyItems: 0, duplicateCompletions: 0, ignoredScopeEvents: 0)
  }
}
