import Combine
import CompanionCore
import CompanionStore
import Foundation

/// Runs only inside this app process. A timer does not claim execution after
/// quit, logout, or sleep. Durable leases/checkpoints remain in LocalStore.
@MainActor
final class JobRunner {
  typealias Executor = @Sendable (DurableJob) async throws -> Data
  private var store: LocalStore?
  private var executor: Executor?
  private var onChange: (@MainActor ([DurableJob]) -> Void)?
  private var onError: (@MainActor (Error) -> Void)?
  private var scheduler: Task<Void, Never>?
  private var tasks: [String: Task<Void, Never>] = [:]
  private var lastPublished: [DurableJob] = []
  private let owner = UUID().uuidString
  private var polling = false

  func start(
    store: LocalStore, executor: @escaping Executor,
    onChange: @escaping @MainActor ([DurableJob]) -> Void,
    onError: @escaping @MainActor (Error) -> Void = { _ in }
  ) {
    self.store = store
    self.executor = executor
    self.onChange = onChange
    self.onError = onError
    guard scheduler == nil else { return }
    scheduler = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        do { try await Task.sleep(for: .seconds(10)) } catch { break }
      }
    }
  }

  /// Cancellation reaches the executor's Task immediately, then persists a
  /// generation change so any late network/tool callback cannot checkpoint.
  func cancel(jobID: String) async throws {
    tasks[jobID]?.cancel()
    guard let store else { return }
    try await store.cancelJob(id: jobID)
    await publish()
  }

  func stop() {
    scheduler?.cancel()
    scheduler = nil
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  func refresh() async {
    guard !polling, let store, let executor else { return }
    polling = true
    defer { polling = false }
    do {
      _ = try await store.recoverInterruptedJobs()
      _ = try await store.enqueueDueRoutines()
      let jobs = try await store.jobs()
      for job in jobs
      where job.status == .queued && (job.nextRunAt.map { $0 <= Date() } ?? true)
        && tasks[job.id] == nil
      {
        guard tasks.count < 2 else { break }
        launch(job: job, store: store, executor: executor)
      }
      await publish()
    } catch { onError?(error) }
  }

  private func launch(job: DurableJob, store: LocalStore, executor: @escaping Executor) {
    let owner = owner
    tasks[job.id] = Task { [weak self] in
      var lease: JobLease?
      var heartbeat: Task<Void, Never>?
      do {
        try Task.checkCancellation()
        let acquired = try await store.acquireLease(jobID: job.id, owner: owner, duration: 45)
        lease = acquired
        heartbeat = Task {
          while !Task.isCancelled {
            do {
              try await Task.sleep(for: .seconds(10))
              _ = try await store.renewLease(acquired, duration: 45)
            } catch {
              if !Task.isCancelled { self?.tasks[job.id]?.cancel() }
              break
            }
          }
        }
        try await store.checkpointJob(acquired, checkpoint: job.checkpoint, progress: 0.1)
        let action = try await store.startAction(
          acquired, operation: "app-running-executor", retryClass: job.retryClass)
        await self?.publish()
        let result = try await executor(job)
        try Task.checkCancellation()
        try await store.completeAction(
          acquired, actionID: action.id, succeeded: true, result: result)
        try await store.checkpointJob(acquired, checkpoint: result, progress: 1)
        try await store.finishJob(acquired, succeeded: true)
      } catch {
        if error is CancellationError || Task.isCancelled {
          if let current = try? await store.job(id: job.id), current.status != .cancelled {
            try? await store.cancelJob(id: job.id)
          }
        } else if let lease {
          try? await store.interruptJob(lease, error: error.localizedDescription)
          self?.onError?(error)
        } else if error as? StoreError != .leaseUnavailable {
          self?.onError?(error)
        }
      }
      heartbeat?.cancel()
      self?.tasks[job.id] = nil
      await self?.publish()
    }
  }

  private func publish() async {
    guard let store, let jobs = try? await store.jobs(), jobs != lastPublished else { return }
    lastPublished = jobs
    onChange?(jobs)
  }
}

