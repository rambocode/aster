import AppKit
import AsterCore
import Foundation

// 「添加机器」面板里的「已保存主机」下拉：第一项是手动输入 target，其后是已保存主机。
// 选中主机后 target 字段只读并显示该主机的连接串；切回手动时恢复用户之前输入的内容。

/// 已保存主机下拉与 target / 标签字段的联动。
@MainActor
final class MachineHostPicker: NSObject {
  /// 下拉里的一台主机。`target` 为 nil 表示主机当前无法解析（例如跳板成环），显示但不可选。
  struct Choice: Equatable {
    var id: UUID
    var title: String
    var target: String?
  }

  let popup: NSPopUpButton
  private let targetField: NSTextField
  private let labelField: NSTextField
  private let choices: [Choice]
  /// 手动模式下用户输入的 target；切到主机时暂存，切回时恢复。
  private var manualTarget: String
  /// 由选择主机自动填进标签的值。标签仍等于它（用户没改过）时，换主机会跟着换。
  private var autoLabel: String?

  /// 由已保存主机生成下拉项。`hostTarget` 解析失败的主机保留在列表里但不可选。
  static func choices(
    for hosts: [SSHHostProfile], hostTarget: (UUID) throws -> String
  ) -> [Choice] {
    hosts.filter { !$0.isDefaults }.map { host in
      let title = host.name.isEmpty ? host.connectString : host.name
      do {
        return Choice(id: host.id, title: title, target: try hostTarget(host.id))
      } catch {
        return Choice(id: host.id, title: title, target: nil)
      }
    }
  }

  init(
    choices: [Choice], targetField: NSTextField, labelField: NSTextField, selectedHostID: UUID?
  ) {
    self.choices = choices
    self.targetField = targetField
    self.labelField = labelField
    manualTarget = targetField.stringValue
    popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
    super.init()
    popup.identifier = NSUserInterfaceItemIdentifier("machine-host-picker")
    popup.setAccessibilityLabel(L("已保存主机"))
    popup.translatesAutoresizingMaskIntoConstraints = false
    // 不可解析的主机要显示成灰色项，必须关掉自动启用。
    popup.autoenablesItems = false
    popup.addItem(withTitle: L("手动输入 target"))
    for choice in choices {
      let title =
        choice.target == nil ? L("\(choice.title)（配置无法解析）") : "\(choice.title) — \(choice.target ?? "")"
      popup.addItem(withTitle: title)
      popup.lastItem?.representedObject = choice.id.uuidString
      popup.lastItem?.isEnabled = choice.target != nil
    }
    popup.target = self
    popup.action = #selector(selectionChanged(_:))
    select(hostID: selectedHostID)
  }

  /// 当前选中的主机；手动输入时为 nil。
  var selectedHostID: UUID? {
    let index = popup.indexOfSelectedItem
    guard index > 0, index - 1 < choices.count else { return nil }
    return choices[index - 1].id
  }

  /// 程序化选择（预填）。主机不存在或不可解析时退回手动输入。
  func select(hostID: UUID?) {
    let index = hostID.flatMap { id in
      choices.firstIndex { $0.id == id && $0.target != nil }
    }
    popup.selectItem(at: index.map { $0 + 1 } ?? 0)
    apply()
  }

  @objc private func selectionChanged(_ sender: NSPopUpButton) { apply() }

  /// 按当前选择刷新 target 与标签字段。
  private func apply() {
    guard let id = selectedHostID, let choice = choices.first(where: { $0.id == id }),
      let target = choice.target
    else {
      if !targetField.isEditable {
        // 从主机切回手动：恢复用户原来输入的内容，而不是留着主机的连接串。
        targetField.stringValue = manualTarget
      }
      targetField.isEditable = true
      targetField.isSelectable = true
      return
    }
    if targetField.isEditable { manualTarget = targetField.stringValue }
    targetField.stringValue = target
    targetField.isEditable = false
    targetField.isSelectable = true
    let currentLabel = labelField.stringValue
    if currentLabel.isEmpty || currentLabel == autoLabel {
      labelField.stringValue = choice.title
      autoLabel = choice.title
    }
  }
}
