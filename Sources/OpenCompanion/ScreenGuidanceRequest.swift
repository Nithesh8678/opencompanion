import Foundation

/// A bounded user-requested guidance flow. It authorizes fresh perception after
/// an observed user click, never an automatic desktop action.
struct ScreenGuidanceRequest: Sendable, Equatable {
  let id: UUID
  let prompt: String
  let step: Int
  let expires: TimeInterval
  let speakAloud: Bool

  init(
    id: UUID = UUID(), prompt: String, step: Int = 0, expires: TimeInterval? = nil,
    speakAloud: Bool = true
  ) {
    self.id = id
    self.prompt = prompt
    self.step = step
    self.speakAloud = speakAloud
    self.expires = expires ?? ProcessInfo.processInfo.systemUptime + 180
  }
}
