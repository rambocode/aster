// Grok Build 的本地用量数据源：读取 ~/.grok/sessions 下的会话事件流。
import Foundation

/// 从 `~/.grok/sessions/<percent-encoded-cwd>/<uuid>/updates.jsonl` 统计 Grok Build 的 token 用量。
///
/// 口径（在本机数据上反推得到）：`turn_completed` 的 usage 满足
/// `totalTokens == inputTokens + outputTokens`，而 `cachedReadTokens <= inputTokens`，
/// 说明 **`inputTokens` 已经把缓存命中算在里面**，必须减掉才能得到统一口径的 `input`。
/// `reasoningTokens` 恒 `<= outputTokens`，说明 **`outputTokens` 已含 reasoning**。
///
/// 子 agent / 后台任务回合（`prompt_id` 以 `task-completed-` 开头）**保留计入**。
/// 依据：两个非空会话里 `modelCalls(主回合) + modelCalls(task-completed 回合)`
/// 分别为 22+1=23、79+1=80，与同会话 `events.jsonl` 里的 `loop_started` 条数 23、80 完全相等，
/// 且 `turn_started` 条数（8、4）等于两类回合之和。即两类回合的模型调用互不重叠，
/// 排除它们会漏算真实发生的用量。
public struct GrokTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .grokBuild

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let root = homeDirectory.appendingPathComponent(".grok/sessions", isDirectory: true)
    var files: [TokenSourceFile] = []
    // `sessions/` 下除了按 cwd 命名的目录还混着 sqlite 文件，必须只取目录再下钻一层。
    for projectDirectory in JSONLTokenScanner.subdirectories(of: root) {
      for sessionDirectory in JSONLTokenScanner.subdirectories(of: projectDirectory) {
        let updates = sessionDirectory.appendingPathComponent("updates.jsonl", isDirectory: false)
        if let file = JSONLTokenScanner.sourceFile(at: updates) { files.append(file) }
      }
    }
    return files
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    var totalsByDay: [Int: TokenTotals] = [:]
    var seenPromptIDs: Set<String> = []

    JSONLTokenScanner.forEachLine(inFileAt: file.path) { line in
      guard JSONLTokenScanner.contains(line, Self.turnMarker),
        let record = JSONLTokenScanner.object(line),
        let update = JSONLTokenScanner.dictionary(
          JSONLTokenScanner.dictionary(record, "params"), "update"),
        update["sessionUpdate"] as? String == "turn_completed",
        let usage = JSONLTokenScanner.dictionary(update, "usage")
      else { return }
      if let promptID = update["prompt_id"] as? String {
        guard seenPromptIDs.insert(promptID).inserted else { return }
      }
      let seconds = JSONLTokenScanner.int64(record["timestamp"])
      guard seconds > 0 else { return }

      let cacheRead = JSONLTokenScanner.int64(usage["cachedReadTokens"])
      let cacheWrite = JSONLTokenScanner.int64(usage["cacheCreationTokens"])
      // 本机样本里 cacheCreationTokens 恒为 0，无法直接验证它是否也被算进 inputTokens；
      // 按与 cachedReadTokens 一致的包含关系扣除，并用 max(0,·) 兜住反例。
      let input = max(0, JSONLTokenScanner.int64(usage["inputTokens"]) - cacheRead - cacheWrite)
      let totals = TokenTotals(
        input: input, cacheWrite: cacheWrite, cacheRead: cacheRead,
        output: JSONLTokenScanner.int64(usage["outputTokens"]))
      guard !totals.isEmpty else { return }
      totalsByDay[context.localDay(forEpochSeconds: seconds), default: TokenTotals()] += totals
    }

    return JSONLTokenScanner.buckets(from: totalsByDay, project: project(of: file, context: context))
  }

  /// 会话的工作目录写在上一级目录名里（整条路径做了 percent 编码）。
  private func project(of file: TokenSourceFile, context: TokenScanContext) -> String {
    let encoded = URL(fileURLWithPath: file.path).deletingLastPathComponent()
      .deletingLastPathComponent().lastPathComponent
    guard let cwd = encoded.removingPercentEncoding, cwd.hasPrefix("/") else {
      return TokenProject.otherKey
    }
    return context.projectKey(forWorkingDirectory: cwd)
  }

  private static let turnMarker = Array("turn_completed".utf8)
}
