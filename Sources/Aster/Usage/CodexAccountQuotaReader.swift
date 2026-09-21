// Codex 账号级配额的读取：从 ~/.codex/sessions 里最新的 rollout 文件尾部取 5 小时 / 每周窗口。
import AsterCore
import Foundation

/// Codex 没有配额接口，账号用量只能从它自己写的 rollout JSONL 里回读。
///
/// 这是「当前账号还剩多少」的一次性快照：不认会话、不监听文件，由调用方在需要时
/// （功能开启、浮动窗打开）主动调用。全部是同步文件 IO，必须放在后台任务里执行。
enum CodexAccountQuotaReader {
  /// 最多回看多少个日目录：当天没跑过 Codex 就往前找，但再旧的数据已经没有参考价值。
  static let maximumDayLookback = 7
  /// 最多实际读取多少个 rollout 文件；一天里可能有几十个会话，避免翻遍整个目录。
  static let maximumFileProbes = 8

  /// 取最近一次 Codex 会话留下的账号级配额。返回 nil 表示找不到可用数据。
  ///
  /// 只保留 `.fiveHour` / `.weekly`：`.session` 是某个会话的上下文占比，不是账号配额，
  /// 放进「配额」页会让人误以为额度快用完了。
  /// `updatedAt` 取该 rollout 文件的修改时刻，用来标注数据新旧。
  nonisolated static func latestWindows(
    homeDirectory: URL, now: Date
  ) -> (windows: [AgentUsageWindow], updatedAt: Date, plan: String?)? {
    let root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    var probes = 0
    for day in recentDayDirectories(under: root) {
      for file in rolloutFiles(in: day) {
        guard probes < maximumFileProbes else { return nil }
        probes += 1
        guard let tail = tail(of: file),
          let snapshot = CodexRolloutUsageParser.parse(tail: tail, now: now)
        else { continue }
        let windows = accountWindows(from: snapshot.windows, now: now)
        guard !windows.isEmpty else { continue }
        return (windows, modificationDate(of: file) ?? now, planType(fromTail: tail))
      }
    }
    return nil
  }

  /// 从尾部最后一条 `token_count` 里取 `rate_limits.plan_type`。
  ///
  /// `CodexRolloutUsageParser` 只回传窗口、不保留原始行，所以这里自己反向扫一遍。实测本机
  /// 这个键经常是 `null`（只有服务端认为需要时才填），所以拿不到是常态，不是错误。
  nonisolated static func planType(fromTail tail: Data) -> String? {
    var end = tail.endIndex
    while end > tail.startIndex {
      let newline = tail[tail.startIndex..<end].lastIndex(of: 0x0A)
      let start = newline.map { tail.index(after: $0) } ?? tail.startIndex
      if let plan = planType(fromLine: tail[start..<end]) { return plan }
      guard let newline else { return nil }
      end = newline
    }
    return nil
  }

  /// 单行解析：只认带 `rate_limits` 的 `token_count` 事件；其它行返回 nil 继续往前找。
  private nonisolated static func planType(fromLine line: Data.SubSequence) -> String? {
    guard !line.isEmpty, line.count <= CodexRolloutUsageParser.maximumLineBytes,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count",
      let limits = payload["rate_limits"] as? [String: Any]
    else { return nil }
    return UsagePlanName.normalized(limits["plan_type"] as? String)
  }

  /// 过滤出账号级窗口，并把已经过了重置时刻的窗口按「已清零」处理。
  ///
  /// 为什么不直接丢弃：重置之后账号的已用量确实回到 0，而 Codex 不跑就不会写新行，文件里
  /// 永远停在重置前的百分比。丢弃会让 Codex 整行从浮动窗消失（看起来像功能坏了），照抄旧值
  /// 又是明确错误的数字。所以百分比按 0，清掉已经过期的 `resetsAt`，并在说明里点明来由。
  private nonisolated static func accountWindows(
    from windows: [AgentUsageWindow], now: Date
  ) -> [AgentUsageWindow] {
    windows.compactMap { window in
      guard window.kind == .fiveHour || window.kind == .weekly else { return nil }
      guard let resetsAt = window.resetsAt, resetsAt < now else { return window }
      return AgentUsageWindow(
        kind: window.kind, usedPercent: 0, resetsAt: nil,
        detail: L("配额已重置，等 Codex 下次运行后更新"), label: window.label)
    }
  }

  /// 按目录名倒序下钻 年/月/日，返回最近的若干个日目录。
  ///
  /// 目录名是零填充的 `YYYY` / `MM` / `DD`，所以字符串倒序就是时间倒序，不需要解析日期。
  private nonisolated static func recentDayDirectories(under root: URL) -> [URL] {
    var days: [URL] = []
    for year in sortedSubdirectories(of: root) {
      for month in sortedSubdirectories(of: year) {
        for day in sortedSubdirectories(of: month) {
          days.append(day)
          if days.count >= maximumDayLookback { return days }
        }
      }
    }
    return days
  }

  /// 子目录按名字倒序。目录不存在或不可读时返回空数组。
  private nonisolated static func sortedSubdirectories(of directory: URL) -> [URL] {
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
      ?? []
    return contents
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  /// 日目录里的 rollout 文件按名字倒序；文件名带 `rollout-<ISO 时间>-<uuid>`，倒序即最新优先。
  private nonisolated static func rolloutFiles(in directory: URL) -> [URL] {
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return contents
      .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  /// 只读文件末尾 `CodexRolloutUsageParser.tailBytes`；文件较小时整读。
  private nonisolated static func tail(of url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > UInt64(CodexRolloutUsageParser.tailBytes)
      ? size - UInt64(CodexRolloutUsageParser.tailBytes) : 0
    guard (try? handle.seek(toOffset: start)) != nil else { return nil }
    return try? handle.readToEnd()
  }

  private nonisolated static func modificationDate(of url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}
