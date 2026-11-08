import Foundation
import Testing

@testable import OpenCompanion

struct ExplanationOrbitStateTests {
  @Test func ordinaryPointerAndBackgroundStayPassiveUntilOptionAndAMeshHit() {
    var state = ExplanationOrbitState()
    var input = ready()
    input.modifiers = []
    let ordinary = state.update(input)
    #expect(ordinary == .passive && !state.acceptsMouseEvents && state.authority == nil)
    input.modifiers = .option
    input.pointerOnVisibleMesh = false
    let background = state.update(input)
    #expect(background == .passive && !state.acceptsMouseEvents)
    input.pointerOnVisibleMesh = true
    let armed = state.update(input)
    #expect(armed == .armed && state.acceptsMouseEvents && state.authority == input.authority)
    input.pointerOnVisibleMesh = false
    let exited = state.update(input)
    #expect(exited == .passive && !state.acceptsMouseEvents)
  }

  @Test(arguments: [
    ExplanationOrbitState.Modifiers.option,
    [.option, .capsLock], [.option, .numericPad], [.option, .capsLock, .numericPad],
  ])
  func capsLockAndNumericPadDoNotChangeOptionOnlyAdmission(
    _ modifiers: ExplanationOrbitState.Modifiers
  ) {
    var state = ExplanationOrbitState()
    var input = ready()
    input.modifiers = modifiers
    let result = state.update(input)
    #expect(result == .armed && state.acceptsMouseEvents)
  }

  @Test(arguments: [
    ExplanationOrbitState.Modifiers(), .control, [.option, .control],
    [.option, .control, .capsLock, .numericPad], [.option, .command], [.option, .shift],
    [.option, .function], [.option, .help], [.option, .init(rawValue: 1 << 15)],
  ])
  func voiceChordAndEveryOtherActiveModifierPreventArming(
    _ modifiers: ExplanationOrbitState.Modifiers
  ) {
    var state = ExplanationOrbitState()
    var input = ready()
    input.modifiers = modifiers
    let result = state.update(input)
    #expect(result == .passive && !state.acceptsMouseEvents)
  }

  @Test func onlyFreshLeftDownOnAnAlreadyArmedMeshCanBeginDrag() {
    var state = ExplanationOrbitState()
    var input = ready()
    input.buttons = .left
    let passiveDown = state.beginDrag(input)
    let heldDown = state.update(input)
    #expect(!passiveDown && heldDown == .passive)
    input.buttons = []
    state.update(input)
    input.buttons = .left
    let started = state.beginDrag(input)
    #expect(started && state.phase == .dragging && state.acceptsMouseEvents)
    input.pointerOnVisibleMesh = false
    let outside = state.update(input)
    #expect(outside == .dragging && state.authority == input.authority)
  }

  @Test(arguments: [
    ExplanationOrbitState.Buttons(), .right, .other, [.left, .right], [.left, .other],
    [.left, .init(rawValue: 1 << 9)],
  ])
  func wrongButtonOrMissingFreshMeshHitCannotStartDrag(_ buttons: ExplanationOrbitState.Buttons) {
    var state = ExplanationOrbitState()
    var input = ready()
    state.update(input)
    input.buttons = buttons
    let began = state.beginDrag(input)
    #expect(!began && state.phase == .passive && !state.acceptsMouseEvents)
    input.buttons = []
    state.update(input)
    input.buttons = .left
    input.pointerOnVisibleMesh = false
    let missed = state.beginDrag(input)
    #expect(!missed && state.phase == .passive)
  }

  enum Invalidation: CaseIterable, Sendable {
    case lease, document, generation, display, invisible, sleeping, inactiveSession, missingDisplay
    case noGeometry, optionReleased, controlPressed, commandPressed, shiftPressed, functionPressed
    case leftReleased, additionalButton
  }

