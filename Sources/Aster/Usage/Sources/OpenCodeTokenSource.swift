// opencode 的本地用量数据源：只读查询 ~/.local/share/opencode/opencode.db。
import AsterCore
import Foundation
import SQLite3

/// 从 opencode 的 SQLite 库里统计 token 用量。
///
/// 口径：`message.data.tokens` 形如 `{"input":…,"output":…,"reasoning":…,"cache":{"read":…,"write":…}}`，
/// `input` 与 `cache.read` 量级完全脱节（1696 对 29184），说明 **`input` 不含缓存命中**。
///
/// `reasoning` **不再加进 `output`**：本机 716 条带 reasoning 的记录里，gpt-5.x 系（694 条、
/// output 合计 50.7 万）恒满足 `reasoning <= output`，即 output 已含 reasoning，再加就是双计；
/// 只有 gemini-3-flash-preview（22 条、output 合计 2211、reasoning 5686）的 output 不含 reasoning。
/// 两害相权：漏算这 22 条约 5.7k token（占 opencode output 总量约 1%），
/// 远好于给主力模型多算 29 万 token。
///
/// 只读 `message` 表：`part` 表里同样带 `tokens`（2469 行），是同一批用量的分片副本，读了会翻倍。
public struct OpenCodeTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .openCode

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let path = homeDirectory.appendingPathComponent(
      ".local/share/opencode/opencode.db", isDirectory: false
    ).path
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
      // `time_created` 是 Unix 毫秒；本地日换算统一交给 context，这里只降到秒。
      let day = context.localDay(forEpochSeconds: ReadOnlySQLiteDatabase.int64(row, 0) / 1000)
      let directory = ReadOnlySQLiteDatabase.text(row, 1) ?? ""
      // 目录到项目键的换算按会话高度重复，先在本地记一份，省掉重复的 git 根查找。
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

  private static let query = """
    SELECT m.time_created, s.directory,
      json_extract(m.data, '$.tokens.input'), json_extract(m.data, '$.tokens.output'),
      json_extract(m.data, '$.tokens.cache.read'), json_extract(m.data, '$.tokens.cache.write')
    FROM message m
    JOIN session s ON s.id = m.session_id
    WHERE json_extract(m.data, '$.role') = 'assistant'
    """
}
