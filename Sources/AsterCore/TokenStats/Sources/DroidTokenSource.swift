// Factory droid 的本地用量数据源：读取 ~/.factory/sessions 下的会话设置文件。
import Foundation

/// 从 `~/.factory/sessions/<uuid>.settings.json` 的 `tokenUsage` 统计 droid 的 token 用量。
///
/// 口径：droid 走 Anthropic 系口径，`inputTokens` 与 `cacheReadTokens` 量级完全脱节
/// （本机样本有 3713 对 8576、4430 对 2299882），说明 **`input` 不含缓存命中**；
/// `thinkingTokens` 在 11 个有用量的会话里恒 `<= outputTokens`，说明 **`output` 已含 thinking**。
/// 该文件没有 total 字段可做闭合校验，这是唯一靠量级关系而非等式确认的数据源。
///
/// 这份数据是**整个会话的累计值**且不带 cwd：因此按文件修改时间归到一天，
/// 项目记为 `TokenProject.otherKey`。会话跨天时全部算在最后活动的那天。
public struct DroidTokenSource: TokenUsageSource {
  public let provider: AgentProvider = .droid

  public init() {}

  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let root = homeDirectory.appendingPathComponent(".factory/sessions", isDirectory: true)
    return JSONLTokenScanner.entries(of: root)
      .filter { $0.lastPathComponent.hasSuffix(".settings.json") }
      .compactMap(JSONLTokenScanner.sourceFile(at:))
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)),
      let root = JSONLTokenScanner.object(data),
      let usage = JSONLTokenScanner.dictionary(root, "tokenUsage")
    else { return [] }

    let totals = TokenTotals(
      input: JSONLTokenScanner.int64(usage["inputTokens"]),
      cacheWrite: JSONLTokenScanner.int64(usage["cacheCreationTokens"]),
      cacheRead: JSONLTokenScanner.int64(usage["cacheReadTokens"]),
      output: JSONLTokenScanner.int64(usage["outputTokens"]))
    guard !totals.isEmpty else { return [] }

    let day = context.localDay(forEpochSeconds: Int64(file.modified.rounded(.down)))
    return [TokenBucket(day: day, project: TokenProject.otherKey, totals: totals)]
  }
}
