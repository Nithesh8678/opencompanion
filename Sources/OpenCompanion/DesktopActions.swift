import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

struct DesktopTarget: Identifiable, Sendable, Equatable {
  let id: String
  let role: String
  let label: String
  let value: String
  let x: Double, y: Double, width: Double, height: Double
  let actions: [String]
  let path: [Int]
  let secure: Bool
  var canPress: Bool { actions.contains(kAXPressAction as String) && !secure }
  var canType: Bool {
    [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(
      role) && !secure
  }
}
struct DesktopSnapshot: Sendable {
  let revision: UUID
  let pid: pid_t
  let windowTitle: String
  let targets: [DesktopTarget]
  let truncated: Bool
  let collectedAt: Date
}
struct DesktopApplication: Identifiable, Sendable {
  let pid: pid_t
  let name: String
  var id: pid_t { pid }
}
struct DesktopTutorialStep: Identifiable, Sendable {
  let id = UUID()
  let instruction: String
  let expectedTitle: String
  let expectedValue: String
  let targetRole: String
  let targetLabel: String
}
private enum DesktopActionError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { text } else { "Desktop action failed." }
  }
}

/// Bounded AX work is actor-isolated and never runs in a display/audio callback.
private actor DesktopAXWorker {
  private var latest: DesktopSnapshot?
  private let maxTargets = 220
  private let maxVisited = 700

  private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.12)
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }
  private func string(_ element: AXUIElement, _ key: String) -> String {
    guard let value = attribute(element, key), CFGetTypeID(value) == CFStringGetTypeID() else {
      return ""
    }
    return String((value as! String).prefix(1000))
  }
  private func children(_ element: AXUIElement) -> [AXUIElement] {
    AXUIElementSetMessagingTimeout(element, 0.12)
    var count: CFIndex = 0
    guard
      AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        == .success, count > 0
    else { return [] }
    var values: CFArray?
    guard
      AXUIElementCopyAttributeValues(
        element, kAXChildrenAttribute as CFString, 0, min(count, 250), &values) == .success
    else { return [] }
    return values as? [AXUIElement] ?? []
  }
  private func focusedPID() -> pid_t? {
    let system = AXUIElementCreateSystemWide()
    guard let value = attribute(system, kAXFocusedApplicationAttribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    var pid: pid_t = 0
    return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
  }
  private func scan(pid: pid_t) throws -> DesktopSnapshot {
    guard AXIsProcessTrusted() else {
      throw DesktopActionError.message(
        "Accessibility access is required. Enable OpenCompanion in System Settings → Privacy & Security → Accessibility."
      )
    }
    try Task.checkCancellation()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.12)
    let started = ProcessInfo.processInfo.systemUptime
    guard let focusedWindowValue = attribute(app, kAXFocusedWindowAttribute),
      CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID()
    else {
      throw DesktopActionError.message(
        "The selected app exposes no focused window. Bring its window forward and collect again.")
    }
    let focusedWindow = focusedWindowValue as! AXUIElement
    let appChildren = children(app)
    // Keep AXUIElement traversal in plain actor-local loops. Swift 6.1's
    // region isolation cannot safely infer non-Sendable AX references
    // captured by collection predicates or a loop's `where` expression.
    var windowIndex: Int?
    var appChildIndex = 0
    while appChildIndex < appChildren.count {
      if CFEqual(appChildren[appChildIndex], focusedWindow) {
        windowIndex = appChildIndex
        break
      }
      appChildIndex += 1
    }
    guard let windowIndex else {
      throw DesktopActionError.message(
        "This app does not expose a direct focused-window accessibility path; no actions are enabled."
      )
    }
    var queue: [(AXUIElement, [Int])] = [(focusedWindow, [windowIndex])]
    var cursor = 0
    var targets: [DesktopTarget] = []
    var windowTitle = ""
    while cursor < queue.count && cursor < maxVisited && targets.count < maxTargets
      && ProcessInfo.processInfo.systemUptime - started < 0.8
    {
      try Task.checkCancellation()
      let (element, path) = queue[cursor]
      cursor += 1
      let role = string(element, kAXRoleAttribute)
      if role == kAXWindowRole as String && windowTitle.isEmpty {
        windowTitle = string(element, kAXTitleAttribute)
      }
      let subrole = string(element, kAXSubroleAttribute)
      let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
      let label =
        [
          string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
          string(element, kAXHelpAttribute),
        ].first(where: { !$0.isEmpty }) ?? ""
      var actionValues: CFArray?
      let actions: [String] =
        AXUIElementCopyActionNames(element, &actionValues) == .success
        ? (actionValues as? [String] ?? []) : []
      var point = CGPoint.zero
      var size = CGSize.zero
      if let raw = attribute(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID()
      {
        AXValueGetValue(raw as! AXValue, .cgPoint, &point)
      }
      if let raw = attribute(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        AXValueGetValue(raw as! AXValue, .cgSize, &size)
      }
      if !path.isEmpty
        && (actions.contains(kAXPressAction as String)
          || [
            kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
            kAXStaticTextRole as String, kAXWindowRole as String,
          ].contains(role))
        && point.x.isFinite && point.y.isFinite && size.width > 0 && size.height > 0
      {
        let value = secure ? "[protected]" : string(element, kAXValueAttribute)
        targets.append(
          DesktopTarget(
            id: "\(pid):" + path.map(String.init).joined(separator: "."), role: role, label: label,
            value: value, x: point.x, y: point.y, width: size.width, height: size.height,
            actions: actions, path: path, secure: secure))
      }
      let hasQueueCapacity = queue.count < maxVisited
      if path.count < 12 && hasQueueCapacity {
        let childValues = children(element)
        var childIndex = 0
        while childIndex < childValues.count {
          if queue.count >= maxVisited { break }
          let child = childValues[childIndex]
          queue.append((child, path + [childIndex]))
          childIndex += 1
        }
      }
    }
    return DesktopSnapshot(
      revision: UUID(), pid: pid, windowTitle: windowTitle, targets: targets,
      truncated: cursor < queue.count, collectedAt: Date())
  }
  func collect(pid: pid_t) throws -> DesktopSnapshot {
    let snapshot = try scan(pid: pid)
    latest = snapshot
    return snapshot
  }
  private func resolve(pid: pid_t, path: [Int]) throws -> AXUIElement {
    var element = AXUIElementCreateApplication(pid)
    for index in path {
      try Task.checkCancellation()
      let values = children(element)
      guard values.indices.contains(index) else {
        throw DesktopActionError.message("Target detached. Collect a fresh snapshot.")
      }
      element = values[index]
    }
    return element
  }
  func perform(
    pid: pid_t, revision: UUID, ref: String, kind: String, text: String, expectedTitle: String
  ) async throws -> (DesktopSnapshot, String) {
    guard let old = latest, old.pid == pid, old.revision == revision,
      let target = old.targets.first(where: { $0.id == ref })
    else { throw DesktopActionError.message("Stale target. Collect and select again.") }
    guard Date().timeIntervalSince(old.collectedAt) < 60 else {
      throw DesktopActionError.message("Snapshot expired. Collect fresh evidence first.")
    }
    guard focusedPID() == pid else {
      throw DesktopActionError.message("Selected app is not focused. No action dispatched.")
    }
    let current = try scan(pid: pid)
    guard current.windowTitle == old.windowTitle,
      let fresh = current.targets.first(where: { $0.id == ref }), fresh == target
    else {
      latest = current
      throw DesktopActionError.message(
        "Target changed or moved. No action dispatched; collect again.")
    }
    guard !target.secure else {
      throw DesktopActionError.message("Protected fields require direct user input.")
    }
    let element = try resolve(pid: pid, path: target.path)
    AXUIElementSetMessagingTimeout(element, 0.12)
    try Task.checkCancellation()
    guard focusedPID() == pid else {
      throw DesktopActionError.message("Focus changed before dispatch.")
    }
    if kind == "press" {
      guard target.canPress else {
        throw DesktopActionError.message("Target exposes no press action.")
      }
      guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
        throw DesktopActionError.message(
          "The app rejected its press action; no success is assumed.")
      }
    } else if kind == "type" {
      guard target.canType, text.utf8.count <= 12000 else {
        throw DesktopActionError.message("Choose an ordinary text field and at most 12,000 bytes.")
      }
      guard
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
          == .success
      else { throw DesktopActionError.message("Typing focus could not be set.") }
      let system = AXUIElementCreateSystemWide()
      guard let focused = attribute(system, kAXFocusedUIElementAttribute),
        CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, element),
        focusedPID() == pid
      else {
        throw DesktopActionError.message("Actual typing focus did not match the selected target.")
      }
      guard
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
          == .success
      else { throw DesktopActionError.message("The app rejected the value write.") }
    } else {
      throw DesktopActionError.message("Unsupported desktop action.")
    }
    // An accepted AX dispatch still needs independently re-read evidence.
    do {
      try await Task.sleep(for: .milliseconds(180))
      try Task.checkCancellation()
    } catch {
      throw DesktopActionError.message(
        "Stopped after dispatch. Outcome unknown; observe the app before retrying.")
    }
    let after: DesktopSnapshot
    do { after = try scan(pid: pid) } catch {
      throw DesktopActionError.message(
        "Attempted · outcome unknown. Fresh AX evidence could not be read after dispatch. Observe before retrying."
      )
    }
    latest = after
    if kind == "type", let readback = after.targets.first(where: { $0.id == ref }),
      readback.value == text
    {
      return (after, "Verified: the selected field now contains the requested value.")
    }
    if !expectedTitle.isEmpty, after.windowTitle.contains(expectedTitle),
      after.windowTitle != old.windowTitle
    {
      return (after, "Verified: fresh window title matches ‘\(expectedTitle)’.")
    }
    return (
      after,
      "Attempted · outcome unknown. The action was accepted by AX; no requested postcondition was verified. Observe before retrying."
    )
  }
  func verify(pid: pid_t, step: DesktopTutorialStep) throws -> (DesktopSnapshot, Bool) {
    let snapshot = try scan(pid: pid)
    latest = snapshot
    let titleOK = step.expectedTitle.isEmpty || snapshot.windowTitle.contains(step.expectedTitle)
    let candidates = snapshot.targets.filter {
      $0.role == step.targetRole && $0.label == step.targetLabel && !$0.secure
    }
    let valueOK =
      step.expectedValue.isEmpty
      || (candidates.count == 1 && candidates[0].value == step.expectedValue)
    return (
      snapshot, titleOK && valueOK && (!step.expectedTitle.isEmpty || !step.expectedValue.isEmpty)
    )
  }
}