  @Test(arguments: Invalidation.allCases)
  func activeDragCancelsImmediatelyOnEveryOwnershipOrAvailabilityChange(_ reason: Invalidation) {
    var state = ExplanationOrbitState()
    var input = ready()
    state.update(input)
    input.buttons = .left
    let began = state.beginDrag(input)
    #expect(began)
    let old = input.authority!
    switch reason {
    case .lease:
      input.authority = .init(
        lease: UUID(), documentID: old.documentID, generation: old.generation,
        displayID: old.displayID)
    case .document:
      input.authority = .init(
        lease: old.lease, documentID: "different", generation: old.generation,
        displayID: old.displayID)
    case .generation:
      input.authority = .init(
        lease: old.lease, documentID: old.documentID, generation: old.generation + 1,
        displayID: old.displayID)
    case .display:
      input.authority = .init(
        lease: old.lease, documentID: old.documentID, generation: old.generation,
        displayID: old.displayID + 1)
    case .invisible: input.presentationVisible = false
    case .sleeping: input.awake = false
    case .inactiveSession: input.sessionActive = false
    case .missingDisplay: input.displayAvailable = false
    case .noGeometry: input.spatialReady = false
    case .optionReleased: input.modifiers = []
    case .controlPressed: input.modifiers.insert(.control)
    case .commandPressed: input.modifiers.insert(.command)
    case .shiftPressed: input.modifiers.insert(.shift)
    case .functionPressed: input.modifiers.insert(.function)
    case .leftReleased: input.buttons = []
    case .additionalButton: input.buttons.insert(.right)
    }
    let result = state.update(input)
    #expect(result == .passive && !state.acceptsMouseEvents && state.authority == nil)
    input.buttons = .left
    let reentered = state.update(input)
    #expect(reentered == .passive)
  }

  @Test func explicitMouseUpMayRearmWhileObservedButtonLossOnlyCancels() {
    var state = ExplanationOrbitState()
    var input = ready()
    state.update(input)
    input.buttons = .left
    state.beginDrag(input)
    input.buttons = []
    let ended = state.endDrag(input)
    #expect(ended && state.phase == .armed)
    input.buttons = .left
    state.beginDrag(input)
    input.buttons = []
    let lost = state.update(input)
    #expect(lost == .passive)
    let duplicateUp = state.endDrag(input)
    #expect(!duplicateUp && state.phase == .passive)
  }

  @Test func staleDownAndUpCannotTakeOrEndANewerPresentationsDrag() {
    var state = ExplanationOrbitState()
    let old = ready()
    state.update(old)
    var current = ready()
    let invalidated = state.update(current)
    #expect(invalidated == .passive)
    state.update(current)
    var staleDown = old
    staleDown.buttons = .left
    let oldDown = state.beginDrag(staleDown)
    #expect(!oldDown && state.phase == .armed && state.authority == current.authority)
    current.buttons = .left
    let currentDown = state.beginDrag(current)
    let oldUp = state.endDrag(old)
    #expect(currentDown && !oldUp && state.phase == .dragging)
    #expect(state.authority == current.authority)
    current.buttons = []
    let currentUp = state.endDrag(current)
    #expect(currentUp && state.phase == .armed)
  }

  @Test func teardownIsIdempotentAndMidDragModifierRepressDoesNotReacquireInput() {
    var state = ExplanationOrbitState()
    var input = ready()
    state.update(input)
    input.buttons = .left
    state.beginDrag(input)
    input.modifiers = [.option, .control]
    state.update(input)
    input.modifiers = .option
    let stillHeld = state.update(input)
    let attemptedResume = state.beginDrag(input)
    #expect(stillHeld == .passive && !attemptedResume)
    state.cancel()
    state.cancel()
    #expect(state.phase == .passive && !state.acceptsMouseEvents && state.authority == nil)
  }

  @Test func invalidOrMissingAuthorityCannotArmAndInputRemainsUnchanged() {
    let valid = ready()
    let authorities: [ExplanationOrbitState.Authority?] = [
      nil,
      .init(lease: UUID(), documentID: "", generation: 1, displayID: 1),
      .init(
        lease: UUID(), documentID: String(repeating: "x", count: 257), generation: 1, displayID: 1),
      .init(lease: UUID(), documentID: "scene", generation: 1, displayID: 0),
    ]
    for authority in authorities {
      var state = ExplanationOrbitState()
      var input = valid
      input.authority = authority
      let before = input
      let result = state.update(input)
      #expect(result == .passive && input == before)
    }
  }

