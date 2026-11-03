import AppKit
import Carbon
import Foundation
import SwiftUI

enum ShortcutKey: String, CaseIterable, Codable, Identifiable, Sendable {
  case space = "Space"
  case r = "R"
  case k = "K"
  case g = "G"
  case j = "J"
  var id: String { rawValue }
  var keyCode: UInt32 {
    switch self {
    case .space: UInt32(kVK_Space)
    case .r: UInt32(kVK_ANSI_R)
    case .k: UInt32(kVK_ANSI_K)
    case .g: UInt32(kVK_ANSI_G)
    case .j: UInt32(kVK_ANSI_J)
    }
  }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
  let rawValue: UInt8
  init(rawValue: UInt8) { self.rawValue = rawValue }
  static let command = Self(rawValue: 1 << 0)
  static let shift = Self(rawValue: 1 << 1)
  static let option = Self(rawValue: 1 << 2)
  static let control = Self(rawValue: 1 << 3)
  static let allowed: Self = [.command, .shift, .option, .control]
  var carbonMask: UInt32 {
    var mask: UInt32 = 0
    if contains(.command) { mask |= UInt32(cmdKey) }
    if contains(.shift) { mask |= UInt32(shiftKey) }
    if contains(.option) { mask |= UInt32(optionKey) }
    if contains(.control) { mask |= UInt32(controlKey) }
    return mask
  }
  var symbols: String {
    (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
      + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
  }
}

struct GlobalShortcut: Codable, Equatable, Sendable {
  var key: ShortcutKey
  var modifiers: ShortcutModifiers
  var displayName: String { modifiers.symbols + key.rawValue }

  @discardableResult func validated() throws -> Self {
    guard modifiers.subtracting(.allowed).isEmpty else {
      throw ShortcutValidationError.unsupportedModifiers
    }
    guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
      throw ShortcutValidationError.modifierRequired
    }
    return self
  }
}

enum ShortcutValidationError: Error, Equatable, LocalizedError {
  case modifierRequired, unsupportedModifiers, duplicateActions
  var errorDescription: String? {
    switch self {
    case .modifierRequired: "Use Command, Option, or Control so ordinary typing remains available."
    case .unsupportedModifiers: "This shortcut contains an unsupported modifier."
    case .duplicateActions: "Open companion and capture screen need different shortcuts."
    }
  }
}

extension Notification.Name {
  static let shortcutPreferencesDidChange = Notification.Name(
    "org.opencompanion.shortcutPreferencesDidChange")
}

struct ShortcutPreferences: Codable, Equatable, Sendable {
  static let storageKey = "globalShortcutPreferences.v1"
  static let defaults = Self()
  var openShortcut = GlobalShortcut(key: .space, modifiers: [.command, .shift])
  var captureShortcut = GlobalShortcut(key: .r, modifiers: [.command, .shift])
  var captureEnabled = false
  var voiceHoldEnabled = true

  private enum CodingKeys: String, CodingKey {
    case openShortcut, captureShortcut, captureEnabled, voiceHoldEnabled
  }
  init() {}
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    openShortcut = try values.decode(GlobalShortcut.self, forKey: .openShortcut)
    captureShortcut = try values.decode(GlobalShortcut.self, forKey: .captureShortcut)
    captureEnabled = try values.decode(Bool.self, forKey: .captureEnabled)
    voiceHoldEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceHoldEnabled) ?? true
  }

  @discardableResult func validated() throws -> Self {
    try openShortcut.validated()
    try captureShortcut.validated()
    guard !captureEnabled || openShortcut != captureShortcut else {
      throw ShortcutValidationError.duplicateActions
    }
    return self
  }
  static func load(defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: storageKey),
      let decoded = try? JSONDecoder().decode(Self.self, from: data),
      (try? decoded.validated()) != nil
    else { return Self.defaults }
    return decoded
  }
  @MainActor func save(defaults: UserDefaults = .standard) throws {
    try validated()
    defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    NotificationCenter.default.post(name: .shortcutPreferencesDidChange, object: nil)
  }
}

