import CompanionCore
import CompanionStore
import CryptoKit
import SwiftUI

struct JobsView: View {
  @ObservedObject var model: AppModel
  @State private var instruction = ""
  @State private var interval = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Let a thought keep working.").font(.system(size: 28, weight: .medium, design: .rounded))
      Text(
        "Run a bounded research or explanation request in the background. Jobs use your selected provider while this app is running. Sleep and quit pause execution; action outcomes are never assumed."
      ).font(.system(size: 13)).foregroundStyle(.secondary)
      TextField("Describe the result you want", text: $instruction, axis: .vertical).textFieldStyle(
        .roundedBorder
      ).lineLimit(2...5)
      HStack {
        Picker("Repeat", selection: $interval) {
          Text("Once").tag(0)
          Text("Every hour while app is open").tag(3600)
          Text("Every day while app is open").tag(86400)
        }.frame(maxWidth: 360)
        Button(interval == 0 ? "Start job" : "Create routine") {
          model.enqueueJob(instruction, interval: interval)
          instruction = ""
        }.buttonStyle(.borderedProminent).disabled(instruction.isEmpty)
        Spacer()
        Button("Refresh") { Task { await model.reload() } }
      }
      List(model.jobs) { job in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(job.instruction).font(.headline).lineLimit(2)
            Spacer()
            Text(job.status.rawValue).font(.caption).foregroundStyle(
              job.status == .succeeded ? .green : .secondary)
          }
          ProgressView(value: job.progress)
          HStack {
            Text("App-running • \(job.scope)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if job.status == .queued || job.status == .running {
              Button("Cancel") { model.cancelJob(job.id) }
            }
            if let data = job.checkpoint, job.status == .succeeded {
              Button("View result") { model.viewJobResult(data) }
            }
          }
          if let error = job.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 7)
      }
    }.padding(28)
  }
}
struct ConnectionsView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    TabView {
      BrowserConnectionView(browser: model.browser, model: model).tabItem { Text("Browser") }
      MCPConnectionView().tabItem { Text("MCP server") }
      DesktopActionsView().tabItem { Text("Desktop") }
    }.padding(20)
  }
}
struct BrowserConnectionView: View {
  @ObservedObject var browser: BrowserBridge
  @ObservedObject var model: AppModel
  @State private var selectedTab: Int?
  @State private var result = ""
  @State private var ref = ""
  @State private var value = ""
  @State private var kind = "click"
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      Text("Bring a tab into the conversation.").font(
        .system(size: 25, weight: .medium, design: .rounded))
      Text(
        "Install the original OpenCompanion extension from the repository. Start the bridge, then explicitly connect the active tab from the extension popup. Each action needs that tab’s write scope."
      ).font(.system(size: 13)).foregroundStyle(.secondary)
      HStack {
        Label(
          browser.status, systemImage: browser.tabs.isEmpty ? "circle" : "checkmark.circle.fill")
        Spacer()
        Button(browser.running ? "Stop bridge" : "Start bridge") {
          if browser.running { browser.stop() } else { browser.start() }
        }
        Link(
          "Installation guide",
          destination: URL(
            string: "https://github.com/Nithesh8678/opencompanion/blob/main/docs/BROWSER.md")!)
      }
      Picker("Connected tab", selection: $selectedTab) {
        Text("Choose a tab").tag(Int?.none)
        ForEach(browser.tabs) { tab in Text(tab.title).tag(Int?.some(tab.tabID)) }
      }
      HStack {
        Button("Read fresh snapshot") { request("snapshot") }.disabled(selectedTab == nil)
        Button("Use snapshot as context") {
          model.selectedContext = String(result.prefix(48000))
          model.contextTitle = "Connected browser snapshot"
          model.section = "Companion"
        }.disabled(result.isEmpty)
      }
      DisclosureGroup("Run an explicit browser action") {
        VStack(alignment: .leading, spacing: 9) {
          Text(
            "Use a ref from the fresh snapshot below. The extension rechecks document/revision, visibility and hit target before acting. The returned receipt contains the fresh result; dispatch alone does not prove your task finished."
          ).font(.caption).foregroundStyle(.secondary)
          HStack {
            TextField("Element ref", text: $ref)
            Picker("Action", selection: $kind) {
              Text("Click").tag("click")
              Text("Fill").tag("fill")
              Text("Select").tag("select")
            }
            TextField("Value", text: $value)
            Button("Perform action") { act() }.disabled(selectedTab == nil || ref.isEmpty)
          }
        }
      }
      ScrollView {
        Text(result.isEmpty ? "A connected snapshot will appear here." : result).font(
          .system(size: 11, design: .monospaced)
        ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
      }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }.padding(20)
  }
  private func request(_ operation: String, payload: Data = Data("{}".utf8)) {
    guard let selectedTab else { return }
    Task {
      do {
        let data = try await browser.request(
          operation: operation, tabID: selectedTab, payload: payload)
        if let json = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        {
          result = String(decoding: pretty, as: UTF8.self)
        } else {
          result = String(decoding: data, as: UTF8.self)
        }
      } catch { result = error.localizedDescription }
    }
  }
  private func act() {
    guard let snapshot = browser.lastSnapshot,
      let object = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any]
    else {
      result = "Read a snapshot before acting."
      return
    }
    let source = (object["snapshot"] as? [String: Any]) ?? object
    guard let document = source["documentID"], let revision = source["revision"],
      let data = try? JSONSerialization.data(withJSONObject: [
        "documentID": document, "revision": revision, "ref": ref, "kind": kind, "value": value,
      ])
    else {
      result = "Snapshot has no current document/revision."
      return
    }
    request("act", payload: data)
  }
}
struct MCPConnectionView: View {
  @AppStorage("mcp.connection.name") private var name = ""
  @AppStorage("mcp.connection.endpoint") private var endpoint = ""
  @AppStorage("mcp.connection.account") private var account = "Personal"
  @State private var token = ""
  @State private var status = "Disconnected"
  @State private var client: MCPClient?
  @State private var tools: [MCPTool] = []
  @State private var selected = ""
  @State private var arguments = "{}"
  @State private var result = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connect a real tool server.").font(.system(size: 25, weight: .medium, design: .rounded))
      Text(
        "Streamable HTTP MCP with explicit account and Keychain token. Only tools actually returned by a connected server appear here. OAuth registration is not bundled."
      ).font(.system(size: 13)).foregroundStyle(.secondary)
      HStack {
        TextField("Connection name", text: $name)
        TextField("Account label", text: $account)
      }
      TextField("HTTPS MCP endpoint", text: $endpoint)
      SecureField("Bearer token (optional)", text: $token)
      HStack {
        Button("Connect & discover tools") { connect() }.disabled(endpoint.isEmpty || name.isEmpty)
        Button("Disconnect & forget token") {
          Task {
            try? await client?.disconnect(removeCredential: true)
            client = nil
            tools = []
            status = "Disconnected; saved token removed"
          }
        }
        Text(status).font(.caption).textSelection(.enabled)
      }
      if !tools.isEmpty {
        Picker("Available tool", selection: $selected) {
          Text("Choose tool").tag("")
          ForEach(tools) { tool in Text(tool.name).tag(tool.name) }
        }
        if let tool = tools.first(where: { $0.name == selected }) {
          Text(tool.description ?? tool.name).font(.caption).foregroundStyle(.secondary)
          if let encoded = try? JSONEncoder().encode(tool.inputSchema) {
            Text(String(decoding: encoded, as: UTF8.self)).font(
              .system(size: 10, design: .monospaced)
            ).textSelection(.enabled).lineLimit(8)
          }
        }
        Text(
          "Review arguments before sending. Calling a tool can change data in your connected account."
        ).font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 85)
          .border(.gray.opacity(0.3))
        Button("Call selected tool") { call() }.disabled(selected.isEmpty)
      }
      ScrollView {
        Text(result).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading)
      }
      Spacer()
    }.textFieldStyle(.roundedBorder).padding(20)
  }
  private func connect() {
    guard let url = URL(string: endpoint) else {
      status = "Invalid URL"
      return
    }
    let id = SHA256.hash(data: Data((endpoint + "|" + account).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let configuration = MCPConfiguration(id: id, name: name, url: url, account: account)
    tools = []
    selected = ""
    let adapter = MCPClient(configuration: configuration)
    client = adapter
    status = "Connecting…"
    Task {
      do {
        if !token.isEmpty { try await adapter.setToken(token) }
        tools = try await adapter.connect()
        status = "Connected • \(tools.count) tools"
      } catch { status = error.localizedDescription }
    }
  }
  private func call() {
    guard let client else { return }
    Task {
      do {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8))
        let output = try await client.callTool(name: selected, arguments: value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        result = String(decoding: try encoder.encode(output), as: UTF8.self)
      } catch { result = error.localizedDescription }
    }
  }
}
