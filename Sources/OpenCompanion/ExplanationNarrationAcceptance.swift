import AppKit
import CompanionCore
import Foundation
import SceneKit

/// Opt-in real synthesis and own-view presentation check. It plays two authored
/// public paragraphs; it neither captures a microphone/desktop nor calls a provider.
enum ExplanationNarrationAcceptance {
  @MainActor static func run(model: AppModel, output: URL) async throws {
    guard let screen = NSScreen.main ?? NSScreen.screens.first,
      let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    else { throw ProviderError.message("A display and foreground baseline are required.") }
    let physicalPointer = NSEvent.mouseLocation
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let observation = Observation()
    let originalSpeech = model.configuration.speechEnabled
    let oldSceneReady = model.onSceneReady
    let oldPresent = model.onExplanationPresentationChanged
    let oldSpeech = model.onExplanationNarrationEvent
    let oldCaptionStart = model.onNarrationCaptionStarted
    let oldCaptionUpdate = model.onNarrationCaptionUpdate
    let oldCaptionFinish = model.onNarrationCaptionFinished
    let oldCancelled = model.onCursorCancelled
    let oldFocusStart = model.onExplanationFocusStarted
    let oldFocusEnd = model.onExplanationFocusEnded
    let cursor = CursorCompanionCoordinator(
      model: model, observePointer: false, preferences: CursorCompanionPreferences())
    let overlay = ExplanationOverlay(model: model, observeOrbitInput: false) { model.stop() }
    let oldVisitBounds = cursor.sceneNodeVisitBounds
    let oldFocusPoint = overlay.onSceneFocusPoint
    let oldOverlayFocusEnd = overlay.onSceneFocusEnded
    defer {
      for task in observation.snapshotTasks { task.cancel() }
      model.stop()
      overlay.shutdown()
      cursor.shutdown()
      model.configuration.speechEnabled = originalSpeech
      model.onSceneReady = oldSceneReady
      model.onExplanationPresentationChanged = oldPresent
      model.onExplanationNarrationEvent = oldSpeech
      model.onNarrationCaptionStarted = oldCaptionStart
      model.onNarrationCaptionUpdate = oldCaptionUpdate
      model.onNarrationCaptionFinished = oldCaptionFinish
      model.onCursorCancelled = oldCancelled
      model.onExplanationFocusStarted = oldFocusStart
      model.onExplanationFocusEnded = oldFocusEnd
      cursor.sceneNodeVisitBounds = oldVisitBounds
      overlay.onSceneFocusPoint = oldFocusPoint
      overlay.onSceneFocusEnded = oldOverlayFocusEnd
    }

    model.stop()
    model.scene = nil
    model.configuration.speechEnabled = true
    model.playing = false
    let generation = model.taskGeneration
    let policy = ResponsePolicy.resolve(
      text: "Create a small 3D explanation of two simple parts.", screenGuidanceEnabled: false)
    guard policy.allowsNotebook, !policy.includesExistingNotebook else {
      throw ProviderError.message(
        "The authored request did not acquire new-explanation capability.")
    }
    model.configureResponseOutput(policy)
    cursor.beginResponse(generation: generation)
    cursor.pointerMoved(to: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
    model.onSceneReady = {
      guard let document = model.explanationDisplayDocument else { return }
      overlay.show(document: document, on: screen)
    }
    model.onNarrationCaptionStarted = { text, context, native in
      cursor.beginNarration(text: text, context: context, nativeSpeech: native)
    }
    model.onNarrationCaptionUpdate = { cursor.updateNarration($0) }
    model.onNarrationCaptionFinished = { cursor.finishNarration(context: $0) }
    model.onCursorCancelled = { cursor.cancel(generation: $0) }
    cursor.sceneNodeVisitBounds = { [weak overlay] authority in
      overlay?.sceneNodeVisitBounds(authority: authority)
    }
    model.onExplanationFocusStarted = { context, presentation in
      overlay.beginSceneFocus(context: context, presentation: presentation)
    }
    model.onExplanationFocusEnded = { overlay.endSceneFocus(context: $0) }
    overlay.onSceneFocusPoint = { [weak cursor] authority, point in
      guard let stage = observation.stage(for: authority.beatID),
        authority.focusID == expectedFocusID(stage: stage)
      else {
        observation.fail("A native focus callback has no matching authored stage.")
        return
      }
      observation.focusAuthorities[stage] = authority
      observation.focusPoints[stage] = point
      observation.focusPointCounts[stage] = min(
        1_000_000, (observation.focusPointCounts[stage] ?? 0) + 1)
      if cursor?.visitSceneNode(authority: authority, point: point) == true {
        observation.focusVisitStages.insert(stage)
      }
    }
    overlay.onSceneFocusEnded = { [weak cursor] authority in
      cursor?.cancelSceneNodeVisit(authority: authority)
    }
    cursor.onNarrationCaptionCompleted = { model.completeExplanationCaption(context: $0) }
    model.onExplanationPresentationChanged = { presentation in
      observation.presentations.append(presentation)
      observation.record(
        kind: "presentation", stage: observation.presentations.count,
        beatID: presentation.beatID, revision: presentation.document.revision)
      if observation.presentations.count > 2 {
        observation.fail("More than two explanation snapshots were released.")
      }
    }
    model.onExplanationNarrationEvent = { update in
      guard observation.updates.count < 256 else {
        observation.fail("The native utterance callback trace exceeded its bound.")
        return
      }
      guard let stage = observation.stage(for: update.context.narrationID) else {
        observation.fail("An utterance has no matching presentation beat.")
        return
      }
      observation.record(
        kind: update.kind.rawValue, stage: stage, beatID: update.context.narrationID,
        revision: model.explanationPresentation?.document.revision,
        rangeEnd: update.revealedUTF16End, observedUptime: update.observedUptime)
      observation.updates.append(update)
      if update.kind == .cancelled {
        observation.fail("Native synthesis cancelled instead of completing the public fixture.")
      }
      if update.kind == .enqueued {
        do {
          let canvas = try ownCanvas(
            overlay: overlay, documentID: model.explanationDisplayDocument?.id)
          guard canvas.renderedDocumentRevision == stage,
            model.explanationPresentation?.document.revision == stage
          else {
            throw ProviderError.message("Speech was enqueued before its exact native revision.")
          }
          observation.renderMatchedBeforeEnqueue.insert(stage)
        } catch { observation.fail(error.localizedDescription) }
      }
      // Run after AppModel delivers this real range to the cursor. Snapshot work
      // is outside the synthesis delegate callback and never blocks an audio tap.
      if update.kind == .range, observation.requestedSnapshots.insert(stage).inserted {
        observation.snapshotDeadlines[stage] = ProcessInfo.processInfo.systemUptime + 8
        let task = Task { @MainActor in
          do {
            await Task.yield()
            try Task.checkCancellation()
            guard model.taskGeneration == generation,
              model.explanationPresentation?.beatID == update.context.narrationID,
              model.explanationDisplayDocument?.revision == stage
            else {
              throw ProviderError.message("The spoken scene changed before its own-view snapshot.")
            }
            let arrivalDeadline = ProcessInfo.processInfo.systemUptime + 3
            var arrival: (SceneFocusAuthority, SceneFocusProjection, RetainedCanvasView, Double)?
            while arrival == nil {
              try Task.checkCancellation()
              guard model.taskGeneration == generation,
                model.explanationPresentation?.beatID == update.context.narrationID,
                model.explanationDisplayDocument?.revision == stage,
                !observation.finishedStages.contains(stage),
                NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                pointerUnchanged(physicalPointer)
              else {
                throw ProviderError.message(
                  "Scene focus lost active stage, foreground or physical pointer ownership.")
              }
              let canvas = try ownCanvas(
                overlay: overlay, documentID: model.explanationDisplayDocument?.id)
              if let authority = observation.focusAuthorities[stage],
                let projection = canvas.currentSceneFocusProjection,
                cursor.sceneNodeVisitAuthority == authority,
                projection.targetID == expectedFocusID(stage: stage),
                projection.documentID == authority.documentID,
                projection.documentRevision == stage, projection.generation == generation,
                projection.renderSerial > 0,
                authority.presentationLease == overlay.presentationLease,
                authority.beatID == update.context.narrationID,
                overlay.sceneNodeVisitBounds(authority: authority) != nil,
                let target = cursor.sceneNodeVisitTargetPoint,
                distance(target, projection.globalPoint) <= 0.01
              {
                let snapshot = cursor.snapshot
                let tip = CGPoint(x: snapshot.bodyCenter.x + 7.5, y: snapshot.bodyCenter.y)
                let error = distance(tip, projection.globalPoint)
                if snapshot.visible, snapshot.ignoresMouseEvents, !snapshot.canBecomeKey, error <= 1
                {
                  _ = try verifyNativeSurface(
                    authority: authority, projection: projection, canvas: canvas)
                  arrival = (authority, projection, canvas, error)
                }
              }
              if arrival == nil {
                guard ProcessInfo.processInfo.systemUptime < arrivalDeadline else {
                  throw ProviderError.message(
                    "The cursor did not reach the current native focus surface within three seconds."
                  )
                }
                try await Task.sleep(for: .milliseconds(20))
              }
            }
            let (authority, projection, canvas, error) = try require(arrival)
            try verifyCursorStacking(canvas: canvas)
            let caption = cursor.snapshot
            let text = stage == 1 ? firstNarration : secondNarration
            guard !caption.text.isEmpty, text.hasPrefix(caption.text), caption.ignoresMouseEvents,
              !caption.canBecomeKey
            else {
              throw ProviderError.message(
                "Real speech ranges did not drive the owned cursor prefix.")
            }
            let captionGap = try verifyCaptionAttachment(snapshot: caption)
            let bitmap = try canvas.explanationSnapshot()
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
              throw ProviderError.message("Could not encode the authored explanation snapshot.")
            }
            try data.write(
              to: output.appendingPathComponent("stage-\(stage).png"), options: .atomic)
            try await cursor.exportSnapshot(
              to: output.appendingPathComponent("stage-\(stage)-cursor.png"))
            observation.ownCursorCaptureStages.insert(stage)
            guard model.taskGeneration == generation,
              model.explanationPresentation?.beatID == authority.beatID,
              model.explanationDisplayDocument?.revision == stage,
              !observation.finishedStages.contains(stage),
              cursor.sceneNodeVisitAuthority == authority,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
              pointerUnchanged(physicalPointer),
              let currentProjection = canvas.currentSceneFocusProjection,
              currentProjection.targetID == projection.targetID,
              currentProjection.documentID == authority.documentID,
              currentProjection.documentRevision == authority.documentRevision,
              currentProjection.generation == authority.generation,
              overlay.presentationLease == authority.presentationLease,
              overlay.sceneNodeVisitBounds(authority: authority) != nil,
              let currentTarget = cursor.sceneNodeVisitTargetPoint,
              distance(currentTarget, currentProjection.globalPoint) <= 0.01
            else {
              throw ProviderError.message(
                "The native scene focus changed during its own-window capture.")
            }
            try verifyCursorStacking(canvas: canvas)
            let afterCapture = cursor.snapshot
            let currentTip = CGPoint(
              x: afterCapture.bodyCenter.x + 7.5, y: afterCapture.bodyCenter.y)
            let finalError = distance(currentTip, currentProjection.globalPoint)
            guard afterCapture.visible, afterCapture.ignoresMouseEvents, !afterCapture.canBecomeKey,
              finalError <= 1
            else {
              throw ProviderError.message(
                "The cursor no longer points to the captured native focus surface.")
            }
            let surfaceID = try verifyNativeSurface(
              authority: authority, projection: currentProjection, canvas: canvas)
            let afterCaptureCaptionGap = try verifyCaptionAttachment(snapshot: afterCapture)
            observation.focusArrivalStages.insert(stage)
            observation.focusSurfaceIDs[stage] = surfaceID
            observation.focusArrivalReceipts[stage] = [
              "focusID": authority.focusID, "surfaceNodeID": surfaceID,
              "presentationLease": authority.presentationLease.uuidString,
              "generation": authority.generation, "beatID": authority.beatID.uuidString,
              "documentID": authority.documentID, "documentRevision": authority.documentRevision,
              "renderSerial": currentProjection.renderSerial,
              "tipErrorLogicalPoints": error,
              "afterCaptureTipErrorLogicalPoints": finalError,
              "captionBodyGapLogicalPoints": captionGap,
              "afterCaptureCaptionBodyGapLogicalPoints": afterCaptureCaptionGap,
              "nativePoint": [
                "x": currentProjection.globalPoint.x, "y": currentProjection.globalPoint.y,
              ],
            ]
            observation.snapshots.insert(stage)
            observation.cursorAboveExplanationStages.insert(stage)
            observation.snapshotDeadlines.removeValue(forKey: stage)
            observation.captionUTF16Lengths[stage] = caption.text.utf16.count
          } catch { observation.fail(error.localizedDescription) }
        }
        observation.snapshotTasks.append(task)
      }
    }

    do {
      let units = fixtureUnits()
      try model.accept(units[0], generation: generation, expectedEvidence: nil)
      try model.accept(units[1], generation: generation, expectedEvidence: nil)
      guard model.scene?.revision == 2,
        model.scene?.nodes.contains(where: { $0.id == "amber-box" }) == true,
        model.explanationDisplayDocument?.revision == 1, model.presentingExplanation
      else {
        throw ProviderError.message("The canonical future revision bypassed ordered presentation.")
      }
      observation.canonicalTipAhead = true
      let canonical = model.scene
      let deadline = ProcessInfo.processInfo.systemUptime + 80
      while observation.finishedStages.count < 2 || observation.snapshots.count < 2
        || model.presentingExplanation
      {
        try Task.checkCancellation()
        if let failure = observation.failure { throw ProviderError.message(failure) }
        if let error = model.error { throw ProviderError.message(error) }
        guard
          !observation.snapshotDeadlines.values.contains(where: {
            ProcessInfo.processInfo.systemUptime >= $0
          })
        else {
          throw ProviderError.message(
            "An authored own-window snapshot did not finish within eight seconds.")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw ProviderError.message(
            "Real narration did not finish both stages within 80 seconds.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else {
          throw ProviderError.message("The explanation changed the foreground baseline.")
        }
        guard pointerUnchanged(physicalPointer) else {
          throw ProviderError.message(
            "The physical pointer baseline changed during authored acceptance.")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      try observation.validateOrdering()
      guard observation.renderMatchedBeforeEnqueue == [1, 2], observation.snapshots == [1, 2],
        observation.focusVisitStages == [1, 2], observation.focusArrivalStages == [1, 2],
        observation.ownCursorCaptureStages == [1, 2],
        observation.cursorAboveExplanationStages == [1, 2],
        observation.focusSurfaceIDs[1] == "blue-sphere",
        observation.focusSurfaceIDs[2] == "amber-box",
        model.scene == canonical, model.explanationDisplayDocument?.revision == 2,
        !model.voice.hasPendingSpeech,
        NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
        pointerUnchanged(physicalPointer)
      else {
        throw ProviderError.message(
          "Final narration, native presentation or canonical state differs.")
      }
      let oldPresentation = try require(model.explanationPresentation)
      let oldContext = try require(observation.updates.last?.context)
      let oldAuthority = try require(observation.focusAuthorities[2])
      let oldPoint = try require(observation.focusPoints[2])
      let releases = observation.presentations.count
      model.stop()
      model.completeExplanationCaption(context: oldContext)
      model.acknowledgeExplanationRenderSubmitted(oldPresentation)
      let lateFocusAccepted = cursor.visitSceneNode(authority: oldAuthority, point: oldPoint)
      await Task.yield()
      guard !model.presentingExplanation, model.explanationPresentation == oldPresentation,
        model.scene == canonical, observation.presentations.count == releases,
        !model.voice.hasPendingSpeech, !lateFocusAccepted, cursor.sceneNodeVisitAuthority == nil
      else {
        throw ProviderError.message(
          "A late completion or render acknowledgment revived stopped playback.")
      }
      observation.staleFocusAfterStopRejected = true
      try writeResult(
        observation, output: output, passed: true, failure: nil,
        foregroundPreserved: NSWorkspace.shared.frontmostApplication?.processIdentifier
          == foreground, physicalPointerUnchanged: pointerUnchanged(physicalPointer))
    } catch {
      try? writeResult(
        observation, output: output, passed: false, failure: error.localizedDescription,
        foregroundPreserved: NSWorkspace.shared.frontmostApplication?.processIdentifier
          == foreground, physicalPointerUnchanged: pointerUnchanged(physicalPointer))
      throw error
    }
  }

  private static let firstNarration =
    "The blue sphere is the first part. Keep it in view while I finish this short explanation."
  private static let secondNarration =
    "The amber box is the second part. The first sphere remains beside it."

  private static func fixtureUnits() -> [ProviderUnit] {
    [
      ProviderUnit(
        type: "scene", title: "Public narration fixture",
        nodes: [
          .init(
            id: "blue-sphere", kind: .mesh, fill: "#4B92DB",
            spatial3D: .init(
              transform: .init(position: .init(x: -0.8, y: 0, z: 0)),
              geometry: .sphere(radius: 0.55, segments: 24))),
          .init(
            id: "sphere-label", kind: .text, width: 140, height: 36, text: "Sphere",
            color: "#FFFFFF",
            fontSize: 18,
            spatial3D: .init(
              labelAnchor: .init(targetID: "blue-sphere", point: .init(x: 0, y: 0.5, z: 0)))),
        ], narration: firstNarration, focusID: "blue-sphere"),
      ProviderUnit(
        type: "scene",
        nodes: [
          .init(
            id: "amber-box", kind: .mesh, fill: "#D5A04C",
            spatial3D: .init(
              transform: .init(position: .init(x: 0.8, y: 0, z: 0)),
              geometry: .box(width: 0.9, height: 0.9, depth: 0.9, chamferRadius: 0.04))),
          .init(
            id: "box-label", kind: .text, width: 140, height: 36, text: "Box", color: "#FFFFFF",
            fontSize: 18,
            spatial3D: .init(
              labelAnchor: .init(targetID: "amber-box", point: .init(x: 0, y: 0.45, z: 0)))),
        ], narration: secondNarration, focusID: "amber-box"),
    ]
  }

  @MainActor private static func ownCanvas(
    overlay: ExplanationOverlay, documentID: String?
  ) throws -> RetainedCanvasView {
    guard let documentID, overlay.isVisible(documentID: documentID),
      let window = NSApp.windows.first(where: {
        $0.isVisible && $0.identifier?.rawValue == "org.opencompanion.explanation.visual"
      }), window.ignoresMouseEvents, !window.canBecomeKey, window.sharingType == .none,
      let canvas = window.contentView as? RetainedCanvasView,
      canvas.renderedDocumentID == documentID
    else {
      throw ProviderError.message(
        "The matching nonactivating passive native canvas is unavailable.")
    }
    return canvas
  }

  private static func require<T>(_ value: T?) throws -> T {
    guard let value else {
      throw ProviderError.message("A required authored narration receipt is missing.")
    }
    return value
  }

  private static func expectedFocusID(stage: Int) -> String {
    stage == 1 ? "blue-sphere" : "amber-box"
  }

  private static func pointerUnchanged(_ baseline: CGPoint) -> Bool {
    distance(NSEvent.mouseLocation, baseline) <= 0.01
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(a.x - b.x, a.y - b.y)
  }

  @MainActor private static func verifyNativeSurface(
    authority: SceneFocusAuthority, projection: SceneFocusProjection, canvas: RetainedCanvasView
  ) throws -> String {
    guard let window = canvas.window, let stage = canvas.spatialStage,
      canvas.renderedDocumentID == authority.documentID,
      canvas.renderedDocumentRevision == authority.documentRevision,
      projection.targetID == authority.focusID, projection.surfaceNodeID == authority.focusID
    else { throw ProviderError.message("The authored focus has no exact current native mesh.") }
    let point = canvas.convert(window.convertPoint(fromScreen: projection.globalPoint), from: nil)
    guard canvas.bounds.contains(point),
      canvas.visibleSpatialMesh(atCanvasPoint: point) == authority.focusID
    else {
      throw ProviderError.message("The projected focus is not on the intended visible native mesh.")
    }
    // Independent closest-triangle query over the entire own scene: never
    // filter the ray to the requested target or use a bounding-box hit.
    let local = stage.convert(point, from: canvas)
    guard
      let hit = stage.hitTest(
        local,
        options: [
          .searchMode: SCNHitTestSearchMode.closest.rawValue, .boundingBoxOnly: false,
          .clipToZRange: true, .backFaceCulling: true, .ignoreHiddenNodes: true,
          .categoryBitMask: 1,
        ]
      ).first,
      let target = canvas.spatialNode(id: authority.focusID), hit.node === target,
      hit.node.geometry != nil, hit.faceIndex >= 0,
      hit.worldCoordinates.x.isFinite, hit.worldCoordinates.y.isFinite,
      hit.worldCoordinates.z.isFinite
    else {
      throw ProviderError.message(
        "The whole-scene closest triangle does not belong to the authored focus.")
    }
    return authority.focusID
  }

  @MainActor private static func verifyCursorStacking(canvas: RetainedCanvasView) throws {
    guard let visual = canvas.window,
      let cursor = NSApp.windows.first(where: {
        $0.isVisible && $0.identifier?.rawValue == "org.opencompanion.cursor"
      }),
      cursor.level.rawValue > visual.level.rawValue,
      cursor.ignoresMouseEvents, !cursor.canBecomeKey
    else {
      throw ProviderError.message("The passive cursor window is not stacked above its explanation.")
    }
  }

  @MainActor private static func verifyCaptionAttachment(
    snapshot: CursorCompanionSnapshot
  ) throws -> Double {
    guard
      let window = NSApp.windows.first(where: {
        $0.isVisible && $0.identifier?.rawValue == "org.opencompanion.cursor"
      }), let view = window.contentView as? CursorCompanionView,
      let local = view.visibleCaptionFrame, local.width > 0, local.height > 0
    else { throw ProviderError.message("The owned cursor has no visible native caption.") }
    let caption = window.convertToScreen(view.convert(local, to: nil))
    let body = CGRect(
      x: snapshot.bodyCenter.x - CursorCompanionLayout.bodySize.width / 2,
      y: snapshot.bodyCenter.y - CursorCompanionLayout.bodySize.height / 2,
      width: CursorCompanionLayout.bodySize.width, height: CursorCompanionLayout.bodySize.height)
    let gap = hypot(
      max(0, caption.minX - body.maxX, body.minX - caption.maxX),
      max(0, caption.minY - body.maxY, body.minY - caption.maxY))
    guard gap.isFinite, gap <= 24.01 else {
      throw ProviderError.message("The native caption detached from its scene cursor.")
    }
    return gap
  }

  @MainActor private static func writeResult(
    _ observation: Observation, output: URL, passed: Bool, failure: String?,
    foregroundPreserved: Bool, physicalPointerUnchanged: Bool
  ) throws {
    let result: [String: Any] = [
      "result": passed ? "passed" : "failed", "failure": String((failure ?? "").prefix(2_048)),
      "publicAuthoredFixture": true, "actualSpeechSynthesisRequested": true,
      "providerCalled": false, "desktopCaptured": false, "microphoneCaptured": false,
      "audioRecorded": false, "acousticOutputVerified": false, "physicalInputUsed": false,
      "frameRateVerified": false, "foregroundPreserved": foregroundPreserved,
      "physicalPointerUnchanged": physicalPointerUnchanged, "pointerAutomationUsed": false,
      "ownWindowCaptured": !observation.ownCursorCaptureStages.isEmpty,
      "desktopCompositeVerified": false,
      "ownWindowCaptureStages": observation.ownCursorCaptureStages.sorted(),
      "cursorAboveExplanationStages": observation.cursorAboveExplanationStages.sorted(),
      "focusVisitStages": observation.focusVisitStages.sorted(),
      "focusArrivalStages": observation.focusArrivalStages.sorted(),
      "focusPointCounts": observation.focusPointCounts.mapKeysToStrings(),
      "focusArrivals": observation.focusArrivalReceipts.keys.sorted().compactMap {
        observation.focusArrivalReceipts[$0]
      },
      "staleFocusAfterStopRejected": observation.staleFocusAfterStopRejected,
      "canonicalTipAheadOfPresentation": observation.canonicalTipAhead,
      "renderSubmittedBeforeSpeechEnqueue": observation.renderMatchedBeforeEnqueue.sorted(),
      "nativeStageSnapshots": observation.snapshots.sorted(),
      "captionUTF16Lengths": observation.captionUTF16Lengths.mapKeysToStrings(),
      "startedStages": observation.stages(for: .started),
      "rangeStages": observation.stages(for: .range),
      "finishedStages": observation.finishedStages.sorted(),
      "staleCompletionAndRenderAckAfterStopRejected": passed,
      "timeline": observation.timeline,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(
        to: output.appendingPathComponent("explanation-narration-acceptance.json"), options: .atomic
      )
  }

  @MainActor private final class Observation {
    let started = ProcessInfo.processInfo.systemUptime
    var presentations: [ExplanationPresentation] = []
    var updates: [VoiceUtteranceUpdate] = []
    var timeline: [[String: Any]] = []
    var requestedSnapshots = Set<Int>()
    var snapshots = Set<Int>()
    var captionUTF16Lengths: [Int: Int] = [:]
    var renderMatchedBeforeEnqueue = Set<Int>()
    var focusAuthorities: [Int: SceneFocusAuthority] = [:]
    var focusPoints: [Int: CGPoint] = [:]
    var focusPointCounts: [Int: Int] = [:]
    var focusSurfaceIDs: [Int: String] = [:]
    var focusVisitStages = Set<Int>()
    var focusArrivalStages = Set<Int>()
    var ownCursorCaptureStages = Set<Int>()
    var cursorAboveExplanationStages = Set<Int>()
    var focusArrivalReceipts: [Int: [String: Any]] = [:]
    var staleFocusAfterStopRejected = false
    var canonicalTipAhead = false
    var failure: String?
    var snapshotTasks: [Task<Void, Never>] = []
    var snapshotDeadlines: [Int: TimeInterval] = [:]

    var finishedStages: Set<Int> { Set(stages(for: .finished)) }

    func stage(for id: UUID) -> Int? {
      presentations.firstIndex(where: { $0.beatID == id }).map { $0 + 1 }
    }
    func stages(for kind: VoiceUtteranceUpdate.Kind) -> [Int] {
      Set(updates.filter { $0.kind == kind }.compactMap { stage(for: $0.context.narrationID) })
        .sorted()
    }
    func fail(_ message: String) { if failure == nil { failure = String(message.prefix(2_048)) } }
    func record(
      kind: String, stage: Int, beatID: UUID, revision: Int?, rangeEnd: Int? = nil,
      observedUptime: Double? = nil
    ) {
      guard timeline.count < 256 else {
        fail("The public callback trace exceeded its bound.")
        return
      }
      var event: [String: Any] = [
        "kind": kind, "stage": stage, "beatID": beatID.uuidString,
        "elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
      ]
      if let revision { event["revision"] = revision }
      if let rangeEnd { event["revealedUTF16End"] = rangeEnd }
      if let observedUptime { event["engineObservedMS"] = (observedUptime - started) * 1_000 }
      timeline.append(event)
    }
    func validateOrdering() throws {
      for stage in [1, 2] {
        let events = updates.filter { self.stage(for: $0.context.narrationID) == stage }
        guard events.filter({ $0.kind == .enqueued }).count == 1,
          events.filter({ $0.kind == .started }).count == 1,
          events.contains(where: { $0.kind == .range && $0.revealedUTF16End > 0 }),
          events.filter({ $0.kind == .finished }).count == 1,
          !events.contains(where: { $0.kind == .cancelled })
        else {
          throw ProviderError.message("Actual native speech events are incomplete or duplicated.")
        }
      }
      func index(_ kind: String, _ stage: Int) -> Int? {
        timeline.firstIndex { $0["kind"] as? String == kind && $0["stage"] as? Int == stage }
      }
      guard let finishOne = index("finished", 1), let presentTwo = index("presentation", 2),
        let enqueueTwo = index("enqueued", 2), let startTwo = index("started", 2),
        finishOne < presentTwo, presentTwo < enqueueTwo, enqueueTwo < startTwo,
        presentations.map(\.document.revision) == [1, 2]
      else {
        throw ProviderError.message("The second scene/narration bypassed the first native finish.")
      }
    }
  }
}

extension Dictionary where Key == Int, Value == Int {
  fileprivate func mapKeysToStrings() -> [String: Int] {
    [String: Int](uniqueKeysWithValues: map { (String($0.key), $0.value) })
  }
}