struct ShortcutSettingsView: View {
  @State private var preferences = ShortcutPreferences.load()
  @State private var feedback: String?
  @State private var hasError = false

  var body: some View {
    Section("Global shortcuts") {
      shortcutEditor("Open companion for text", shortcut: $preferences.openShortcut)
      Toggle("Hold Control + Option to talk", isOn: $preferences.voiceHoldEnabled)
        .accessibilityIdentifier("settings.shortcuts.voiceHold")
      Text(
        "Press and hold both modifiers to speak; release either to finish. Command, Shift, Fn or another key cancels the hold. Caps Lock does not change it. Your text/open shortcut remains separate."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "Global voice observation needs Input Monitoring permission, and on some macOS configurations Accessibility. If unavailable, use Talk in the notch. Control + Option is also used by VoiceOver; turn this shortcut off here if it conflicts. VoiceOver settings are never changed."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Allow global voice shortcut…") {
          _ = VoiceShortcutMonitor.requestListenPermission()
        }
        Button("Open Input Monitoring") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }
      Text(voicePermissionMessage).font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("settings.shortcuts.voicePermission")
      Toggle("Enable a shortcut to capture the selected display", isOn: $preferences.captureEnabled)
      if preferences.captureEnabled {
        shortcutEditor("Capture screen", shortcut: $preferences.captureShortcut)
      }
      Text(
        "Capture selects one frame for your next question. macOS reports shortcuts already used by another app; the menu remains available."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "If a replacement conflicts, the last working shortcut stays active for this session. Saved preferences are retried at the next launch."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save shortcuts") {
          do {
            try preferences.save()
            hasError = false
            feedback =
              "Preferences saved. Check the companion for registration conflicts; a rejected replacement keeps the previous working shortcut."
          } catch {
            hasError = true
            feedback = error.localizedDescription
          }
        }
        Button("Reset defaults") {
          preferences = .defaults
          hasError = false
          feedback = "Default shortcuts selected. Press Save shortcuts to apply."
        }
      }
      if let feedback {
        Text(feedback).font(.caption).foregroundStyle(hasError ? .red : .secondary)
          .accessibilityIdentifier("settings.shortcuts.feedback")
      }
    }
  }
  private var voicePermissionMessage: String {
    if CGPreflightListenEventAccess() || AXIsProcessTrusted() {
      return
        "Permission is available. Save shortcuts to apply changes; the companion reports whether global observation is installed."
    }
    return VoiceShortcutMonitor.permissionMessage
  }
  private func shortcutEditor(_ title: String, shortcut: Binding<GlobalShortcut>) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
        Spacer()
        Text(shortcut.wrappedValue.displayName).font(.system(.body, design: .monospaced))
          .foregroundStyle(.secondary)
        Picker("Key", selection: shortcut.key) {
          ForEach(ShortcutKey.allCases) { key in Text(key.rawValue).tag(key) }
        }.labelsHidden().frame(width: 100).accessibilityLabel("\(title) key")
      }
      HStack(spacing: 14) {
        modifierToggle("Command", modifier: .command, shortcut: shortcut)
        modifierToggle("Shift", modifier: .shift, shortcut: shortcut)
        modifierToggle("Option", modifier: .option, shortcut: shortcut)
        modifierToggle("Control", modifier: .control, shortcut: shortcut)
      }.toggleStyle(.checkbox)
    }.padding(.vertical, 3)
  }
  private func modifierToggle(
    _ title: String, modifier: ShortcutModifiers,
    shortcut: Binding<GlobalShortcut>
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { shortcut.wrappedValue.modifiers.contains(modifier) },
        set: { enabled in
          if enabled {
            shortcut.wrappedValue.modifiers.insert(modifier)
          } else {
            shortcut.wrappedValue.modifiers.remove(modifier)
          }
        }))
  }
}
