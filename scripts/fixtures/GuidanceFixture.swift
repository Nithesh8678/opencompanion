import AppKit

/// Public in-memory practice UI for screen-guidance acceptance. This executable
/// has no account, file, network, persistence, or automation integration.
@MainActor private final class FixturePage: NSView {
  private var settingsVisible = false
  private let heading = NSTextField(labelWithString: "Practice Project")
  private let descriptionLabel = NSTextField(
    wrappingLabelWithString:
      "A public practice screen for guided clicks. Open the table settings to continue.")
  private let openButton = NSButton(title: "Open table settings", target: nil, action: nil)
  private let nameLabel = NSTextField(labelWithString: "Table name")
  private let nameField = NSTextField(string: "")
  private let protection = NSButton(checkboxWithTitle: "Protect data", target: nil, action: nil)
  private let backButton = NSButton(title: "Back", target: nil, action: nil)
  private let closeButton = NSButton(title: "Close fixture", target: nil, action: nil)
  private let footer = NSTextField(
    labelWithString:
      "Guidance Fixture · Public test content · Everything stays in memory")

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor(srgbRed: 0.065, green: 0.075, blue: 0.095, alpha: 1).cgColor
    heading.font = .systemFont(ofSize: 36, weight: .semibold)
    heading.textColor = .white
    heading.setAccessibilityIdentifier("fixture.heading")
    descriptionLabel.font = .systemFont(ofSize: 15)
    descriptionLabel.textColor = NSColor(white: 0.73, alpha: 1)
    descriptionLabel.maximumNumberOfLines = 3
    nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
    nameLabel.textColor = .white
    nameField.font = .systemFont(ofSize: 17)
    nameField.placeholderString = "Enter a table name"
    nameField.setAccessibilityLabel("Table name")
    nameField.setAccessibilityIdentifier("fixture.tableName")
    protection.state = .on
    protection.font = .systemFont(ofSize: 16)
    protection.contentTintColor = .white
    protection.setAccessibilityIdentifier("fixture.protectData")
    openButton.target = self
    openButton.action = #selector(openSettings)
    openButton.setAccessibilityIdentifier("fixture.openTableSettings")
    openButton.setAccessibilityLabel("Open table settings")
    openButton.font = .systemFont(ofSize: 17, weight: .semibold)
    openButton.bezelStyle = .rounded
    openButton.controlSize = .large
    openButton.bezelColor = .systemBlue
    openButton.contentTintColor = .white
    backButton.target = self
    backButton.action = #selector(goBack)
    backButton.setAccessibilityIdentifier("fixture.back")
    closeButton.target = self
    closeButton.action = #selector(closeFixture)
    closeButton.setAccessibilityIdentifier("fixture.close")
    footer.font = .systemFont(ofSize: 12)
    footer.textColor = NSColor(white: 0.48, alpha: 1)
    for view in [
      heading, descriptionLabel, openButton, nameLabel, nameField, protection,
      backButton, closeButton, footer,
    ] {
      addSubview(view)
    }
    refreshPage()
  }

  required init?(coder: NSCoder) { return nil }

  override func layout() {
    super.layout()
    let contentWidth = min(620, max(240, bounds.width - 96))
    let center = CGPoint(x: bounds.width * 0.4, y: bounds.height * 0.45)
    let left = max(32, center.x - contentWidth / 2)
    heading.frame = CGRect(x: left, y: center.y - 146, width: contentWidth, height: 48)
    descriptionLabel.frame = CGRect(x: left, y: center.y - 86, width: contentWidth, height: 54)
    openButton.frame = CGRect(x: center.x - 132, y: center.y - 25, width: 264, height: 50)
    nameLabel.frame = CGRect(x: left, y: center.y - 16, width: contentWidth, height: 26)
    nameField.frame = CGRect(x: left, y: center.y + 20, width: min(contentWidth, 420), height: 34)
    protection.frame = CGRect(x: left, y: center.y + 75, width: 240, height: 30)
    backButton.frame = CGRect(x: left, y: center.y + 135, width: 110, height: 34)
    closeButton.frame = CGRect(
      x: bounds.width - 180, y: bounds.height - 72, width: 140, height: 34)
    footer.frame = CGRect(
      x: 40, y: bounds.height - 64, width: max(0, bounds.width - 250), height: 24)
  }

  private func refreshPage() {
    heading.stringValue = settingsVisible ? "Table settings" : "Practice Project"
    descriptionLabel.stringValue =
      settingsVisible
      ? "Name your practice table and choose whether to protect its data. This form is only a test."
      : "A public practice screen for guided clicks. Open the table settings to continue."
    openButton.isHidden = settingsVisible
    for view in [nameLabel, nameField, protection, backButton] { view.isHidden = !settingsVisible }
    needsLayout = true
  }

  @objc private func openSettings() {
    settingsVisible = true
    refreshPage()
  }
  @objc private func goBack() {
    settingsVisible = false
    refreshPage()
  }
  @objc private func closeFixture() { NSApplication.shared.terminate(nil) }
}

@MainActor private final class FixtureWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor private final class FixtureDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let screen = NSScreen.main else {
      NSApplication.shared.terminate(nil)
      return
    }
    let window = FixtureWindow(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.title = "Guidance Fixture"
    window.setAccessibilityLabel("Guidance Fixture public practice screen")
    window.isOpaque = true
    window.backgroundColor = NSColor(srgbRed: 0.065, green: 0.075, blue: 0.095, alpha: 1)
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.contentView = FixturePage(frame: CGRect(origin: .zero, size: screen.frame.size))
    window.makeKeyAndOrderFront(nil)
    self.window = window
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main @MainActor private enum GuidanceFixture {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let applicationMenu = NSMenu()
    applicationMenu.addItem(
      withTitle: "Quit Guidance Fixture", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let item = NSMenuItem()
    item.submenu = applicationMenu
    menu.addItem(item)
    app.mainMenu = menu
    let delegate = FixtureDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
