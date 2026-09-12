import Foundation

/// 远端冷恢复结果类型：描述服务端重启后每个窗格的恢复路径。
/// 四类路径互斥：继续运行（分离重连）、新 Shell、历史回放、Agent 对话恢复。

/// 单个窗格的冷恢复路径。
public enum PaneRecoveryPath: Equatable, Sendable {
  /// 终端仍在运行（分离后重连，PID 不变）。不是冷恢复。
  case continueRunning(terminalID: String, pid: Int)
  /// 冷恢复创建了新 Shell（新 terminalID、新 PID）。
  case newShell(oldTerminalID: String, newTerminalID: String, newPID: Int)
  /// 历史回放（磁盘屏幕历史可用，非实时状态）。
  case historyReplay(oldTerminalID: String, newTerminalID: String, capturedAt: Date)
  /// Agent 原生恢复（provider 的 resume 命令已执行）。
  case agentRestore(oldTerminalID: String, newTerminalID: String, newPID: Int, provider: AgentProvider, nativeSession: String)
  /// 恢复失败，创建了明确的新 Shell 替代。
  case failed(oldTerminalID: String, newTerminalID: String, newPID: Int, reason: String)
}

/// 完整的冷恢复计划结果。
public struct ColdRestoreResult: Equatable, Sendable {
  /// 所有窗格的恢复路径，按 paneID 索引。
  public var paneResults: [String: PaneRecoveryPath]
  /// 服务端是否完成了冷恢复。
  public var isCompleted: Bool
  /// 恢复是否已经被另一个客户端触发过（防止重复恢复）。
  public var alreadyRestored: Bool

  public init(paneResults: [String: PaneRecoveryPath] = [:], isCompleted: Bool = false, alreadyRestored: Bool = false) {
    self.paneResults = paneResults
    self.isCompleted = isCompleted
    self.alreadyRestored = alreadyRestored
  }
}
