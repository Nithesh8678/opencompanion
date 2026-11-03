import Foundation

@main struct AppBridgeSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Supply python3 and native_peer.py paths") }
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("oc-bridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        let bridge = BrowserBridge(socketURL: socket)
        bridge.start()
        guard bridge.running else { fatalError(bridge.status) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        process.arguments = [CommandLine.arguments[2], socket.path]
        try process.run()
        defer { bridge.stop(); if process.isRunning { process.terminate() } }
        for _ in 0..<100 {
            if !bridge.tabs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard bridge.tabs.first?.tabID == 42, bridge.status.contains("Connected") else { fatalError("No true native hello received: \(bridge.status)") }
        let data = try await bridge.request(operation: "snapshot", tabID: 42)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["documentID"] as? String == "native-smoke-document", bridge.lastSnapshot != nil else { fatalError("Snapshot round trip failed") }
        bridge.stop()
        print("PASS: Swift app listener ↔ Unix socket ↔ real native host subprocess ↔ native frames; true handshake and snapshot response.")
    }
}