@MainActor final class DesktopActionsController: ObservableObject {
  @Published var applications: [DesktopApplication] = []
  @Published var selectedPID: pid_t?
  @Published var selectedRef: String?
  @Published var snapshot: DesktopSnapshot?
  @Published var status = "Choose an app and collect deliberate accessibility evidence."
  @Published var busy = false
  @Published var text = ""
  @Published var expectedTitle = ""
  @Published var instruction = ""
  @Published var expectedValue = ""
  @Published var steps: [DesktopTutorialStep] = []
  @Published var verifiedSteps = 0
  private let worker = DesktopAXWorker()
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  var selectedTarget: DesktopTarget? { snapshot?.targets.first(where: { $0.id == selectedRef }) }
  init() { refreshApplications() }
  func refreshApplications() {
    applications = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular
        && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }.map {
      DesktopApplication(
        pid: $0.processIdentifier, name: $0.localizedName ?? "App \($0.processIdentifier)")
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    if !applications.contains(where: { $0.pid == selectedPID }) {
      selectedPID = applications.first?.pid
      snapshot = nil
      selectedRef = nil
    }
  }
  func collect() {
    guard let pid = selectedPID else { return }
    stop()
    busy = true
    status = "Collecting bounded AX evidence…"
    let current = generation
    task = Task {
      do {
        let result = try await worker.collect(pid: pid)
        guard current == generation else { return }
        snapshot = result
        selectedRef = nil
        status =
          "Observed \(result.targets.count) targets\(result.truncated ? " · bounded/truncated" : "") in ‘\(result.windowTitle)’."
        busy = false
      } catch {
        guard current == generation else { return }
        status = error.localizedDescription
        busy = false
      }
    }
  }
  func perform(_ kind: String) {
    guard let snapshot, let target = selectedTarget, snapshot.pid == selectedPID else { return }
    stop()
    busy = true
    status = "Activating the selected app for your explicit action…"
    let current = generation
    let value = text
    let title = expectedTitle
    task = Task {
      do {
        guard let app = NSRunningApplication(processIdentifier: snapshot.pid),
          app.activate(options: [])
        else { throw DesktopActionError.message("Could not activate the selected app.") }
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        let (after, receipt) = try await worker.perform(
          pid: snapshot.pid, revision: snapshot.revision, ref: target.id, kind: kind, text: value,
          expectedTitle: title)
        guard current == generation else { return }
        self.snapshot = after
        selectedRef = nil
        status = receipt
        busy = false
      } catch {
        guard current == generation else { return }
        status = error.localizedDescription
        selectedRef = nil
        busy = false
      }
    }
  }
  func addStep() {
    guard !instruction.trimmingCharacters(in: .whitespaces).isEmpty,
      !expectedTitle.isEmpty || !expectedValue.isEmpty
    else {
      status = "A tutorial step needs an instruction and an observable title/value postcondition."
      return
    }
    if !expectedValue.isEmpty && selectedTarget == nil {
      status = "Select the field whose future value should be verified."
      return
    }
    steps.append(
      DesktopTutorialStep(
        instruction: String(instruction.prefix(2000)),
        expectedTitle: String(expectedTitle.prefix(1000)),
        expectedValue: String(expectedValue.prefix(1000)), targetRole: selectedTarget?.role ?? "",
        targetLabel: selectedTarget?.label ?? ""))
    instruction = ""
    status = "Step added. Perform it in the selected app, then observe and verify."
  }
  func verifyNext() {
    guard let pid = selectedPID, steps.indices.contains(verifiedSteps) else { return }
    stop()
    busy = true
    let current = generation
    let step = steps[verifiedSteps]
    task = Task {
      do {
        let (after, success) = try await worker.verify(pid: pid, step: step)
        guard current == generation else { return }
        snapshot = after
        selectedRef = nil
        if success {
          verifiedSteps += 1
          status =
            verifiedSteps == steps.count
            ? "Tutorial complete · every configured postcondition was observed."
            : "Postcondition verified. Continue with the next step."
        } else {
          status =
            "Postcondition not observed. Step remains pending; inspect the app and try observing again."
        }
        busy = false
      } catch {
        guard current == generation else { return }
        status = error.localizedDescription
        busy = false
      }
    }
  }
  func stop() {
    generation &+= 1
    task?.cancel()
    task = nil
    busy = false
    status = "Stopped. Observe the app before retrying any action already dispatched."
  }
}

