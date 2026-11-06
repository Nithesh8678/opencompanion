import CoreGraphics
import Foundation

/// The deliberately selected capture extent for a live guidance request. This
/// descriptor carries no image, frame/candidate identity or durable authority.
/// The host must independently own selectionID and each newly captured frame.
struct ScreenGuidanceCaptureScope: Sendable, Equatable {
  let selectionID: UUID
  let foregroundPID: pid_t
  let displayID: CGDirectDisplayID
  let windowID: CGWindowID?
  let sourceRect: CGRect

  init(evidence: ScreenEvidence, selectionID: UUID) throws {
    let rect = evidence.screenRect
    guard evidence.foregroundPID > 0, evidence.displayID > 0,
      evidence.windowID.map({ $0 > 0 }) ?? true,
      rect.origin.x.isFinite, rect.origin.y.isFinite,
      abs(rect.origin.x) <= 10_000_000, abs(rect.origin.y) <= 10_000_000,
      rect.size.width.isFinite, rect.size.height.isFinite,
      rect.size.width > 0, rect.size.height > 0,
      rect.size.width <= 100_000, rect.size.height <= 100_000,
      rect.maxX.isFinite, rect.maxY.isFinite
    else {
      throw ProviderError.message(
        "The selected screen scope is invalid. Recapture that window or region before continuing guidance."
      )
    }
    self.selectionID = selectionID
    foregroundPID = evidence.foregroundPID
    displayID = evidence.displayID
    windowID = evidence.windowID
    sourceRect = rect
  }

  /// Metadata equality alone does not authorize a frame or a host selection.
  func matches(_ evidence: ScreenEvidence?) -> Bool {
    guard let evidence else { return false }
    return evidence.foregroundPID == foregroundPID && evidence.displayID == displayID
      && evidence.windowID == windowID && evidence.screenRect.origin == sourceRect.origin
      && evidence.screenRect.size == sourceRect.size
  }
}

/// A bounded user-requested guidance flow. It authorizes fresh perception after
/// an observed user click, never an automatic desktop action.
struct ScreenGuidanceRequest: Sendable, Equatable {
  let id: UUID
  let prompt: String
  let step: Int
  let expires: TimeInterval
  let speakAloud: Bool
  let selectedScope: ScreenGuidanceCaptureScope?

  init(
    id: UUID = UUID(), prompt: String, step: Int = 0, expires: TimeInterval? = nil,
    speakAloud: Bool = true, selectedScope: ScreenGuidanceCaptureScope? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.step = step
    self.speakAloud = speakAloud
    self.selectedScope = selectedScope
    self.expires = expires ?? ProcessInfo.processInfo.systemUptime + 180
  }
}
