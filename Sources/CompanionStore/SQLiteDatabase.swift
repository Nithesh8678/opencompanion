import CSQLite
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
  case text(String)
  case integer(Int)
  case real(Double)
  case blob(Data)
  case null
}

/// The handle is accessed only through LocalStore's actor after initialization.
/// FULLMUTEX additionally protects SQLite's connection internals and close.
final class SQLiteDatabase: @unchecked Sendable {
  private var handle: OpaquePointer?

  init(url: URL) throws {
    guard url.isFileURL else { throw StoreError.invalidValue("A local database file is required.") }
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let result = sqlite3_open_v2(
      url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard result == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
      if let handle { sqlite3_close_v2(handle) }
      handle = nil
      throw StoreError.database(code: result, message: message)
    }
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      sqlite3_busy_timeout(handle, 5_000)
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA foreign_keys = ON")
      try execute("PRAGMA secure_delete = ON")
      try execute("PRAGMA synchronous = FULL")
      try migrate()
    } catch {
      if let handle { sqlite3_close_v2(handle) }
      handle = nil
      throw error
    }
  }

  deinit { if let handle { sqlite3_close_v2(handle) } }

  func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW { result = sqlite3_step(statement) }
    guard result == SQLITE_DONE else { throw failure(result) }
  }

  func query<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (OpaquePointer) throws -> T) throws
    -> [T]
  {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    var values: [T] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return values }
      guard result == SQLITE_ROW else { throw failure(result) }
      values.append(try map(statement))
    }
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else { throw failure(result) }
    do {
      for (offset, binding) in bindings.enumerated() {
        let index = Int32(offset + 1)
        let code: Int32
        switch binding {
        case .text(let value):
          code = value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), sqliteTransient)
          }
        case .integer(let value): code = sqlite3_bind_int64(statement, index, Int64(value))
        case .real(let value): code = sqlite3_bind_double(statement, index, value)
        case .blob(let data):
          if data.isEmpty {
            code = sqlite3_bind_zeroblob(statement, index, 0)
          } else {
            code = data.withUnsafeBytes {
              sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient)
            }
          }
        case .null: code = sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else { throw failure(code) }
      }
      return statement
    } catch {
      sqlite3_finalize(statement)
      throw error
    }
  }

  private func failure(_ code: Int32) -> StoreError {
    // Error messages contain no bound values. Callers must not log payloads.
    .database(code: code, message: String(cString: sqlite3_errmsg(handle)))
  }

  private func migrate() throws {
    let version = try query("PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    guard version <= LocalStore.schemaVersion else { throw StoreError.unsupportedSchema(version) }
    if version < 1 {
      try transaction {
        try execute(
          """
          CREATE TABLE records (
              id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
              body TEXT NOT NULL, payload BLOB, created_at REAL NOT NULL, updated_at REAL NOT NULL
          )
          """)
        try execute("CREATE INDEX records_kind_updated ON records(kind, updated_at DESC)")
        try execute("PRAGMA user_version = 1")
      }
    }
    if version < 2 {
      try transaction {
        try execute(
          """
          CREATE TABLE jobs (
              id TEXT PRIMARY KEY NOT NULL, instruction TEXT NOT NULL, scope TEXT NOT NULL,
              checkpoint BLOB, status TEXT NOT NULL, progress REAL NOT NULL DEFAULT 0,
              retry_class TEXT NOT NULL, retry_budget INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
              cancellation_generation INTEGER NOT NULL DEFAULT 0, next_run_at REAL,
              lease_owner TEXT, lease_token TEXT, lease_expires_at REAL, last_error TEXT,
              created_at REAL NOT NULL, updated_at REAL NOT NULL
          )
          """)
        try execute("CREATE INDEX jobs_due ON jobs(status, next_run_at)")
        try execute(
          """
          CREATE TABLE action_receipts (
              id TEXT PRIMARY KEY NOT NULL, job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
              operation TEXT NOT NULL, retry_class TEXT NOT NULL, idempotency_key TEXT,
              status TEXT NOT NULL, result BLOB, created_at REAL NOT NULL, updated_at REAL NOT NULL
          )
          """)
        try execute("CREATE INDEX actions_job ON action_receipts(job_id, created_at)")
        try execute("PRAGMA user_version = 2")
      }
    }
    if version < 3 {
      try transaction {
        try execute(
          """
          CREATE TABLE routines (
              id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, instruction TEXT NOT NULL, scope TEXT NOT NULL,
              interval_seconds REAL NOT NULL, next_run_at REAL NOT NULL, missed_run_policy TEXT NOT NULL,
              enabled INTEGER NOT NULL, last_enqueued_at REAL
          )
          """)
        try execute("PRAGMA user_version = 3")
      }
    }
    if version < 4 {
      try transaction {
        try execute(
          """
          CREATE TABLE deleted_conversations (
              id TEXT PRIMARY KEY NOT NULL, deleted_at REAL NOT NULL
          )
          """)
        try execute("PRAGMA user_version = 4")
      }
    }
  }
}

extension SQLValue {
  static func optional(_ data: Data?) -> SQLValue { data.map(Self.blob) ?? .null }
  static func optional(_ text: String?) -> SQLValue { text.map(Self.text) ?? .null }
  static func optional(_ date: Date?) -> SQLValue {
    date.map { .real($0.timeIntervalSince1970) } ?? .null
  }
}

enum SQLColumn {
  static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, index) else { return "" }
    return String(
      decoding: UnsafeBufferPointer(
        start: pointer, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
  }
  static func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
  }
  static func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: pointer, count: count)
  }
  static func date(_ statement: OpaquePointer, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }
  static func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : date(statement, index)
  }
}
