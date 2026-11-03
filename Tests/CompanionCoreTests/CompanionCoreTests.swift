import Foundation
import Testing
@testable import CompanionCore

struct CompanionCoreTests {
    @Test func coordinateRoundTripOnNegativeSecondaryDisplay() throws {
        let transform = try AffineTransform2D.imageToAppKit(pixelSize: .init(width: 3840, height: 2160), display: .init(x: -1920, y: 220, width: 1920, height: 1080))
        let origin = transform.applying(to: .init(x: 0, y: 0))
        #expect(origin == Point2D(x: -1920, y: 1300))
        let point = Point2D(x: 1273.6, y: 825.1)
        let result = try transform.inverted().applying(to: transform.applying(to: point))
        #expect(abs(result.x - point.x) < 1e-8); #expect(abs(result.y - point.y) < 1e-8)
        #expect(throws: CoreError.invalidTransform) { try AffineTransform2D(a: 0, d: 0).inverted() }
    }
    @Test func affineCompositionPreservesOrder() {
        let translate = AffineTransform2D(tx: 10, ty: 20)
        let scale = AffineTransform2D(a: 2, d: 3)
        #expect(translate.concatenating(scale).applying(to: .init(x: 1, y: 1)) == Point2D(x: 22, y: 63))
    }
    @Test func transactionsAreAtomicAndRejectOldRevisions() throws {
        let original = SceneDocument(id: "test", nodes: [.init(id: "label", kind: .text, text: "Original")])
        let transaction = SceneTransaction(baseDocumentRevision: 0, operations: [.patch(id: "label", fields: .init(text: "Changed")), .remove(id: "missing")])
        #expect(throws: CoreError.missingReference("missing")) { try original.applying(transaction) }
        #expect(original.nodes.first?.text == "Original"); #expect(original.revision == 0)
        let changed = try original.applying(.init(baseDocumentRevision: 0, operations: [.patch(id: "label", fields: .init(text: "Changed"))]))
        #expect(changed.revision == 1); #expect(changed.nodes.first?.id == "label")
        #expect(throws: CoreError.revisionConflict(expected: 1, received: 0)) { try changed.applying(transaction) }
    }
    @Test func parentRemovalIsTransitiveAndCleansAnimations() throws {
        let scene = SceneDocument(nodes: [.init(id: "g", kind: .group), .init(id: "nested", kind: .group, parentID: "g"), .init(id: "leaf", kind: .ellipse, parentID: "nested")], animations: [.init(id: "spin", targetID: "leaf")])
        let removed = try scene.applying(.init(baseDocumentRevision: 0, operations: [.remove(id: "g")]))
        #expect(removed.nodes.isEmpty); #expect(removed.animations.isEmpty)
    }
    @Test func graphRejectsCyclesDuplicateIDsAndNonfiniteGeometry() {
        #expect(throws: (any Error).self) { try SceneDocument(nodes: [.init(id: "a", kind: .group, parentID: "b"), .init(id: "b", kind: .group, parentID: "a")]).validated() }
        #expect(throws: CoreError.duplicateID("a")) { try SceneDocument(nodes: [.init(id: "a", kind: .group), .init(id: "a", kind: .group)]).validated() }
        #expect(throws: (any Error).self) { try SceneDocument(nodes: [.init(id: "bad", kind: .rectangle, x: .infinity)]).validated() }
    }
    @Test func finiteBudgetsRejectOversizeTextAndUnknownBindings() {
        #expect(throws: (any Error).self) { try SceneDocument(nodes: [.init(id: "big", kind: .text, text: String(repeating: "x", count: 128_001))]).validated() }
        #expect(throws: (any Error).self) { try SceneDocument(nodes: [.init(id: "bad", kind: .group, bindings: ["shell": .number(1)])]).validated() }
    }
    @Test func expressionTypesCyclesAndDeadBranchesAreChecked() throws {
        let graph = ExpressionEvaluator(expressions: ["a": .reference("b"), "b": .reference("a")])
        #expect(throws: (any Error).self) { try graph.validate() }
        let invalidDeadArm: SafeExpression = .operation(.select, [.boolean(true), .number(1), .reference("missing")])
        #expect(throws: CoreError.missingReference("missing")) { try ExpressionEvaluator().evaluate(invalidDeadArm) }
        #expect(throws: (any Error).self) { try ExpressionEvaluator().evaluate(.operation(.add, [.boolean(true), .number(2)])) }
        #expect(try ExpressionEvaluator().evaluate(.operation(.mul, [.number(2), .number(3), .number(4)])) == .number(24))
    }
    @Test func expressionBudgetAndOverflowAreRejected() {
        let expression = (0..<40).reduce(SafeExpression.number(1)) { partial, _ in .operation(.sin, [partial]) }
        #expect(throws: (any Error).self) { try ExpressionEvaluator().evaluate(expression) }
        #expect(throws: (any Error).self) { try ExpressionEvaluator().evaluate(.operation(.mul, [.number(Double.greatestFiniteMagnitude), .number(2)])) }
        let batch = Array(repeating: SafeExpression.operation(.add, [.number(1), .number(2)]), count: 3_000)
        #expect(throws: (any Error).self) { try ExpressionEvaluator().evaluateMany(batch) }
    }
    @Test func motorFixtureImportsAllNodesAndReversesCurrent() throws {
        let scene = try BuiltInLessons.motor()
        #expect(scene.nodes.count == 55)
        for theta in [0.0, .pi / 4, .pi / 2, .pi, .pi * 1.5, .pi * 2] {
            let evaluator = scene.expressionEvaluator(at: theta / (.pi / 4))
            let current = try evaluator.evaluate(.reference("currentA")).number!
            if abs(cos(theta)) < 0.0524 { #expect(current == 0) } else { #expect(current == (cos(theta) > 0 ? 1 : -1)) }
            let resolved = try scene.resolvedNodes(at: theta / (.pi / 4))
            let a = resolved.first { $0.id == "conductorA" }!; let b = resolved.first { $0.id == "conductorB" }!
            #expect(abs((a.x + b.x) / 2 - 355) < 1e-8); #expect(abs((a.y + b.y) / 2 - 350) < 1e-8)
        }
    }
    @Test func unrelatedBuiltInLessonsAreRetainedAndRoundTrip() throws {
        for scene in [BuiltInLessons.lever(), BuiltInLessons.circuit(), try BuiltInLessons.motor()] {
            _ = try scene.validated()
            let restored = try JSONDecoder().decode(SceneDocument.self, from: JSONEncoder().encode(scene))
            #expect(restored == scene)
        }
    }
    @Test func transactionJSONUsesTypedOperationNames() throws {
        let data = Data(##"{"transactionID":"t","baseDocumentRevision":0,"operations":[{"op":"node.create","node":{"id":"a","kind":"text","text":"Hello"}},{"op":"node.patch","id":"a","fields":{"color":"#FF0000"}}]}"##.utf8)
        let transaction = try JSONDecoder().decode(SceneTransaction.self, from: data)
        let scene = try SceneDocument().applying(transaction)
        #expect(scene.nodes.first?.color == "#FF0000")
        let unknown = Data(#"{"op":"native.execute","id":"x"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SceneOperation.self, from: unknown) }
    }
    @Test func framerHandlesSplitUnicodeAndTruncation() throws {
        let input = Data("{\"value\":\"電気\"}\r\n{\"ok\":true}\n".utf8)
        var framer = JSONLineFramer(); var result: [Data] = []
        for byte in input { result += try framer.append(Data([byte])) }
        #expect(result.count == 2); #expect(String(data: result[0], encoding: .utf8) == "{\"value\":\"電気\"}")
        _ = try framer.append(Data("unfinished".utf8)); #expect(throws: (any Error).self) { try framer.finish() }
    }
    @Test func orderingDeduplicatesAndRejectsOldGenerations() throws {
        var gate = StreamOrderGate(sessionID: "s", turnID: "t", generation: 1)
        let first = StreamEnvelope(sessionID: "s", turnID: "t", taskGeneration: 1, sequence: 0, eventID: "0", kind: .turnStarted)
        let second = StreamEnvelope(sessionID: "s", turnID: "t", taskGeneration: 1, sequence: 1, eventID: "1", kind: .turnCompleted)
        #expect(try gate.accept(second, at: 1).isEmpty)
        #expect(try gate.accept(first, at: 2).map(\.sequence) == [0, 1])
        #expect(try gate.accept(first, at: 3).isEmpty)
        try gate.advanceGeneration(to: 2)
        #expect(throws: CoreError.staleGeneration) { try gate.accept(second, at: 4) }
    }
    @Test func missingSequenceExpiresWithoutGuessing() throws {
        var gate = StreamOrderGate(sessionID: "s", turnID: "t", generation: 1)
        _ = try gate.accept(.init(sessionID: "s", turnID: "t", taskGeneration: 1, sequence: 1, kind: .turnCompleted), at: 10)
        #expect(throws: (any Error).self) { try gate.checkGap(at: 16) }; #expect(gate.nextSequence == 0)
    }
    @Test func guidanceClickDoesNotClaimVerifiedSuccess() throws {
        var state = GuidanceState(); try state.begin()
        let evidence = ScreenEvidence(frameID: "1", taskGeneration: state.generation, perceptionSceneRevision: 1, displayID: 1, foregroundPID: 42, observedAtMonotonic: 10, transformID: "x")
        try state.present(evidence: evidence, target: .init(x: 10, y: 10, width: 20, height: 20), instruction: "Press Save", expectedEffect: "Saved indicator")
        try state.awaitInteraction(); try state.observedInteraction(currentEvidence: evidence, now: 11)
        #expect(state.phase == .verifying)
        #expect(throws: (any Error).self) { try state.verify(effectObserved: true, freshEvidence: evidence) }
        var fresh = evidence; fresh.frameID = "2"; fresh.observedAtMonotonic = 12
        try state.verify(effectObserved: true, freshEvidence: fresh); #expect(state.phase == .verified)
    }
    @Test func screenInvalidationAndDocumentRevisionsAreIndependent() throws {
        var guidance = GuidanceState(); try guidance.begin(); guidance.invalidateScreen()
        let doc = SceneDocument(nodes: [.init(id: "note", kind: .text)])
        let revised = try doc.applying(.init(baseDocumentRevision: 0, operations: [.patch(id: "note", fields: .init(text: "Still valid"))]))
        #expect(revised.revision == 1); #expect(guidance.phase == .observing)
    }
    @Test func animationSpeedChangesDoNotJumpAndPausePreservesPhase() throws {
        var clock = AnimationClock(at: 10)
        #expect(try clock.value(at: 12) == 2)
        try clock.setSpeed(0.5, at: 12); #expect(try clock.value(at: 12) == 2)
        try clock.setPlaying(false, at: 14); #expect(try clock.value(at: 20) == 3)
        try clock.setPlaying(true, at: 20); #expect(try clock.value(at: 22) == 4)
    }
    @Test func beatsRequireHostPlaybackAndUseTextFallback() throws {
        let scene = SceneDocument(id: "s", nodes: [.init(id: "diagram", kind: .group)])
        var scheduler = BeatScheduler(generation: 1)
        try scheduler.commit(.init(id: "visual", text: "Diagram first", surfaceID: "s", generation: 1, requiredDocumentRevision: 0, dependsOnNodeIDs: ["diagram"]), against: scene)
        try scheduler.commit(.init(id: "speech", text: "Then speech", surfaceID: "s", generation: 1, requiredDocumentRevision: 0, policy: .speechSynchronized, releaseAtPlaybackSeconds: 1), against: scene)
        #expect(try scheduler.releaseReady(at: 10).map(\.id) == ["visual"])
        scheduler.markGenerationComplete(); #expect(!scheduler.enginePlaybackComplete); #expect(!scheduler.visualComplete)
        try scheduler.useTextFallback(at: 10)
        #expect(try scheduler.releaseReady(at: 11).map(\.id) == ["speech"])
        #expect(scheduler.visualComplete)
        try scheduler.cancel(to: 2)
        #expect(throws: CoreError.staleGeneration) { try scheduler.hostPlaybackProgress(seconds: 3, generation: 1) }
    }
}
