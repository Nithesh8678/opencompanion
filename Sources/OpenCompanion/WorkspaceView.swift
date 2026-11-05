import AppKit
import ApplicationServices
import CompanionCore
import CompanionStore
import SwiftUI

private let ink = WorkspacePalette.text
private let blue = WorkspacePalette.blue

struct WorkspaceView: View {
  @ObservedObject var model: AppModel
  @State private var editingMemory: StoredRecord?
  @State private var sidebarVisible = true
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
      .background(WorkspacePalette.background).foregroundStyle(WorkspacePalette.text)
      .tint(blue).preferredColorScheme(.dark)
      .sheet(
        isPresented: Binding(
          get: {
            !notebookOnly && model.showingWindowPicker && model.windowPickerHost == .workspace
          },
          set: { if !$0 { model.cancelWindowPicker() } }
        )
      ) {
        CompanionWindowPickerView(
          windows: model.captureWindows,
          select: { window in
            model.cancelWindowPicker()
            model.performCapture(window: window)
          }, cancel: model.cancelWindowPicker)
      }
  }

  private var isChat: Bool {
    !["Notebook", "Library", "Memory", "Jobs", "Connections", "Settings"].contains(model.section)
  }
  private var workspace: some View {
    HStack(spacing: 0) {
      if sidebarVisible { sidebar }
      VStack(spacing: 0) {
        workspaceHeader
        if let error = model.error { banner(error, isError: true) }
        if let notice = model.notice { banner(notice, isError: false) }
        ZStack {
          // Keep the transcript mounted while browsing other destinations so
          // its local reading/live-edge state is not discarded by navigation.
          companion.opacity(isChat ? 1 : 0).allowsHitTesting(isChat).disabled(!isChat)
            .accessibilityHidden(!isChat)
          if !isChat {
            Group {
              switch model.section {
              case "Notebook":
                ContentUnavailableView {
                  Label("Your notebook has its own panel", systemImage: "pencil.and.outline")
                } description: {
                  Text("Keep the explanation beside your conversation.")
                } actions: {
                  Button("Open notebook") { model.onOpen?() }
                }
              case "Library": library
              case "Memory": memory
              case "Jobs": JobsView(model: model)
              case "Connections": ConnectionsView(model: model)
              case "Settings": CompanionSettingsView(model: model)
              default: EmptyView()
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(WorkspacePalette.background)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(WorkspacePalette.background)
    }
  }

  private var workspaceHeader: some View {
    HStack(spacing: 13) {
      Button {
        sidebarVisible.toggle()
      } label: {
        Image(systemName: "sidebar.left").font(.system(size: 15))
      }.buttonStyle(.plain).foregroundStyle(WorkspacePalette.secondary)
        .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
        .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
      VStack(alignment: .leading, spacing: 2) {
        Text(isChat ? "OpenCompanion" : model.section)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
        if isChat {
          Text("Your conversation").font(.system(size: 10)).foregroundStyle(
            WorkspacePalette.secondary)
        }
      }
      Spacer()
      if isChat {
        Button(action: model.newConversation) {
          Image(systemName: "square.and.pencil").font(.system(size: 14, weight: .medium))
            .frame(width: 30, height: 30)
            .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).foregroundStyle(WorkspacePalette.secondary)
          .accessibilityLabel("New chat").accessibilityIdentifier("workspace.newChat")
          .help("Start a new conversation")
      }
      if model.busy || model.presentingExplanation || model.listening || model.state == "Speaking"
        || model.state == "Observing"
        || model.voice.hasPendingSpeech
      {
        Text(model.state).font(.system(size: 11)).foregroundStyle(WorkspacePalette.secondary)
        Button("Stop", systemImage: "stop.circle", action: model.stop)
          .buttonStyle(.borderless).controlSize(.small)
          .help("Stop current voice, response and capture work")
      }
      Button("Open notch", systemImage: "rectangle.topthird.inset.filled", action: model.showBadge)
        .font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(
          WorkspacePalette.secondary)
    }.padding(.horizontal, 23).frame(height: 58)
      .background(WorkspacePalette.background)
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 9) {
        Image(systemName: "sparkle").font(.system(size: 22, weight: .light))
          .foregroundStyle(blue)
        Text("OpenCompanion").font(.system(size: 14, weight: .semibold, design: .rounded))
          .lineLimit(1).minimumScaleFactor(0.8)
        Spacer(minLength: 0)
        Menu {
          Button("New notebook", action: model.newNotebook)
          Divider()
          Button("Motor example") { model.sample("motor") }
          Button("Lever example") { model.sample("lever") }
          Button("Circuit example") { model.sample("circuit") }
        } label: {
          Image(systemName: "plus").font(.system(size: 12))
        }.menuStyle(.borderlessButton).fixedSize().help("Create a notebook or open an example")
      }.padding(.horizontal, 10).padding(.top, 23).padding(.bottom, 22)

      ForEach(
        [
          ("Companion", "Chat", "bubble.left.and.text.bubble.right"),
          ("Notebook", "Notebook", "pencil.and.outline"),
          ("Library", "Library", "books.vertical"), ("Memory", "Memory", "bookmark"),
          ("Jobs", "Jobs", "clock.arrow.circlepath"),
          ("Connections", "Connections", "point.3.connected.trianglepath.dotted"),
        ], id: \.0
      ) { section, title, symbol in
        sidebarButton(section, title: title, symbol: symbol)
      }
      Spacer(minLength: 20)
      Button(action: model.showBadge) {
        HStack(spacing: 9) {
          Image(systemName: "rectangle.topthird.inset.filled")
          VStack(alignment: .leading, spacing: 3) {
            Text("Back to your notch").font(.system(size: 11, weight: .medium))
            Text(ShortcutPreferences.load().openShortcut.displayName).font(.system(size: 10))
              .foregroundStyle(WorkspacePalette.secondary)
          }
          Spacer(minLength: 0)
        }.padding(11)
      }.buttonStyle(.plain).foregroundStyle(WorkspacePalette.text)
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 8)
      sidebarButton("Settings", title: "Settings", symbol: "gearshape")
      Link(
        "Independent & open source",
        destination: URL(string: "https://github.com/Nithesh8678/opencompanion")!
      )
      .font(.system(size: 10)).foregroundStyle(WorkspacePalette.secondary)
      .padding(.horizontal, 11).padding(.top, 4).padding(.bottom, 18)
    }.padding(.horizontal, 12).frame(width: 218)
      .background(WorkspacePalette.sidebar)
      .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.05)).frame(width: 1) }
  }

  private func sidebarButton(_ section: String, title: String, symbol: String) -> some View {
    let selected = model.section == section
    return Button {
      model.section = section
      if section == "Notebook" { model.onOpen?() }
      Task { await model.reload() }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 13)).frame(width: 19)
        Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
        Spacer(minLength: 0)
        if section == "Jobs", !model.jobs.isEmpty {
          Text(String(model.jobs.count)).font(.system(size: 10)).monospacedDigit()
            .foregroundStyle(selected ? Color.black.opacity(0.55) : WorkspacePalette.secondary)
        }
      }.padding(.horizontal, 12).frame(height: 39)
        .foregroundStyle(
          selected ? Color(red: 0.16, green: 0.17, blue: 0.19) : WorkspacePalette.text.opacity(0.8)
        )
        .background {
          if selected {
            WorkspacePaperShape().fill(WorkspacePalette.paper)
              .rotationEffect(.degrees(-0.35)).shadow(color: .black.opacity(0.18), radius: 2, y: 2)
          }
        }.contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func banner(_ text: String, isError: Bool) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
      Text(text).font(.system(size: 12)).textSelection(.enabled)
      Spacer(minLength: 8)
      Button {
        if isError { model.error = nil } else { model.notice = nil }
      } label: {
        Image(systemName: "xmark").font(.system(size: 10))
      }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
    }.foregroundStyle(isError ? Color(red: 1, green: 0.70, blue: 0.62) : WorkspacePalette.blue)
      .padding(.horizontal, 22).padding(.vertical, 11)
      .background(isError ? Color.red.opacity(0.10) : WorkspacePalette.blue.opacity(0.07))
  }

  private var companion: some View {
    VStack(spacing: 0) {
      CompanionTranscriptView(model: model)
      composer
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !model.contextTitle.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: model.evidence == nil ? "doc.text" : "viewfinder")
          Text(model.contextTitle).lineLimit(1).truncationMode(.middle)
          Button(action: model.clearContext) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).accessibilityLabel("Remove selected context")
          Spacer(minLength: 0)
        }.font(.system(size: 11)).foregroundStyle(blue)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
      }
      HStack(alignment: .bottom, spacing: 12) {
        Button(action: model.toggleVoice) {
          VStack(spacing: 5) {
            HStack(spacing: 8) {
              Image(systemName: model.listening ? "stop.fill" : "mic.fill")
              Text(
                model.state == "Finishing speech"
                  ? "Finishing…" : model.listening ? "Finish recording" : "Talk"
              )
              .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            Text(
              model.state == "Finishing speech"
                ? "Preparing your transcript"
                : model.listening ? "Then review your words" : "Review before sending"
            )
            .font(.system(size: 9))
          }.foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.21))
            .frame(width: 147, height: 59)
            .background(
              LinearGradient(
                colors: [Color(red: 0.69, green: 0.86, blue: 1), blue], startPoint: .top,
                endPoint: .bottom),
              in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.3), lineWidth: 0.7))
        }.buttonStyle(.plain).disabled(model.pushToTalkActive || model.state == "Finishing speech")
          .help("Record a draft to review. Hold Control+Option to submit a voice question instead.")
          .accessibilityLabel(
            model.listening
              ? "Finish recording and review transcript" : "Talk, then review transcript")
        HStack(alignment: .bottom, spacing: 11) {
          TextField("Ask a question…", text: $model.input, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...5)
            .padding(.vertical, 4).onSubmit {
              if !model.busy { model.send() }
            }.accessibilityLabel("Message").accessibilityIdentifier("workspace.message")
          Button(action: model.send) {
            Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
              .foregroundStyle(
                canSend ? Color(red: 0.08, green: 0.14, blue: 0.21) : WorkspacePalette.secondary
              )
              .frame(width: 31, height: 31)
              .background(canSend ? blue : WorkspacePalette.raised, in: Circle())
          }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("Send message")
        }.padding(13).frame(minHeight: 59)
          .background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 15))
          .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.08), lineWidth: 0.7))
      }
      HStack(spacing: 14) {
        Menu {
          Button("Capture display", action: model.observe)
          Button("Capture a window") { model.chooseWindow() }
          Button("Select region") { model.chooseRegion(.region) }
          Button("Draw spatial context") { model.chooseRegion(.scribble) }
        } label: {
          Label("Add screen", systemImage: "viewfinder")
        }
        Button("Attach file", systemImage: "paperclip", action: model.importFile)
        if model.messages.isEmpty {
          Menu("Examples") {
            Button("Inside a DC motor") { model.sample("motor") }
            Button("A lever in balance") { model.sample("lever") }
            Button("A simple circuit") { model.sample("circuit") }
          }
        }
        Spacer(minLength: 0)
        Text(
          model.pushToTalkActive
            ? "Release ⌃⌥ to send"
            : model.voiceShortcutAvailable
              ? "Hold ⌃⌥ to talk and send" : "Talk records a draft to review"
        )
        .font(.system(size: 10)).foregroundStyle(WorkspacePalette.secondary)
      }.font(.system(size: 11)).buttonStyle(.borderless).controlSize(.small)
        .foregroundStyle(WorkspacePalette.secondary)
    }.padding(.horizontal, 25).padding(.top, 14).padding(.bottom, 20)
      .background(WorkspacePalette.background)
      .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
  }

  private var canSend: Bool {
    !model.busy && !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
          WorkspacePalette.surface)
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
          }.padding(.vertical, 8).listRowBackground(WorkspacePalette.surface)
        }.scrollContentBackground(.hidden)
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
        TextEditor(text: $model.memoryBody).font(.system(size: 14)).scrollContentBackground(.hidden)
          .padding(9).background(WorkspacePalette.surface, in: RoundedRectangle(cornerRadius: 8))
          .frame(
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
        }.padding(.vertical, 10).listRowBackground(WorkspacePalette.surface)
      }.scrollContentBackground(.hidden)
    }.padding(28).sheet(item: $editingMemory) { record in
      if let store = model.store {
        MemoryEditorView(store: store, record: record) { _ in
          model.notice = "Memory updated."
          Task { await model.reload() }
        }
      }
    }
  }
}
