import Foundation

/// 用量条展示的三个维度。不同 provider 只提供其中一部分，UI 按快照里实际存在的窗口显示。
public enum AgentUsageWindowKind: String, Codable, Equatable, Sendable, CaseIterable {
  case fiveHour
  case weekly
  /// 按模型单独计费的周窗口（Claude 的 `weekly_scoped`，例如 Fable）。标签由服务端给的
  /// 模型名决定，所以实际展示走 `AgentUsageWindow.displayLabel`，这里只是兜底。
  case modelWeekly
  /// 当前会话的上下文窗口占比；目前只有 Codex 提供（来自 rollout 文件）。
  case session

  /// 用量条上的短标签。
  public var shortLabel: String {
    switch self {
    case .fiveHour: "5h"
    case .weekly: "周"
    case .modelWeekly: "模型周"
    case .session: "会话"
    }
  }
}

/// 单个用量窗口：已用百分比与可选的重置时间。`session` 表示当前会话的上下文窗口占比。
public struct AgentUsageWindow: Equatable, Sendable {
  /// 超限（如 Claude spend_limit）时百分比可以 >100，但钳制到该上限避免 UI 溢出。
  public static let maximumPercent: Double = 999

  public let kind: AgentUsageWindowKind
  public let usedPercent: Double
  public let resetsAt: Date?
  /// tooltip 里的补充说明（例如累计 token 数）。
  public let detail: String?
  /// 覆盖 `kind.shortLabel` 的展示名；用于服务端才知道名字的窗口（模型级周配额的模型名）。
  public let label: String?

  /// 非有限数（NaN / inf）没有展示意义，直接拒绝而不是钳成 0。
  public init?(
    kind: AgentUsageWindowKind, usedPercent: Double, resetsAt: Date? = nil, detail: String? = nil,
    label: String? = nil
  ) {
    guard usedPercent.isFinite else { return nil }
    self.kind = kind
    self.usedPercent = min(max(usedPercent, 0), Self.maximumPercent)
    self.resetsAt = resetsAt
    self.detail = detail
    self.label = label
  }

  /// 用量条与 tooltip 实际显示的标签。
  public var displayLabel: String { label ?? kind.shortLabel }
}

/// 一个 Pane 当前 Agent 的用量快照。
///
/// `==` 刻意不比较 `updatedAt`：轮询与 rollout 追加常常带来同样的百分比，
/// Session 依赖 Equatable 抑制重复发布，否则用量条会随每次刷新重绘。
public struct AgentUsageSnapshot: Equatable, Sendable {
  public let provider: AgentProvider
  public let windows: [AgentUsageWindow]
  public let updatedAt: Date

  /// 窗口按 kind 的声明顺序排序；同一 kind 重复时只保留第一项。
  public init(provider: AgentProvider, windows: [AgentUsageWindow], updatedAt: Date = Date()) {
    self.provider = provider
    var seen: Set<AgentUsageWindowKind> = []
    let unique = windows.filter { seen.insert($0.kind).inserted }
    let order = AgentUsageWindowKind.allCases
    self.windows = unique.sorted {
      (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
    }
    self.updatedAt = updatedAt
  }

  public func window(_ kind: AgentUsageWindowKind) -> AgentUsageWindow? {
    windows.first { $0.kind == kind }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.provider == rhs.provider && lhs.windows == rhs.windows
  }
}

/// 从 Codex rollout JSONL 的尾部提取最后一条 `token_count` 事件的配额与上下文占比。
///
/// Codex 每次模型响应都会追加一条带 `rate_limits` 的 `token_count`，因此只需读文件尾部。
/// `primary` / `secondary` 哪个槽位对应哪个窗口取决于账号 plan（本机 pro 账号只有
/// `primary=10080` 且 `secondary=null`），所以一律按 `window_minutes` 归类，槽位无意义。
public enum CodexRolloutUsageParser {
  public static let tailBytes = 65_536
  /// 单行超过此长度视为异常数据，跳过而不是尝试解析。
  public static let maximumLineBytes = 262_144
  static let fiveHourMinutes = 300
  static let weeklyMinutes = 10_080

  public static func parse(tail: Data, now: Date = Date()) -> AgentUsageSnapshot? {
    // 从尾部反向切行：并发追加时最后一段可能是不完整行，只要它不能解析就自然跳过。
    var end = tail.endIndex
    while end > tail.startIndex {
      guard let newline = tail[tail.startIndex..<end].lastIndex(of: 0x0A) else {
        if let snapshot = parseLine(tail[tail.startIndex..<end], now: now) { return snapshot }
        break
      }
      let line = tail[tail.index(after: newline)..<end]
      if let snapshot = parseLine(line, now: now) { return snapshot }
      end = newline
    }
    return nil
  }

  /// 单行解析：只认 `event_msg` + `token_count`；其它事件返回 nil 继续向前找。
  static func parseLine(_ line: Data, now: Date) -> AgentUsageSnapshot? {
    guard !line.isEmpty, line.count <= maximumLineBytes,
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "event_msg",
      let payload = object["payload"] as? [String: Any],
      payload["type"] as? String == "token_count"
    else { return nil }

    var windows: [AgentUsageWindow] = []
    if let limits = payload["rate_limits"] as? [String: Any] {
      for slot in ["primary", "secondary"] {
        guard let window = limits[slot] as? [String: Any],
          let minutes = integer(window["window_minutes"]),
          let percent = double(window["used_percent"])
        else { continue }
        let kind: AgentUsageWindowKind
        switch minutes {
        case fiveHourMinutes: kind = .fiveHour
        case weeklyMinutes: kind = .weekly
        default: continue
        }
        let resetsAt = double(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        if let usage = AgentUsageWindow(kind: kind, usedPercent: percent, resetsAt: resetsAt) {
          windows.append(usage)
        }
      }
    }
    if let info = payload["info"] as? [String: Any],
      let last = info["last_token_usage"] as? [String: Any],
      let contextWindow = double(info["model_context_window"]), contextWindow > 0,
      let total = double(last["total_tokens"])
    {
      // 与 Codex TUI 口径一致：推理输出不占上下文，从总量里扣掉。
      let reasoning = double(last["reasoning_output_tokens"]) ?? 0
      let inContext = max(total - reasoning, 0)
      let detail = "\(Int(inContext)) / \(Int(contextWindow)) tokens"
      if let usage = AgentUsageWindow(
        kind: .session, usedPercent: inContext / contextWindow * 100, detail: detail)
      {
        windows.append(usage)
      }
    }
    guard !windows.isEmpty else { return nil }
    return AgentUsageSnapshot(provider: .codex, windows: windows, updatedAt: now)
  }

  private static func double(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: number.doubleValue
    default: nil
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    double(value).map { Int($0) }
  }
}
