import CompanionCore
import Foundation
import Testing

@testable import OpenCompanion

/// Exercise the actual host acceptance boundary without starting a turn task,
/// reading the library/Keychain, capturing a screen, opening UI, or speaking.
@Suite @MainActor struct AppModelResponsePolicyTests {
  @Test func aPreviousAutomaticGuidanceFrameRequiresFreshCaptureAndExcludesSelectedText() {
    let frame = screenFrame()
    let plan = ResponseInputPlan.resolve(
      policy: guidancePolicy, voiceOnly: false,
      selectedContext: "Public saved file fixture that must not be transmitted", evidence: frame,
      explicitManualEvidence: nil)

    #expect(plan.requiresFreshGuidanceCapture)
    #expect(plan.context.isEmpty)
    #expect(plan.image == nil && plan.evidenceIdentity == nil)
  }

  @Test(arguments: [
    "Selected file: public fixture text",
    "Saved memory: public fixture text",
    "User-drawn spatial context (normalized top-left points): [[0.1,0.2]]",
  ])
  func manualGuidanceRetainsOnlyItsExactCapturedScopeAndScreenSemantics(
    _ unrelatedSelectedText: String
  ) {
    let frame = screenFrame()
    let identity = ScreenEvidenceIdentity(frame)
    let plan = ResponseInputPlan.resolve(
      policy: guidancePolicy, voiceOnly: false, selectedContext: unrelatedSelectedText,
      evidence: frame, explicitManualEvidence: identity)

    #expect(!plan.requiresFreshGuidanceCapture)
    #expect(plan.context == frame.semanticText)
    #expect(!plan.context.contains(unrelatedSelectedText))
    #expect(plan.image == frame.image)
    #expect(plan.evidenceIdentity == identity)
    #expect(plan.evidenceIdentity?.windowID == frame.windowID)
    #expect(plan.evidenceIdentity?.screenRect == frame.screenRect)
  }

  @Test func replacementFramesAndChangedRegionsCannotInheritManualCaptureProvenance() {
    let manual = screenFrame()
    let identity = ScreenEvidenceIdentity(manual)
    var replacement = manual
    replacement.frameID = UUID()
    var newRevision = manual
    newRevision.revision += 1
    var newRegion = manual
    newRegion.screenRect.origin.x += 20
    for changed in [replacement, newRevision, newRegion] {
      let plan = ResponseInputPlan.resolve(
        policy: guidancePolicy, voiceOnly: false, selectedContext: "Selected memory fixture",
        evidence: changed, explicitManualEvidence: identity)
      #expect(plan.requiresFreshGuidanceCapture)
      #expect(plan.context.isEmpty && plan.image == nil && plan.evidenceIdentity == nil)
    }
  }

  @Test func voiceGuidanceUsesFreshEvidenceEvenWhenAManualFrameIsSelected() {
    let frame = screenFrame()
    let plan = ResponseInputPlan.resolve(
      policy: guidancePolicy, voiceOnly: true, selectedContext: "Selected file fixture",
      evidence: frame, explicitManualEvidence: ScreenEvidenceIdentity(frame))

    #expect(plan.requiresFreshGuidanceCapture)
    #expect(plan.context.isEmpty && plan.image == nil && plan.evidenceIdentity == nil)
  }

  @Test func ordinaryVoiceOmitsAttachmentsWhileOrdinaryTypedInputRetainsThem() {
    let frame = screenFrame()
    let policy = ResponsePolicy.resolve(
      text: "What is a prime number?", screenGuidanceEnabled: true)
    let selected = "Selected public file fixture\n"
    let voice = ResponseInputPlan.resolve(
      policy: policy, voiceOnly: true, selectedContext: selected, evidence: frame,
      explicitManualEvidence: ScreenEvidenceIdentity(frame))
    #expect(!voice.requiresFreshGuidanceCapture)
    #expect(voice.context.isEmpty && voice.image == nil && voice.evidenceIdentity == nil)

    let typed = ResponseInputPlan.resolve(
      policy: policy, voiceOnly: false, selectedContext: selected, evidence: frame,
      explicitManualEvidence: ScreenEvidenceIdentity(frame))
    #expect(!typed.requiresFreshGuidanceCapture)
    #expect(typed.context == selected + frame.semanticText)
    #expect(typed.image == frame.image)
    #expect(typed.evidenceIdentity == ScreenEvidenceIdentity(frame))
  }

