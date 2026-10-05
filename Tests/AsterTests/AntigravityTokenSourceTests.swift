// AntigravityTokenSource 的行为测试：夹具库用 SQLite3 C API 现建，blob 用手写 protobuf 编码。
import AsterCore
import Foundation
import SQLite3
import Testing

@testable import Aster

/// 测试用的扫描上下文：固定按 UTC 归日，项目键原样返回。
private final class AgyScanContext: TokenScanContext {
  func localDay(forEpochSeconds seconds: Int64) -> Int { Int(floor(Double(seconds) / 86_400)) }
  func projectKey(forWorkingDirectory path: String) -> String { path }
}

/// 最小的 protobuf 编码器，只够拼测试夹具。
private enum PB {
  static func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var out: [UInt8] = []
    repeat {
      let byte = UInt8(value & 0x7F)
      value >>= 7
      out.append(value == 0 ? byte : byte | 0x80)
    } while value != 0
    return out
  }

  static func int(_ number: Int, _ value: UInt64) -> [UInt8] {
    varint(UInt64(number << 3)) + varint(value)
  }

  static func bytes(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
    varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload
  }

  /// 一条 `steps.metadata`：创建时刻 + 用量（输入 / 输出 / 缓存写 / 缓存读）。
  static func step(
    at seconds: UInt64?, input: UInt64, output: UInt64, cacheWrite: UInt64 = 0,
    cacheRead: UInt64 = 0
  ) -> [UInt8] {
    let usage =
      int(1, 1320) + int(2, input) + int(3, output) + int(4, cacheWrite) + int(5, cacheRead)
      + bytes(7, Array("bot-1".utf8))
    let created = seconds.map { bytes(1, int(1, $0) + int(2, 501_710_000)) } ?? []
    return created + int(3, 2) + bytes(9, usage) + int(11, 1320)
  }

  /// `trajectory_metadata_blob` 的 main 行：字段 7 是工作目录。
  static func trajectory(workingDirectory: String) -> [UInt8] {
    bytes(3, Array("id".utf8)) + bytes(7, Array(workingDirectory.utf8))
  }

  static func hex(_ bytes: [UInt8]) -> String {
    "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
  }
}

/// 一次性的假 home，析构时整棵删掉。
private final class AgyHome {
  static let conversations = ".gemini/antigravity-cli/conversations"
  let url: URL

