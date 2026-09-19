// Pi Agent 的本地用量数据源：读取 ~/.pi/agent/sessions 下的会话 JSONL。
import Foundation

/// 从 `~/.pi/agent/sessions/<cwd-slug>/*.jsonl` 统计 Pi 的 token 用量。
///
/// 口径（在本机数据上反推得到）：每条 `message` 记录的 `usage` 满足
/// `totalTokens == input + output + cacheRead + cacheWrite`，说明 **`input` 不含缓存命中**，
/// 四列可以直接对应。`reasoning` 在 521 条样本中恒 `<= output`，说明 **`output` 已含 reasoning**，
/// 不能再加一次。各条记录是本轮增量（`input` 在会话内上下波动，不是累计值），直接求和。
public struct PiTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .pi

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let root = homeDirectory.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    var files: [TokenSourceFile] = []
    for sessionDirectory in JSONLTokenScanner.subdirectories(of: root) {
      for entry in JSONLTokenScanner.entries(of: sessionDirectory)
      where entry.pathExtension == "jsonl" {
        if let file = JSONLTokenScanner.sourceFile(at: entry) { files.append(file) }
      }
    }
    return files
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    var totalsByDay: [Int: TokenTotals] = [:]
    var seenRecordIDs: Set<String> = []
    var workingDirectory: String?

    JSONLTokenScanner.forEachLine(inFileAt: file.path) { line in
      // 预筛：只有会话头行和带用量的消息行需要解析，其余（工具输出、正文分片）直接跳过。
      // 会话头行只在文件开头出现一次，拿到 cwd 后就不必再为每一行扫这个子串。
      let isSessionHeader =
        workingDirectory == nil && JSONLTokenScanner.contains(line, Self.sessionMarker)
      guard isSessionHeader || JSONLTokenScanner.contains(line, Self.usageMarker) else { return }
      guard let record = JSONLTokenScanner.object(line) else { return }

      if isSessionHeader, record["type"] as? String == "session" {
        if let cwd = record["cwd"] as? String, !cwd.isEmpty { workingDirectory = cwd }
        return
      }
      guard record["type"] as? String == "message",
        let usage = JSONLTokenScanner.dictionary(
          JSONLTokenScanner.dictionary(record, "message"), "usage")
      else { return }
      // 同一条记录可能因为重放或断点续写重复落盘，按记录 id 在文件内去重。
      if let identifier = record["id"] as? String {
        guard seenRecordIDs.insert(identifier).inserted else { return }
      }
      guard let timestamp = record["timestamp"] as? String,
        let seconds = JSONLTokenScanner.epochSeconds(iso8601: timestamp)
      else { return }

      let totals = TokenTotals(
        input: JSONLTokenScanner.int64(usage["input"]),
        cacheWrite: JSONLTokenScanner.int64(usage["cacheWrite"]),
        cacheRead: JSONLTokenScanner.int64(usage["cacheRead"]),
        output: JSONLTokenScanner.int64(usage["output"]))
      guard !totals.isEmpty else { return }
      totalsByDay[context.localDay(forEpochSeconds: seconds), default: TokenTotals()] += totals
    }

    let project = workingDirectory.map(context.projectKey(forWorkingDirectory:))
      ?? TokenProject.otherKey
    return JSONLTokenScanner.buckets(from: totalsByDay, project: project)
  }

  private static let sessionMarker = Array("\"session\"".utf8)
  private static let usageMarker = Array("\"usage\"".utf8)
}