struct MCPConfiguration: Identifiable, Codable, Sendable, Equatable {
  var id: String = UUID().uuidString
  var name: String
  var url: URL
  var account: String
  var credentialAccount: String { "\(id):\(account)" }
}

struct MCPTool: Identifiable, Codable, Sendable, Equatable {
  var id: String { name }
  let name: String
  let title: String?
  let description: String?
  let inputSchema: JSONValue
}

struct MCPCapabilityState: Sendable, Equatable {
  enum Status: String, Sendable { case disconnected, connecting, connected, failed }
  var status: Status = .disconnected
  var serverName: String?
  var protocolVersion: String?
  var tools: [MCPTool] = []
  var message = "Not connected"
}

enum MCPError: Error, LocalizedError, Sendable {
  case invalidEndpoint, invalidResponse, responseTooLarge, timeout, sessionExpired
  case http(Int)
  case rpc(Int)
  case incompatibleVersion(String)
  case unavailableTool(String)
  case invalidArguments(String)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "MCP requires an HTTPS URL, or HTTP on localhost, without embedded credentials."
    case .invalidResponse: "The MCP server returned an invalid or incomplete response."
    case .responseTooLarge: "The MCP response exceeded the bounded context limit."
    case .timeout:
      "The MCP request reached its time limit. Check the server before retrying an action."
    case .sessionExpired:
      "The MCP session expired. Reconnect and check the previous action's outcome before retrying."
    case .http(let code):
      "MCP request failed (HTTP \(code)). Check the server and selected account credential."
    case .rpc(let code): "The MCP server rejected the request (JSON-RPC \(code))."
    case .incompatibleVersion(let version):
      "The MCP server selected an unsupported protocol version: \(version)."
    case .unavailableTool(let name): "This connected server has not advertised the tool \(name)."
    case .invalidArguments(let reason): "MCP tool arguments are invalid: \(reason)"
    }
  }
}

