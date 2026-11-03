import AppKit
import Carbon
import Combine
import CompanionStore
import SwiftUI

@main enum OpenCompanionApplication {
  @MainActor static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel!
  private var shell: CompanionShell?
  private var utilityWindow: NSWindow?
  private let hotkey = HotkeyService()
  private let stopHotkey = HotkeyService()
  private var stateSubscription: AnyCancellable?
  private var stopKeyRegistered = false
  private var statusItem: NSStatusItem?
  private var localKeys: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApp.appearance = NSAppearance(named: .aqua)
    model = AppModel()
    model.onOpen = { [weak self] in self?.showWorkspace() }
    installMenus()
    if CommandLine.arguments.contains("--keychain-acceptance") {
      let service = "org.opencompanion.acceptance.\(UUID().uuidString)"
      let credentials = CredentialStore()
      do {
        defer { try? credentials.delete(service: service, account: "fixture") }
        let value = Data("public acceptance fixture".utf8)
        try credentials.save(value, service: service, account: "fixture")
        guard try credentials.load(service: service, account: "fixture") == value else {
          throw ProviderError.message("Keychain roundtrip mismatch")
        }
        print("KEYCHAIN_ACCEPTANCE_PASSED")
      } catch {
        print("KEYCHAIN_ACCEPTANCE_FAILED: \(error.localizedDescription)")
        exit(1)
      }
      NSApp.terminate(nil)
      return
    }
    if CommandLine.arguments.contains("--smoke-test-codex") {
      Task {
        do {
          try await CodexIntegrationSmoke.run(
            executable: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
              ".local/bin/codex"
            ).path
          ) { text in
            try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
          }
          print("CODEX_ACCEPTANCE_PASSED")
        } catch {
          print("CODEX_ACCEPTANCE_FAILED: \(error.localizedDescription)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
      return
    }
    shell = CompanionShell(model: model, onOpenWorkspace: { [weak self] in self?.showWorkspace() })
    shell?.show(anchor: .notch)
    hotkey.register { [weak self] in
      self?.model.record("hotkey.keyDown")
      self?.shell?.toggle()
      self?.model.record("hotkey.companionRequested")
    }
    stateSubscription = model.$busy.combineLatest(model.$listening, model.$state).sink {
      [weak self] busy, listening, state in
      MainActor.assumeIsolated {
        guard let self else { return }
        let active = busy || listening || state == "Speaking" || state == "Observing"
        guard active != self.stopKeyRegistered else { return }
        self.stopKeyRegistered = active
        if active {
          self.stopHotkey.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
            self?.model.stop()
            self?.shell?.collapse()
          }
        } else {
          self.stopHotkey.unregister()
        }
      }
    }
    localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let consume = MainActor.assumeIsolated {
        if event.keyCode == 53 {
          self?.model.stop()
          self?.shell?.collapse()
          return true
        }
        return false
      }
      return consume ? nil : event
    }
    if CommandLine.arguments.contains("--render-acceptance") {
      Task { @MainActor in
        do {
          let path =
            CommandLine.arguments.drop(while: { $0 != "--render-acceptance" }).dropFirst().first
            ?? "/tmp/OpenCompanion-Acceptance"
          let output = URL(fileURLWithPath: path)
          try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
          try? await Task.sleep(for: .milliseconds(400))
          try shell?.exportSnapshot(to: output.appendingPathComponent("notch-collapsed.png"))
          if let geometry = shell?.geometry {
            try JSONEncoder().encode(geometry).write(
              to: output.appendingPathComponent("notch-geometry.json"))
          }
          shell?.toggle()
          try? await Task.sleep(for: .milliseconds(500))
          try shell?.exportSnapshot(to: output.appendingPathComponent("notch-expanded.png"))
          shell?.collapse()
          showWorkspace()
          try? await Task.sleep(for: .milliseconds(500))
          try RenderAcceptance.run()
          print("RENDER_ACCEPTANCE_PASSED")
        } catch {
          print("RENDER_ACCEPTANCE_FAILED: \(error)")
          exit(1)
        }
        NSApp.terminate(nil)
      }
    }
  }

  private func installMenus() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: "Open companion", action: #selector(toggleCompanion), keyEquivalent: ""
    ).target = self
    appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
      .target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit OpenCompanion", action: #selector(quit), keyEquivalent: "q")
      .target = self
    let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    main.addItem(edit)
    let editMenu = NSMenu(title: "Edit")
    edit.submenu = editMenu
    for (title, action, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
    NSApp.mainMenu = main
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    status.button?.image = NSImage(
      systemSymbolName: "sparkle", accessibilityDescription: "OpenCompanion")
    let menu = NSMenu()
    menu.addItem(withTitle: "Open companion", action: #selector(toggleCompanion), keyEquivalent: "")
      .target = self
    menu.addItem(
      withTitle: "Notebook & library", action: #selector(openWorkspace), keyEquivalent: ""
    ).target = self
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Stop", action: #selector(stop), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "").target = self
    status.menu = menu
    statusItem = status
  }

  func showWorkspace() {
    if utilityWindow == nil {
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 1220, height: 820),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = "OpenCompanion"
      window.isReleasedWhenClosed = false
      window.minSize = CGSize(width: 1000, height: 680)
      window.contentView = NSHostingView(
        rootView: WorkspaceView(model: model).preferredColorScheme(.light))
      window.center()
      utilityWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    utilityWindow?.makeKeyAndOrderFront(nil)
  }
  @objc private func toggleCompanion() { shell?.toggle() }
  @objc private func openWorkspace() { showWorkspace() }
  @objc private func openSettings() {
    model.section = "Settings"
    showWorkspace()
  }
  @objc private func stop() { model.stop() }
  @objc private func quit() { NSApp.terminate(nil) }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    shell?.toggle()
    return false
  }
  func applicationWillTerminate(_ notification: Notification) {
    model.stop()
    model.runner.stop()
    model.browser.stop()
    hotkey.unregister()
    stopHotkey.unregister()
    if let localKeys { NSEvent.removeMonitor(localKeys) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