  init() {
    url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("aster-agy-token-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url.appendingPathComponent(Self.conversations), withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  /// 建一个会话库。`steps` 为各行的 metadata（nil 表示 NULL），`trajectory` 为 main 行。
  func makeConversation(
    _ name: String, steps: [[UInt8]?], trajectory: [UInt8]? = nil, createTables: Bool = true
  ) {
    let path = url.appendingPathComponent(Self.conversations).appendingPathComponent(name).path
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let database = handle
    else { return }
    // 与真实的会话库一致：WAL 模式，会话结束后不留 `-wal` / `-shm`。系统自带的 SQLite 关闭时
    // 会把这两个文件留下，所以先把 WAL 全部合进主库，关闭后再手动删掉。
    defer {
      sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
      sqlite3_close_v2(database)
      for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    sqlite3_exec(database, "PRAGMA journal_mode=WAL", nil, nil, nil)
    guard createTables else {
      sqlite3_exec(database, "CREATE TABLE unrelated (k TEXT)", nil, nil, nil)
      return
    }
    var statements = [
      "CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer, metadata blob)",
      "CREATE TABLE trajectory_metadata_blob (id text PRIMARY KEY, data blob)",
    ]
    for (index, metadata) in steps.enumerated() {
      let value = metadata.map(PB.hex) ?? "NULL"
      statements.append("INSERT INTO steps VALUES (\(index), 15, \(value))")
    }
    if let trajectory {
      statements.append("INSERT INTO trajectory_metadata_blob VALUES ('main', \(PB.hex(trajectory)))")
    }
    for statement in statements { sqlite3_exec(database, statement, nil, nil, nil) }
  }
}

@Suite("TokenSource Antigravity CLI 会话库解析")
struct AntigravityTokenSourceTests {
  @Test("按步骤时间归日、按会话工作目录归项目，四列直接映射")
  func mapsStepUsage() throws {
    let home = AgyHome()
    home.makeConversation(
      "a.db",
      steps: [
        PB.step(at: 1_781_976_095, input: 100, output: 50, cacheWrite: 40, cacheRead: 700),
        // 工具调用步骤：没有用量字段，不计。
        PB.bytes(1, PB.int(1, 1_781_976_096)) + PB.int(3, 2),
        nil,
        PB.step(at: 1_781_976_099, input: 1, output: 2, cacheRead: 3),
        // 跨到第二天。
        PB.step(at: 1_782_000_600, input: 7, output: 3),
      ],
      trajectory: PB.trajectory(workingDirectory: "file:///work/alpha%20one"))
    let source = AntigravityTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)

    let buckets = source.buckets(of: files[0], context: AgyScanContext())
      .sorted { $0.day < $1.day }
    #expect(buckets.map(\.day) == [20624, 20625])
    #expect(buckets.allSatisfy { $0.project == "/work/alpha one" })
    #expect(buckets[0].totals == TokenTotals(input: 101, cacheWrite: 40, cacheRead: 703, output: 52))
    #expect(buckets[1].totals == TokenTotals(input: 7, output: 3))
  }

  @Test("每个会话库是一个独立文件；没有工作目录的旧库归到「其他」")
  func oneFilePerConversationAndMissingDirectory() {
    let home = AgyHome()
    home.makeConversation(
      "a.db", steps: [PB.step(at: 1_781_976_095, input: 5, output: 1)],
      trajectory: PB.trajectory(workingDirectory: "/work/beta"))
    home.makeConversation("b.db", steps: [PB.step(at: 1_781_976_095, input: 9, output: 2)])
    let source = AntigravityTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.map { ($0.path as NSString).lastPathComponent } == ["a.db", "b.db"])

    let first = source.buckets(of: files[0], context: AgyScanContext())
    #expect(first.map(\.project) == ["/work/beta"])
    let second = source.buckets(of: files[1], context: AgyScanContext())
    #expect(second.map(\.project) == [TokenProject.otherKey])
    #expect(second.first?.totals == TokenTotals(input: 9, output: 2))
  }

  // WAL 库在只读目录里没法建 `-shm`，普通只读连接会直接打不开；静止库必须仍然读得出来。
  @Test("会话目录不可写时仍能读出静止的 WAL 库，且不留伴生文件")
  func readsQuiescentWALDatabaseInReadOnlyDirectory() throws {
    let home = AgyHome()
    home.makeConversation("a.db", steps: [PB.step(at: 1_781_976_095, input: 5, output: 1)])
    let directory = home.url.appendingPathComponent(AgyHome.conversations).path
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
    }
    let source = AntigravityTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(source.buckets(of: files[0], context: AgyScanContext()).map(\.totals)
      == [TokenTotals(input: 5, output: 1)])
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["a.db"])
  }

  @Test("步骤没有时间戳时退到库文件的修改时间")
  func missingTimestampFallsBackToFileModificationDate() {
    let home = AgyHome()
    home.makeConversation("a.db", steps: [PB.step(at: nil, input: 5, output: 1)])
    let source = AntigravityTokenSource()
    var file = source.discoverFiles(homeDirectory: home.url)[0]
    file.modified = 1_782_000_600
    #expect(source.buckets(of: file, context: AgyScanContext()).map(\.day) == [20625])
  }

  @Test("畸形 blob 整条跳过，不影响其它步骤")
  func malformedBlobIsSkipped() {
    let home = AgyHome()
    home.makeConversation(
      "a.db",
      steps: [
        [0x4A, 0x7F, 0x01],  // 字段 9 声明的长度超过剩余字节
        [0xFF, 0xFF, 0xFF],
        PB.step(at: 1_781_976_095, input: 5, output: 1),
      ])
    let source = AntigravityTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: AgyScanContext())
    #expect(buckets.map(\.totals) == [TokenTotals(input: 5, output: 1)])
  }

  @Test("表不存在、目录不存在、非 db 文件都静默返回空")
  func missingDataYieldsNothing() {
    let empty = AgyHome()
    try? FileManager.default.removeItem(at: empty.url.appendingPathComponent(".gemini"))
    #expect(AntigravityTokenSource().discoverFiles(homeDirectory: empty.url).isEmpty)

    let home = AgyHome()
    home.makeConversation("a.db", steps: [], createTables: false)
    try? "x".write(
      to: home.url.appendingPathComponent(AgyHome.conversations).appendingPathComponent("notes.txt"),
      atomically: true, encoding: .utf8)
    let source = AntigravityTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)
    #expect(source.buckets(of: files[0], context: AgyScanContext()).isEmpty)
  }

  @Test("工作目录只认 file:// URI 与裸绝对路径")
  func workingDirectoryParsing() {
    func parse(_ text: String) -> String? {
      AntigravityTokenSource.workingDirectory(
        fromTrajectoryMetadata: PB.trajectory(workingDirectory: text))
    }
    #expect(parse("file:///Users/me/code") == "/Users/me/code")
    #expect(parse("/Users/me/code") == "/Users/me/code")
    #expect(parse("vscode-remote://ssh/host/code") == nil)
    #expect(parse("") == nil)
    #expect(AntigravityTokenSource.workingDirectory(fromTrajectoryMetadata: []) == nil)
  }

  // 真机对账：`ASTER_AGY_TOKEN_SMOKE=1` 时读本机真实会话库，把四列总数打出来人工比对。
  @Test(
    "真机冒烟：汇总本机 agy 会话库",
    .enabled(if: ProcessInfo.processInfo.environment["ASTER_AGY_TOKEN_SMOKE"] == "1"))
  func liveSmoke() {
    let source = AntigravityTokenSource()
    let files = source.discoverFiles(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    var totals = TokenTotals()
    var readable = 0
    for file in files {
      let buckets = source.buckets(of: file, context: AgyScanContext())
      if !buckets.isEmpty { readable += 1 }
      for bucket in buckets { totals += bucket.totals }
    }
    print("AGY_TOKEN_SMOKE files=\(files.count) readable=\(readable) totals=\(totals)")
  }
}
