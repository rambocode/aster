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
    alert.messageText = "添加机器"
    alert.informativeText =
      "输入 SSH target（支持 alias、user@host、ssh://user@host:port 和 root@ubuntu@orb）"
      + "，并指定要绑定的命名会话。一个配置只绑定一个会话。"
    alert.addButton(withTitle: "连接并保存")
    alert.addButton(withTitle: "取消")

    let form = NSStackView()
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 6
    form.frame = NSRect(x: 0, y: 0, width: 360, height: 108)

    let labelField = makeField(placeholder: "标签，例如 orb-ubuntu", identifier: "machine-label-field")
    let targetField = makeField(
      placeholder: "SSH target，例如 root@ubuntu@orb", identifier: "machine-target-field")
    let sessionField = makeField(placeholder: "命名会话", identifier: "machine-session-field")
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
    alert.messageText = "重命名机器"
    alert.informativeText = "重命名只更新显示标签，不会断开或重建连接。"
    alert.addButton(withTitle: "重命名")
    alert.addButton(withTitle: "取消")
    let field = makeField(placeholder: "标签", identifier: "machine-rename-field")
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
      case .installation: "需要在远端安装 aster-session"
      case .incompatibleServer: "远端运行中的服务与客户端不兼容"
      case .developmentArtifact: "将使用自定义开发产物"
      }
    alert.informativeText = """
      目标：\(confirmation.target)
      平台：\(confirmation.platform)
      版本：\(confirmation.version)
      进程影响：\(confirmation.processImpact)

      \(confirmation.reason)
      """
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "我已了解，继续")
    return run(alert, in: window) == .alertSecondButtonReturn
  }

  /// 移除机器的确认。移除只断开配置，远端资源全部保留——文案必须说清楚。
  static func confirmRemoval(label: String, in window: NSWindow?) -> Bool {
    let alert = NSAlert()
    alert.messageText = "移除机器「\(label)」？"
    alert.informativeText =
      "只会删除本机上的这份配置并断开连接。远端的命名会话、终端进程与布局全部保留，不会被停止。"
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "移除")
    return run(alert, in: window) == .alertSecondButtonReturn
  }

  /// 展示一条可直接阅读的失败说明。文案来自设置事务，已脱敏。
  static func presentFailure(_ message: String, in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "操作未完成"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
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
