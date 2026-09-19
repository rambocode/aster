// OpenCodeTokenSource / HermesTokenSource 的行为测试：夹具库用 SQLite3 C API 现建。
import AsterCore
import Foundation
import SQLite3
import Testing

@testable import Aster

/// 测试用的扫描上下文：固定按 UTC 归日，项目键原样返回。
private final class SQLiteScanContext: TokenScanContext {
  func localDay(forEpochSeconds seconds: Int64) -> Int { Int(floor(Double(seconds) / 86_400)) }
  func projectKey(forWorkingDirectory path: String) -> String { path }
}

/// 一次性的临时目录，析构时整棵删掉。
private final class SQLiteHome {
  let url: URL

  init() {
    url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("aster-token-sqlite-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  /// 在相对路径处建库并执行建表 / 插入语句，返回库文件的绝对路径。
  @discardableResult
  func makeDatabase(at relativePath: String, statements: [String]) -> String {
    let target = url.appendingPathComponent(relativePath)
    try? FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(
        target.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let database = handle
    else { return target.path }
    for statement in statements { sqlite3_exec(database, statement, nil, nil, nil) }
    sqlite3_close_v2(database)
    return target.path
  }

  /// 写入任意文件内容（用于伪造 `-wal` 这类伴生文件）。
  func write(_ contents: String, to relativePath: String) {
    let target = url.appendingPathComponent(relativePath)
    try? FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: target, atomically: true, encoding: .utf8)
  }

  func setModificationDate(_ date: Date, at relativePath: String) {
    try? FileManager.default.setAttributes(
      [.modificationDate: date],
      ofItemAtPath: url.appendingPathComponent(relativePath).path)
  }
}

@Suite("TokenSource opencode 数据库解析")
struct TokenSourceOpenCodeTests {
  private static let databasePath = ".local/share/opencode/opencode.db"

  /// 手写脱敏夹具：两个会话、一条 user 消息、一条无用量消息，外加一张重复的 part 表。
  private func makeHome() -> SQLiteHome {
    let home = SQLiteHome()
    home.makeDatabase(
      at: Self.databasePath,
      statements: [
        "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL)",
        """
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL, data TEXT NOT NULL)
        """,
        "CREATE TABLE part (id TEXT PRIMARY KEY, data TEXT NOT NULL)",
        "INSERT INTO session VALUES ('s-1', '/work/alpha')",
        "INSERT INTO session VALUES ('s-2', '/work/beta')",
        """
        INSERT INTO message VALUES ('m-1', 's-1', 1781976095000,
          '{"role":"assistant","tokens":{"input":100,"output":50,"reasoning":30,
            "cache":{"read":700,"write":40}}}')
        """,
        """
        INSERT INTO message VALUES ('m-2', 's-1', 1781976096000,
          '{"role":"user","tokens":{"input":9999,"output":9999,"reasoning":0,
            "cache":{"read":9999,"write":9999}}}')
        """,
        """
        INSERT INTO message VALUES ('m-3', 's-2', 1782000600000,
          '{"role":"assistant","tokens":{"input":7,"output":3,"reasoning":0,
            "cache":{"read":0,"write":0}}}')
        """,
        "INSERT INTO message VALUES ('m-4', 's-2', 1782000601000, '{\"role\":\"assistant\"}')",
        """
        INSERT INTO part VALUES ('p-1',
          '{"tokens":{"input":100,"output":50,"cache":{"read":700,"write":40}}}')
        """,
      ])
    return home
  }

  @Test("只算 assistant 消息，reasoning 不重复计入 output")
  func countsAssistantMessagesOnly() {
    let home = makeHome()
    let source = OpenCodeTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)

    let buckets = source.buckets(of: files[0], context: SQLiteScanContext())
    let alpha = buckets.first { $0.project == "/work/alpha" }
    // user 那条的 9999 必须完全不出现；reasoning 30 也不能加进 output。
    #expect(alpha?.totals == TokenTotals(input: 100, cacheWrite: 40, cacheRead: 700, output: 50))
    #expect(alpha?.day == 20624)
  }

  @Test("不读 part 表，避免与 message 重复计量")
  func ignoresPartTable() {
    let home = makeHome()
    let source = OpenCodeTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: SQLiteScanContext())
    // part 表里放了与 m-1 相同的一份用量；若被读进来 input 会变成 200。
    #expect(buckets.reduce(into: Int64(0)) { $0 += $1.totals.input } == 107)
  }

