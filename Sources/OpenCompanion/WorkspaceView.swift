import AppKit
import ApplicationServices
import CompanionCore
import CompanionStore
import SwiftUI

private let ink = Color(red: 0.13, green: 0.22, blue: 0.37)
private let blue = Color(red: 0.17, green: 0.36, blue: 0.72)
struct WorkspaceView: View {
  @ObservedObject var model: AppModel
  @State private var editingMemory: StoredRecord?
  var notebookOnly = false
  var body: some View {
    Group {
      if notebookOnly {
        VStack(spacing: 0) {
          if let error = model.error { banner(error, isError: true) }
          if let notice = model.notice { banner(notice, isError: false) }
          notebook
        }
      } else {
        workspace
      }
    }.frame(minWidth: notebookOnly ? 760 : 1000, minHeight: notebookOnly ? 580 : 680)
      .background(Color(nsColor: .windowBackgroundColor)).tint(blue)
  }
  private var workspace: some View {
    HStack(spacing: 0) {
      sidebar
      VStack(spacing: 0) {
        HStack {
          Text(model.section).font(.system(size: 15, weight: .semibold))
          Spacer()
          Circle().fill(model.busy || model.listening ? .blue : .green).frame(width: 6, height: 6)
          Text(model.state).font(.system(size: 12)).foregroundStyle(.secondary)
          Button {
            model.stop()
          } label: {
            Image(systemName: "stop.circle")
          }.help("Stop all current output (Escape)").keyboardShortcut(.escape, modifiers: [])
        }.padding(.horizontal, 25).frame(height: 52)
        Divider()
        if let error = model.error { banner(error, isError: true) }
        if let notice = model.notice { banner(notice, isError: false) }
        Group {
          switch model.section {
          case "Notebook":
            ContentUnavailableView {
              Label("Your notebook is in its own panel", systemImage: "pencil.and.outline")
            } description: {
              Text("Keep the explanation beside your work while you talk from the notch.")
            } actions: {
              Button("Open notebook") { model.onOpen?() }
            }
          case "Library": library
          case "Memory": memory
          case "Jobs": jobs
          case "Connections": ConnectionsView(model: model)
          case "Settings": settings
          default: companion
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(Color(nsColor: .windowBackgroundColor))
    }.frame(minWidth: 1000, minHeight: 680).tint(blue)
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "sparkle").font(.system(size: 25, weight: .medium)).foregroundStyle(blue)
        Text("OpenCompanion").font(.system(size: 14, weight: .semibold)).fixedSize()
          .foregroundStyle(ink)
      }.padding(.vertical, 23).padding(.horizontal, 17)
      ForEach(
        [
          ("Companion", "bubble.left.and.text.bubble.right"), ("Notebook", "pencil.and.outline"),
          ("Library", "books.vertical"), ("Memory", "bookmark"), ("Jobs", "clock.arrow.circlepath"),
          ("Connections", "point.3.connected.trianglepath.dotted"),
          ("Settings", "slider.horizontal.3"),
        ], id: \.0
      ) { name, icon in
        Button {
          model.section = name
          if name == "Notebook" { model.onOpen?() }
          Task { await model.reload() }
        } label: {
          Label(name, systemImage: icon).font(
            .system(size: 13, weight: model.section == name ? .semibold : .regular)
          ).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(
            .vertical, 10
          ).background(
            model.section == name ? blue.opacity(0.1) : .clear,
            in: RoundedRectangle(cornerRadius: 8)
          ).foregroundStyle(model.section == name ? blue : ink.opacity(0.8))
        }.buttonStyle(.plain)
      }
      Spacer()
      VStack(alignment: .leading, spacing: 8) {
        Text("A little clarity,\nright where you are.").font(
          .system(size: 16, weight: .medium, design: .rounded)
        ).foregroundStyle(ink)
        Text("\(ShortcutPreferences.load().openShortcut.displayName) to open").font(
          .system(size: 11)
        ).foregroundStyle(.secondary)
        Text("Independent & open source").font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(15)
    }.padding(.horizontal, 10).frame(width: 210).background(
      Color(red: 0.94, green: 0.96, blue: 0.99)
    ).overlay(alignment: .trailing) { Divider() }
  }
  private func banner(_ text: String, isError: Bool) -> some View {
    HStack(alignment: .top) {
      Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
      Text(text).font(.system(size: 12)).textSelection(.enabled)
      Spacer()
      Button {
        if isError { model.error = nil } else { model.notice = nil }
      } label: {
        Image(systemName: "xmark")
      }.buttonStyle(.plain)
    }.foregroundStyle(isError ? Color.red : blue).padding(12).background(
      isError ? Color.red.opacity(0.06) : blue.opacity(0.05))
  }
  private var companion: some View {
    VStack(spacing: 0) {
      if model.messages.isEmpty {
        welcome
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 23) {
              ForEach(model.messages) { line in
                VStack(alignment: .leading, spacing: 8) {
                  Text(line.role == "user" ? "You" : "OpenCompanion").font(
                    .system(size: 11, weight: .semibold)
                  ).foregroundStyle(line.role == "user" ? .secondary : blue)
                  Text(line.text).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                }.padding(.horizontal, 28).id(line.id)
              }
              if model.busy {
                HStack {
                  ProgressView().controlSize(.small)
                  Text("Preparing the next complete thought…").foregroundStyle(.secondary).font(
                    .system(size: 12))
                }.padding(.horizontal, 28)
              }
            }.padding(.vertical, 30)
          }.onChange(of: model.messages.count) { _, _ in
            if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
      }
      composer
    }
  }
  private var welcome: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 25) {
        HStack {
          ZStack {
            Circle().fill(blue.opacity(0.07)).frame(width: 78, height: 78)
            Image(systemName: "sparkle").font(.system(size: 39, weight: .light)).foregroundStyle(
              blue)
          }
          Spacer()
          Text("Your Mac, a little more understandable.").font(.system(size: 12)).foregroundStyle(
            .secondary)
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("Make room for\na clearer thought.").font(
            .system(size: 42, weight: .medium, design: .rounded)
          ).tracking(-1.2).foregroundStyle(ink)
          Text(
            "Ask a question. Work through an idea. Bring a screen or a file\nwhen it helps, and keep the useful parts in your notebook."
          ).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
        }
        HStack(alignment: .top, spacing: 15) {
          suggestion(
            "Understand a screen", icon: "viewfinder", detail: "Choose exactly what to share"
          ) { model.observe() }
          suggestion(
            "Think in diagrams", icon: "scribble.variable", detail: "Create an editable notebook"
          ) { model.newNotebook() }
          suggestion(
            "Talk through a file", icon: "doc.text", detail: "Read the source, with context"
          ) { model.importFile() }
        }
        Divider().padding(.top, 10)
        HStack {
          Text("Try a local interactive example").font(.system(size: 12)).foregroundStyle(
            .secondary)
          Spacer()
          Text("No model call").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
          sampleButton(
            "Inside a DC motor", detail: "Magnetic force → rotation", kind: "motor",
            icon: "gearshape.2")
          sampleButton(
            "A lever in balance", detail: "Distance changes force", kind: "lever", icon: "scalemass"
          )
          sampleButton(
            "A simple circuit", detail: "Voltage, current, resistance", kind: "circuit",
            icon: "bolt")
        }
      }.padding(42).frame(maxWidth: 980, alignment: .leading)
    }
  }
  private func suggestion(
    _ title: String, icon: String, detail: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 11) {
        Image(systemName: icon).font(.system(size: 23, weight: .light)).foregroundStyle(blue)
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(18).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading).background(
        .white, in: RoundedRectangle(cornerRadius: 12)
      ).overlay(RoundedRectangle(cornerRadius: 12).stroke(blue.opacity(0.12)))
    }.buttonStyle(.plain)
  }
  private func sampleButton(_ title: String, detail: String, kind: String, icon: String)
    -> some View
  {
    Button {
      model.sample(kind)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: icon).font(.system(size: 17)).foregroundStyle(blue)
        VStack(alignment: .leading, spacing: 5) {
          Text(title).font(.system(size: 12, weight: .medium))
          Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }.buttonStyle(.plain)
  }
  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !model.contextTitle.isEmpty {
        HStack {
          Label(model.contextTitle, systemImage: model.evidence == nil ? "doc.text" : "viewfinder")
            .font(.system(size: 11))
          Button("Remove", action: model.clearContext).font(.system(size: 10))
        }.foregroundStyle(blue)
      }
      HStack(alignment: .bottom, spacing: 12) {
        TextField(
          "Ask anything, or describe what you want to understand…", text: $model.input,
          axis: .vertical
        ).textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5).onSubmit {
          if !model.busy { model.send() }
        }.accessibilityLabel("Message")
        Button {
          model.toggleVoice()
        } label: {
          Image(systemName: model.listening ? "stop.fill" : "mic").font(.system(size: 17))
        }.buttonStyle(.plain).help(model.listening ? "Finish recording" : "Start voice input")
        Button {
          model.send()
        } label: {
          Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(
            .white
          ).frame(width: 31, height: 31).background(blue, in: Circle())
        }.buttonStyle(.plain).disabled(
          model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy
        ).accessibilityLabel("Send message")
      }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(
        RoundedRectangle(cornerRadius: 14).stroke(blue.opacity(0.2)))
      HStack {
        Menu {
          Button("Capture display", action: model.observe)
          Button("Capture a window", action: model.chooseWindow)
          Button("Select region") { model.chooseRegion(.region) }
          Button("Draw spatial context") { model.chooseRegion(.scribble) }
        } label: {
          Label("Add screen", systemImage: "viewfinder")
        }
        Button("Add file", systemImage: "paperclip", action: model.importFile)
        Spacer()
        Text(model.providerMode).font(.system(size: 10)).foregroundStyle(.secondary)
      }.buttonStyle(.borderless).controlSize(.small)
    }.padding(.horizontal, 28).padding(.bottom, 21).padding(.top, 12)
  }
  private var notebook: some View {
    VStack(spacing: 0) {
      if let scene = model.scene {
        HStack {
          TextField(
            "Title",
            text: Binding(get: { model.scene?.title ?? "" }, set: { model.renameScene($0) })
          ).textFieldStyle(.plain).font(.system(size: 22, weight: .medium, design: .rounded))
          Spacer()
          Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
          Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
          Toggle("Draw", isOn: $model.drawing).toggleStyle(.button)
          Button("Add text", systemImage: "text.badge.plus", action: model.addText)
          Button("Save", systemImage: "square.and.arrow.down", action: model.saveScene).buttonStyle(
            .borderedProminent)
          Menu("Export") {
            Button("Editable document JSON", action: model.exportScene)
            Button("PNG image") {
              do {
                try SceneExport.chooseExport(document: scene, time: model.playTime, pdf: false)
              } catch { model.showError(error) }
            }
            Button("PDF") {
              do {
                try SceneExport.chooseExport(document: scene, time: model.playTime, pdf: true)
              } catch { model.showError(error) }
            }
          }
        }.controlSize(.small).padding(20)
        HStack(spacing: 0) {
          SceneCanvas(
            document: scene, time: model.playTime, selectedID: model.selectedNodeID,
            onSelect: { model.selectedNodeID = $0 },
            onMove: { model.editNode(id: $0, x: $1, y: $2) }, playing: model.playing,
            speed: model.speed, seekRevision: model.seekRevision,
            onTimeChange: { model.playTime = $0 }, drawing: model.drawing,
            onStroke: { model.addStroke($0) }, onBeginEdit: { model.snapshotUndo() }
          ).background(.white).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 20)
            .padding(.bottom, 15)
          if let id = model.selectedNodeID, let node = scene.nodes.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
              Text("Selected part").font(.headline)
              Text(node.id).font(.caption).foregroundStyle(.secondary)
              TextField(
                "Text",
                text: Binding(
                  get: { model.scene?.nodes.first(where: { $0.id == id })?.text ?? "" },
                  set: { model.editNode(id: id, text: $0) }), axis: .vertical
              ).lineLimit(3...10)
              Text("Drag the part on the canvas to move it.").font(.caption).foregroundStyle(
                .secondary)
              Button("Deselect") { model.selectedNodeID = nil }
              Spacer()
            }.padding(15).frame(width: 180)
          }
        }
        if !scene.notes.isEmpty {
          Text(scene.notes).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(
            .enabled
          ).padding(.horizontal, 23).padding(.bottom, 9).frame(
            maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 15) {
          Button(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause" : "play") {
            model.playing.toggle()
          }
          Button("Step", systemImage: "forward.end") {
            model.playing = false
            model.playTime += 0.25
            model.seekRevision += 1
          }
          Button("Replay", systemImage: "arrow.counterclockwise") {
            model.playTime = 0
            model.seekRevision += 1
          }
          Text("Speed").font(.caption)
          Slider(value: $model.speed, in: 0.1...2).frame(width: 100)
          Text(String(format: "%.1f×", model.speed)).font(.caption).monospacedDigit()
          Spacer()
          Text("Local controls").font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small).padding(.horizontal, 22).padding(.vertical, 12).background(
          .white.opacity(0.7))
        if !scene.parameters.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 20) {
              ForEach(scene.parameters.keys.sorted(), id: \.self) { name in
                if let parameter = scene.parameters[name] {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(name + " " + String(format: "%.2f", parameter.value)).font(.caption)
                    Slider(
                      value: Binding(
                        get: { model.scene?.parameters[name]?.value ?? parameter.value },
                        set: { model.setParameter(name, value: $0) }),
                      in: parameter.minimum...parameter.maximum
                    ).frame(width: 170)
                  }
                }
              }
            }.padding(.horizontal, 22).padding(.vertical, 8)
          }
        }
        if notebookOnly {
          HStack {
            Text("Ask follow-ups from the notch").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Open companion", action: model.showBadge)
          }.controlSize(.small).padding(.horizontal, 22).padding(.vertical, 10)
        } else {
          composer
        }
      } else {
        VStack(spacing: 20) {
          Image(systemName: "pencil.and.outline").font(.system(size: 48, weight: .ultraLight))
            .foregroundStyle(blue)
          Text("A place to work things out.").font(
            .system(size: 25, weight: .medium, design: .rounded))
          Text("Create a notebook, ask for a diagram, or open a saved lesson.").foregroundStyle(
            .secondary)
          HStack {
            Button("New notebook", action: model.newNotebook)
            Button("Open motor example") { model.sample("motor") }
          }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
  private var library: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Search notebooks and conversations", text: $model.search).textFieldStyle(
          .roundedBorder
        ).onChange(of: model.search) { _, _ in Task { await model.reload() } }
        Button("Export library", action: model.exportLibrary)
      }.padding(22)
      if model.records.isEmpty {
        ContentUnavailableView(
          "Your library starts here", systemImage: "books.vertical",
          description: Text("Save a notebook or finish a conversation to keep it here."))
      } else {
        List(model.records.filter { $0.kind != "memory" }) { record in
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(record.title).font(.headline)
              Text(
                record.kind.capitalized + " • "
                  + record.updatedAt.formatted(date: .abbreviated, time: .shortened)
              ).font(.caption).foregroundStyle(.secondary)
              Text(record.body.prefix(150)).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { model.openRecord(record) }
            Button(role: .destructive) {
              model.deleteRecord(record.id)
            } label: {
              Image(systemName: "trash")
            }
          }.padding(.vertical, 8)
        }
      }
    }
  }
  private var memory: some View {
    HStack(alignment: .top, spacing: 25) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Keep what matters.").font(.system(size: 28, weight: .medium, design: .rounded))
        Text(
          "Memories are written by you. Select one to include it in a question; screen captures are never automatically retained."
        ).font(.system(size: 13)).foregroundStyle(.secondary)
        TextField("Memory title", text: $model.memoryTitle).textFieldStyle(.roundedBorder)
        TextEditor(text: $model.memoryBody).font(.system(size: 14)).frame(
          minHeight: 150, maxHeight: 220
        ).overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.2)))
        Button("Save memory", action: model.saveMemory).buttonStyle(.borderedProminent).disabled(
          model.memoryTitle.isEmpty)
        Spacer()
      }.frame(maxWidth: 450)
      List(model.records.filter { $0.kind == "memory" }) { record in
        VStack(alignment: .leading, spacing: 10) {
          Text(record.title).font(.headline)
          Text(record.body).font(.system(size: 13)).textSelection(.enabled)
          HStack {
            Button("Use in question") { model.useRecord(record) }
            Button("Edit") { editingMemory = record }.disabled(model.store == nil)
            Button("Delete", role: .destructive) { model.deleteRecord(record.id) }
          }
        }.padding(.vertical, 10)
      }
    }.padding(28).sheet(item: $editingMemory) { record in
      if let store = model.store {
        MemoryEditorView(store: store, record: record) { _ in
          model.notice = "Memory updated."
          Task { await model.reload() }
        }
      }
    }
  }
  private var jobs: some View { JobsView(model: model) }
  private var settings: some View {
    Form {
      Section("Reasoning provider") {
        Picker("Connection", selection: $model.providerMode) {
          Text("ChatGPT via Codex").tag("ChatGPT via Codex")
          Text("API key or self-hosted").tag("API key or self-hosted")
        }
        if model.providerMode == "ChatGPT via Codex" {
          TextField("Codex executable", text: $model.codexPath)
          TextField("Model (blank uses Codex default)", text: $model.codexModel)
          Text(
            "Uses your installed Codex CLI and its ChatGPT sign-in. OpenCompanion does not read or copy login tokens. Run ‘codex login’ in Terminal if you need to sign in."
          ).font(.caption).foregroundStyle(.secondary)
        } else {
          TextField("API base URL", text: $model.configuration.endpoint)
          TextField("Model ID", text: $model.configuration.model)
          SecureField("API key / relay token", text: $model.apiKey)
          Text(
            "An API model needs separate provider access. Self-hosted endpoints use the same open streaming interface."
          ).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Save settings", action: model.saveSettings)
          Button("Test live connection", action: model.testConnection)
        }
        Text(model.connectionStatus).font(.caption).textSelection(.enabled)
      }
      Section("Voice") {
        Toggle("Read accepted answers aloud", isOn: $model.configuration.speechEnabled)
        Text(
          "Voice input uses Apple Speech Recognition, on-device when available. Otherwise Apple may process audio. Hold Control + Option and release to send and hear a reply. The Talk button lets you review the transcript before sending."
        ).font(.caption).foregroundStyle(.secondary)
        Text("Stop current output: Escape.").font(.caption)
        Button("Show companion", action: model.showBadge)
      }
      ShortcutSettingsView()
      Section("Voice shortcut status") {
        Label(
          model.voiceShortcutStatus,
          systemImage: model.voiceShortcutAvailable ? "checkmark.circle" : "keyboard.badge.ellipsis"
        )
        .font(.caption).textSelection(.enabled)
      }
      Section("Permissions") {
        HStack {
          Label(
            CGPreflightScreenCaptureAccess()
              ? "Screen recording allowed" : "Screen recording needs permission",
            systemImage: "viewfinder")
          Spacer()
          Button("Request") { _ = CGRequestScreenCaptureAccess() }
        }
        HStack {
          Label(
            AXIsProcessTrusted() ? "Accessibility allowed" : "Accessibility optional",
            systemImage: "accessibility")
          Spacer()
          Button("Request", action: AccessibilityService.requestPermission)
        }
        Button("Open privacy settings") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        }
        Text(
          "Text and notebooks remain usable with permissions denied. Capture happens only when you choose Add screen."
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section("Selected display") {
        Picker(
          "Capture display",
          selection: Binding(
            get: { model.selectedDisplay ?? 0 }, set: { model.selectedDisplay = $0 == 0 ? nil : $0 }
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
      }
      Section("Data & diagnostics") {
        HStack {
          Button("Export library", action: model.exportLibrary)
          Button("Export diagnostics", action: model.exportDiagnostics)
        }
        Text(
          "Local library: ~/Library/Application Support/OpenCompanion. Provider credentials: macOS Keychain. Captured screen frames stay in memory only. Diagnostics contain host timing events, not prompts or credentials."
        ).font(.caption).foregroundStyle(.secondary)
        Link(
          "Source & feature status",
          destination: URL(string: "https://github.com/Nithesh8678/opencompanion")!)
      }
    }.formStyle(.grouped).scrollContentBackground(.hidden)
  }
}
