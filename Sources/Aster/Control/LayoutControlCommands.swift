// 控制协议的结构方法：pane.close / pane.split / tab.new / tab.close / tab.focus / tab.rename。
// 从 AsterControlDispatcher 拆出来，按「改变窗口结构」这一职责单独成文件。

import AsterCore
import Foundation

extension AsterControlDispatcher {
  /// 执行一个结构方法并返回已编码的结果。只接受上面六个方法，其它方法是调用方的编程错误。
  ///
  /// 这些动作都不弹确认框：调用方是脚本或 Agent，模态弹窗会把控制连接挂死。放行与否只看
  /// IPC 写门禁；未保存文档的保存提示仍然保留，用户取消时返回 `write_rejected`。
  func performLayoutMethod(
    _ method: AsterControlMethod, request: AsterControlRequest
  ) throws -> JSONValue {
    switch method {
    case .paneClose:
      return try JSONValue(encoding: try closePane(try layoutParams(PaneCloseParams.self, request)))
    case .paneSplit:
      return try JSONValue(encoding: try splitPane(try layoutParams(PaneSplitParams.self, request)))
    case .tabNew:
      return try JSONValue(encoding: try newTab(try layoutParams(TabNewParams.self, request)))
    case .tabClose:
      return try JSONValue(encoding: try closeTab(try layoutParams(TabTargetParams.self, request)))
    case .tabFocus:
      let record = try bridge.resolve(selector: try layoutParams(TabTargetParams.self, request).tab)
      record.model.revealWorkspaceLocation(tabID: record.tab.id, paneID: record.tab.activePaneID)
      record.model.onRequestWindowFocus?()
      return try JSONValue(encoding: AsterControlOKResult())
    case .tabRename:
      try renameTab(try layoutParams(TabRenameParams.self, request))
      return try JSONValue(encoding: AsterControlOKResult())
    default:
      throw AsterControlError(code: .internalError, message: "\(method.rawValue) 不是结构方法")
    }
  }

  // MARK: - Pane

  /// 关闭 Pane；标签只剩这一个 Pane 时连标签一起关（与 ⌘W 一致）。
  private func closePane(_ params: PaneCloseParams) throws -> LayoutActionResult {
    let record = try bridge.resolve(selector: params.pane)
    try gateStructureWrite(closing: [record.session].compactMap { $0 })
    let model = record.model
    let tab = record.tab
    let paneUUID = record.runtime.id
    let closesTab = tab.layout.allPanes.count <= 1
    // 复用「Shell 自己退出后关 Pane」的路径：不弹关闭确认、最后一个 Pane 升级成关标签、
    // 远端走服务端事务、写入「重新打开」历史并落盘。
    model.closePaneAfterShellExit(paneID: paneUUID, in: tab)
    // 远端关闭是异步事务，这里还看不到结果；本地是同步的，仍然在就说明被保存提示取消了。
    if model.remoteStructureHandler == nil, bridge.record(paneUUID: paneUUID) != nil {
      throw AsterControlError(
        code: .writeRejected, message: "\(record.paneID) 没有关闭（可能有未保存的文档）")
    }
    return LayoutActionResult(
      windowID: record.windowID.description,
      tabID: closesTab ? record.tabID.description : nil,
      paneID: record.paneID.description, closedTab: closesTab)
  }

  /// 在目标 Pane 的一侧拆出新的终端 Pane。
  private func splitPane(_ params: PaneSplitParams) throws -> LayoutActionResult {
    let record = try bridge.resolve(selector: params.pane)
    try gateStructureWrite(closing: [])
    let model = record.model
    let tab = record.tab
    if let remote = model.remoteStructureHandler {
      remote.splitPane(tabID: tab.id, paneID: record.runtime.id, direction: params.direction)
      return LayoutActionResult(windowID: record.windowID.description)
    }
    let before = Set(tab.layout.allPanes.map(\.id))
    // `split` 拆的是标签的活动 Pane，所以先把活动 Pane 换成目标。
    tab.setActivePane(record.runtime.id)
    tab.split(direction: params.direction)
    model.persistWorkspace()
    guard let created = tab.layout.allPanes.map(\.id).first(where: { !before.contains($0) }),
      let createdRecord = bridge.record(paneUUID: created)
    else {
      throw AsterControlError(code: .internalError, message: "\(record.paneID) 拆分失败")
    }
    return LayoutActionResult(
      windowID: createdRecord.windowID.description, paneID: createdRecord.paneID.description)
  }

