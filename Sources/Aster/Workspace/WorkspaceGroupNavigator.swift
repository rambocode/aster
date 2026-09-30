// 从窗口外部（菜单、切换器、新建表单、CLI）操作某个窗口的窗口内工作区：置前窗口、切回本机、选中或新建。
import AppKit
import AsterCore

/// 跨窗口的窗口内工作区导航。
///
/// 侧栏只操作自己所在的窗口；菜单、切换器与 CLI 要先找到目标窗口，并在窗口正显示远端机器时
/// 先切回本机——窗口内工作区只管本机标签，远端活动时 `AppModel` 会拒绝选中与新建。
@MainActor
enum WorkspaceGroupNavigator {
  /// 最前面的可见工作区窗口：key window 优先，其次按窗口前后顺序。没有时返回 nil。
  static func frontmostController() -> WorkspaceViewController? {
    if let key = NSApp.keyWindow?.contentViewController as? WorkspaceViewController { return key }
    let windows = (NSApp.delegate as? AsterAppDelegate)?.workspaceWindows ?? []
    return windows.lazy
      .filter { $0.window.isVisible || $0.window.isMiniaturized }
      .compactMap { $0.window.contentViewController as? WorkspaceViewController }
      .first
  }

  /// 按 `NSWindow.windowNumber` 找回工作区窗口控制器；窗口已关闭时返回 nil。
  static func controller(windowNumber: Int) -> WorkspaceViewController? {
    NSApp.window(withWindowNumber: windowNumber)?.contentViewController as? WorkspaceViewController
  }

  /// 置前窗口（最小化的先还原）并激活 App。
  static func bringToFront(_ controller: WorkspaceViewController) {
    guard let window = controller.view.window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  /// 窗口正显示远端机器时切回本机；返回时 `model.isLocalMachineActive` 已为真。
  ///
  /// 先走侧栏选本机的同一条路径（记全局活动机器、刷新侧栏），再等一次本机激活：
  /// 本机激活不发网络请求，`beginActivation` 同步换回本机标签集合；侧栏路径随后排队的
  /// 那次激活发现已是本机，是空操作。
  static func ensureLocal(_ controller: WorkspaceViewController) async {
    guard !controller.model.isLocalMachineActive else { return }
    controller.presentMachineSelection(MachineProfile.localProfileID)
    await controller.remoteWorkspaces.activate(machineProfileID: MachineProfile.localProfileID)
  }

  /// 置前窗口、切回本机并选中工作区。
  static func select(_ groupID: UUID, in controller: WorkspaceViewController) async {
    bringToFront(controller)
    await ensureLocal(controller)
    controller.model.selectWorkspaceGroup(groupID)
  }

  /// 置前窗口、切回本机并新建工作区。名称非法时抛 `NamedWorkspaceRegistryError`。
  ///
  /// 名称先校验：非法名称不应顺带把用户正在看的远端机器切走。
  @discardableResult
  static func create(named name: String, in controller: WorkspaceViewController) async throws
    -> WorkspaceGroup
  {
    _ = try NamedWorkspaceRegistry.validatedName(name)
    bringToFront(controller)
    await ensureLocal(controller)
    return try controller.model.createWorkspaceGroup(named: name)
  }
}
