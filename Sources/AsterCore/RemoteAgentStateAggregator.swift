import Foundation

/// 跨机器 Agent 状态聚合器（P5）。
///
/// 汇总多台机器上报的 Agent 状态，按优先级排序并去重，为 UI 提供统一视图。

/// 聚合后的 Agent 摘要，包含来源机器信息。
public struct RemoteAgentSummary: Equatable, Sendable {
  /// 来源机器的配置 ID。
  public var machineID: UUID
  /// Agent 详细信息。
  public var agent: RemoteAgentInfo

  public init(machineID: UUID, agent: RemoteAgentInfo) {
    self.machineID = machineID
    self.agent = agent
  }
}

/// 事件去重键：(serverID, epoch, eventID) 三元组唯一标识一个事件。
public struct RemoteAgentEventKey: Hashable, Sendable {
  public var serverID: String
  public var epoch: String
  public var eventID: String

  public init(serverID: String, epoch: String, eventID: String) {
    self.serverID = serverID
    self.epoch = epoch
    self.eventID = eventID
  }
}

/// 跨机器 Agent 状态聚合器。非线程安全，调用方负责同步。
public final class RemoteAgentStateAggregator: Sendable {
  /// 状态优先级：blocked > working > done(unread) > done > idle > unknown。
  /// 数值越小优先级越高。
  private static func priority(_ agent: RemoteAgentInfo) -> Int {
    switch agent.state {
    case .blocked: return 0
    case .working: return 1
    case .done: return agent.unread ? 2 : 3
    case .idle: return 4
    case .unknown: return 5
    }
  }

  /// 内部存储：按机器 ID 分组的 agent 列表。
  private let _machines: LockedValue<[UUID: [RemoteAgentInfo]]>
  /// 已处理的事件 key 集合，用于去重。
  private let _seenEvents: LockedValue<Set<RemoteAgentEventKey>>
  /// 状态变更回调。
  private let _onAgentChanged: LockedValue<((RemoteAgentSummary) -> Void)?>

  public init() {
    _machines = LockedValue([:])
    _seenEvents = LockedValue(Set())
    _onAgentChanged = LockedValue(nil)
  }

  /// 设置状态变更通知回调。
  public func setOnAgentChanged(_ handler: ((RemoteAgentSummary) -> Void)?) {
    _onAgentChanged.withLock { $0 = handler }
  }

  /// 接收一台机器上报的 agent 列表并更新聚合状态。
  public func aggregate(machineID: UUID, agents: [RemoteAgentInfo]) -> [RemoteAgentSummary] {
    _machines.withLock { $0[machineID] = agents }
    let summaries = buildSortedSummaries()
    // 通知变更
    let handler = _onAgentChanged.withLock { $0 }
    if let handler {
      for summary in summaries where summary.machineID == machineID {
        handler(summary)
      }
    }
    return summaries
  }

  /// 标记指定终端的 Agent 完成通知为已读。
  public func markRead(machineID: UUID, terminalID: String) {
    _machines.withLock { machines in
      guard var agents = machines[machineID] else { return }
      if let index = agents.firstIndex(where: { $0.terminalID == terminalID }) {
        agents[index].unread = false
        machines[machineID] = agents
      }
    }
  }

  /// 机器断开时将其所有 Agent 标记为 unknown（过期）。
  public func staleAllForMachine(machineID: UUID) {
    _machines.withLock { machines in
      guard var agents = machines[machineID] else { return }
      for i in agents.indices {
        agents[i].state = .unknown
      }
      machines[machineID] = agents
    }
  }

  /// 检查事件是否已处理过（用于跨配置去重）。已见过返回 true。
  public func checkAndRecordEvent(_ key: RemoteAgentEventKey) -> Bool {
    _seenEvents.withLock { seen in
      !seen.insert(key).inserted
    }
  }

  /// 构建按优先级排序的聚合摘要。
  private func buildSortedSummaries() -> [RemoteAgentSummary] {
    let machines = _machines.withLock { $0 }
    var summaries: [RemoteAgentSummary] = []
    for (machineID, agents) in machines {
      for agent in agents {
        summaries.append(RemoteAgentSummary(machineID: machineID, agent: agent))
      }
    }
    summaries.sort { Self.priority($0.agent) < Self.priority($1.agent) }
    return summaries
  }
}

/// 简易线程安全包装。仅内部使用。
private final class LockedValue<T>: @unchecked Sendable {
  private var value: T
  private let lock = NSLock()

  init(_ value: T) {
    self.value = value
  }

  func withLock<R>(_ body: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}
