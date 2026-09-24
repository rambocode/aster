import AppKit
import AsterCore
import Foundation

// 「添加机器」的共享入口：侧栏、设置页主机列表、Open Quickly 与新建工作区表单都走这里，
// 保证同一套确认、安装与失败提示。

/// 添加机器流程。
@MainActor
enum MachineSetupFlow {
  /// 预填值。`hostID` 有值时机器绑定该已保存主机，target 取主机的连接串。
  struct Prefill: Equatable {
    var label: String?
    var sshTarget: String?
    var hostID: UUID?
    var sessionName: String?

    init(label: String? = nil, sshTarget: String? = nil, hostID: UUID? = nil, sessionName: String? = nil) {
      self.label = label
      self.sshTarget = sshTarget
      self.hostID = hostID
      self.sessionName = sessionName
    }
  }

  /// 弹出添加面板并执行设置事务。取消或失败返回 nil；成功返回新机器 ID。
  @discardableResult
  static func presentAddMachine(
    prefill: Prefill = Prefill(),
    fleet: MachineFleetModel = .shared,
    in window: NSWindow?
  ) async -> UUID? {
    guard let draft = MachineSetupSheet.promptForNewMachine(in: window) else { return nil }
    let result = await fleet.addMachine(
      label: draft.label, sshTarget: draft.sshTarget, sessionName: draft.sessionName,
      confirm: { MachineSetupSheet.confirm($0, in: window) })
    switch result {
    case .added(let profile), .updated(let profile): return profile.id
    case .failed(let message):
      MachineSetupSheet.presentFailure(message, in: window)
      return nil
    case .upToDate, .cancelled: return nil
    }
  }
}