  @Test("按会话目录与 time_created 归到项目与本地日")
  func groupsByProjectAndDay() {
    let home = makeHome()
    let source = OpenCodeTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: SQLiteScanContext())
    #expect(buckets.count == 2)
    let beta = buckets.first { $0.project == "/work/beta" }
    #expect(beta?.day == 20625)
    #expect(beta?.totals == TokenTotals(input: 7, output: 3))
  }

  @Test("缓存身份把 -wal 一并计入")
  func identityIncludesWriteAheadLog() {
    let home = makeHome()
    let source = OpenCodeTokenSource()
    let withoutLog = source.discoverFiles(homeDirectory: home.url)[0]

    home.write(String(repeating: "x", count: 512), to: Self.databasePath + "-wal")
    home.setModificationDate(
      Date(timeIntervalSince1970: 2_000_000_000), at: Self.databasePath + "-wal")
    let withLog = source.discoverFiles(homeDirectory: home.url)[0]

    #expect(withLog.path == withoutLog.path)
    #expect(withLog.size == withoutLog.size + 512)
    #expect(withLog.modified == 2_000_000_000)
  }

  @Test("数据库不存在时返回空")
  func missingDatabaseYieldsNothing() {
    let home = SQLiteHome()
    #expect(OpenCodeTokenSource().discoverFiles(homeDirectory: home.url).isEmpty)
  }

  @Test("表结构不符时静默返回空，不抛错")
  func unexpectedSchemaYieldsNothing() {
    let home = SQLiteHome()
    home.makeDatabase(
      at: Self.databasePath, statements: ["CREATE TABLE unrelated (id TEXT PRIMARY KEY)"])
    let source = OpenCodeTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)
    #expect(source.buckets(of: files[0], context: SQLiteScanContext()).isEmpty)
  }
}

@Suite("TokenSource hermes 数据库解析")
struct TokenSourceHermesTests {
  private static let databasePath = ".hermes/state.db"

  private func makeHome(rows: [String]) -> SQLiteHome {
    let home = SQLiteHome()
    home.makeDatabase(
      at: Self.databasePath,
      statements: [
        """
        CREATE TABLE sessions (id TEXT PRIMARY KEY, started_at REAL NOT NULL, cwd TEXT,
          input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
          cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
          reasoning_tokens INTEGER DEFAULT 0)
        """
      ] + rows)
    return home
  }

  @Test("四列直接映射，reasoning 不重复计入 output")
  func mapsSessionColumns() {
    let home = makeHome(rows: [
      "INSERT INTO sessions VALUES ('h-1', 1781976095.5, '/work/alpha', 100, 50, 700, 40, 30)",
      "INSERT INTO sessions VALUES ('h-2', 1782000600.0, NULL, 7, 3, 0, 0, 0)",
    ])
    let source = HermesTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)

    let buckets = source.buckets(of: files[0], context: SQLiteScanContext())
    let alpha = buckets.first { $0.project == "/work/alpha" }
    #expect(alpha?.totals == TokenTotals(input: 100, cacheWrite: 40, cacheRead: 700, output: 50))
    #expect(alpha?.day == 20624)
    // cwd 为空的会话归到「其他」。
    #expect(buckets.first { $0.project == TokenProject.otherKey }?.day == 20625)
  }

  @Test("表为空时静默返回空")
  func emptyTableYieldsNothing() {
    let home = makeHome(rows: [])
    let source = HermesTokenSource()
    #expect(source.buckets(of: source.discoverFiles(homeDirectory: home.url)[0],
      context: SQLiteScanContext()).isEmpty)
  }

  @Test("sessions 表不存在时静默返回空")
  func missingTableYieldsNothing() {
    let home = SQLiteHome()
    home.makeDatabase(at: Self.databasePath, statements: ["CREATE TABLE state_meta (k TEXT)"])
    let source = HermesTokenSource()
    #expect(source.buckets(of: source.discoverFiles(homeDirectory: home.url)[0],
      context: SQLiteScanContext()).isEmpty)
  }

  @Test("数据库不存在时返回空")
  func missingDatabaseYieldsNothing() {
    let home = SQLiteHome()
    #expect(HermesTokenSource().discoverFiles(homeDirectory: home.url).isEmpty)
  }
}
