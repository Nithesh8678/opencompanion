import Combine
import Darwin
import Foundation

struct BrowserTab: Identifiable, Codable, Sendable {
  let tabID: Int
  let title: String
  let url: String
  let origin: String
  let allowActions: Bool
  var id: Int { tabID }
}

enum BrowserBridgeError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let message) = self { message } else { "Browser bridge failed." }
  }
}

/// Owns only the local IPC endpoint. A connected browser tab is a separate,
/// explicit permission granted from the extension popup.
@MainActor final class BrowserBridge: ObservableObject {
  @Published private(set) var status = "Stopped"
  @Published private(set) var tabs: [BrowserTab] = []
  @Published private(set) var lastSnapshot: Data?
  @Published private(set) var running = false
  private var transport: BrowserSocketTransport?
  private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
  private var timeouts: [String: Task<Void, Never>] = [:]
  private var generation: UInt64 = 0
  private let socketPath: String

  init(socketURL: URL? = nil) {
    socketPath =
      (socketURL
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/OpenCompanion/browser.sock")).path
  }

  func start() {
    guard transport == nil else { return }
    generation &+= 1
    let current = generation
    let path = socketPath
    let socket = BrowserSocketTransport()
    do {
      try socket.start(
        path: path,
        receive: { [weak self] data in
          Task { @MainActor in
            guard let self, self.generation == current else { return }
            self.receive(data)
          }
        },
        disconnected: { [weak self] in
          Task { @MainActor in
            guard let self, self.generation == current else { return }
            self.tabs = []
            self.status = "Listening · extension disconnected"
            self.failPending(
              "Browser disconnected. An action already dispatched may have an unknown outcome.")
          }
        })
      transport = socket
      running = true
      status = "Listening · connect a tab in the extension"
    } catch {
      status = error.localizedDescription
      running = false
    }
  }

  func stop() {
    generation &+= 1
    transport?.stop()
    transport = nil
    running = false
    tabs = []
    lastSnapshot = nil
    failPending("Browser bridge stopped. Inspect the page before retrying an interrupted action.")
    status = "Stopped"
  }

  /// Payload/results are encoded JSON Data so untyped dictionaries never cross
  /// isolation boundaries. The extension validates action refs and revisions.
  func request(operation: String, tabID: Int, payload: Data = Data("{}".utf8)) async throws -> Data
  {
    guard let transport else { throw BrowserBridgeError.message("Start the browser bridge first.") }
    guard tabs.contains(where: { $0.tabID == tabID }) else {
      throw BrowserBridgeError.message("Connect this tab in the extension popup first.")
    }
    guard ["snapshot", "act", "navigate", "capture", "stop"].contains(operation) else {
      throw BrowserBridgeError.message("Unsupported browser operation.")
    }
    guard pending.count < 4 else { throw BrowserBridgeError.message("Browser queue is full.") }
    let object = try JSONSerialization.jsonObject(with: payload)
    guard object is [String: Any] else {
      throw BrowserBridgeError.message("Browser payload must be an object.")
    }
    let requestID = UUID().uuidString
    let data = try JSONSerialization.data(withJSONObject: [
      "protocolVersion": 1, "type": "browser.request", "requestID": requestID,
      "operation": operation, "tabID": tabID, "payload": object,
    ])
    guard data.count < 1_048_576 else {
      throw BrowserBridgeError.message("Browser request exceeds 1 MiB.")
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending[requestID] = continuation
        timeouts[requestID] = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          self?.finish(
            requestID,
            result: .failure(
              BrowserBridgeError.message(
                "Browser request timed out. Do not retry an action until its outcome is observed."))
          )
          self?.stop()
        }
        transport.send(data) { [weak self] error in
          guard let error else { return }
          Task { @MainActor in
            self?.finish(requestID, result: .failure(BrowserBridgeError.message(error)))
          }
        }
      }
    } onCancel: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.finish(requestID, result: .failure(CancellationError()))
        // Drop the socket to invalidate queued work and force an explicit
        // extension reconnect. Already-dispatched effects remain unknown.
        self.stop()
      }
    }
  }

  private func receive(_ data: Data) {
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["protocolVersion"] as? Int == 1
      else { throw BrowserBridgeError.message("Invalid browser envelope.") }
      switch object["type"] as? String {
      case "browser.hello":
        guard let values = object["tabs"] as? [[String: Any]], values.count <= 100 else {
          throw BrowserBridgeError.message("Invalid browser tab list.")
        }
        tabs = try JSONDecoder().decode(
          [BrowserTab].self, from: JSONSerialization.data(withJSONObject: values))
        status =
          tabs.isEmpty
          ? "Connected · no tabs scoped"
          : "Connected · \(tabs.count) scoped tab\(tabs.count == 1 ? "" : "s")"
      case "browser.result":
        guard let id = object["requestID"] as? String, pending[id] != nil else { return }
        if object["ok"] as? Bool == true, let value = object["result"] {
          let result = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
          if let dictionary = value as? [String: Any] {
            if let snapshot = dictionary["snapshot"] {
              lastSnapshot = try JSONSerialization.data(
                withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            } else if dictionary["documentID"] != nil {
              lastSnapshot = try JSONSerialization.data(
                withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
            }
          }
          finish(id, result: .success(result))
        } else {
          let error = object["error"] as? [String: Any]
          finish(
            id,
            result: .failure(
              BrowserBridgeError.message(error?["message"] as? String ?? "Browser request failed."))
          )
        }
      default: throw BrowserBridgeError.message("Unsupported browser message.")
      }
    } catch { status = error.localizedDescription }
  }
  private func finish(_ id: String, result: Result<Data, any Error>) {
    timeouts.removeValue(forKey: id)?.cancel()
    pending.removeValue(forKey: id)?.resume(with: result)
  }
  private func failPending(_ message: String) {
    for id in Array(pending.keys) {
      finish(id, result: .failure(BrowserBridgeError.message(message)))
    }
  }
}

