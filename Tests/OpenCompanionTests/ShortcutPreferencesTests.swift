import Carbon
import Foundation
import Testing

@testable import OpenCompanion

struct ShortcutPreferencesTests {
  @Test func defaultsKeepOpenShortcutAndLeaveCaptureOptIn() throws {
    let preferences = try ShortcutPreferences.defaults.validated()
    #expect(preferences.openShortcut == GlobalShortcut(key: .space, modifiers: [.command, .shift]))
    #expect(preferences.captureShortcut == GlobalShortcut(key: .r, modifiers: [.command, .shift]))
    #expect(!preferences.captureEnabled)
    #expect(preferences.openShortcut.modifiers.carbonMask == UInt32(cmdKey | shiftKey))
  }
  @Test func ordinaryTypingAndUnknownModifierBitsAreRejected() {
    for modifiers: ShortcutModifiers in [[], .shift] {
      #expect(throws: ShortcutValidationError.modifierRequired) {
        try GlobalShortcut(key: .r, modifiers: modifiers).validated()
      }
    }
    #expect(throws: ShortcutValidationError.unsupportedModifiers) {
      try GlobalShortcut(key: .k, modifiers: .init(rawValue: 255)).validated()
    }
  }
  @Test func enabledActionsCannotShareACombination() throws {
    var preferences = ShortcutPreferences.defaults
    preferences.captureShortcut = preferences.openShortcut
    _ = try preferences.validated()
    preferences.captureEnabled = true
    #expect(throws: ShortcutValidationError.duplicateActions) { try preferences.validated() }
    preferences.captureShortcut.modifiers.insert(.option)
    _ = try preferences.validated()
  }
  @Test func persistentRepresentationRoundTripsAndRejectsUnknownKeys() throws {
    var preferences = ShortcutPreferences.defaults
    preferences.openShortcut = .init(key: .k, modifiers: [.control, .option])
    preferences.captureEnabled = true
    #expect(
      try JSONDecoder().decode(
        ShortcutPreferences.self,
        from: JSONEncoder().encode(preferences)) == preferences)
    #expect(preferences.openShortcut.displayName == "⌃⌥K")
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        GlobalShortcut.self,
        from: Data(#"{"key":"Fictional","modifiers":{"rawValue":1}}"#.utf8))
    }
  }
  @Test func registrationErrorsKeepTheOperatingSystemStatus() {
    let error = HotkeyRegistrationError(
      status: OSStatus(eventHotKeyExistsErr), operation: "register")
    #expect(error.localizedDescription.contains("already used"))
    #expect(error.localizedDescription.contains(String(eventHotKeyExistsErr)))
  }
}
