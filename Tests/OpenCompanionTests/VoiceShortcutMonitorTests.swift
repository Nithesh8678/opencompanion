import CoreGraphics
import Foundation
import Testing

@testable import OpenCompanion

@Suite struct VoiceShortcutMonitorTests {
  @Test func exactChordPressesOnceAndEitherModifierCanRelease() {
    var state = VoiceHoldStateMachine()
    state.beginObserving(modifiers: [])
    #expect(state.flagsChanged(.control) == nil)
    #expect(state.flagsChanged(.chord) == .pressed)
    #expect(state.flagsChanged(.chord) == nil)
    #expect(state.flagsChanged(.option) == .released)
    #expect(state.flagsChanged(.option) == nil)
    #expect(state.flagsChanged(.chord) == .pressed)
    #expect(state.flagsChanged(.control) == .released)
    #expect(state.flagsChanged([]) == nil)
  }

  @Test func optionCanBePressedBeforeControl() {
    var state = VoiceHoldStateMachine()
    #expect(state.flagsChanged(.option) == nil)
    #expect(state.flagsChanged(.chord) == .pressed)
    #expect(state.flagsChanged([]) == .released)
  }

  @Test func observationNeverStartsFromModifiersAlreadyHeld() {
    var state = VoiceHoldStateMachine()
    state.beginObserving(modifiers: .chord)
    #expect(state.flagsChanged(.chord) == nil)
    #expect(state.flagsChanged(.option) == nil)
    #expect(state.flagsChanged(.chord) == nil)
    #expect(state.flagsChanged([]) == nil)
    #expect(state.flagsChanged(.chord) == .pressed)
  }

  @Test func extraModifiersCancelAndRequireAFullModifierRelease() {
    for extra: VoiceChordModifiers in [.command, .shift, .function] {
      var state = VoiceHoldStateMachine()
      #expect(state.flagsChanged(.chord) == .pressed)
      #expect(state.flagsChanged(.chord.union(extra)) == .cancelled(.unexpectedModifiers))
      #expect(state.flagsChanged(.chord) == nil)
      #expect(state.flagsChanged([]) == nil)
      #expect(state.flagsChanged(.chord.union(extra)) == nil)
      #expect(state.flagsChanged(.chord) == nil)
      #expect(state.flagsChanged([]) == nil)
      #expect(state.flagsChanged(.chord) == .pressed)
    }
  }

  @Test func ordinaryShortcutsCancelWithoutRearmingOnKeyUp() {
    var state = VoiceHoldStateMachine()
    #expect(state.flagsChanged(.chord) == .pressed)
    #expect(state.ordinaryKeyDown(isRepeat: false) == .cancelled(.anotherKey))
    #expect(state.ordinaryKeyDown(isRepeat: true) == nil)
    state.ordinaryKeyUp()
    #expect(state.flagsChanged(.chord) == nil)
    #expect(state.flagsChanged([]) == nil)
    #expect(state.flagsChanged(.chord) == .pressed)
  }

  @Test func aPreviouslyHeldOrdinaryKeyPreventsVoiceActivation() {
    var state = VoiceHoldStateMachine()
    #expect(state.ordinaryKeyDown(isRepeat: false) == nil)
    #expect(state.flagsChanged(.chord) == nil)
    state.ordinaryKeyUp()
    #expect(state.flagsChanged(.chord) == nil)
    #expect(state.flagsChanged([]) == nil)
    #expect(state.flagsChanged(.chord) == .pressed)
  }

  @Test func cancellationIsDistinctFromReleaseAndEmittedOnlyOnce() {
    for reason: VoiceShortcutCancellation in [
      .systemSleep, .sessionInactive, .monitorUnavailable, .teardown, .manualStop,
    ] {
      var state = VoiceHoldStateMachine()
      #expect(state.flagsChanged(.chord) == .pressed)
      #expect(state.cancel(reason) == .cancelled(reason))
      #expect(state.cancel(reason) == nil)
      #expect(state.flagsChanged([]) == nil)
      #expect(state.flagsChanged(.chord) == .pressed)
    }
  }

  @Test func lockAndDeviceFlagsAreExplicitlyIgnoredWhileChordCategoriesRemainExact() {
    #expect(
      VoiceChordModifiers(flags: [.maskControl, .maskAlternate, .maskAlphaShift, .maskNumericPad])
        == .chord)
    #expect(VoiceChordModifiers(flags: [.maskControl, .maskAlternate, .maskShift]) != .chord)
    #expect(VoiceChordModifiers(flags: [.maskControl, .maskAlternate, .maskSecondaryFn]) != .chord)
  }

  @Test func legacyPreferencesKeepCustomTextShortcutsAndEnableVoiceHoldByDefault() throws {
    let legacy = Data(
      #"{"openShortcut":{"key":"K","modifiers":12},"captureShortcut":{"key":"R","modifiers":3},"captureEnabled":true}"#
        .utf8)
    let decoded = try JSONDecoder().decode(ShortcutPreferences.self, from: legacy)
    #expect(decoded.voiceHoldEnabled)
    #expect(decoded.openShortcut == GlobalShortcut(key: .k, modifiers: [.control, .option]))
    #expect(decoded.captureEnabled)
    var disabled = decoded
    disabled.voiceHoldEnabled = false
    #expect(
      try JSONDecoder().decode(ShortcutPreferences.self, from: JSONEncoder().encode(disabled))
        == disabled)
  }
}
