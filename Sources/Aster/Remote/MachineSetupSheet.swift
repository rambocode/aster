import AppKit
import AsterCore
import Foundation

/// 添加/重命名机器的交互入口（P4.3）。
///
/// 全部对话框都是**真实可点**的 AppKit 面板，不是编程接口的包装：验收要求 UI 阶段
/// 用真实操作完成，而不是调用控制器方法。
@MainActor
enum MachineSetupSheet {
  /// 用户在添加面板里填的内容。
  struct Draft: Equatable {
    var label: String
    var sshTarget: String
    var sessionName: String
  }

  /// 展示添加机器面板。取消返回 nil，此时**不做任何网络动作、不保存配置**。
  static func promptForNewMachine(in window: NSWindow?) -> Draft? {
    let alert = NSAlert()
    alert.messageText = L("添加机器")
    alert.informativeText =
      L("输入 SSH target（支持 alias、user@host、ssh://user@host:port 和 root@ubuntu@orb）")
      + L("，并指定要绑定的命名会话。一个配置只绑定一个会话。")
    alert.addButton(withTitle: L("连接并保存"))
    alert.addButton(withTitle: L("取消"))

    let form = NSStackView()
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 6
    form.frame = NSRect(x: 0, y: 0, width: 360, height: 108)

    let labelField = makeField(placeholder: L("标签，例如 orb-ubuntu"), identifier: "machine-label-field")
    let targetField = makeField(
      placeholder: L("SSH target，例如 root@ubuntu@orb"), identifier: "machine-target-field")
    let sessionField = makeField(placeholder: L("命名会话"), identifier: "machine-session-field")
    sessionField.stringValue = "default"
    for field in [labelField, targetField, sessionField] {
      field.widthAnchor.constraint(equalToConstant: 360).isActive = true
      form.addArrangedSubview(field)
    }
    alert.accessoryView = form
    alert.window.initialFirstResponder = labelField

    let response = run(alert, in: window)
    guard response == .alertFirstButtonReturn else { return nil }
    return Draft(
      label: labelField.stringValue,
      sshTarget: targetField.stringValue,
      sessionName: sessionField.stringValue.isEmpty ? "default" : sessionField.stringValue)
  }

  /// 展示重命名面板。重命名只改标签，不触发重连。
  static func promptForRename(current: String, in window: NSWindow?) -> String? {
    let alert = NSAlert()
    alert.messageText = L("重命名机器")
    alert.informativeText = L("重命名只更新显示标签，不会断开或重建连接。")
    alert.addButton(withTitle: L("重命名"))
    alert.addButton(withTitle: L("取消"))
    let field = makeField(placeholder: L("标签"), identifier: "machine-rename-field")
    field.stringValue = current
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard run(alert, in: window) == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }

