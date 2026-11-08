import CoreGraphics
import Foundation

/// Pure admission policy for a bounded explanation card. Option drag requires
/// a visible-triangle hit; local two-finger scroll requires the card's surface.
/// A native caller supplies actual geometry hits and maps its
/// modifier/button flags symbolically. This does not route, repost or synthesize
/// input, prove transparent-pixel hit behavior, focus a window or edit a scene.
struct ExplanationOrbitState: Equatable, Sendable {
  enum Phase: String, Codable, Sendable { case passive, armed, dragging, scrolling }

  struct Authority: Equatable, Sendable {
    let lease: UUID
    let documentID: String
    let generation: UInt64
    let displayID: UInt32

    fileprivate var isValid: Bool {
      !documentID.isEmpty && documentID.utf8.prefix(257).count <= 256 && displayID != 0
    }
  }

  /// These symbolic bits are deliberately not NSEvent.ModifierFlags raw bits.
  struct Modifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt16
    static let option = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let command = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)
    static let function = Self(rawValue: 1 << 4)
    static let capsLock = Self(rawValue: 1 << 5)
    static let numericPad = Self(rawValue: 1 << 6)
    static let help = Self(rawValue: 1 << 7)

    fileprivate var isOptionOnly: Bool {
      subtracting([.capsLock, .numericPad]) == .option
    }
  }

  struct Buttons: OptionSet, Equatable, Sendable {
    let rawValue: UInt16
    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let other = Self(rawValue: 1 << 2)
  }

  struct Input: Equatable, Sendable {
    var authority: Authority?
    var modifiers: Modifiers
    var buttons: Buttons
    var presentationVisible: Bool
    var awake: Bool
    var sessionActive: Bool
    var displayAvailable: Bool
    var spatialReady: Bool
    var pointerOnVisibleMesh: Bool
    var pointerInsideSurface = false

    fileprivate var canOwnSurface: Bool {
      authority?.isValid == true && presentationVisible
        && awake && sessionActive && displayAvailable && spatialReady
    }

    fileprivate var canOwnPanel: Bool { canOwnSurface && modifiers.isOptionOnly }

    fileprivate var canScroll: Bool {
      canOwnSurface && modifiers.subtracting([.capsLock, .numericPad]).isEmpty
        && buttons.isEmpty && pointerInsideSurface
    }
  }

  private(set) var phase = Phase.passive
  private(set) var authority: Authority?

  /// True reserves the bounded native panel for interaction. It makes no claim
  /// that transparent background clicks reach another application while armed.
  var acceptsMouseEvents: Bool { phase != .passive }

  /// Reconcile an authoritative current observation. A released/lost drag goes
  /// passive here; only an explicit endDrag may immediately rearm on mouse-up.
  @discardableResult mutating func update(_ input: Input) -> Phase {
    switch phase {
    case .passive:
      if input.canOwnPanel, input.buttons.isEmpty, input.pointerOnVisibleMesh {
        authority = input.authority
        phase = .armed
      }
    case .armed:
      guard input.canOwnPanel, input.authority == authority,
        input.buttons.isEmpty, input.pointerOnVisibleMesh
      else {
        cancel()
        return phase
      }
    case .dragging:
      guard input.canOwnPanel, input.authority == authority, input.buttons == .left
      else {
        cancel()
        return phase
      }
    // A drag admitted on real geometry retains ownership outside its mesh.
    case .scrolling:
      guard input.canScroll, input.authority == authority else {
        cancel()
        return phase
      }
    }
    return phase
  }

  /// Call only for the native panel's real left-mouse-down, before sending that
  /// down through generic update. Never acquires a drag that began underneath
  /// an initially passive panel. Recheck the actual mesh hit at this event.
  @discardableResult mutating func beginDrag(_ input: Input) -> Bool {
    guard phase == .armed, input.authority == authority else { return false }
    guard input.canOwnPanel, input.buttons == .left, input.pointerOnVisibleMesh else {
      cancel()
      return false
    }
    phase = .dragging
    return true
  }

  /// A queued mouse-up from an older presentation cannot end a newer drag.
  @discardableResult mutating func endDrag(_ input: Input) -> Bool {
    guard phase == .dragging, input.authority == authority else { return false }
    cancel()
    update(input)
    return true
  }

  /// Only a local gesture delivered to the owned card can call this. Momentum
  /// cannot acquire a new owner; the native caller enforces gesture phases.
  @discardableResult mutating func beginScroll(_ input: Input) -> Bool {
    guard phase != .dragging, input.canScroll else { return false }
    if phase == .scrolling, input.authority != authority { return false }
    authority = input.authority
    phase = .scrolling
    return true
  }

  @discardableResult mutating func endScroll(_ input: Input) -> Bool {
    guard phase == .scrolling, input.authority == authority else { return false }
    cancel()
    return true
  }

  /// Host-authored gain, not a reference-app cadence. No inertia is synthesized;
  /// every returned rotation comes from one finite local wheel/trackpad event.
  static func scrollDelta(x: Double, y: Double, precise: Bool) -> CGPoint? {
    guard x.isFinite, y.isFinite, abs(x) <= 4_096, abs(y) <= 4_096 else { return nil }
    let gain = precise ? 0.008 : 0.035
    return CGPoint(x: max(-0.20, min(0.20, x * gain)), y: max(-0.20, min(0.20, y * gain)))
  }

  mutating func cancel() {
    phase = .passive
    authority = nil
  }
}