/// Explicitly configured Streamable HTTP transport, implementing initialize,
/// notifications/initialized, paginated tools/list and user-requested tools/call.
/// No tool is called by discovery, and no failed action is automatically retried.
/// Protocol: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
actor MCPClient {
  static let credentialService = "org.opencompanion.mcp"
  private let configuration: MCPConfiguration
  private let credentials: CredentialStore
  private let session: URLSession
  private let credentialLoader: (@Sendable () throws -> Data?)?
  private var sessionID: String?
  private var protocolVersion = "2025-06-18"
  private var state = MCPCapabilityState()
  private let requestTimeout: TimeInterval

  init(
    configuration: MCPConfiguration, credentials: CredentialStore = CredentialStore(),
    session: URLSession? = nil, requestTimeout: TimeInterval = 45,
    credentialLoader: (@Sendable () throws -> Data?)? = nil
  ) {
    self.credentialLoader = credentialLoader
    self.configuration = configuration
    self.credentials = credentials
    let timeout = min(max(requestTimeout, 1), 120)
    self.requestTimeout = timeout
    if let session {
      self.session = session
    } else {
      let options = URLSessionConfiguration.ephemeral
      options.timeoutIntervalForRequest = timeout
      options.timeoutIntervalForResource = timeout
      options.httpShouldSetCookies = false
      options.urlCredentialStorage = nil
      self.session = URLSession(
        configuration: options, delegate: MCPRedirectPolicy(), delegateQueue: nil)
    }
  }

  func capabilityState() -> MCPCapabilityState { state }

  func setToken(_ token: String) throws {
    if token.isEmpty {
      try credentials.delete(
        service: Self.credentialService, account: configuration.credentialAccount)
    } else {
      try credentials.save(
        Data(token.utf8), service: Self.credentialService, account: configuration.credentialAccount)
    }
  }

  @discardableResult
  func connect() async throws -> [MCPTool] {
    guard state.status != .connecting else { throw MCPError.invalidResponse }
    state = MCPCapabilityState(status: .connecting, message: "Negotiating capabilities…")
    sessionID = nil
    do {
      let initialized = try await request(
        method: "initialize",
        params: .object([
          "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
          "clientInfo": .object(["name": .string("OpenCompanion"), "version": .string("0.1.0")]),
        ]))
      guard let result = initialized.object, let version = result["protocolVersion"]?.string,
        let capabilities = result["capabilities"]?.object
      else { throw MCPError.invalidResponse }
      guard ["2025-06-18", "2025-03-26"].contains(version) else {
        throw MCPError.incompatibleVersion(version)
      }
      protocolVersion = version
      try await notification(method: "notifications/initialized", params: nil)
      state.serverName = result["serverInfo"]?.object?["name"]?.string
      state.protocolVersion = version
      if capabilities["tools"] != nil { state.tools = try await discoverTools() }
      state.status = .connected
      state.message = "Connected • \(state.tools.count) advertised tools"
      return state.tools
    } catch {
      sessionID = nil
      state.status = .failed
      state.tools = []
      state.message = error.localizedDescription
      throw error
    }
  }

  func refreshTools() async throws -> [MCPTool] {
    guard state.status == .connected else { throw MCPError.invalidResponse }
    let tools = try await discoverTools()
    state.tools = tools
    state.message = "Connected • \(tools.count) advertised tools"
    return tools
  }

  /// The caller presents the selected tool and arguments for explicit user
  /// invocation. Tool descriptions/annotations are untrusted server content.
  func callTool(name: String, arguments: JSONValue) async throws -> JSONValue {
    guard state.status == .connected, let tool = state.tools.first(where: { $0.name == name })
    else {
      throw MCPError.unavailableTool(name)
    }
    try MCPArgumentValidator.validate(arguments, schema: tool.inputSchema)
    return try await request(
      method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
  }

  func disconnect(removeCredential: Bool = false) async throws {
    let oldSession = sessionID
    sessionID = nil
    state = MCPCapabilityState()
    if let oldSession {
      var request = try makeRequest(body: nil)
      request.httpMethod = "DELETE"
      request.setValue(oldSession, forHTTPHeaderField: "Mcp-Session-Id")
      request.timeoutInterval = 5
      // Session termination is best effort; many servers return 405.
      if let (bytes, _) = try? await session.bytes(for: request) { bytes.task.cancel() }
    }
    if removeCredential {
      try credentials.delete(
        service: Self.credentialService, account: configuration.credentialAccount)
    }
  }

  private func discoverTools() async throws -> [MCPTool] {
    var tools: [MCPTool] = []
    var cursor: String?
    var visited = Set<String>()
    for _ in 0..<20 {
      let params = cursor.map { JSONValue.object(["cursor": .string($0)]) } ?? .object([:])
      let response = try await request(method: "tools/list", params: params)
      guard let object = response.object, let page = object["tools"] else {
        throw MCPError.invalidResponse
      }
      let decoded = try page.decoded(as: [MCPTool].self)
      for tool in decoded {
        guard !tool.name.isEmpty, tool.name.utf8.count <= 512, tool.inputSchema.object != nil,
          !tools.contains(where: { $0.name == tool.name })
        else { throw MCPError.invalidResponse }
        tools.append(tool)
      }
      guard tools.count <= 500 else { throw MCPError.responseTooLarge }
      cursor = object["nextCursor"]?.string
      guard let next = cursor else { return tools }
      guard next.utf8.count <= 2_048, visited.insert(next).inserted else {
        throw MCPError.invalidResponse
      }
    }
    throw MCPError.responseTooLarge
  }

  private func request(method: String, params: JSONValue) async throws -> JSONValue {
    let id = UUID().uuidString
    let body = JSONValue.object([
      "jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params,
    ])
    let request = try makeRequest(body: body)
    do {
      let response = try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: MCPWireResponse.self) { group in
          let session = session
          let timeout = requestTimeout
          group.addTask {
            try await Self.transport(request: request, session: session, matchingID: id)
          }
          group.addTask {
            try await Task.sleep(for: .seconds(timeout))
            throw MCPError.timeout
          }
          defer { group.cancelAll() }
          guard let response = try await group.next() else { throw MCPError.invalidResponse }
          return response
        }
      } onCancel: {
        Task { await self.cancelRemote(id: id) }
      }
      if let receivedSession = response.sessionID { sessionID = receivedSession }
      guard let object = response.message.object, object["jsonrpc"]?.string == "2.0",
        object["id"]?.string == id
      else { throw MCPError.invalidResponse }
      if let error = object["error"]?.object {
        throw MCPError.rpc(Int(error["code"]?.number ?? -32_603))
      }
      guard let result = object["result"] else { throw MCPError.invalidResponse }
      return result
    } catch {
      if case MCPError.sessionExpired = error {
        sessionID = nil
        state.status = .failed
        state.tools = []
        state.message = error.localizedDescription
      }
      if case MCPError.timeout = error { await cancelRemote(id: id) }
      throw error
    }
  }

  private func notification(method: String, params: JSONValue?) async throws {
    var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
    if let params { object["params"] = params }
    let request = try makeRequest(body: .object(object))
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
    guard http.statusCode == 202 else { throw MCPError.http(http.statusCode) }
  }

  private func cancelRemote(id: String) async {
    try? await notification(
      method: "notifications/cancelled",
      params: .object([
        "requestId": .string(id), "reason": .string("User cancellation or request deadline"),
      ]))
  }

  private func makeRequest(body: JSONValue?) throws -> URLRequest {
    let url = configuration.url
    guard let scheme = url.scheme, let host = url.host, !host.isEmpty,
      scheme == "https"
        || (scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)),
      url.user == nil, url.password == nil, url.fragment == nil
    else { throw MCPError.invalidEndpoint }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    let credential: Data?
    if let credentialLoader {
      credential = try credentialLoader()
    } else {
      credential = try credentials.load(
        service: Self.credentialService, account: configuration.credentialAccount)
    }
    if let data = credential {
      guard let token = String(data: data, encoding: .utf8), !token.contains("\r"),
        !token.contains("\n")
      else { throw MCPError.invalidResponse }
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      let data = try JSONEncoder().encode(body)
      guard data.count <= 1_000_000 else { throw MCPError.responseTooLarge }
      request.httpBody = data
    }
    return request
  }

  private static func transport(request: URLRequest, session: URLSession, matchingID: String)
    async throws -> MCPWireResponse
  {
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
    if http.statusCode == 404, request.value(forHTTPHeaderField: "Mcp-Session-Id") != nil {
      throw MCPError.sessionExpired
    }
    guard (200..<300).contains(http.statusCode) else { throw MCPError.http(http.statusCode) }
    let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
    if let sessionID {
      guard sessionID.utf8.count <= 512, sessionID.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
      else { throw MCPError.invalidResponse }
    }
    let isSSE =
      http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream")
      == true
    if !isSSE {
      guard
        http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json")
          == true
      else { throw MCPError.invalidResponse }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        data.append(byte)
        guard data.count <= 2_000_000 else { throw MCPError.responseTooLarge }
      }
      return MCPWireResponse(
        message: try JSONDecoder().decode(JSONValue.self, from: data), sessionID: sessionID)
    }
    var line = Data()
    var eventData = ""
    var total = 0
    for try await byte in bytes {
      try Task.checkCancellation()
      total += 1
      guard total <= 2_000_000, line.count <= 262_144 else { throw MCPError.responseTooLarge }
      if byte == 10 {
        guard var text = String(data: line, encoding: .utf8) else { throw MCPError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.hasSuffix("\r") { text.removeLast() }
        if text.isEmpty {
          if !eventData.isEmpty {
            let message = try JSONDecoder().decode(JSONValue.self, from: Data(eventData.utf8))
            eventData = ""
            if message.object?["id"]?.string == matchingID {
              return MCPWireResponse(message: message, sessionID: sessionID)
            }
            if let serverRequest = message.object, let requestID = serverRequest["id"],
              let method = serverRequest["method"]?.string
            {
              // Ping is part of the base protocol. Optional server
              // requests were not advertised and receive -32601.
              let response: JSONValue
              if method == "ping" {
                response = .object([
                  "jsonrpc": .string("2.0"), "id": requestID, "result": .object([:]),
                ])
              } else {
                response = .object([
                  "jsonrpc": .string("2.0"), "id": requestID,
                  "error": .object([
                    "code": .number(-32_601), "message": .string("Client capability not supported"),
                  ]),
                ])
              }
              var reply = request
              reply.httpBody = try JSONEncoder().encode(response)
              if let sessionID { reply.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
              let (acknowledgement, ackResponse) = try await session.bytes(for: reply)
              acknowledgement.task.cancel()
              guard (ackResponse as? HTTPURLResponse)?.statusCode == 202 else {
                throw MCPError.invalidResponse
              }
            }
          }
        } else if text.hasPrefix("data:") {
          var field = String(text.dropFirst(5))
          if field.hasPrefix(" ") { field.removeFirst() }
          if !eventData.isEmpty { eventData += "\n" }
          eventData += field
        }
      } else {
        line.append(byte)
      }
    }
    throw MCPError.invalidResponse
  }
}

