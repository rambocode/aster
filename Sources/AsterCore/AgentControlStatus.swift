import Foundation

/// 内部 `AgentTaskState` → 对外 `AgentControlStatus` 的纯映射。
/// 状态矩阵（行：taskState，列：附加信号）：
/// - processing → working
/// - awaitingInput → blocked
/// - idle + completionUnread → done
/// - idle，且既无 hook 权威也无屏幕检测（纯 5s 静默启发式）→ unknown：
///   启发式只能说「一段时间没输出」，不能证明 agent 真的空闲，对外不许冒充 idle。
/// - idle 其它情况 → idle
/// 来源优先级：hook 权威 > 屏幕扫描 > 启发式；权威 hook 在场时即使屏幕也命中仍报 hook。
public enum AgentControlStatusMapper {
  public struct Mapping: Equatable, Sendable {
    public let status: AgentControlStatus
    public let source: AgentDetectionSource

    public init(status: AgentControlStatus, source: AgentDetectionSource) {
      self.status = status
      self.source = source
    }
  }

  public static func map(
    taskState: AgentTaskState,
    completionUnread: Bool,
    authoritative: Bool,
    screenDetected: Bool
  ) -> Mapping {
    let source: AgentDetectionSource
    if authoritative {
      source = .hook
    } else if screenDetected {
      source = .screen
    } else {
      source = .heuristic
    }
    let status: AgentControlStatus
    switch taskState {
    case .processing:
      status = .working
    case .awaitingInput:
      status = .blocked
    case .idle:
      if completionUnread {
        status = .done
      } else if source == .heuristic {
        status = .unknown
      } else {
        status = .idle
      }
    }
    return Mapping(status: status, source: source)
  }
}

/// `agent.wait` 的到达判定。
public enum AgentWaitCondition {
  /// until 为空时的默认集合：任何「不再 working」的稳定态都算到达。
  public static let defaultUntil: [AgentControlStatus] = [.idle, .done, .blocked]

  /// 归一化 until：空 → 默认集合；去重保持顺序。
  public static func resolvedUntil(_ until: [AgentControlStatus]) -> [AgentControlStatus] {
    let source = until.isEmpty ? defaultUntil : until
    var seen = Set<AgentControlStatus>()
    return source.filter { seen.insert($0).inserted }
  }

  /// unknown 永远不算到达（即使调用方误把它放进 until，validate 也会拒绝）。
  public static func matches(status: AgentControlStatus, until: [AgentControlStatus]) -> Bool {
    guard status != .unknown else { return false }
    return resolvedUntil(until).contains(status)
  }
}
