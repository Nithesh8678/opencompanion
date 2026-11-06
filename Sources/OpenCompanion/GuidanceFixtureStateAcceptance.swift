import AppKit
import ApplicationServices

/// Opt-in acceptance support for the separate, authored public fixture only.
/// Nothing here activates an app, changes a value, requests a grant or posts input.
enum GuidanceFixtureStateAcceptance {
  struct Snapshot: Codable, Sendable, Equatable {
    let tableNameMatchesReleaseQA: Bool
    let protectDataChecked: Bool
    let capturedAtUptime: TimeInterval
    let publicFixturePID: pid_t
  }

  enum Control: String, Sendable, Hashable, CaseIterable {
    case tableName = "fixture.tableName"
    case protectData = "fixture.protectData"
  }

  enum Failure: Error, Sendable, Equatable {
    case accessibilityDenied
    case fixtureAbsent
    case fixtureDisappeared
    case staleIdentity
    case displayNotCovered
    case focusedWindowAbsent
    case attributeUnavailable
    case traversalLimitExceeded
    case deadlineExceeded
    case missingControl(Control)
    case duplicateControl(Control)
    case invalidRole(Control)
    case hiddenControl(Control)
    case invalidValue(Control)
  }

  /// Content-free values produced only after reading one of the exact IDs.
  enum ObservedValue: Sendable {
    case tableNameMatches(Bool)
    case checkboxChecked(Bool)
  }

  struct Observation: Sendable {
    let control: Control
    let role: String
    let hidden: Bool
    let value: ObservedValue
  }

  struct TraversalBudget: Sendable {
    private(set) var visited = 0
    var remaining: Int { 128 - visited }

    mutating func visit(depth: Int) throws {
      guard (0...8).contains(depth), visited < 128 else {
        throw Failure.traversalLimitExceeded
      }
      visited += 1
    }

    func admitChildren(_ count: Int, depth: Int) throws {
      guard count >= 0, count <= remaining, count == 0 || depth < 8 else {
        throw Failure.traversalLimitExceeded
      }
    }
  }

  /// Pre/post identity checks establish observation boundaries, not an atomic
  /// screenshot/AX transaction. The caller must bracket its final capture too.
  @MainActor static func snapshot(
    expectedFixturePID: pid_t, displayID: CGDirectDisplayID, screenRect: CGRect
  ) async throws -> Snapshot {
    try Task.checkCancellation()
    let before = try identity(
      expectedFixturePID: expectedFixturePID, displayID: displayID, screenRect: screenRect)
    guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
    let worker = Task.detached(priority: .userInitiated) {
      try readControls(pid: expectedFixturePID)
    }
    let result = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    try Task.checkCancellation()
    let after = try identity(
      expectedFixturePID: expectedFixturePID, displayID: displayID, screenRect: screenRect)
    guard before == after else { throw Failure.staleIdentity }
    guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
    return result
  }

  static func validatedSnapshot(
    observations: [Observation], capturedAtUptime: TimeInterval, publicFixturePID: pid_t
  ) throws -> Snapshot {
    guard publicFixturePID > 0, capturedAtUptime.isFinite, capturedAtUptime >= 0,
      observations.count <= 128
    else { throw Failure.staleIdentity }
    var tableMatches: Bool?
    var protectionChecked: Bool?
    var seen = Set<Control>()
    for observation in observations {
      guard seen.insert(observation.control).inserted else {
        throw Failure.duplicateControl(observation.control)
      }
      let expectedRole = observation.control == .tableName ? "AXTextField" : "AXCheckBox"
      guard observation.role == expectedRole else {
        throw Failure.invalidRole(observation.control)
      }
      guard !observation.hidden else { throw Failure.hiddenControl(observation.control) }
      switch (observation.control, observation.value) {
      case (.tableName, .tableNameMatches(let matches)): tableMatches = matches
      case (.protectData, .checkboxChecked(let checked)): protectionChecked = checked
      default: throw Failure.invalidValue(observation.control)
      }
    }
    guard let tableMatches else { throw Failure.missingControl(.tableName) }
    guard let protectionChecked else { throw Failure.missingControl(.protectData) }
    return Snapshot(
      tableNameMatchesReleaseQA: tableMatches, protectDataChecked: protectionChecked,
      capturedAtUptime: capturedAtUptime, publicFixturePID: publicFixturePID)
  }

