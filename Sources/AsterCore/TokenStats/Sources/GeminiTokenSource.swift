// Gemini CLI 的本地用量数据源：读取 ~/.gemini/tmp 下各项目的聊天记录。
import Foundation

/// 从 `~/.gemini/tmp/<项目>/chats/session-*.jsonl`（旧版为单个 `.json`）统计 Gemini 的 token 用量。
///
/// 口径（在本机 251 条记录上反推得到）：`tokens` 满足
/// `total == input + output + thoughts + tool`，且 `cached <= input`，
/// 说明 **`input` 已含缓存命中**（要减掉），而 `thoughts`、`tool` 都在 `input`/`output` 之外单列。
/// 对应 Gemini API 的 `usageMetadata`：`tool` 是 `toolUsePromptTokenCount`，属于输入侧，
/// 因此并入 `input`；`thoughts` 属于输出侧，并入 `output`。这样四列之和仍等于 `total`。
/// Gemini 只有隐式缓存、不单列写入量，`cacheWrite` 恒为 0。
public struct GeminiTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .gemini

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let root = homeDirectory.appendingPathComponent(".gemini/tmp", isDirectory: true)
    var files: [TokenSourceFile] = []
    for projectDirectory in JSONLTokenScanner.subdirectories(of: root) {
      let chats = projectDirectory.appendingPathComponent("chats", isDirectory: true)
      for entry in JSONLTokenScanner.entries(of: chats)
      where entry.lastPathComponent.hasPrefix("session-")
        && (entry.pathExtension == "jsonl" || entry.pathExtension == "json") {
        if let file = JSONLTokenScanner.sourceFile(at: entry) { files.append(file) }
      }
    }
    return files
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    var totalsByDay: [Int: TokenTotals] = [:]
    var seenRecordIDs: Set<String> = []
    let accumulate = { (record: [String: Any]) in
      guard record["type"] as? String == "gemini",
        let tokens = JSONLTokenScanner.dictionary(record, "tokens")
      else { return }
      // 同一条消息在文件里会被重写多次（内容相同），按 id 去重后只计一次。
      if let identifier = record["id"] as? String {
        guard seenRecordIDs.insert(identifier).inserted else { return }
      }
      guard let timestamp = record["timestamp"] as? String,
        let seconds = JSONLTokenScanner.epochSeconds(iso8601: timestamp)
      else { return }

      let cacheRead = JSONLTokenScanner.int64(tokens["cached"])
      let prompt = JSONLTokenScanner.int64(tokens["input"])
      let totals = TokenTotals(
        input: max(0, prompt - cacheRead) + JSONLTokenScanner.int64(tokens["tool"]),
        cacheWrite: 0, cacheRead: cacheRead,
        output: JSONLTokenScanner.int64(tokens["output"])
          + JSONLTokenScanner.int64(tokens["thoughts"]))
      guard !totals.isEmpty else { return }
      totalsByDay[context.localDay(forEpochSeconds: seconds), default: TokenTotals()] += totals
    }

    if file.path.hasSuffix(".jsonl") {
      JSONLTokenScanner.forEachLine(inFileAt: file.path) { line in
        guard JSONLTokenScanner.contains(line, Self.tokensMarker),
          let record = JSONLTokenScanner.object(line)
        else { return }
        accumulate(record)
      }
    } else {
      // 旧版把整个会话写成一个 JSON 对象，消息在 `messages` 数组里，字段与新版逐行记录一致。
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)),
        let root = JSONLTokenScanner.object(data),
        let messages = root["messages"] as? [[String: Any]]
      else { return [] }
      for message in messages { accumulate(message) }
    }

    return JSONLTokenScanner.buckets(from: totalsByDay, project: project(of: file, context: context))
  }

  /// 项目真实路径写在 `chats` 同级的 `.project_root` 文件里；读不到就归到「其他」。
  private func project(of file: TokenSourceFile, context: TokenScanContext) -> String {
    let projectDirectory = URL(fileURLWithPath: file.path).deletingLastPathComponent()
      .deletingLastPathComponent()
    let marker = projectDirectory.appendingPathComponent(".project_root", isDirectory: false)
    guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
      return TokenProject.otherKey
    }
    let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/") else { return TokenProject.otherKey }
    return context.projectKey(forWorkingDirectory: path)
  }

  private static let tokensMarker = Array("\"tokens\"".utf8)
}