private struct MCPWireResponse: Sendable {
  let message: JSONValue
  let sessionID: String?
}

/// Redirects can change the token recipient. Require the configured endpoint to
/// be used directly; the user can edit it after inspecting a redirect target.
private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

extension JSONValue {
  fileprivate var object: [String: JSONValue]? {
    if case .object(let value) = self { value } else { nil }
  }
  fileprivate var string: String? { if case .string(let value) = self { value } else { nil } }
  fileprivate var number: Double? { if case .number(let value) = self { value } else { nil } }
  fileprivate var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

/// A deliberately bounded JSON Schema subset. Schemas needing references or
/// pattern evaluation fail closed instead of pretending to validate them.
private enum MCPArgumentValidator {
  static func validate(_ value: JSONValue, schema: JSONValue) throws {
    try checkSupportedSchema(schema)
    try validateValue(value, schema: schema)
  }

  private static func checkSupportedSchema(_ schema: JSONValue, depth: Int = 0) throws {
    guard depth <= 16 else { throw MCPError.invalidArguments("The schema is nested too deeply.") }
    if case .bool = schema { return }
    guard let rule = schema.object else {
      throw MCPError.invalidArguments("The server supplied a malformed schema.")
    }
    let unsupported = [
      "$ref", "$dynamicRef", "$recursiveRef", "pattern", "patternProperties", "not", "if", "then",
      "else",
      "contains", "minContains", "maxContains", "propertyNames", "dependencies",
      "dependentRequired",
      "dependentSchemas", "unevaluatedProperties", "unevaluatedItems", "prefixItems", "multipleOf",
      "uniqueItems",
    ]
    guard !unsupported.contains(where: { rule[$0] != nil }) else {
      throw MCPError.invalidArguments(
        "This tool's schema requires a validator feature this client does not support.")
    }
    if let properties = rule["properties"]?.object {
      guard properties.count <= 256, properties.keys.allSatisfy({ $0.utf8.count <= 256 }) else {
        throw MCPError.invalidArguments("The schema exceeds the property limit.")
      }
      for child in properties.values { try checkSupportedSchema(child, depth: depth + 1) }
    }
    for name in ["items", "additionalProperties"] {
      if let child = rule[name] { try checkSupportedSchema(child, depth: depth + 1) }
    }
    for name in ["allOf", "anyOf", "oneOf"] {
      if let child = rule[name] {
        guard let variants = child.array, !variants.isEmpty, variants.count <= 16 else {
          throw MCPError.invalidArguments("The schema's composition is unsupported.")
        }
        for variant in variants { try checkSupportedSchema(variant, depth: depth + 1) }
      }
    }
  }

