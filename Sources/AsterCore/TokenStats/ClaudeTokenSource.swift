// Claude Code 的本地 transcript 数据源。移植自 jettoai/tally（MIT）的 TokenStatsParser.readClaude。
import Foundation

/// 读 `~/.claude/projects/**/*.jsonl`：每行一个 JSON 对象，token 计数在 assistant 行的
/// `message.usage` 上，`cwd` 与 `timestamp` 在顶层。
public struct ClaudeTokenSource: TokenUsageSource {
  public var provider: AgentProvider { .claudeCode }

  public init() {}

  /// 递归遍历 `projects/`。子 agent 与 workflow 的 transcript 嵌在会话目录下
  /// （`<project>/<session>/subagents/**`），只列一层会漏掉大半语料。
  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let root = homeDirectory
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
    return TokenFileWalker.files(in: [root]) { $0.pathExtension == "jsonl" }
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    TokenLineReader.withMappedBytes(atPath: file.path) { raw in
      Self.parse(raw, context: context)
    } ?? []
  }

  /// 一个 assistant turn 会写成多行（文本、thinking、每个工具调用各一行），共用一个 `message.id`，
  /// 而每行重复的是**截至该行**的 usage，不是最终值。
  ///
  /// 所以这些行既不能求和（实际用量会被放大约一倍），也不能只留第一行
  /// （流式输出的首行 output 往往是个位数，直接丢掉大部分产出）。正确口径是：
  /// 同一个 message.id 取每一列历史最大值，按增量一次次记账（`TokenTotals.raise(to:)`）。
  ///
  /// 去重表**按文件**而不是全局：续聊或 fork 会话会把早前的 turn 复制进新 transcript，
  /// 少数 id 确实会出现在两个文件里。要抓这些就得把整个语料的 message id 都塞进缓存，
  /// 代价比它消除的误差高几个数量级。
  private static func parse(_ raw: UnsafeRawBufferPointer, context: TokenScanContext)
    -> [TokenBucket]
  {
    let scan = JSONScan(bytes: raw)
    var accumulator = TokenBucketAccumulator()
    var projects = TokenProjectKeyMemo()
    var counted: [UInt64: TokenTotals] = [:]

    TokenLineReader.forEachLine(raw) { line in
      guard TokenLineReader.contains(raw, line, "\"usage\"") else { return }

      var cwd: Range<Int>?
      var timestamp: Range<Int>?
      var message: Range<Int>?
      scan.forEachMember(in: line) { key, value in
        if scan.key(key, is: "cwd") {
          cwd = value
        } else if scan.key(key, is: "timestamp") {
          timestamp = value
        } else if scan.key(key, is: "message") {
          message = value
        }
      }
      guard let message, let timestamp,
        let seconds = LocalDayStamper.epochSeconds(scan, timestamp)
      else { return }
      let day = context.localDay(forEpochSeconds: seconds)

      var usage: Range<Int>?
      var messageID: Range<Int>?
      scan.forEachMember(in: message) { key, value in
        if scan.key(key, is: "usage") {
          usage = value
        } else if scan.key(key, is: "id") {
          messageID = value
        }
      }
      guard let usage else { return }

      var totals = TokenTotals()
      scan.forEachMember(in: usage) { key, value in
        if scan.key(key, is: "input_tokens") {
          totals.input = scan.int64(value) ?? 0
        } else if scan.key(key, is: "cache_creation_input_tokens") {
          totals.cacheWrite = scan.int64(value) ?? 0
        } else if scan.key(key, is: "cache_read_input_tokens") {
          totals.cacheRead = scan.int64(value) ?? 0
        } else if scan.key(key, is: "output_tokens") {
          totals.output = scan.int64(value) ?? 0
        }
      }
      guard !totals.isEmpty else { return }

      // 没有 id（老版本 transcript）就无法区分「重述」和「新 turn」；整条计入是更安全的误差方向，
      // 压着不算会直接丢掉整个 turn。
      if let messageID {
        let added = counted[TokenLineReader.fingerprint(raw, messageID), default: TokenTotals()]
          .raise(to: totals)
        guard !added.isEmpty else { return }
        totals = added
      }
      accumulator.add(totals, day: day, project: projects.key(scan, cwd, context: context))
    }
    return accumulator.buckets()
  }
}