  /// 展示需要安装 / 需要替换不兼容服务的确认（§4.1 第 2 条）。
  ///
  /// 必须同时展示**目标、版本和进程影响**：用户在点确认之前要知道这会不会杀掉
  /// 远端正在跑的任务。默认按钮是取消，避免误按回车就动了远端进程。
  static func confirm(_ confirmation: MachineSetupConfirmation, in window: NSWindow?) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      switch confirmation.kind {
      case .installation: L("需要在远端安装 aster-session")
      case .incompatibleServer: L("远端运行中的服务与客户端不兼容")
      case .developmentArtifact: L("将向远端安装未签名的开发产物")
      case .serviceReplacement: L("更新远端 aster-session 将重启服务")
      }
    alert.informativeText =
      L("目标：\(confirmation.target)\n平台：\(confirmation.platform)\n版本：\(confirmation.version)\n进程影响：\(confirmation.processImpact)\n\n\(confirmation.reason)")
    alert.addButton(withTitle: L("取消"))
    alert.addButton(withTitle: L("我已了解，继续"))
    return run(alert, in: window) == .alertSecondButtonReturn
  }

  /// 移除机器的确认。移除只断开配置，远端资源全部保留——文案必须说清楚。
  static func confirmRemoval(label: String, in window: NSWindow?) -> Bool {
    let alert = NSAlert()
    alert.messageText = L("移除机器「\(label)」？")
    alert.informativeText =
      L("只会删除本机上的这份配置并断开连接。远端的命名会话、终端进程与布局全部保留，不会被停止。")
    alert.addButton(withTitle: L("取消"))
    alert.addButton(withTitle: L("移除"))
    return run(alert, in: window) == .alertSecondButtonReturn
  }

  /// 远端 Agent 集成的确认：列出远端发现的 CLI、将改动的远端配置文件与 hook 脚本位置。
  /// 改的是用户在远端 home 下的 Agent 配置，必须先看清楚再点。
  static func confirmAgentIntegration(
    _ report: RemoteAgentIntegrationReport, target: String, in window: NSWindow?
  ) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L("在远端安装 Aster Agent 集成")
    let pending = report.pending.map { entry in
      "• \(entry.provider.displayName)\(entry.version.map { " \($0)" } ?? "") → \(entry.configurationPath ?? "")"
    }
    let done = report.candidates.filter(\.integrated).map { "• \($0.provider.displayName)（\(L("已就位"))）" }
    let screenOnly = report.screenOnly.map(\.provider.displayName)
    var lines = [L("目标：\(target)"), L("hook 脚本：\(report.hookScriptPath)"), "", L("将写入远端配置：")]
    lines += pending
    if !done.isEmpty { lines += ["", L("无需改动：")] + done }
    if !screenOnly.isEmpty {
      lines += ["", L("只能屏幕检测（不改动）：\(screenOnly.joined(separator: "、"))")]
    }
    lines += ["", L("只添加带 Aster 标记的 hook 条目，不覆盖你的其它配置；可随时在远端删除。")]
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: L("取消"))
    alert.addButton(withTitle: L("安装"))
    return run(alert, in: window) == .alertSecondButtonReturn
  }

  /// 「新建远端 Agent」选择面板：只列远端真实探测到的 CLI（对齐 herdrm 的 New Agent）。
  static func promptForRemoteAgent(
    _ catalog: [RemoteAgentCatalogEntry], machineLabel: String, in window: NSWindow?
  ) -> AgentProvider? {
    let alert = NSAlert()
    alert.messageText = L("在「\(machineLabel)」上新建 Agent")
    alert.informativeText = L("在远端以 Agent 身份开一个标签：登录 Shell 直接启动所选 CLI，退出即关闭标签。")
    alert.addButton(withTitle: L("启动"))
    alert.addButton(withTitle: L("取消"))
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
    popup.identifier = NSUserInterfaceItemIdentifier("machine-agent-picker")
    for entry in catalog {
      let title = entry.version.map { "\(entry.provider.displayName) — \($0)" } ?? entry.provider.displayName
      popup.addItem(withTitle: title)
      popup.lastItem?.representedObject = entry.provider.rawValue
    }
    alert.accessoryView = popup
    alert.window.initialFirstResponder = popup
    guard run(alert, in: window) == .alertFirstButtonReturn,
      let raw = popup.selectedItem?.representedObject as? String
    else { return nil }
    return AgentProvider(rawValue: raw)
  }

  /// 远端 Agent 集成的结果说明。
  static func presentAgentIntegration(_ report: RemoteAgentIntegrationReport, in window: NSWindow?) {
    let alert = NSAlert()
    let failures = report.entries.filter { $0.failure != nil }
    alert.alertStyle = failures.isEmpty ? .informational : .warning
    alert.messageText = failures.isEmpty ? L("远端 Agent 集成已就位") : L("远端 Agent 集成部分失败")
    var lines = report.candidates.map { entry -> String in
      if let failure = entry.failure { return "• \(entry.provider.displayName)：\(L("失败"))——\(failure)" }
      return "• \(entry.provider.displayName)：\(entry.integrated ? L("已集成") : L("未集成"))"
    }
    lines += ["", L("远端 Agent 需要重新启动才会加载 hook。之后它的状态、等待输入与完成通知会出现在侧栏与 Dock。")]
    alert.informativeText = lines.joined(separator: "\n")
    alert.addButton(withTitle: L("好"))
    _ = run(alert, in: window)
  }

  /// 展示一条信息性说明（例如"远端已是最新"）。不是错误，不用警告样式。
  static func presentNotice(_ message: String, title: String = L("无需更新"), in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L("好"))
    _ = run(alert, in: window)
  }

  /// 展示一条可直接阅读的失败说明。文案来自设置事务，已脱敏。
  static func presentFailure(_ message: String, in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("操作未完成")
    alert.informativeText = message
    alert.addButton(withTitle: L("好"))
    _ = run(alert, in: window)
  }

  private static func makeField(placeholder: String, identifier: String) -> NSTextField {
    let field = NSTextField()
    field.placeholderString = placeholder
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityLabel(placeholder)
    return field
  }

  /// 统一的展示方式：有窗口时用 sheet，无窗口（例如无头测试宿主）时退化为模态。
  private static func run(_ alert: NSAlert, in window: NSWindow?) -> NSApplication.ModalResponse {
    guard let window else { return alert.runModal() }
    var result: NSApplication.ModalResponse = .cancel
    alert.beginSheetModal(for: window) { response in
      result = response
      NSApp.stopModal(withCode: response)
    }
    result = NSApp.runModal(for: alert.window)
    return result
  }
}
