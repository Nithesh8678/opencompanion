import CompanionCore
import CompanionStore
import Foundation
import Testing
@testable import OpenCompanion

@Suite(.serialized)
struct ProductivityRuntimeTests {
    @Test func mcpNegotiatesPaginatesAndValidatesBeforeInvocation() async throws {
        let fixture = MCPFixture()
        let client = fixture.client()
        let tools = try await client.connect()
        #expect(tools.map(\.name) == ["counter", "echo"])
        let state = await client.capabilityState()
        #expect(state.status == .connected)
        #expect(state.serverName == "Local fixture")
        #expect(fixture.methods() == ["initialize", "notifications/initialized", "tools/list", "tools/list"])
        #expect(fixture.requests().dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Mcp-Session-Id") == "test-session" })
        let before = fixture.methods().count
        let invalid: [JSONValue] = [.object(["count": .string("wrong")]), .object(["count": .number(-1)]),
                                    .object([:]), .object(["count": .number(2), "unexpected": .bool(true)])]
        for arguments in invalid {
            do {
                _ = try await client.callTool(name: "counter", arguments: arguments)
                Issue.record("Invalid arguments should be rejected before a request is sent.")
            } catch MCPError.invalidArguments { }
        }
        #expect(fixture.methods().count == before)
        let result = try await client.callTool(name: "counter", arguments: .object(["count": .number(2)]))
        let data = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["isError"] as? Bool == false)
        #expect(fixture.methods().last == "tools/call")
        try await client.disconnect()
        #expect(await client.capabilityState().status == .disconnected)
    }

    @Test func mcpAcceptsSSEAndStopsOnMatchingResponse() async throws {
        let fixture = MCPFixture(sse: true)
        let client = fixture.client()
        #expect(try await client.connect().count == 2)
        #expect(await client.capabilityState().protocolVersion == "2025-06-18")
        let pingReplies = fixture.requests().compactMap { $0.httpBody }.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { $0["id"] as? String == "server-ping" && $0["result"] != nil }
        #expect(pingReplies.count == 3)
        try await client.disconnect()
    }

    @Test func mcpSessionExpiryDoesNotReplayAnAction() async throws {
        let fixture = MCPFixture(expireCall: true)
        let client = fixture.client()
        _ = try await client.connect()
        do {
            _ = try await client.callTool(name: "counter", arguments: .object(["count": .number(2)]))
            Issue.record("Expired sessions must be surfaced without replay.")
        } catch MCPError.sessionExpired { }
        #expect(fixture.methods().filter { $0 == "tools/call" }.count == 1)
        #expect(await client.capabilityState().status == .failed)
    }

    @Test func mcpCancellationReachesTransportAndServer() async throws {
        let fixture = MCPFixture(slowCall: true)
        let client = fixture.client()
        _ = try await client.connect()
        let request = Task { try await client.callTool(name: "counter", arguments: .object(["count": .number(2)])) }
        for _ in 0..<100 {
            if fixture.methods().contains("tools/call") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.methods().contains("tools/call"))
        request.cancel()
        do { _ = try await request.value; Issue.record("Cancelled call unexpectedly succeeded.") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        for _ in 0..<100 {
            if fixture.methods().contains("notifications/cancelled") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.methods().contains("notifications/cancelled"))
    }

    @Test func unsupportedSchemaIsRejectedBeforeNetworkInvocation() async throws {
        let fixture = MCPFixture(unsupportedSchema: true)
        let client = fixture.client()
        _ = try await client.connect()
        let before = fixture.methods().count
        do {
            _ = try await client.callTool(name: "counter", arguments: .object(["count": .number(2)]))
            Issue.record("Unsupported schema validation must fail closed.")
        } catch MCPError.invalidArguments { }
        #expect(fixture.methods().count == before)
    }

    @Test func mcpDeadlineIsBoundedAndSendsCancellation() async throws {
        let fixture = MCPFixture(slowCall: true)
        let client = fixture.client(timeout: 1)
        _ = try await client.connect()
        let started = ContinuousClock.now
        do {
            _ = try await client.callTool(name: "counter", arguments: .object(["count": .number(2)]))
            Issue.record("The slow fixture unexpectedly completed before its deadline.")
        } catch MCPError.timeout { }
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(fixture.methods().contains("notifications/cancelled"))
    }

    @MainActor @Test func restartingSchedulerConfigurationPreservesActiveWork() async throws {
        let url = runtimeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalStore(url: url)
        let job = try await store.enqueueJob(instruction: "Complete the first request", scope: "local", retryClass: .idempotent)
        let runner = JobRunner()
        defer { runner.stop() }
        runner.start(store: store, executor: { _ in try await Task.sleep(for: .milliseconds(150)); return Data("first".utf8) }, onChange: { _ in })
        for _ in 0..<100 {
            if try await store.job(id: job.id).status == .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        runner.start(store: store, executor: { _ in Data("second".utf8) }, onChange: { _ in })
        for _ in 0..<100 {
            if try await store.job(id: job.id).status == .succeeded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let completed = try await store.job(id: job.id)
        #expect(completed.status == .succeeded)
        #expect(completed.checkpoint == Data("first".utf8))
    }

    @MainActor @Test func jobRunnerPersistsTheActualResult() async throws {
        let url = runtimeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalStore(url: url)
        let job = try await store.enqueueJob(instruction: "Read selected notes", scope: "notes", retryClass: .idempotent)
        let runner = JobRunner()
        defer { runner.stop() }
        runner.start(store: store, executor: { _ in Data("Actual completed result".utf8) }, onChange: { _ in })
        for _ in 0..<100 {
            if try await store.job(id: job.id).status == .succeeded { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = try await store.job(id: job.id)
        #expect(completed.status == .succeeded)
        #expect(completed.progress == 1)
        #expect(completed.checkpoint == Data("Actual completed result".utf8))
        #expect(try await store.actionReceipts(jobID: job.id).first?.status == .succeeded)
    }

    @MainActor @Test func jobRunnerCancellationStopsTheExecutor() async throws {
        let url = runtimeStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalStore(url: url)
        let job = try await store.enqueueJob(instruction: "Wait for bounded work", scope: "local", retryClass: .idempotent)
        let runner = JobRunner()
        defer { runner.stop() }
        runner.start(store: store, executor: { _ in try await Task.sleep(for: .seconds(30)); return Data() }, onChange: { _ in })
        for _ in 0..<100 {
            if try await store.job(id: job.id).status == .running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await runner.cancel(jobID: job.id)
        for _ in 0..<100 {
            if try await store.job(id: job.id).status == .cancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.job(id: job.id).status == .cancelled)
        #expect(try await store.job(id: job.id).checkpoint == nil)
    }
}

private func runtimeStoreURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("OpenCompanionRuntime-\(UUID().uuidString)").appendingPathComponent("store.sqlite")
}

private final class MCPFixture: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var received: [URLRequest] = []
    let sse: Bool
    let expireCall: Bool
    let slowCall: Bool
    let unsupportedSchema: Bool

    init(sse: Bool = false, expireCall: Bool = false, slowCall: Bool = false, unsupportedSchema: Bool = false) {
        url = URL(string: "https://mcp-fixture.invalid/\(UUID().uuidString)")!
        self.sse = sse
        self.expireCall = expireCall
        self.slowCall = slowCall
        self.unsupportedSchema = unsupportedSchema
        MCPFixtureRegistry.shared.register(self)
    }

    func client(timeout: TimeInterval = 45) -> MCPClient {
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [MCPFixtureProtocol.self]
        let configuration = MCPConfiguration(name: "Local test fixture", url: url, account: "fixture")
        return MCPClient(configuration: configuration, session: URLSession(configuration: options), requestTimeout: timeout, credentialLoader: { nil })
    }

    func requests() -> [URLRequest] { lock.withLock { received } }
    func methods() -> [String] {
        requests().compactMap { request in
            guard let data = request.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["method"] as? String
        }
    }

    func response(to request: URLRequest) throws -> (Int, [String: String], Data, Bool) {
        lock.withLock { received.append(request) }
        if request.httpMethod == "DELETE" { return (204, [:], Data(), false) }
        guard let body = request.httpBody, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw URLError(.badServerResponse) }
        if object["method"] == nil, object["id"] != nil, object["result"] != nil { return (202, [:], Data(), false) }
        guard let method = object["method"] as? String else { throw URLError(.badServerResponse) }
        if method.hasPrefix("notifications/") { return (202, [:], Data(), false) }
        let id = object["id"] as? String ?? "missing"
        let result: [String: Any]
        switch method {
        case "initialize": result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "Local fixture", "version": "1"]]
        case "tools/list":
            let params = object["params"] as? [String: Any]
            if params?["cursor"] == nil {
                var countSchema: [String: Any] = ["type": "integer", "minimum": 0]
                if unsupportedSchema { countSchema["multipleOf"] = 2 }
                result = ["tools": [["name": "counter", "inputSchema": ["type": "object", "properties": ["count": countSchema], "required": ["count"], "additionalProperties": false]]], "nextCursor": "second-page"]
            } else { result = ["tools": [["name": "echo", "inputSchema": ["type": "object"]]]] }
        case "tools/call":
            if expireCall { return (404, ["Content-Type": "application/json"], Data(), false) }
            result = ["content": [["type": "text", "text": "Observed fixture result"]], "isError": false]
        default: throw URLError(.badServerResponse)
        }
        let payload = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result], options: [.sortedKeys])
        var headers = ["Content-Type": sse ? "text/event-stream" : "application/json"]
        if method == "initialize" { headers["Mcp-Session-Id"] = "test-session" }
        if sse {
            let progress = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n"
            let ping = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"server-ping\",\"method\":\"ping\"}\n\n"
            let stream = progress + ping + "event: message\ndata: " + String(decoding: payload, as: UTF8.self) + "\n\n"
            return (200, headers, Data(stream.utf8), slowCall && method == "tools/call")
        }
        return (200, headers, payload, slowCall && method == "tools/call")
    }
}

private final class MCPFixtureRegistry: @unchecked Sendable {
    static let shared = MCPFixtureRegistry()
    private let lock = NSLock()
    private var fixtures: [URL: MCPFixture] = [:]
    func register(_ fixture: MCPFixture) { lock.withLock { fixtures[fixture.url] = fixture } }
    func fixture(for url: URL) -> MCPFixture? { lock.withLock { fixtures[url] } }
}

private final class MCPFixtureProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mcp-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let fixture = MCPFixtureRegistry.shared.fixture(for: url) else { throw URLError(.unsupportedURL) }
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                    guard body.count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                }
                captured.httpBody = body
            }
            let (status, headers, data, slow) = try fixture.response(to: captured)
            let task = Task { @Sendable [self] in
                do {
                    if slow { try await Task.sleep(for: .seconds(10)) }
                    try Task.checkCancellation()
                    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
                    client?.urlProtocolDidFinishLoading(self)
                } catch { }
            }
            lock.withLock { work = task }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { lock.withLock { work?.cancel(); work = nil } }
}