  // MARK: - 标签

  /// 在目标窗口新建标签并选中它。
  private func newTab(_ params: TabNewParams) throws -> LayoutActionResult {
    let anchor: AsterControlBridge.PaneRecord
    if let window = params.window {
      anchor = try bridge.resolve(selector: window)
    } else if let current = bridge.currentPane() {
      anchor = current
    } else {
      throw AsterControlError(code: .notFound, message: "没有可用的窗口")
    }
    try gateStructureWrite(closing: [])
    let model = anchor.model
    if let remote = model.remoteStructureHandler {
      // 远端标签的目录在远端文件系统上，本机查不了，原样交给服务端判断。
      remote.createTab(workingDirectory: params.cwd)
      return LayoutActionResult(windowID: anchor.windowID.description)
    }
    if let cwd = params.cwd {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue
      else { throw AsterControlError.invalidParams("cwd 不是已存在的目录: \(cwd)") }
    }
    let before = Set(model.tabs.map(\.id))
    model.newTab(workingDirectory: params.cwd)
    guard let tab = model.tabs.first(where: { !before.contains($0.id) }),
      let created = bridge.record(paneUUID: tab.activePaneID)
    else {
      throw AsterControlError(code: .internalError, message: "新建标签失败")
    }
    return LayoutActionResult(
      windowID: created.windowID.description, tabID: created.tabID.description,
      paneID: created.paneID.description)
  }

  /// 关闭整个标签（里面所有 Pane 的进程一起结束）。
  private func closeTab(_ params: TabTargetParams) throws -> LayoutActionResult {
    let record = try bridge.resolve(selector: params.tab)
    let model = record.model
    let tab = record.tab
    try gateStructureWrite(
      closing: tab.layout.allPanes.compactMap { tab.runtime(for: $0.id)?.terminalSession })
    model.closeTab(id: tab.id, confirm: false)
    if model.remoteStructureHandler == nil, model.tabs.contains(where: { $0.id == tab.id }) {
      throw AsterControlError(
        code: .writeRejected, message: "\(record.tabID) 没有关闭（可能有未保存的文档）")
    }
    return LayoutActionResult(
      windowID: record.windowID.description, tabID: record.tabID.description)
  }

  /// 固定标签名；`title` 为空时恢复自动标题。
  private func renameTab(_ params: TabRenameParams) throws {
    let record = try bridge.resolve(selector: params.tab)
    let title = params.title ?? ""
    if let remote = record.model.remoteStructureHandler {
      // 远端标签标题是共享结构，没有「自动标题」这个状态可以恢复。
      guard !title.isEmpty else {
        throw AsterControlError.invalidParams("远端标签不支持恢复自动标题，请给出 title")
      }
      remote.renameTab(tabID: record.tab.id, title: title)
      return
    }
    record.tab.setTabTitleOverride(title.isEmpty ? .automatic : .name(title))
    record.model.persistWorkspace()
  }

  // MARK: - 辅助

  /// 解码并校验结构方法的参数。
  private func layoutParams<T: Decodable & AsterControlValidatable>(
    _ type: T.Type, _ request: AsterControlRequest
  ) throws -> T {
    let params = try request.decodeParams(type)
    try params.validate()
    return params
  }

  /// 结构写门禁：先看全局写开关；`closing` 是这次动作会结束的终端，其中有敏感会话时还要
  /// 敏感会话开关。不看 Pane 自身是否可写——进程已退出的 Pane 正是最需要被关掉的。
  private func gateStructureWrite(closing sessions: [TerminalSession]) throws {
    let policy = policyProvider()
    guard policy.allowSendKeys else {
      throw AsterControlError(code: .writeNotAllowed, message: "IPC Allow Send Keys 未开启。")
    }
    for session in sessions {
      if let blocker = AsterControlWriteGate.policyBlocker(
        session: session, allowSendKeys: policy.allowSendKeys,
        allowSensitiveSessions: policy.allowSensitiveSessions)
      {
        throw blocker
      }
    }
  }
}
