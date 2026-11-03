import Foundation

extension Notification.Name {
  static let cursorCompanionPreferencesDidChange = Notification.Name(
    "org.opencompanion.cursorCompanionPreferencesDidChange")
}

struct CursorCompanionPreferences: Codable, Equatable, Sendable {
  static let storageKey = "cursorCompanionPreferences.v1"
  var enabled = true
  var showReplies = true
  var screenGuidanceEnabled = true

  init(enabled: Bool = true, showReplies: Bool = true, screenGuidanceEnabled: Bool = true) {
    self.enabled = enabled
    self.showReplies = showReplies
    self.screenGuidanceEnabled = screenGuidanceEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case enabled, showReplies, screenGuidanceEnabled
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    showReplies = try values.decodeIfPresent(Bool.self, forKey: .showReplies) ?? true
    screenGuidanceEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .screenGuidanceEnabled) ?? true
  }

  static func load(defaults: UserDefaults = .standard) -> Self {
    guard let data = defaults.data(forKey: storageKey),
      let preferences = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return preferences
  }

  @MainActor func save(defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.storageKey)
    NotificationCenter.default.post(name: .cursorCompanionPreferencesDidChange, object: nil)
  }
}
