import Foundation

/// 重开 App 时把持久化的受管终端引用与服务端实测状态对齐。
///
/// 规则来自 `docs/developer/remote-work.md` §7 与 P2.5：持久化的只是稳定引用，
/// 不是运行证据。冷重启后服务 epoch 变化、terminalID 失效，必须显示真实状态，
/// 不能把上次保存的 "running" 当作当前进程仍在运行。

/// 单个受管 Pane 的对账结果。
public enum ManagedTerminalResolution: Equatable, Sendable {
  /// 同一进程继续运行，可直接重新附加。
  case attached(ManagedTerminalStatus)
  /// 进程已退出；保留结束状态，不无条件创建替代进程。
  case exited(ManagedTerminalStatus)
  /// 服务已冷重启（serverID 或 epoch 变化），旧 terminalID 不再有效。
  case serverRestarted(expected: ManagedTerminalReference, currentServerEpoch: String?)
  /// 服务可达但找不到该 terminalID。
  case missing(ManagedTerminalReference)
  /// 服务不可达；保留最后已知引用，禁止据此宣称任务仍在运行。
  case unreachable(ManagedTerminalReference, reason: String)
}

public enum ManagedTerminalReconciler {
  /// 用一次 `terminal.list` 结果对账一批持久化引用。
  ///
  /// `persistedServerEpoch` 是上次运行记录的 epoch。它只用于判定“服务是否换了实例”，
  /// 不参与身份判等；缺失时按未知处理，只要 serverID 匹配且终端存在就按实测状态返回。
  public static func reconcile(
    references: [ManagedTerminalReference],
    liveTerminals: [ManagedTerminalStatus],
    currentServer: SessionServerReference?,
    currentServerEpoch: String?,
    persistedServerEpoch: String?,
    unreachableReason: String? = nil
  ) -> [ManagedTerminalReference: ManagedTerminalResolution] {
    var result: [ManagedTerminalReference: ManagedTerminalResolution] = [:]
    for reference in references {
      guard let currentServer, unreachableReason == nil else {
        result[reference] = .unreachable(
          reference, reason: unreachableReason ?? "server unavailable")
        continue
      }
      // serverID 变化表示这是另一个服务实例；epoch 变化表示同一服务冷重启。
      // 两种情况下旧 terminalID 都不能再证明原进程存活。
      let sameServer =
        currentServer.serverID == reference.server.serverID
        && currentServer.sessionID == reference.server.sessionID
      let sameEpoch =
        persistedServerEpoch == nil || currentServerEpoch == nil
        || persistedServerEpoch == currentServerEpoch
      guard sameServer, sameEpoch else {
        result[reference] = .serverRestarted(
          expected: reference, currentServerEpoch: currentServerEpoch)
        continue
      }
      guard let live = liveTerminals.first(where: { $0.reference.terminalID == reference.terminalID })
      else {
        result[reference] = .missing(reference)
        continue
      }
      result[reference] = live.state == .running ? .attached(live) : .exited(live)
    }
    return result
  }
}
