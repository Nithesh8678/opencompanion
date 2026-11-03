import AVFoundation
import AppKit
import ApplicationServices
import Speech
import SwiftUI

/// Settings share the companion's attached surface and the full-window host.
/// Provider saves continue through AppModel's existing Keychain-backed path.
@MainActor struct CompanionSettingsView: View {
  @ObservedObject var model: AppModel
  var openDestination: ((String) -> Void)? = nil
  @State private var selection = CompanionSettingsPage.general
  @State private var shortcuts = ShortcutPreferences.load()
  @State private var feedback: String?
  @State private var feedbackIsError = false
  @State private var permissions = CompanionPermissionSnapshot.current()
  @AppStorage("speechLocale") private var speechLocale = "en-US"

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 7) {
            Text(selection.rawValue)
              .font(.system(size: 23, weight: .semibold, design: .rounded))
              .accessibilityAddTraits(.isHeader)
            Text(selection.detail)
              .font(.system(size: 12, design: .rounded))
              .foregroundStyle(SettingsColors.secondary)
          }
          pageContent
          if let feedback {
            Label(
              feedback, systemImage: feedbackIsError ? "exclamationmark.circle" : "checkmark.circle"
            )
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(feedbackIsError ? Color.orange : SettingsColors.secondary)
            .textSelection(.enabled)
            .accessibilityIdentifier("companion.settings.feedback")
          }
        }
        .frame(maxWidth: 650, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(26)
      }
      .scrollIndicators(.automatic)
      .accessibilityIdentifier("companion.settings.content")
    }
    .font(.system(size: 13, design: .rounded))
    .foregroundStyle(SettingsColors.text)
    .background(SettingsColors.background)
    .tint(SettingsColors.accent)
    .preferredColorScheme(.dark)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      permissions = .current()
    }
    .onReceive(NotificationCenter.default.publisher(for: .shortcutPreferencesDidChange)) { _ in
      shortcuts = .load()
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Preferences")
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(SettingsColors.secondary)
        .padding(.horizontal, 12).padding(.bottom, 10)
      ForEach(CompanionSettingsPage.allCases) { page in
        if page == .providers || page == .privacy {
          Divider().overlay(.white.opacity(0.04)).padding(.vertical, 9)
        }
        Button {
          selection = page
          feedback = nil
          permissions = .current()
        } label: {
          HStack(spacing: 10) {
            Image(systemName: page.symbol).font(.system(size: 13)).frame(width: 17)
              .foregroundStyle(selection == page ? SettingsColors.text : SettingsColors.secondary)
            Text(page.rawValue).font(
              .system(
                size: 12, weight: selection == page ? .semibold : .regular,
                design: .rounded))
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12).padding(.vertical, 10)
          .background(
            selection == page ? Color.white.opacity(0.09) : .clear,
            in: RoundedRectangle(cornerRadius: 9)
          )
          .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.settings.page.\(page.id)")
        .accessibilityAddTraits(selection == page ? .isSelected : [])
      }
      Spacer(minLength: 22)
      VStack(alignment: .leading, spacing: 4) {
        Text("OpenCompanion").foregroundStyle(SettingsColors.text.opacity(0.8))
        Text(versionDescription).foregroundStyle(SettingsColors.secondary)
      }
      .font(.system(size: 10, design: .rounded))
      .padding(.horizontal, 12).padding(.bottom, 4)
    }
    .padding(.horizontal, 12).padding(.vertical, 24)
    .frame(width: 180, alignment: .leading)
    .background(SettingsColors.sidebar)
  }

  @ViewBuilder private var pageContent: some View {
    switch selection {
    case .general: general
    case .voice: voice
    case .shortcuts: shortcutSettings
    case .providers: providers
    case .connections: connections
    case .privacy: privacy
    }
  }

  private var general: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsGroup("Companion") {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("At home in your notch").fontWeight(.medium)
            detail("Open a conversation without leaving the app you are using.")
          }
          Spacer(minLength: 12)
          Button("Show companion", action: model.showBadge)
            .accessibilityIdentifier("companion.settings.showCompanion")
        }
        rowDivider
        HStack {
          Text("Current activity")
          Spacer()
          Text(model.state).foregroundStyle(SettingsColors.secondary)
        }
      }
      settingsGroup("Screen context") {
        Text("Capture display").fontWeight(.medium)
        Picker(
          "Capture display",
          selection: Binding(
            get: { model.selectedDisplay ?? 0 },
            set: { model.selectedDisplay = $0 == 0 ? nil : $0 }
          )
        ) {
          Text("First available display").tag(UInt32(0))
          ForEach(NSScreen.screens, id: \.self) { screen in
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
              as? NSNumber
            {
              Text(screen.localizedName).tag(number.uint32Value)
            }
          }
        }
        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("companion.settings.captureDisplay")
        detail(
          "Add screen chooses a frame from this display for your next question. You can also select a window or region from the conversation."
        )
      }
      settingsGroup("About") {
        HStack {
          Text("OpenCompanion")
          Spacer()
          Text(versionDescription).foregroundStyle(SettingsColors.secondary)
        }
        detail("An independent, open-source companion for your Mac.")
        Link(
          "Source and feature status",
          destination: URL(string: "https://github.com/Nithesh8678/opencompanion")!)
      }
    }
  }

  private var voice: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsGroup("Spoken answers") {
        Toggle(isOn: $model.configuration.speechEnabled) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Read answers aloud").fontWeight(.medium)
            detail("Applies to typed questions. Hold-to-talk always answers aloud.")
          }
        }
        .toggleStyle(.switch).controlSize(.small)
        .accessibilityIdentifier("companion.settings.readAloud")
        HStack {
          Button("Save voice preference") {
            model.configuration.save()
            feedbackIsError = false
            feedback = "Voice preference saved."
          }
          Spacer()
          Button("Stop response", action: model.stop)
            .disabled(!model.busy && !model.listening && model.state != "Speaking")
        }
      }
      settingsGroup("Speech recognition") {
        Text("Recognition language").fontWeight(.medium)
        Picker("Recognition language", selection: $speechLocale) {
          if !Self.recognitionLocales.contains(where: { $0.identifier == speechLocale }) {
            Text("Unavailable: \(speechLocale)").tag(speechLocale)
          }
          ForEach(Self.recognitionLocales, id: \.identifier) { locale in
            Text(
              Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            )
            .tag(locale.identifier)
          }
        }
        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("companion.settings.speechLocale")
        detail(
          "Saved automatically for your next recording. Apple Speech runs on-device when available; otherwise Apple may process audio."
        )
      }
      settingsGroup("Talk your way") {
        instruction(
          "Hold Control + Option",
          detail: "Speak while held, then release either key to send and hear a reply.",
          symbol: "waveform")
        rowDivider
        instruction(
          "Talk button",
          detail: "Record a transcript, review it in the composer, then send when ready.",
          symbol: "mic")
        rowDivider
        instruction("Escape", detail: "Stop the current recording or response.", symbol: "escape")
        Label(
          model.voiceShortcutStatus,
          systemImage: model.voiceShortcutAvailable ? "checkmark.circle" : "info.circle"
        )
        .font(.system(size: 11, design: .rounded)).foregroundStyle(SettingsColors.secondary)
        .textSelection(.enabled)
      }
    }
  }

  private var shortcutSettings: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsGroup("Voice shortcut") {
        Toggle("Hold Control + Option to talk", isOn: $shortcuts.voiceHoldEnabled)
          .toggleStyle(.switch).controlSize(.small)
          .accessibilityIdentifier("settings.shortcuts.voiceHold")
        detail(
          "Release either modifier to send. Another key, Command, Shift or Fn cancels the hold. If this conflicts with VoiceOver, turn it off here."
        )
        Label(
          model.voiceShortcutStatus,
          systemImage: model.voiceShortcutAvailable ? "checkmark.circle" : "keyboard"
        )
        .font(.system(size: 11, design: .rounded)).foregroundStyle(SettingsColors.secondary)
        .textSelection(.enabled)
        HStack {
          Button("Allow global shortcut…") {
            _ = VoiceShortcutMonitor.requestListenPermission()
            permissions = .current()
          }
          Button("Input Monitoring settings") { openPrivacy("Privacy_ListenEvent") }
        }
      }
      settingsGroup("Keyboard shortcuts") {
        shortcutEditor("Open companion for text", shortcut: $shortcuts.openShortcut)
        rowDivider
        Toggle("Enable a screen capture shortcut", isOn: $shortcuts.captureEnabled)
          .toggleStyle(.switch).controlSize(.small)
        if shortcuts.captureEnabled {
          shortcutEditor("Capture selected display", shortcut: $shortcuts.captureShortcut)
          detail("Adds one screen frame to your next question.")
        }
      }
      HStack {
        Button("Save shortcuts", action: saveShortcuts)
          .buttonStyle(.borderedProminent).accessibilityIdentifier(
            "companion.settings.saveShortcuts")
        Button("Reset defaults") {
          shortcuts = .defaults
          feedbackIsError = false
          feedback = "Defaults selected. Save shortcuts to apply them."
        }
      }
      detail(
        "If a shortcut is already in use, the last working shortcut remains available for this session. The companion reports registration conflicts."
      )
    }
  }

  private var providers: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsGroup("Connection") {
        Picker("Reasoning provider", selection: $model.providerMode) {
          Text("ChatGPT via Codex").tag("ChatGPT via Codex")
          Text("API key or self-hosted").tag("API key or self-hosted")
        }
        .pickerStyle(.menu).accessibilityIdentifier("companion.settings.providerMode")
        rowDivider
        if model.providerMode == "ChatGPT via Codex" {
          settingsField("Codex executable") {
            TextField("Path to Codex", text: $model.codexPath)
              .accessibilityIdentifier("companion.settings.codexPath")
          }
          settingsField("Model") {
            TextField("Use Codex default", text: $model.codexModel)
              .accessibilityIdentifier("companion.settings.codexModel")
          }
          detail(
            "Uses your installed Codex CLI and its ChatGPT sign-in. Run codex login in Terminal to sign in. OpenCompanion does not read or copy login tokens."
          )
        } else {
          settingsField("API base URL") {
            TextField("https://api.openai.com/v1", text: $model.configuration.endpoint)
              .accessibilityIdentifier("companion.settings.apiEndpoint")
          }
          settingsField("Model ID") {
            TextField("Provider model ID", text: $model.configuration.model)
              .accessibilityIdentifier("companion.settings.apiModel")
          }
          settingsField("API key or relay token") {
            SecureField("Stored in macOS Keychain", text: $model.apiKey)
              .accessibilityIdentifier("companion.settings.apiCredential")
          }
          detail(
            "Use an HTTPS endpoint, or HTTP on localhost for a local server. API access is separate from a ChatGPT plan. Saving an empty key removes the credential for this endpoint."
          )
        }
      }
      HStack {
        Button("Save settings", action: saveProviderSettings)
          .buttonStyle(.borderedProminent).accessibilityIdentifier(
            "companion.settings.saveProvider")
        Button("Test live connection", action: model.testConnection)
          .disabled(model.connectionStatus == "Testing a live request…")
          .accessibilityIdentifier("companion.settings.testProvider")
      }
      Text(model.connectionStatus)
        .font(.system(size: 12, design: .rounded)).foregroundStyle(SettingsColors.secondary)
        .textSelection(.enabled).accessibilityIdentifier("companion.settings.connectionStatus")
      detail("The connection test sends a short request to your selected provider.")
    }
  }

  private var connections: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsGroup("Browser") {
        CompanionBrowserSettings(browser: model.browser)
      }
      settingsGroup("Tools and desktop") {
        instruction(
          "Connect your tools",
          detail:
            "Configure an MCP server, discover its actual tools, and review arguments before calling one.",
          symbol: "point.3.connected.trianglepath.dotted")
        rowDivider
        instruction(
          "Desktop actions",
          detail:
            "Inspect an app's current targets before explicitly activating or acting on them.",
          symbol: "macwindow")
        Button("Open connection tools") { openWorkspace("Connections") }
          .accessibilityIdentifier("companion.settings.openConnections")
      }
    }
  }

  private var privacy: some View {
    VStack(alignment: .leading, spacing: 18) {
      settingsGroup("macOS permissions") {
        permissionRow(
          "Microphone", status: permissions.microphone, granted: permissions.microphoneAllowed,
          explanation: "Used when you start voice input."
        ) { openPrivacy("Privacy_Microphone") }
        rowDivider
        permissionRow(
          "Speech Recognition", status: permissions.speech, granted: permissions.speechAllowed,
          explanation: "Turns your speech into a transcript."
        ) { openPrivacy("Privacy_SpeechRecognition") }
        rowDivider
        permissionRow(
          "Screen Recording", status: permissions.screen ? "Allowed" : "Needs permission",
          granted: permissions.screen, explanation: "Used when you choose to add screen context.",
          buttonTitle: permissions.screen ? "Settings…" : "Request…"
        ) {
          if permissions.screen {
            openPrivacy("Privacy_ScreenCapture")
          } else {
            _ = CGRequestScreenCaptureAccess()
            permissions = .current()
          }
        }
        rowDivider
        permissionRow(
          "Accessibility", status: permissions.accessibility ? "Allowed" : "Optional",
          granted: permissions.accessibility,
          explanation: "Adds app context and enables explicit desktop actions.",
          buttonTitle: permissions.accessibility ? "Settings…" : "Request…"
        ) {
          if permissions.accessibility {
            openPrivacy("Privacy_Accessibility")
          } else {
            AccessibilityService.requestPermission()
            permissions = .current()
          }
        }
        rowDivider
        permissionRow(
          "Input Monitoring", status: permissions.input ? "Allowed" : "Needs permission",
          granted: permissions.input, explanation: "Enables the global hold-to-talk shortcut."
        ) {
          openPrivacy("Privacy_ListenEvent")
        }
        Button("Refresh permission status") { permissions = .current() }
        detail(
          "Text and notebooks remain available when permissions are denied. macOS may ask you to restart after changing access."
        )
      }
      settingsGroup("Memory and local data") {
        HStack {
          Text("Saved memories")
          Spacer()
          Text("\(model.records.filter { $0.kind == "memory" }.count)")
            .foregroundStyle(SettingsColors.secondary)
        }
        detail(
          "Memories stay in your local library. Select one explicitly to include it in a question.")
        HStack {
          Button("Manage memories") { openWorkspace("Memory") }
          Button("Export library", action: model.exportLibrary).disabled(model.store == nil)
        }
        rowDivider
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("Selected context")
            detail(model.contextTitle.isEmpty ? "Nothing selected" : model.contextTitle)
          }
          Spacer(minLength: 10)
          Button("Clear", action: model.clearContext)
            .disabled(
              model.contextTitle.isEmpty && model.selectedContext.isEmpty && model.evidence == nil)
        }
        detail(
          "Screen frames stay in memory. Provider credentials stay in macOS Keychain. Your library is in ~/Library/Application Support/OpenCompanion."
        )
      }
      settingsGroup("Diagnostics") {
        detail("Export host timing events without prompts or credentials.")
        Button("Export diagnostics", action: model.exportDiagnostics)
      }
    }
  }

  private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(SettingsColors.secondary).accessibilityAddTraits(.isHeader)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
    .background(SettingsColors.inset, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.045)))
  }

  private var rowDivider: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }

  private func detail(_ text: String) -> some View {
    Text(text).font(.system(size: 11, design: .rounded))
      .foregroundStyle(SettingsColors.secondary).fixedSize(horizontal: false, vertical: true)
  }

  private func instruction(_ title: String, detail text: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(SettingsColors.secondary)
        .frame(width: 20).padding(.top, 2)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).fontWeight(.medium)
        detail(text)
      }
    }
  }

  private func settingsField<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.system(size: 12, weight: .medium, design: .rounded))
      content().textFieldStyle(.roundedBorder)
    }
  }

  private func shortcutEditor(_ title: String, shortcut: Binding<GlobalShortcut>) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(title).fontWeight(.medium)
        Spacer(minLength: 8)
        Text(shortcut.wrappedValue.displayName).foregroundStyle(SettingsColors.secondary)
        Picker("\(title) key", selection: shortcut.key) {
          ForEach(ShortcutKey.allCases) { Text($0.rawValue).tag($0) }
        }.labelsHidden().frame(width: 74)
      }
      HStack(spacing: 12) {
        modifier("Command", .command, shortcut: shortcut)
        modifier("Shift", .shift, shortcut: shortcut)
        modifier("Option", .option, shortcut: shortcut)
        modifier("Control", .control, shortcut: shortcut)
      }.toggleStyle(.checkbox).font(.system(size: 11, design: .rounded))
    }
  }

  private func modifier(
    _ title: String, _ modifier: ShortcutModifiers, shortcut: Binding<GlobalShortcut>
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

  private func permissionRow(
    _ title: String, status: String, granted: Bool, explanation: String,
    buttonTitle: String = "Settings…",
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).fontWeight(.medium)
        detail(explanation)
        Label(status, systemImage: granted ? "checkmark.circle" : "circle")
          .font(.system(size: 10, design: .rounded)).foregroundStyle(SettingsColors.secondary)
      }
      Spacer(minLength: 8)
      Button(buttonTitle, action: action)
        .accessibilityLabel("\(title) permission settings")
    }
  }

  private func saveProviderSettings() {
    model.error = nil
    model.saveSettings()
    feedbackIsError = model.error != nil
    feedback = model.error ?? model.notice
  }

  private func saveShortcuts() {
    do {
      try shortcuts.save()
      feedbackIsError = false
      feedback = "Shortcuts saved. \(model.voiceShortcutStatus)"
    } catch {
      feedbackIsError = true
      feedback = error.localizedDescription
    }
  }

  private func openWorkspace(_ section: String) {
    if let openDestination {
      openDestination(section)
      return
    }
    model.section = section
    model.onOpen?()
  }

  private func openPrivacy(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }

  private var versionDescription: String {
    guard
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    else {
      return "Development build"
    }
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
  }

  private static let recognitionLocales = SFSpeechRecognizer.supportedLocales().sorted {
    (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
      .localizedStandardCompare(
        Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
      == .orderedAscending
  }
}

private enum CompanionSettingsPage: String, CaseIterable, Identifiable {
  case general = "General"
  case voice = "Voice"
  case shortcuts = "Shortcuts"
  case providers = "Providers"
  case connections = "Connections"
  case privacy = "Privacy & memory"
  var id: String {
    switch self {
    case .general: "general"
    case .voice: "voice"
    case .shortcuts: "shortcuts"
    case .providers: "providers"
    case .connections: "connections"
    case .privacy: "privacy"
    }
  }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .voice: "waveform"
    case .shortcuts: "command"
    case .providers: "sparkles"
    case .connections: "point.3.connected.trianglepath.dotted"
    case .privacy: "hand.raised"
    }
  }
  var detail: String {
    switch self {
    case .general: "Your companion and screen preferences."
    case .voice: "How you speak to OpenCompanion and hear its replies."
    case .shortcuts: "Make room for the shortcuts you already use."
    case .providers: "Choose what powers your conversations."
    case .connections: "Connect the browser and tools you choose."
    case .privacy: "Choose access, manage memory, and keep your data close."
    }
  }
}

