// Codex 的本地 rollout 数据源。移植自 jettoai/tally（MIT）的 TokenStatsParser.readCodex。
import Foundation

/// 读 `~/.codex/sessions/**/rollout-*.jsonl` 与 `~/.codex/archived_sessions/**/rollout-*.jsonl`：
/// 工作目录在 `session_meta` 行上，用量在 `token_count` 事件的 `total_token_usage` 里。
public struct CodexTokenSource: TokenUsageSource {
  public var provider: AgentProvider { .codex }

  public init() {}

  /// 归档一个 Codex 会话是把 rollout **移动**到 `archived_sessions/`，
  /// 只读活跃目录会让做完的工作从所有区间里消失、总量随时间倒退，所以两个目录都读。
  /// 文件本身按 `YYYY/MM/DD` 分层存放，必须递归。
  public func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    let base = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    let roots = ["sessions", "archived_sessions"].map {
      base.appendingPathComponent($0, isDirectory: true)
    }
    return TokenFileWalker.files(in: roots) {
      $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
    }
  }

  public func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    TokenLineReader.withMappedBytes(atPath: file.path) { raw in
      Self.parse(raw, context: context)
    } ?? []
  }

  /// `total_token_usage` 是**整个会话的累计值**，不是单轮增量。
  ///
  /// 这里取相邻事件的差分，token 才会落在真正花掉它的那一天（跨午夜的会话能正确拆开）；
  /// 任一列变小说明计数器被重置（换会话上下文、客户端重启），此时把整条当作新值而不是负消费。
  ///
  /// 口径归一：Codex 把缓存命中算在 `input_tokens` **里面**、reasoning 算在 `output_tokens` 里面，
  /// 而 Claude 的缓存读取是单独一列。所以这里把 cached 部分从 input 中扣出来，
  /// 两个 provider 的四列才表示同一件事。
  private static func parse(_ raw: UnsafeRawBufferPointer, context: TokenScanContext)
    -> [TokenBucket]
  {
    let scan = JSONScan(bytes: raw)
    var accumulator = TokenBucketAccumulator()
    var projects = TokenProjectKeyMemo()
    var project = TokenProject.otherKey
    var previous: Counters?

    TokenLineReader.forEachLine(raw) { line in
      guard TokenLineReader.contains(raw, line, "token_count")
        || TokenLineReader.contains(raw, line, "\"cwd\"")
      else { return }

      var type: Range<Int>?
      var timestamp: Range<Int>?
      var payload: Range<Int>?
      scan.forEachMember(in: line) { key, value in
        if scan.key(key, is: "type") {
          type = value
        } else if scan.key(key, is: "timestamp") {
          timestamp = value
        } else if scan.key(key, is: "payload") {
          payload = value
        }
      }
      guard let payload else { return }

      if let type, TokenLineReader.matches(raw, type, "\"session_meta\"") {
        project = projects.key(scan, scan.member("cwd", in: payload), context: context)
        return
      }

      var payloadType: Range<Int>?
      var info: Range<Int>?
      scan.forEachMember(in: payload) { key, value in
        if scan.key(key, is: "type") {
          payloadType = value
        } else if scan.key(key, is: "info") {
          info = value
        }
      }
      guard let payloadType, TokenLineReader.matches(raw, payloadType, "\"token_count\""),
        let info, let usage = scan.member("total_token_usage", in: info),
        let timestamp, let seconds = LocalDayStamper.epochSeconds(scan, timestamp)
      else { return }

      var current = Counters()
      scan.forEachMember(in: usage) { key, value in
        if scan.key(key, is: "input_tokens") {
          current.input = scan.int64(value) ?? 0
        } else if scan.key(key, is: "cached_input_tokens") {
          current.cached = scan.int64(value) ?? 0
        } else if scan.key(key, is: "cache_write_input_tokens") {
          current.cacheWrite = scan.int64(value) ?? 0
        } else if scan.key(key, is: "output_tokens") {
          current.output = scan.int64(value) ?? 0
        }
      }
      let delta = current.delta(since: previous)
      previous = current
      guard !delta.isEmpty else { return }
      accumulator.add(delta, day: context.localDay(forEpochSeconds: seconds), project: project)
    }
    return accumulator.buckets()
  }

  /// 一条 `token_count` 事件里的累计计数器。
  private struct Counters {
    /// 含缓存命中的部分。
    var input: Int64 = 0
    var cached: Int64 = 0
    var cacheWrite: Int64 = 0
    /// 含 reasoning。
    var output: Int64 = 0

    /// 本次事件实际花掉的量，已归一到四列口径。
    func delta(since previous: Counters?) -> TokenTotals {
      // 任一列比上一条小 = 计数器重置，整条当新值；否则逐列作差。
      guard let previous, input >= previous.input, cached >= previous.cached,
        cacheWrite >= previous.cacheWrite, output >= previous.output
      else {
        return TokenTotals(
          input: max(0, input - cached), cacheWrite: cacheWrite, cacheRead: cached, output: output)
      }
      let fresh = (input - previous.input) - (cached - previous.cached)
      return TokenTotals(
        input: max(0, fresh), cacheWrite: cacheWrite - previous.cacheWrite,
        cacheRead: cached - previous.cached, output: output - previous.output)
    }
  }
}
