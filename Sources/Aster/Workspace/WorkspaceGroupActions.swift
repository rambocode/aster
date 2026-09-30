import AppKit
import AsterCore

// 窗口内工作区的交互动作：新建、重命名、删除的对话框。侧栏、菜单、Open Quickly 与
// 新建表单都走这里，保证文案、校验和确认规则只有一份。

@MainActor
enum WorkspaceGroupActions {
  /// 弹出名称框新建工作区并切过去。名称非法时提示后保留输入重新弹出；取消返回 nil。
  @discardableResult
  static func promptCreate(in model: AppModel, window: NSWindow?) -> WorkspaceGroup? {
    var name = model.suggestedWorkspaceGroupName()
    while true {
      guard
        let input = WorkspaceSheetPresenter.promptForName(
          title: L("新建工作区"), message: L("工作区是一组标签。切走的工作区里的终端会继续运行。"),
          current: name, confirm: L("创建"), in: window)
      else { return nil }
      name = input
      do {
        return try model.createWorkspaceGroup(named: input)
      } catch {
        presentFailure(error, in: window)
      }
    }
  }

  /// 弹出名称框重命名工作区。名称非法时提示后保留输入重新弹出。
  static func promptRename(_ groupID: UUID, in model: AppModel, window: NSWindow?) {
    guard var name = model.workspaceGroups.first(where: { $0.id == groupID })?.name else { return }
    while true {
      guard
        let input = WorkspaceSheetPresenter.promptForName(
          title: L("重命名工作区"), message: L("只改名称，不影响其中的终端。"),
          current: name, confirm: L("保存"), in: window)
      else { return }
      name = input
      do {
        try model.renameWorkspaceGroup(groupID, to: input)
        return
      } catch {
        presentFailure(error, in: window)
      }
    }
  }

  /// 确认后删除工作区。确认框写明会关闭多少个标签，默认按钮是「取消」。
  static func confirmAndDelete(_ groupID: UUID, in model: AppModel, window: NSWindow?) {
    guard model.canDeleteWorkspaceGroup(groupID),
      let group = model.workspaceGroups.first(where: { $0.id == groupID })
    else { return }
    let count = model.tabCount(inWorkspaceGroup: groupID)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("删除工作区「\(group.name)」？")
    alert.informativeText = L("会关闭其中的 \(String(count)) 个标签，里面的终端会结束。关闭的标签可以从「最近关闭」重新打开。")
    alert.addButton(withTitle: L("取消"))
    alert.addButton(withTitle: L("删除")).hasDestructiveAction = true
    guard WorkspaceSheetPresenter.run(alert, in: window) == .alertSecondButtonReturn else { return }
    model.deleteWorkspaceGroup(groupID)
  }

  /// 把名称校验等错误翻译成一句话弹出。
  static func presentFailure(_ error: any Error, in window: NSWindow?) {
    let message: String
    switch error {
    case let registry as NamedWorkspaceRegistryError:
      message = NamedWorkspaceDirectory.message(for: .registry(registry))
    case WorkspaceGroupError.remoteMachineActive:
      message = L("当前显示的是远端机器。请先切回本机，再新建本机工作区。")
    default:
      message = WorkspaceSheetPresenter.describe(error)
    }
    MachineSetupSheet.presentFailure(message, in: window)
  }
}