  private struct Identity: Equatable {
    let pid: pid_t
    let launchedAt: Date?
    let windowID: CGWindowID
  }

  /// Identity and geometry only; this does not make an Accessibility request.
  @MainActor static func verifyEnvironment(
    expectedFixturePID: pid_t, displayID: CGDirectDisplayID, screenRect: CGRect
  ) throws {
    _ = try identity(
      expectedFixturePID: expectedFixturePID, displayID: displayID, screenRect: screenRect)
  }

  @MainActor private static func identity(
    expectedFixturePID: pid_t, displayID: CGDirectDisplayID, screenRect: CGRect
  ) throws -> Identity {
    guard expectedFixturePID > 0,
      expectedFixturePID != ProcessInfo.processInfo.processIdentifier,
      let fixture = NSRunningApplication(processIdentifier: expectedFixturePID)
    else { throw Failure.fixtureAbsent }
    guard !fixture.isTerminated else { throw Failure.fixtureDisappeared }
    guard fixture.bundleIdentifier == "org.opencompanion.fixture.guidance",
      NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedFixturePID
    else { throw Failure.staleIdentity }
    guard screenRect.origin.x.isFinite, screenRect.origin.y.isFinite,
      screenRect.size.width.isFinite, screenRect.size.height.isFinite,
      screenRect.size.width > 0, screenRect.size.height > 0,
      screenRect.size.width <= 100_000, screenRect.size.height <= 100_000,
      abs(screenRect.origin.x) <= 10_000_000, abs(screenRect.origin.y) <= 10_000_000,
      screenRect.contains(NSEvent.mouseLocation),
      let primary = NSScreen.screens.first,
      NSScreen.screens.contains(where: { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
          .uint32Value == displayID && screen.frame == screenRect
      })
    else { throw Failure.staleIdentity }
    let display = CGRect(
      x: screenRect.minX, y: primary.frame.maxY - screenRect.maxY,
      width: screenRect.width, height: screenRect.height)
    guard
      let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]], windows.count <= 4_096
    else { throw Failure.displayNotCovered }
    var matching: [CGWindowID] = []
    for window in windows {
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expectedFixturePID,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 1,
        let number = window[kCGWindowNumber as String] as? NSNumber,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        rect.origin.x.isFinite, rect.origin.y.isFinite,
        rect.size.width.isFinite, rect.size.height.isFinite,
        rect.size.width > 0, rect.size.height > 0, rect.contains(display)
      else { continue }
      matching.append(number.uint32Value)
    }
    guard matching.count == 1, let windowID = matching.first else {
      throw Failure.displayNotCovered
    }
    return Identity(pid: expectedFixturePID, launchedAt: fixture.launchDate, windowID: windowID)
  }

  private static func readControls(pid: pid_t) throws -> Snapshot {
    guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementSetMessagingTimeout(app, 0.15) == .success else {
      throw Failure.attributeUnavailable
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 1.2
    func check() throws {
      try Task.checkCancellation()
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.deadlineExceeded }
    }
    func checkedError(_ error: AXError) throws {
      if error == .apiDisabled { throw Failure.accessibilityDenied }
      if error == .invalidUIElement { throw Failure.fixtureDisappeared }
      throw Failure.attributeUnavailable
    }
    func read(_ element: AXUIElement, _ key: CFString, optional: Bool = false) throws -> CFTypeRef?
    {
      try check()
      // AX messaging timeouts belong to each client-side element object. The
      // application's timeout does not apply to its focused window or children.
      let timeout = AXUIElementSetMessagingTimeout(element, 0.15)
      guard timeout == .success else {
        try checkedError(timeout)
        return nil
      }
      var value: CFTypeRef?
      let error = AXUIElementCopyAttributeValue(element, key, &value)
      if optional && (error == .attributeUnsupported || error == .noValue) { return nil }
      guard error == .success, let value else {
        try checkedError(error)
        return nil
      }
      try check()
      return value
    }
    func boundedString(_ value: CFTypeRef?, maximum: Int) throws -> String? {
      guard let value else { return nil }
      guard CFGetTypeID(value) == CFStringGetTypeID() else {
        throw Failure.attributeUnavailable
      }
      let string = value as! CFString
      guard CFStringGetLength(string) <= maximum else { throw Failure.attributeUnavailable }
      return string as String
    }
    func children(_ element: AXUIElement, budget: TraversalBudget, depth: Int) throws
      -> [AXUIElement]
    {
      try check()
      let timeout = AXUIElementSetMessagingTimeout(element, 0.15)
      guard timeout == .success else {
        try checkedError(timeout)
        return []
      }
      var count: CFIndex = 0
      let error = AXUIElementGetAttributeValueCount(
        element, kAXChildrenAttribute as CFString, &count)
      if error == .attributeUnsupported || error == .noValue { return [] }
      guard error == .success else {
        try checkedError(error)
        return []
      }
      try budget.admitChildren(count, depth: depth)
      guard count > 0 else { return [] }
      try check()
      var values: CFArray?
      let copied = AXUIElementCopyAttributeValues(
        element, kAXChildrenAttribute as CFString, 0, count, &values)
      guard copied == .success, let values, CFArrayGetCount(values) == count,
        let result = values as? [AXUIElement], result.count == count
      else {
        try checkedError(copied)
        return []
      }
      try check()
      return result
    }
    guard let focused = try read(app, kAXFocusedWindowAttribute as CFString, optional: true) else {
      throw Failure.focusedWindowAbsent
    }
    guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
      throw Failure.attributeUnavailable
    }
    var budget = TraversalBudget()
    var observations: [Observation] = []
    func walk(_ element: AXUIElement, depth: Int, ancestorHidden: Bool) throws {
      try check()
      try budget.visit(depth: depth)
      guard
        let role = try boundedString(
          read(element, kAXRoleAttribute as CFString), maximum: 64)
      else { throw Failure.attributeUnavailable }
      // Never inspect values or descendants of a secure field, even in a fixture.
      let subrole = try boundedString(
        read(element, kAXSubroleAttribute as CFString, optional: true), maximum: 64)
      if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return }
      let hiddenValue = try read(element, kAXHiddenAttribute as CFString, optional: true)
      if let hiddenValue, CFGetTypeID(hiddenValue) != CFBooleanGetTypeID() {
        throw Failure.attributeUnavailable
      }
      let hidden = ancestorHidden || (hiddenValue as? Bool ?? false)
      let identifier = try boundedString(
        read(element, kAXIdentifierAttribute as CFString, optional: true), maximum: 128)
      if let identifier, let control = Control(rawValue: identifier) {
        guard !observations.contains(where: { $0.control == control }) else {
          throw Failure.duplicateControl(control)
        }
        guard role == (control == .tableName ? "AXTextField" : "AXCheckBox") else {
          throw Failure.invalidRole(control)
        }
        guard !hidden else { throw Failure.hiddenControl(control) }
        guard let value = try read(element, kAXValueAttribute as CFString) else {
          throw Failure.invalidValue(control)
        }
        let observed: ObservedValue
        switch control {
        case .tableName:
          guard CFGetTypeID(value) == CFStringGetTypeID() else {
            throw Failure.invalidValue(control)
          }
          // Compare CF strings directly; never retain/export the field's text.
          let string = value as! CFString
          observed = .tableNameMatches(
            CFStringGetLength(string) == 10 && CFEqual(string, "Release QA" as CFString))
        case .protectData:
          guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
            number.doubleValue == 0 || number.doubleValue == 1
          else { throw Failure.invalidValue(control) }
          observed = .checkboxChecked(number.doubleValue == 1)
        }
        observations.append(.init(control: control, role: role, hidden: hidden, value: observed))
      }
      for child in try children(element, budget: budget, depth: depth) {
        try walk(child, depth: depth + 1, ancestorHidden: hidden)
      }
    }
    try walk(focused as! AXUIElement, depth: 0, ancestorHidden: false)
    try check()
    return try validatedSnapshot(
      observations: observations, capturedAtUptime: ProcessInfo.processInfo.systemUptime,
      publicFixturePID: pid)
  }
}
