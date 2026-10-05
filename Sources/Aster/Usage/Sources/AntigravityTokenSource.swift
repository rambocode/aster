// Antigravity CLI（agy）的本地用量数据源：只读查询 ~/.gemini/antigravity-cli/conversations/*.db。
import AsterCore
import Foundation
import SQLite3

/// 从 agy 的会话库里统计 token 用量。
///
/// 每个会话一个 SQLite 库，列全是 protobuf blob，没有公开的 `.proto`，所以按字段号取数
/// （`ProtobufScan`）。字段号是 2026-10-05 在本机 agy 1.2.16 的 13 个会话库上实测出来的：
///
/// - `steps.metadata`：`1.1` 是这一步的创建时刻（Unix 秒），`9` 是这一步模型调用的用量。
/// - 用量消息：`2` 输入、`3` 输出、`4` 缓存写入、`5` 缓存读取。
/// - `trajectory_metadata_blob`（`id = 'main'`）：`7` 是工作目录的 `file://` URI。
///
/// 口径：`input` 与缓存读取量级脱节（34.5 万对 688 万），说明 **`input` 不含缓存命中**；
/// 全部 168 条记录都满足 `3 == 9 + 10`（思考 + 正文），即 **`output` 已含 reasoning**。
///
/// 读 `steps` 而不是 `gen_metadata`：后者每行带着整次请求的正文（单行约 100 KB），前者只有
/// 几百字节。两边对过账——带用量的 planner 步骤与 `gen_metadata` 逐库零差额；`steps` 另外多出
/// 几条不进 `gen_metadata` 的模型调用（本机 4 条），它们是真实消耗，所以一并计入。
///
/// 只读 CLI 的目录：Antigravity.app 的会话在 `~/.gemini/antigravity/conversations/*.pb`，
/// 是另一种格式，不在这里处理。私有格式随时会变，任何一步读不出来都静默跳过。
public struct AntigravityTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .antigravity

  /// 单个 metadata blob 的上限；实测只有几百字节，超过说明格式变了，跳过不解析。
  static let maximumMetadataBytes = 1 << 20

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let directory = homeDirectory.appendingPathComponent(
      ".gemini/antigravity-cli/conversations", isDirectory: true)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return []
    }
    // 只认 `.db`：同目录下的 `-wal` / `-shm` 由 `sourceFile` 并进主库的缓存身份。
    return names.filter { $0.hasSuffix(".db") }.sorted().compactMap {
      ReadOnlySQLiteDatabase.sourceFile(
        atDatabasePath: directory.appendingPathComponent($0, isDirectory: false).path)
    }
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    // agy 的会话库是 WAL 模式，会话结束后不留 `-wal`：按静止库打开，不往它的目录里建文件。
    guard let database = ReadOnlySQLiteDatabase(quiescentWALDatabaseAtPath: file.path) else {
      return []
    }
    defer { database.close() }

    // 一个库就是一个会话，工作目录全库只有一份。旧版本的库没有这个字段，归到「其他」；
    // 这条查询失败（表不存在）同样只影响项目归属，不影响用量。
    var directory: String?
    _ = database.forEachRow(Self.workingDirectoryQuery) { row in
      directory = Self.workingDirectory(fromTrajectoryMetadata: ReadOnlySQLiteDatabase.bytes(row, 0))
    }
    let project = directory.map { context.projectKey(forWorkingDirectory: $0) }
      ?? TokenProject.otherKey

    var totalsByDay: [Int: TokenTotals] = [:]
    let succeeded = database.forEachRow(Self.stepsQuery) { row in
      let metadata = ReadOnlySQLiteDatabase.bytes(row, 0)
      guard let usage = Self.usage(fromStepMetadata: metadata), !usage.totals.isEmpty else { return }
      // 个别步骤可能没有时间戳：退到库文件的修改时间，好过丢掉这条用量。
      let seconds = usage.epochSeconds ?? Int64(file.modified)
      totalsByDay[context.localDay(forEpochSeconds: seconds), default: TokenTotals()] += usage.totals
    }
    guard succeeded else { return [] }
    return totalsByDay.map { TokenBucket(day: $0.key, project: project, totals: $0.value) }
  }

  /// 从一条 `steps.metadata` 里取用量与创建时刻。纯函数，可单测。
  ///
  /// 不带用量字段（工具调用等步骤）或 blob 畸形时返回 nil。
  static func usage(fromStepMetadata metadata: [UInt8]) -> (
    totals: TokenTotals, epochSeconds: Int64?
  )? {
    guard !metadata.isEmpty, metadata.count <= maximumMetadataBytes,
      let fields = ProtobufScan.fields(metadata[...]),
      let usageBytes = ProtobufScan.bytes(fields, 9),
      let usage = ProtobufScan.fields(usageBytes)
    else { return nil }
    let totals = TokenTotals(
      input: count(usage, 2), cacheWrite: count(usage, 4), cacheRead: count(usage, 5),
      output: count(usage, 3))
    let seconds = ProtobufScan.bytes(fields, 1).flatMap { ProtobufScan.fields($0) }
      .flatMap { ProtobufScan.varint($0, 1) }
      .flatMap { $0 > 0 ? Int64(exactly: $0) : nil }
    return (totals, seconds)
  }

  /// 从 `trajectory_metadata_blob` 的 main 行里取工作目录的本地路径。纯函数，可单测。
  static func workingDirectory(fromTrajectoryMetadata data: [UInt8]) -> String? {
    guard !data.isEmpty, data.count <= maximumMetadataBytes,
      let fields = ProtobufScan.fields(data[...]),
      let raw = ProtobufScan.bytes(fields, 7),
      let text = String(bytes: raw, encoding: .utf8), !text.isEmpty
    else { return nil }
    // 实测是 `file:///…` URI；防御性地也接受裸的绝对路径，其它 scheme（远程工作区）不认。
    if text.hasPrefix("/") { return text }
    guard let url = URL(string: text), url.isFileURL, !url.path.isEmpty else { return nil }
    return url.path
  }

  /// 取一个计数字段；缺失按 0，超出 `Int64` 的异常值也按 0，免得一条坏数据把总数冲爆。
  private static func count(_ fields: [ProtobufScan.Field], _ number: Int) -> Int64 {
    ProtobufScan.varint(fields, number).flatMap { Int64(exactly: $0) } ?? 0
  }

  private static let workingDirectoryQuery =
    "SELECT data FROM trajectory_metadata_blob WHERE id = 'main' LIMIT 1"
  private static let stepsQuery = "SELECT metadata FROM steps WHERE metadata IS NOT NULL"
}