  @Test func ordinaryTypedInputKeepsSelectedTextButOmitsAnEarlierAutomaticFrame() {
    let frame = screenFrame()
    let policy = ResponsePolicy.resolve(
      text: "What is a prime number?", screenGuidanceEnabled: true)
    let selected = "Selected public memory fixture\n"
    let plan = ResponseInputPlan.resolve(
      policy: policy, voiceOnly: false, selectedContext: selected, evidence: frame,
      explicitManualEvidence: nil)

    #expect(!plan.requiresFreshGuidanceCapture)
    #expect(plan.context == selected)
    #expect(!plan.context.contains(frame.semanticText))
    #expect(plan.image == nil && plan.evidenceIdentity == nil)
  }

  @Test(arguments: [ResponsePolicy.Route.conversation, .notebook])
  func nonGuidancePoliciesIgnoreTargetsBeforeValidationOrPresentation(
    _ route: ResponsePolicy.Route
  ) throws {
    let model = modelWithRetainedNotebook(section: "Companion")
    defer { model.stop() }
    let original = try #require(model.scene)
    let prompt = route == .notebook ? "Draw a diagram of a lever" : "What is a prime number?"
    let policy = ResponsePolicy.resolve(text: prompt, screenGuidanceEnabled: true)
    #expect(policy.route == route)
    model.configureResponseOutput(policy)
    let frame = screenFrame()
    model.evidence = frame
    var cursorCalls = 0
    var guidanceCalls = 0
    model.onCursorTargetAccepted = { _, _, _ in
      cursorCalls += 1
      return 0
    }
    model.onScreenGuidanceTargetAccepted = { _, _, _, _ in guidanceCalls += 1 }

    // The synthetic frame's PID cannot pass OverlayHost foreground validation.
    // A host route gate must return before validation, callbacks or native UI.
    try model.accept(
      decode([
        "type": "target",
        "target": [
          "x": 0.1, "y": 0.2, "width": 0.1, "height": 0.1,
          "instruction": "Select the public fixture button.", "label": "New chat",
          "shape": "ellipse", "advanceOn": "click",
        ],
      ]), generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(frame))

    #expect(cursorCalls == 0 && guidanceCalls == 0)
    #expect(model.messages.isEmpty)
    #expect(model.scene == original)
    #expect(model.section == "Companion")
  }

  @Test(arguments: ["Companion", "Notebook"])
  func chatGPTGuidanceCannotReplaceARetainedNotebook(_ initialSection: String) throws {
    let model = modelWithRetainedNotebook(section: initialSection)
    defer { model.stop() }
    let original = try #require(model.scene)
    var openings = 0
    model.onSceneReady = { openings += 1 }
    let policy = ResponsePolicy.resolve(
      text: "how to create a new chat in ChatGPT", screenGuidanceEnabled: true,
      inNotebook: initialSection == "Notebook", hasNotebook: true)
    #expect(policy.route == .screenGuidance)
    #expect(!policy.includesExistingNotebook)
    model.configureResponseOutput(policy)

    try model.accept(diagramUnit(), generation: model.taskGeneration, expectedEvidence: nil)
    try model.accept(
      textUnit("Use the new chat control."), generation: model.taskGeneration, expectedEvidence: nil
    )

    #expect(model.responsePolicy == policy)
    #expect(model.scene == original)
    #expect(model.section == initialSection)
    #expect(openings == 0)
    #expect(model.messages.count == 1)
    #expect(model.messages.first?.role == "assistant")
    #expect(model.messages.first?.text == "Use the new chat control.")
  }

