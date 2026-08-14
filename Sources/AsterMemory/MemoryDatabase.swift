import Foundation
import SQLite3

/// SQLite 错误的领域包装：携带操作名与底层 message，不携带用户数据。
public struct MemoryDatabaseError: Error, CustomStringConvertible {
  public let operation: String
  public let code: Int32
  public let message: String

  public var description: String { "\(operation) failed (\(code)): \(message)" }
}

/// `SQLITE_TRANSIENT`：告知 SQLite 立即拷贝绑定的文本，允许 Swift 字符串离开作用域。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 系统 libsqlite3 的薄封装：open/exec/prepare/bind/step 与事务。
/// 非 Sendable —— 连接只能被创建它的 actor / 线程独占使用，这是仓库的单写者约定。
public final class MemoryDatabase {
  private var handle: OpaquePointer?

  /// 打开数据库。写连接启用 WAL 与外键；只读连接供 MCP server 使用，
  /// 不触发任何写操作（包括 PRAGMA journal_mode 变更）。
  public init(path: String, readOnly: Bool = false) throws {
    let flags =
      readOnly
      ? SQLITE_OPEN_READONLY
      : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(path, &db, flags, nil)
    guard rc == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
      if let db { sqlite3_close_v2(db) }
      throw MemoryDatabaseError(operation: "open", code: rc, message: message)
    }
    handle = db
    // busy_timeout 让并发读端（MCP）在 checkpoint 间隙自动重试而非立即失败。
    sqlite3_busy_timeout(db, 2_000)
    if !readOnly {
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA foreign_keys=ON")
      try execute("PRAGMA synchronous=NORMAL")
    }
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  /// 执行不带参数的 SQL（DDL/PRAGMA/事务控制）。
  public func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    guard rc == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(errorMessage)
      throw MemoryDatabaseError(operation: "exec", code: rc, message: message)
    }
  }

  /// 绑定值：spike 只需要文本、整数、实数与 NULL 四类。
  public enum Value: Sendable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
  }

  /// 执行带参数的写语句。
  public func run(_ sql: String, _ values: [Value]) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    let rc = sqlite3_step(statement)
    guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
      throw MemoryDatabaseError(
        operation: "step", code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  /// 查询：把每行映射为按列序的可选值数组。列类型按取值时的实际类型转换，
  /// spike 的查询面小，不需要类型化 Row 模型。
  public func query(_ sql: String, _ values: [Value] = []) throws -> [[Value?]] {
    let statement = try prepare(sql, values)
    defer { sqlite3_finalize(statement) }
    var rows: [[Value?]] = []
    while true {
      let rc = sqlite3_step(statement)
      if rc == SQLITE_DONE { break }
      guard rc == SQLITE_ROW else {
        throw MemoryDatabaseError(
          operation: "query", code: rc, message: String(cString: sqlite3_errmsg(handle)))
      }
      let columnCount = sqlite3_column_count(statement)
      var row: [Value?] = []
      row.reserveCapacity(Int(columnCount))
      for index in 0..<columnCount {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
          row.append(nil)
        case SQLITE_INTEGER:
          row.append(.integer(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
          row.append(.real(sqlite3_column_double(statement, index)))
        default:
          if let text = sqlite3_column_text(statement, index) {
            row.append(.text(String(cString: text)))
          } else {
            row.append(nil)
          }
        }
      }
      rows.append(row)
    }
    return rows
  }

  /// 在单个事务中执行一批写操作；任一失败即回滚，保证事件批的原子性。
  public func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// 读取 `PRAGMA user_version`，用于迁移与 MCP 侧的 schema 握手。
  public func userVersion() throws -> Int {
    guard case .integer(let value)?? = try query("PRAGMA user_version").first?.first else {
      return 0
    }
    return Int(value)
  }

  private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard rc == SQLITE_OK, let statement else {
      throw MemoryDatabaseError(
        operation: "prepare", code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let bindResult: Int32
      switch value {
      case .text(let text):
        bindResult = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
      case .integer(let integer):
        bindResult = sqlite3_bind_int64(statement, index, integer)
      case .real(let real):
        bindResult = sqlite3_bind_double(statement, index, real)
      case .null:
        bindResult = sqlite3_bind_null(statement, index)
      }
      guard bindResult == SQLITE_OK else {
        sqlite3_finalize(statement)
        throw MemoryDatabaseError(
          operation: "bind", code: bindResult,
          message: String(cString: sqlite3_errmsg(handle)))
      }
    }
    return statement
  }
}
