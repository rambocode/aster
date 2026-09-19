// Hermes 的本地用量数据源：只读查询 ~/.hermes/state.db 的 sessions 表。
import AsterCore
import Foundation
import SQLite3

/// 从 Hermes 的 `state.db` 统计 token 用量。
///
/// `sessions` 表已经把每个会话的四列拆好（`input_tokens` / `output_tokens` /
/// `cache_read_tokens` / `cache_write_tokens`），直接对应统一口径。
/// `reasoning_tokens` 单列存在但**不加进 output**：与 opencode 同理，这类字段在主流 provider
/// 里都是 output 的子集，加了会双计；本机三张相关表都是 0 行，无法实测，按保守口径处理。
///
/// 时间用 `started_at`（REAL，Unix 秒），项目用 `cwd`。
/// db 不存在、表不存在、表为空三种情况都静默返回空数组，不报错也不重试。
public struct HermesTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .hermes

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let path = homeDirectory.appendingPathComponent(".hermes/state.db", isDirectory: false).path
    guard let file = ReadOnlySQLiteDatabase.sourceFile(atDatabasePath: path) else { return [] }
    return [file]
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    guard let database = ReadOnlySQLiteDatabase(path: file.path) else { return [] }
    defer { database.close() }

    var totalsByKey: [BucketKey: TokenTotals] = [:]
    var projectKeys: [String: String] = [:]
    let succeeded = database.forEachRow(Self.query) { row in
      let totals = TokenTotals(
        input: ReadOnlySQLiteDatabase.int64(row, 2),
        cacheWrite: ReadOnlySQLiteDatabase.int64(row, 5),
        cacheRead: ReadOnlySQLiteDatabase.int64(row, 4),
        output: ReadOnlySQLiteDatabase.int64(row, 3))
      guard !totals.isEmpty else { return }
      let day = context.localDay(forEpochSeconds: ReadOnlySQLiteDatabase.int64(row, 0))
      let directory = ReadOnlySQLiteDatabase.text(row, 1) ?? ""
      let project: String
      if directory.isEmpty {
        project = TokenProject.otherKey
      } else if let cached = projectKeys[directory] {
        project = cached
      } else {
        project = context.projectKey(forWorkingDirectory: directory)
        projectKeys[directory] = project
      }
      totalsByKey[BucketKey(day: day, project: project), default: TokenTotals()] += totals
    }
    guard succeeded else { return [] }
    return totalsByKey.map { TokenBucket(day: $0.key.day, project: $0.key.project, totals: $0.value) }
  }

  private struct BucketKey: Hashable {
    var day: Int
    var project: String
  }

  // `started_at` 是 REAL，`sqlite3_column_int64` 会直接截断成秒，正是想要的。
  private static let query = """
    SELECT started_at, cwd, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens
    FROM sessions
    """
}
