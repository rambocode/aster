import Foundation

/// 受管终端生命周期事件到录制/Agent 状态动作的映射。
///
/// P2.7 的固定要求：客户端分离不得写成进程结束。分离只释放本客户端的租约与订阅，
/// 服务端进程与布局保留；只有服务端上报的真实退出或显式结束才允许写结束事件。
/// 服务端事件可能重复投递（重连后重新同步快照），所以这里按实例身份做幂等。

/// 客户端观察到的受管终端生命周期输入。
public enum ManagedTerminalLifecycleEvent: Equatable, Sendable {
  /// 本客户端分离：关闭窗口、退出 App、隐藏工作区或桥进程结束。
  case clientDetached(ManagedTerminalReference)
  /// 服务端上报的真实结束（进程退出或显式 terminate 完成）。
  case serverReportedEnd(ManagedTerminalStatus)
}

/// 生命周期动作。录制层与 Agent 状态层按此决定写什么。
public enum ManagedTerminalLifecycleAction: Equatable, Sendable {
  /// 只释放客户端侧资源，不写结束事件。
  case releaseClientResources(ManagedTerminalReference)
  /// 写一次结束事件；同一实例重复上报只会产生一次。
  case recordEnded(ManagedTerminalReference, exitCode: Int32?)
  /// 重复事件，忽略。
  case ignoreDuplicate(ManagedTerminalReference)
}

/// 按 `(terminalID, serverEpoch)` 去重的生命周期归约器。
///
/// 用 epoch 参与去重是必要的：服务冷重启后 terminalID 不会复用，但同一引用可能在
/// 新旧 epoch 下各出现一次结束事件，两次都是真实事件，不能被前一次抑制。
public struct ManagedTerminalLifecycleTracker: Sendable {
  private struct Key: Hashable, Sendable {
    let terminalID: String
    let serverID: String
    let serverEpoch: String?
  }

  private var ended: Set<Key> = []
  /// 保护内存上界：结束记录数超过阈值时丢弃最旧插入顺序无关的多余项。
  private let capacity: Int
  private var order: [Key] = []

  public init(capacity: Int = 4096) { self.capacity = max(1, capacity) }

  public mutating func handle(_ event: ManagedTerminalLifecycleEvent)
    -> ManagedTerminalLifecycleAction
  {
    switch event {
    case .clientDetached(let reference):
      // 分离不产生结束事件，也不进入去重集合：之后真实退出仍须被记录。
      return .releaseClientResources(reference)

    case .serverReportedEnd(let status):
      let key = Key(
        terminalID: status.reference.terminalID,
        serverID: status.reference.server.serverID,
        serverEpoch: status.serverEpoch
      )
      guard !ended.contains(key) else { return .ignoreDuplicate(status.reference) }
      ended.insert(key)
      order.append(key)
      if order.count > capacity {
        let evicted = order.removeFirst()
        ended.remove(evicted)
      }
      return .recordEnded(status.reference, exitCode: status.exitCode)
    }
  }

  /// 是否已为该实例写过结束事件。用于重开 App 后避免重复记录。
  public func hasRecordedEnd(for status: ManagedTerminalStatus) -> Bool {
    ended.contains(
      Key(
        terminalID: status.reference.terminalID,
        serverID: status.reference.server.serverID,
        serverEpoch: status.serverEpoch
      ))
  }
}