  private static func validateValue(
    _ value: JSONValue, schema: JSONValue, path: String = "$", depth: Int = 0
  ) throws {
    if case .bool(let allowed) = schema {
      guard allowed else { throw MCPError.invalidArguments("\(path) is disallowed by the schema.") }
      return
    }
    guard depth <= 16, let rule = schema.object else {
      throw MCPError.invalidArguments("Unsupported schema at \(path).")
    }
    if let choices = rule["enum"]?.array, !choices.contains(value) {
      throw MCPError.invalidArguments("\(path) is outside the allowed values.")
    }
    if let constant = rule["const"], value != constant {
      throw MCPError.invalidArguments("\(path) does not match its required value.")
    }
    if let all = rule["allOf"]?.array {
      for part in all { try validateValue(value, schema: part, path: path, depth: depth + 1) }
    }
    for key in ["anyOf", "oneOf"] {
      if let variants = rule[key]?.array {
        let matches = variants.filter {
          (try? validateValue(value, schema: $0, path: path, depth: depth + 1)) != nil
        }.count
        guard key == "oneOf" ? matches == 1 : matches > 0 else {
          throw MCPError.invalidArguments("\(path) does not match \(key).")
        }
      }
    }
    let types = rule["type"]?.string.map { [$0] } ?? rule["type"]?.array?.compactMap(\.string) ?? []
    if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
      throw MCPError.invalidArguments("\(path) has the wrong type.")
    }
    switch value {
    case .object(let object):
      try bounds(
        Double(object.count), minimum: rule["minProperties"]?.number,
        maximum: rule["maxProperties"]?.number, path: path)
      let required = rule["required"]?.array?.compactMap(\.string) ?? []
      for name in required where object[name] == nil {
        throw MCPError.invalidArguments("\(path).\(name) is required.")
      }
      let properties = rule["properties"]?.object ?? [:]
      for (name, item) in object {
        if let property = properties[name] {
          try validateValue(item, schema: property, path: "\(path).\(name)", depth: depth + 1)
        } else if rule["additionalProperties"] == .bool(false) {
          throw MCPError.invalidArguments("\(path).\(name) is not allowed.")
        } else if let additional = rule["additionalProperties"], additional.object != nil {
          try validateValue(item, schema: additional, path: "\(path).\(name)", depth: depth + 1)
        }
      }
    case .array(let array):
      try bounds(
        Double(array.count), minimum: rule["minItems"]?.number, maximum: rule["maxItems"]?.number,
        path: path)
      if let items = rule["items"] {
        for (index, item) in array.enumerated() {
          try validateValue(item, schema: items, path: "\(path)[\(index)]", depth: depth + 1)
        }
      }
    case .string(let text):
      try bounds(
        Double(text.unicodeScalars.count), minimum: rule["minLength"]?.number,
        maximum: rule["maxLength"]?.number, path: path)
    case .number(let number):
      guard number.isFinite else { throw MCPError.invalidArguments("\(path) is not finite.") }
      try bounds(
        number, minimum: rule["minimum"]?.number, maximum: rule["maximum"]?.number, path: path)
      if let minimum = rule["exclusiveMinimum"]?.number, number <= minimum {
        throw MCPError.invalidArguments("\(path) is below its exclusive minimum.")
      }
      if let maximum = rule["exclusiveMaximum"]?.number, number >= maximum {
        throw MCPError.invalidArguments("\(path) exceeds its exclusive maximum.")
      }
    case .bool, .null: break
    }
  }

  private static func bounds(_ value: Double, minimum: Double?, maximum: Double?, path: String)
    throws
  {
    if let minimum, value < minimum {
      throw MCPError.invalidArguments("\(path) is below its minimum.")
    }
    if let maximum, value > maximum {
      throw MCPError.invalidArguments("\(path) exceeds its maximum.")
    }
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (value, type) {
    case (.object, "object"), (.array, "array"), (.string, "string"), (.bool, "boolean"),
      (.null, "null"), (.number, "number"):
      true
    case (.number(let number), "integer"): number.isFinite && number.rounded() == number
    default: false
    }
  }
}