/// Blocking Unix IO stays off the main actor. Descriptor access is locked; send
/// duplicates a descriptor so accept/close cannot accidentally reuse its number.
private final class BrowserSocketTransport: @unchecked Sendable {
  private let lock = NSLock()
  private let writes = DispatchQueue(label: "org.opencompanion.browser.write")
  private var listener: Int32 = -1
  private var client: Int32 = -1
  private var path: String?

  func start(
    path: String, receive: @escaping @Sendable (Data) -> Void,
    disconnected: @escaping @Sendable () -> Void
  ) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var directoryInfo = stat()
    guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
      (directoryInfo.st_mode & S_IFMT) == S_IFDIR
    else {
      throw BrowserBridgeError.message("Browser socket directory must be owned by this user.")
    }
    guard chmod(directory.path, 0o700) == 0 else {
      throw BrowserBridgeError.message("Could not secure browser socket directory.")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw BrowserBridgeError.message("Browser socket path is too long for macOS.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
    }
    var existing = stat()
    if lstat(path, &existing) == 0 {
      guard existing.st_uid == getuid(), (existing.st_mode & S_IFMT) == S_IFSOCK else {
        throw BrowserBridgeError.message("Refusing to replace an unexpected browser socket path.")
      }
      let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
      let alive = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
      }
      Darwin.close(probe)
      guard !alive else {
        throw BrowserBridgeError.message("Another app instance already owns the browser bridge.")
      }
      Darwin.unlink(path)
    }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw BrowserBridgeError.message("Could not create browser socket.")
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 1) == 0 else {
      Darwin.close(descriptor)
      Darwin.unlink(path)
      throw BrowserBridgeError.message("Could not bind browser socket.")
    }
    lock.lock()
    listener = descriptor
    self.path = path
    lock.unlock()
    DispatchQueue.global(qos: .utility).async { [self] in
      while true {
        lock.lock()
        let active = listener == descriptor
        lock.unlock()
        guard active else { break }
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { break }
        lock.lock()
        let stillActive = listener == descriptor
        lock.unlock()
        guard stillActive else {
          Darwin.close(peer)
          break
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(peer, &uid, &gid) == 0, uid == getuid() else {
          Darwin.close(peer)
          continue
        }
        var noSignal: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        lock.lock()
        client = peer
        lock.unlock()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        readLoop: while true {
          let count = Darwin.read(peer, &chunk, chunk.count)
          if count <= 0 { break }
          buffer.append(contentsOf: chunk.prefix(count))
          while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty, line.count < 1_048_576 else { break readLoop }
            receive(line)
          }
          if buffer.count >= 1_048_576 { break }
        }
        lock.lock()
        if client == peer { client = -1 }
        lock.unlock()
        Darwin.close(peer)
        disconnected()
      }
    }
  }

  func send(_ data: Data, completion: @escaping @Sendable (String?) -> Void) {
    writes.async { [self] in
      lock.lock()
      let descriptor = client >= 0 ? Darwin.dup(client) : -1
      lock.unlock()
      guard descriptor >= 0 else {
        completion("The browser extension is disconnected.")
        return
      }
      defer { Darwin.close(descriptor) }
      let framed = data + Data([10])
      let success = framed.withUnsafeBytes { bytes -> Bool in
        var sent = 0
        while sent < bytes.count {
          let count = Darwin.write(
            descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
          if count <= 0 { return false }
          sent += count
        }
        return true
      }
      completion(
        success
          ? nil
          : "Browser socket write failed. An interrupted action needs observation before retry.")
    }
  }

  func stop() {
    lock.lock()
    let server = listener
    let peer = client
    let file = path
    listener = -1
    client = -1
    path = nil
    lock.unlock()
    if peer >= 0 { Darwin.shutdown(peer, SHUT_RDWR) }  // reader owns close
    if server >= 0 {
      Darwin.shutdown(server, SHUT_RDWR)
      Darwin.close(server)
    }
    if let file { Darwin.unlink(file) }
  }
  deinit { stop() }
}