  @Test func localScrollNeedsTheOwnedSurfaceButNoOptionOrMeshHit() {
    var state = ExplanationOrbitState()
    var input = ready()
    input.modifiers = []
    input.pointerOnVisibleMesh = false
    let outside = state.beginScroll(input)
    #expect(!outside && state.phase == .passive)
    input.pointerInsideSurface = true
    let began = state.beginScroll(input)
    #expect(began && state.phase == .scrolling && state.authority == input.authority)
    input.pointerInsideSurface = false
    let leftSurface = state.update(input)
    #expect(leftSurface == .passive && state.authority == nil)
  }

  @Test(arguments: [
    ExplanationOrbitState.Modifiers.option, .control, [.option, .control], .command, .shift,
    .function, .help, .init(rawValue: 1 << 15),
  ])
  func localScrollRefusesSignificantModifiers(_ modifiers: ExplanationOrbitState.Modifiers) {
    var state = ExplanationOrbitState()
    var input = ready()
    input.pointerInsideSurface = true
    input.modifiers = modifiers
    let began = state.beginScroll(input)
    #expect(!began && state.phase == .passive)
  }

  @Test func scrollAuthorityCannotBeReplacedOrEndedByAnOldGesture() {
    var state = ExplanationOrbitState()
    var input = ready()
    input.modifiers = [.capsLock, .numericPad]
    input.pointerInsideSurface = true
    let began = state.beginScroll(input)
    let old = input
    input.authority = .init(lease: UUID(), documentID: "new-scene", generation: 8, displayID: 1)
    let replaced = state.beginScroll(input)
    let wrongEnd = state.endScroll(input)
    #expect(began && !replaced && !wrongEnd && state.authority == old.authority)
    let revoked = state.update(input)
    #expect(revoked == .passive)
    let next = state.beginScroll(input)
    let staleEnd = state.endScroll(old)
    #expect(next && !staleEnd && state.phase == .scrolling)
    input.buttons = .left
    let pressed = state.update(input)
    #expect(pressed == .passive && state.authority == nil)
  }

  @Test func scrollStopsOnHiddenOrUnavailableSurfaceAndNeverStartsDuringADrag() {
    var state = ExplanationOrbitState()
    var input = ready()
    state.update(input)
    input.buttons = .left
    state.beginDrag(input)
    input.buttons = []
    input.modifiers = []
    input.pointerInsideSurface = true
    let whileDragging = state.beginScroll(input)
    #expect(!whileDragging)
    state.cancel()
    for unavailable in 0..<5 {
      var value = input
      switch unavailable {
      case 0: value.presentationVisible = false
      case 1: value.awake = false
      case 2: value.sessionActive = false
      case 3: value.displayAvailable = false
      default: value.spatialReady = false
      }
      let began = state.beginScroll(value)
      #expect(!began && state.phase == .passive)
    }
  }

  @Test func authoredScrollGainIsFiniteBoundedAndPreservesBothAxes() {
    #expect(
      ExplanationOrbitState.scrollDelta(x: 10, y: -5, precise: true) == CGPoint(x: 0.08, y: -0.04))
    #expect(
      ExplanationOrbitState.scrollDelta(x: 1, y: -1, precise: false) == CGPoint(x: 0.035, y: -0.035)
    )
    #expect(
      ExplanationOrbitState.scrollDelta(x: 4096, y: -4096, precise: true)
        == CGPoint(x: 0.20, y: -0.20))
    for value in [Double.nan, .infinity, -.infinity, 4097, -4097] {
      #expect(ExplanationOrbitState.scrollDelta(x: value, y: 0, precise: true) == nil)
      #expect(ExplanationOrbitState.scrollDelta(x: 0, y: value, precise: true) == nil)
    }
  }

  private func ready() -> ExplanationOrbitState.Input {
    .init(
      authority: .init(lease: UUID(), documentID: "public-scene", generation: 7, displayID: 1),
      modifiers: .option, buttons: [], presentationVisible: true, awake: true,
      sessionActive: true, displayAvailable: true, spatialReady: true, pointerOnVisibleMesh: true)
  }
}