struct DesktopActionsView: View {
  @StateObject private var controller = DesktopActionsController()
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Deliberate desktop actions").font(.title2.bold())
      Text(
        "Choose an app, inspect its current targets, then explicitly activate and act. Accessibility permission is separate from screen capture. Secure fields stay protected."
      ).font(.callout).foregroundStyle(.secondary)
      HStack {
        Picker("App", selection: $controller.selectedPID) {
          Text("Choose an app").tag(nil as pid_t?)
          ForEach(controller.applications) { app in Text(app.name).tag(Optional(app.pid)) }
        }.frame(maxWidth: 340)
        Button("Refresh apps") { controller.refreshApplications() }
        Button("Collect once") { controller.collect() }.disabled(
          controller.busy || controller.selectedPID == nil)
        Button("Stop") { controller.stop() }.keyboardShortcut(.escape, modifiers: [])
      }
      if let snapshot = controller.snapshot {
        Text(
          "PID \(snapshot.pid) · revision \(snapshot.revision.uuidString.prefix(8)) · AX global points · \(snapshot.windowTitle)"
        ).font(.caption).foregroundStyle(.secondary)
        List(selection: $controller.selectedRef) {
          ForEach(snapshot.targets) { target in
            VStack(alignment: .leading, spacing: 3) {
              Text(target.label.isEmpty ? target.role : target.label).lineLimit(1)
              Text(
                "\(target.role) · \(target.secure ? "protected" : target.value) · (\(Int(target.x)), \(Int(target.y)))"
              ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.tag(target.id)
          }
        }.frame(minHeight: 160, maxHeight: 240)
        HStack {
          Button("Activate app & press selected") { controller.perform("press") }.disabled(
            controller.busy || controller.selectedTarget?.canPress != true)
          TextField("Text to write in selected field", text: $controller.text)
          Button("Activate app & write text") { controller.perform("type") }.disabled(
            controller.busy || controller.selectedTarget?.canType != true)
        }
        TextField(
          "Expected new window title contains (optional for press)", text: $controller.expectedTitle
        )
      }
      Text(controller.status).font(.callout).textSelection(.enabled).accessibilityLabel(
        "Desktop action status: \(controller.status)")
      Divider()
      Text("Observed tutorial").font(.headline)
      Text(
        "Record your steps and expected results. Actions remain manual unless you explicitly press an action button above. Steps advance only after fresh AX evidence matches."
      ).font(.caption).foregroundStyle(.secondary)
      TextField("Instruction for this step", text: $controller.instruction)
      TextField(
        "Expected selected field value (optional if a title is expected)",
        text: $controller.expectedValue)
      HStack {
        Button("Add step") { controller.addStep() }
        Text("\(controller.verifiedSteps) / \(controller.steps.count) observed").foregroundStyle(
          .secondary)
        Button("Observe & verify next step") { controller.verifyNext() }.disabled(
          controller.busy || controller.verifiedSteps >= controller.steps.count)
        Button("Clear tutorial") {
          controller.steps = []
          controller.verifiedSteps = 0
        }
      }
      if controller.steps.indices.contains(controller.verifiedSteps) {
        Text("Next: \(controller.steps[controller.verifiedSteps].instruction)").font(.callout)
      }
    }.padding(20).onChange(of: controller.selectedPID) { _, _ in
      controller.stop()
      controller.snapshot = nil
      controller.selectedRef = nil
      controller.steps = []
      controller.verifiedSteps = 0
    }.onDisappear { controller.stop() }
  }
}