  @Test func aCandidateFromAnEarlierFrameCannotReachCursorOrOverlayPresentation() throws {
    let model = modelWithRetainedNotebook(section: "Companion")
    defer { model.stop() }
    model.configureResponseOutput(guidancePolicy)
    let frame = screenFrame()
    model.evidence = frame
    var cursorCalls = 0
    model.onCursorTargetAccepted = { _, _, _ in
      cursorCalls += 1
      return 0
    }
    let staleID = ScreenGrounding.candidateID(frameID: UUID(), index: 0)
    let unit = try decode([
      "type": "target",
      "target": [
        "candidateID": staleID, "instruction": "Click New task.", "advanceOn": "click",
      ],
    ])
    #expect(throws: (any Error).self) {
      try model.accept(
        unit, generation: model.taskGeneration, expectedEvidence: ScreenEvidenceIdentity(frame))
    }
    #expect(cursorCalls == 0)
    #expect(model.messages.isEmpty)
    #expect(model.section == "Companion")
  }

  @Test func ordinaryQuestionDoesNotInheritAnOpenNotebookCapability() throws {
    let model = modelWithRetainedNotebook(section: "Notebook")
    defer { model.stop() }
    let original = try #require(model.scene)
    var openings = 0
    model.onSceneReady = { openings += 1 }
    let policy = ResponsePolicy.resolve(
      text: "What is a prime number?", screenGuidanceEnabled: true,
      inNotebook: true, hasNotebook: true)
    #expect(policy.route == .conversation)
    #expect(!policy.allowsNotebook && !policy.includesExistingNotebook)
    model.configureResponseOutput(policy)

    try model.accept(diagramUnit(), generation: model.taskGeneration, expectedEvidence: nil)
    try model.accept(
      textUnit("A prime number has exactly two positive divisors."),
      generation: model.taskGeneration, expectedEvidence: nil)

    #expect(model.scene == original)
    #expect(model.section == "Notebook")
    #expect(openings == 0)
    #expect(model.messages.last?.text == "A prime number has exactly two positive divisors.")
  }

  @Test func explicitDiagramCreatesANewDocumentAndLaterUnitsPatchOnlyThatDocument() throws {
    let model = modelWithRetainedNotebook(section: "Companion")
    defer { model.stop() }
    let original = try #require(model.scene)
    var openings = 0
    model.onSceneReady = { openings += 1 }
    let policy = ResponsePolicy.resolve(
      text: "Draw a diagram of a simple lever", screenGuidanceEnabled: true,
      inNotebook: false, hasNotebook: true)
    #expect(policy.allowsNotebook && !policy.includesExistingNotebook)
    model.configureResponseOutput(policy)

    try model.accept(diagramUnit(), generation: model.taskGeneration, expectedEvidence: nil)
    let created = try #require(model.scene)
    #expect(created.id != original.id)
    #expect(created.revision == 1)
    #expect(Set(created.nodes.map(\.id)) == ["fresh-label", "fresh-box"])
    #expect(Set(created.nodes.map(\.id)).isDisjoint(with: original.nodes.map(\.id)))
    #expect(model.section == "Notebook")
    #expect(openings == 1)

    try model.accept(
      patchUnit(id: "fresh-label", text: "First update", baseRevision: created.revision),
      generation: model.taskGeneration, expectedEvidence: nil)
    let firstPatch = try #require(model.scene)
    #expect(firstPatch.id == created.id && firstPatch.revision == 2)
    #expect(firstPatch.nodes.first { $0.id == "fresh-label" }?.text == "First update")
    #expect(
      firstPatch.nodes.first { $0.id == "fresh-box" }
        == created.nodes.first { $0.id == "fresh-box" })

    try model.accept(
      patchUnit(id: "fresh-label", text: "Second update", baseRevision: firstPatch.revision),
      generation: model.taskGeneration, expectedEvidence: nil)
    let secondPatch = try #require(model.scene)
    #expect(secondPatch.id == created.id && secondPatch.revision == 3)
    #expect(secondPatch.nodes.first { $0.id == "fresh-label" }?.text == "Second update")
    #expect(Set(secondPatch.nodes.map(\.id)) == Set(created.nodes.map(\.id)))
    #expect(openings == 1)
  }

  @Test func anExplicitExistingNotebookEditPreservesUnrelatedParts() throws {
    let model = modelWithRetainedNotebook(section: "Notebook")
    defer { model.stop() }
    let original = try #require(model.scene)
    let selected = try #require(original.nodes.first { $0.kind == .text })
    var openings = 0
    model.onSceneReady = { openings += 1 }
    let policy = ResponsePolicy.resolve(
      text: "Change the selected label in this notebook", screenGuidanceEnabled: true,
      inNotebook: true, hasNotebook: true)
    #expect(policy.allowsNotebook && policy.includesExistingNotebook)
    model.configureResponseOutput(policy)

    try model.accept(
      patchUnit(id: selected.id, text: "Edited by this request", baseRevision: original.revision),
      generation: model.taskGeneration, expectedEvidence: nil)
    let edited = try #require(model.scene)
    #expect(edited.id == original.id)
    #expect(edited.revision == original.revision + 1)
    #expect(edited.nodes.first { $0.id == selected.id }?.text == "Edited by this request")
    #expect(
      edited.nodes.filter { $0.id != selected.id } == original.nodes.filter { $0.id != selected.id }
    )
    #expect(edited.title == original.title)
    #expect(model.section == "Notebook")
    #expect(openings == 1)
  }

  @Test(arguments: [
    "Explain how a motor works, but answer with text only.",
    "Create a diagram of a motor, but don't open a notebook.",
  ])
  func explicitNotebookOptOutIgnoresSceneUnitsWithoutLosingText(_ request: String) throws {
    let model = modelWithRetainedNotebook(section: "Companion")
    defer { model.stop() }
    let original = try #require(model.scene)
    var openings = 0
    model.onSceneReady = { openings += 1 }
    let policy = ResponsePolicy.resolve(
      text: request, screenGuidanceEnabled: true, inNotebook: false, hasNotebook: true)
    #expect(!policy.allowsNotebook)
    model.configureResponseOutput(policy)

    try model.accept(diagramUnit(), generation: model.taskGeneration, expectedEvidence: nil)
    try model.accept(
      textUnit("A text-only answer."), generation: model.taskGeneration, expectedEvidence: nil)

    #expect(model.scene == original)
    #expect(model.section == "Companion")
    #expect(openings == 0)
    #expect(model.messages.last?.text == "A text-only answer.")
  }

  @Test func stopRejectsOldSceneAndTextBeforeEitherCanMutateCurrentState() throws {
    let model = modelWithRetainedNotebook(section: "Companion")
    defer { model.stop() }
    let original = try #require(model.scene)
    var openings = 0
    model.onSceneReady = { openings += 1 }
    model.configureResponseOutput(
      .resolve(text: "Draw a diagram of a lever", screenGuidanceEnabled: true))
    let oldGeneration = model.taskGeneration
    let oldScene = try diagramUnit()
    let oldText = try textUnit("Cancelled text")
    model.stop()

    #expect(throws: CancellationError.self) {
      try model.accept(oldScene, generation: oldGeneration, expectedEvidence: nil)
    }
    #expect(throws: CancellationError.self) {
      try model.accept(oldText, generation: oldGeneration, expectedEvidence: nil)
    }
    #expect(model.scene == original)
    #expect(model.section == "Companion")
    #expect(openings == 0)
    #expect(model.messages.isEmpty)
  }

  private func modelWithRetainedNotebook(section: String) -> AppModel {
    let model = AppModel(acceptanceMode: true)
    model.configuration.speechEnabled = false
    model.scene = BuiltInLessons.lever()
    model.section = section
    return model
  }

  private var guidancePolicy: ResponsePolicy {
    .resolve(text: "how to create a new chat in ChatGPT", screenGuidanceEnabled: true)
  }

  private func screenFrame() -> OpenCompanion.ScreenEvidence {
    OpenCompanion.ScreenEvidence(
      frameID: UUID(), revision: 2, capturedAt: ProcessInfo.processInfo.systemUptime,
      displayID: 1, foregroundPID: -1, foregroundName: "Public capture fixture",
      screenRect: CGRect(x: -700, y: 100, width: 600, height: 400), windowID: 55,
      image: Data("Public captured-image fixture".utf8),
      semanticText: "Public text grounded in this captured window")
  }

  private func diagramUnit() throws -> ProviderUnit {
    try decode([
      "type": "scene", "title": "New request diagram", "baseDocumentRevision": 0,
      "nodes": [
        [
          "id": "fresh-label", "kind": "text", "x": 32, "y": 32, "width": 260, "height": 40,
          "text": "A new diagram",
        ],
        ["id": "fresh-box", "kind": "rectangle", "x": 40, "y": 90, "width": 220, "height": 120],
      ],
    ])
  }

  private func patchUnit(id: String, text: String, baseRevision: Int) throws -> ProviderUnit {
    try decode([
      "type": "scene", "baseDocumentRevision": baseRevision,
      "operations": [["op": "node.patch", "id": id, "fields": ["text": text]]],
    ])
  }

  private func textUnit(_ text: String) throws -> ProviderUnit {
    try decode(["type": "text", "text": text])
  }

  private func decode(_ object: [String: Any]) throws -> ProviderUnit {
    try JSONDecoder().decode(
      ProviderUnit.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