private enum SettingsColors {
  static let background = Color(white: 0.105)
  static let sidebar = Color(white: 0.105)
  static let inset = Color(white: 0.14)
  static let text = Color(white: 0.95)
  static let secondary = Color(white: 0.61)
  static let accent = Color(red: 0.65, green: 0.81, blue: 0.96)
}

private struct CompanionPermissionSnapshot {
  let microphone: String
  let microphoneAllowed: Bool
  let speech: String
  let speechAllowed: Bool
  let screen: Bool
  let accessibility: Bool
  let input: Bool

  static func current() -> Self {
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let speechStatus = SFSpeechRecognizer.authorizationStatus()
    let microphone: String =
      switch microphoneStatus {
      case .authorized: "Allowed"
      case .notDetermined: "Requested when you start voice input"
      case .denied: "Not allowed"
      case .restricted: "Restricted by macOS"
      @unknown default: "Unknown"
      }
    let speech: String =
      switch speechStatus {
      case .authorized: "Allowed"
      case .notDetermined: "Requested when you start voice input"
      case .denied: "Not allowed"
      case .restricted: "Restricted by macOS"
      @unknown default: "Unknown"
      }
    return Self(
      microphone: microphone, microphoneAllowed: microphoneStatus == .authorized,
      speech: speech, speechAllowed: speechStatus == .authorized,
      screen: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted(),
      input: CGPreflightListenEventAccess())
  }
}

@MainActor private struct CompanionBrowserSettings: View {
  @ObservedObject var browser: BrowserBridge
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(browser.status, systemImage: browser.running ? "checkmark.circle" : "circle")
        .font(.system(size: 12, weight: .medium, design: .rounded)).textSelection(.enabled)
      Text(
        "Start the bridge, then connect a tab from the OpenCompanion extension. Only tabs you connect are available."
      )
      .font(.system(size: 11, design: .rounded)).foregroundStyle(SettingsColors.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(browser.running ? "Stop bridge" : "Start bridge") {
          if browser.running { browser.stop() } else { browser.start() }
        }
        Link(
          "Extension guide",
          destination: URL(
            string: "https://github.com/Nithesh8678/opencompanion/blob/main/docs/BROWSER.md")!)
      }
      if browser.running {
        Text("\(browser.tabs.count) connected \(browser.tabs.count == 1 ? "tab" : "tabs")")
          .font(.system(size: 11, design: .rounded)).foregroundStyle(SettingsColors.secondary)
      }
    }
  }
}
