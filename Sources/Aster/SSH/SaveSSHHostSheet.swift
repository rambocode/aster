import AppKit
import AsterCore
import Foundation

// 「保存为主机…」表单：Open Quickly 快连行、ssh alias 行与手敲 ssh 的标签菜单共用。
// 只收集名称、分组与 `user@host:port`；认证、跳板等进阶字段仍在设置 ▸ 主机里编辑。
// 风格与 `MachineSetupSheet` 一致：NSAlert + accessoryView，真实可点。

/// 保存为主机的表单与纯转换逻辑。
@MainActor
enum SaveSSHHostSheet {
  /// 表单预填值。
  struct Prefill: Equatable {
    var name: String
    var group: String?
    var target: QuickConnectTarget
    /// 「保存后立即连接」的初始勾选状态：已经连着的标签默认不勾，快连默认勾。
    var connectNow: Bool

    init(name: String, group: String? = nil, target: QuickConnectTarget, connectNow: Bool = false) {
      self.name = name
      self.group = group
      self.target = target
      self.connectNow = connectNow
    }

    /// 从手敲的 ssh 命令反推预填值。
    ///
    /// 目标是 `~/.ssh/config` 里的 alias 时，`ssh -G` 已解析出真实主机名（`resolved`）：
    /// 主机字段用真实地址，名称保留 alias，用户和端口以命令行显式值优先。
    static func derived(
      target: QuickConnectTarget, invocation: SSHCommandInvocation, resolved: SSHResolvedEndpoint?
    ) -> Prefill {
      var merged = target
      if let resolved, target.host == invocation.fallbackHostName, resolved.hostName != target.host {
        merged.host = resolved.hostName
        merged.user = target.user ?? resolved.user
        merged.port = target.port ?? resolved.port
      }
      return Prefill(name: target.host, target: merged)
    }
  }

  /// 用户提交的内容。
  struct Draft: Equatable {
    var name: String
    var group: String
    var target: String
    var connectNow: Bool
  }

  /// 表单内容无法变成主机配置的原因。
  enum SaveError: Error, Equatable {
    case invalidTarget(String)
  }

  /// 展示表单；取消返回 nil。
  ///
  /// - Parameter groups: 已有分组，供分组下拉补全。
  static func prompt(prefill: Prefill, groups: [String], in window: NSWindow?) -> Draft? {
    let alert = NSAlert()
    alert.messageText = L("保存为主机")
    alert.informativeText = L("保存后可在 Open Quickly 与「设置 ▸ 主机」里使用。认证方式、跳板机等选项请到设置里补充。")
    alert.addButton(withTitle: L("保存"))
    alert.addButton(withTitle: L("取消"))

    let form = NSStackView()
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 6
    form.frame = NSRect(x: 0, y: 0, width: 360, height: 118)

    let nameField = NSTextField()
    configure(nameField, placeholder: L("名称"), identifier: "save-host-name-field")
    nameField.stringValue = prefill.name
    let groupField = NSComboBox()
    configure(groupField, placeholder: L("分组（可选）"), identifier: "save-host-group-field")
    groupField.addItems(withObjectValues: groups)
    groupField.completes = true
    groupField.stringValue = prefill.group ?? ""
    let targetField = NSTextField()
    configure(targetField, placeholder: "user@host:port", identifier: "save-host-target-field")
    targetField.stringValue = prefill.target.displayText
    let connectBox = NSButton(checkboxWithTitle: L("保存后立即连接"), target: nil, action: nil)
    connectBox.identifier = NSUserInterfaceItemIdentifier("save-host-connect-checkbox")
    connectBox.state = prefill.connectNow ? .on : .off

    for field in [nameField, groupField, targetField] as [NSControl] {
      field.widthAnchor.constraint(equalToConstant: 360).isActive = true
      form.addArrangedSubview(field)
    }
    form.addArrangedSubview(connectBox)
    alert.accessoryView = form
    alert.window.initialFirstResponder = nameField

    guard run(alert, in: window) == .alertFirstButtonReturn else { return nil }
    return Draft(
      name: nameField.stringValue, group: groupField.stringValue, target: targetField.stringValue,
      connectNow: connectBox.state == .on)
  }

  /// 把表单内容变成一条新主机配置。纯函数。
  ///
  /// 名称为空时用主机地址；分组为空表示「未分组」；未写端口时不写 `port`，按默认项继承。
  static func makeProfile(_ draft: Draft, id: UUID = UUID()) throws -> SSHHostProfile {
    let text = draft.target.trimmingCharacters(in: .whitespaces)
    guard let target = QuickConnectTarget.parse(text) else { throw SaveError.invalidTarget(text) }
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let group = draft.group.trimmingCharacters(in: .whitespacesAndNewlines)
    return SSHHostProfile(
      id: id,
      name: name.isEmpty ? target.host : name,
      group: group.isEmpty ? nil : group,
      host: target.host,
      port: target.port,
      user: target.user ?? "")
  }

  /// 保存失败的用户文案。
  static func describe(_ error: any Error) -> String {
    if case SaveError.invalidTarget(let text) = error {
      return L("无法识别「\(text)」。请填写 user@host、user@host:port 或 [IPv6]:port。")
    }
    return SettingsHostsBridge.describe(error)
  }

  /// 手敲 ssh 命令不能保存时的用户文案。
  static func describe(_ rejection: QuickConnectTarget.DerivationRejection) -> String {
    switch rejection {
    case .unsupportedOption(let option):
      L("这条命令用了 \(option) 等选项，只保存地址会连到不同的配置。请在「设置 ▸ 主机」里新建主机并填写这些选项。")
    case .missingValue(let option):
      L("命令里的 \(option) 缺少取值。")
    case .invalidPort(let value):
      L("命令里的端口「\(value)」无效。")
    case .invalidDestination(let text):
      L("无法识别连接目标「\(text)」。")
    }
  }

  private static func configure(_ field: NSTextField, placeholder: String, identifier: String) {
    field.placeholderString = placeholder
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityLabel(placeholder)
  }

  /// 与 `MachineSetupSheet` 相同的展示方式：有窗口用 sheet，无窗口退化为模态。
  private static func run(_ alert: NSAlert, in window: NSWindow?) -> NSApplication.ModalResponse {
    guard let window else { return alert.runModal() }
    alert.beginSheetModal(for: window) { response in NSApp.stopModal(withCode: response) }
    return NSApp.runModal(for: alert.window)
  }
}
