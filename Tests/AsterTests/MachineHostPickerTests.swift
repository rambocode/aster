import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// 添加机器面板里「已保存主机」下拉与 target / 标签字段的联动。

@MainActor
@Test("添加面板主机下拉：选主机时 target 只读并显示连接串，切回手动恢复原输入，标签自动跟随")
func machineHostBindingPickerTogglesTargetField() throws {
  let labelField = NSTextField()
  let targetField = NSTextField()
  targetField.stringValue = "root@ubuntu@orb"
  let first = MachineHostPicker.Choice(id: UUID(), title: "lab", target: "deploy@10.0.0.5")
  let second = MachineHostPicker.Choice(id: UUID(), title: "orb", target: "ssh://root@orb:32222")
  let broken = MachineHostPicker.Choice(id: UUID(), title: "loop", target: nil)
  let picker = MachineHostPicker(
    choices: [first, second, broken], targetField: targetField, labelField: labelField,
    selectedHostID: nil)

  #expect(picker.popup.numberOfItems == 4)
  #expect(picker.popup.itemTitles.first == L("手动输入 target"))
  #expect(picker.popup.item(at: 3)?.isEnabled == false)
  #expect(picker.selectedHostID == nil)
  #expect(targetField.isEditable)

  picker.select(hostID: first.id)
  #expect(picker.selectedHostID == first.id)
  #expect(targetField.stringValue == "deploy@10.0.0.5")
  #expect(!targetField.isEditable)
  #expect(labelField.stringValue == "lab")

  // 用户没改过标签：换主机时标签跟着换。
  picker.select(hostID: second.id)
  #expect(labelField.stringValue == "orb")
  // 用户改过标签：不再覆盖。
  labelField.stringValue = "my-orb"
  picker.select(hostID: first.id)
  #expect(labelField.stringValue == "my-orb")

  picker.select(hostID: nil)
  #expect(targetField.isEditable)
  #expect(targetField.stringValue == "root@ubuntu@orb")

  // 预填一个不可解析的主机：退回手动输入。
  picker.select(hostID: broken.id)
  #expect(picker.selectedHostID == nil)
}

@MainActor
@Test("主机下拉的选项：默认项不出现，解析失败的主机保留但没有 target")
func machineHostBindingPickerChoices() {
  let good = SSHHostProfile(name: "", host: "10.0.0.5", user: "deploy")
  let bad = SSHHostProfile(name: "loop", host: "x")
  let choices = MachineHostPicker.choices(for: [.emptyDefaults(), good, bad]) { id in
    if id == bad.id { throw SSHHostResolutionError.jumpCycle(id) }
    return "deploy@10.0.0.5"
  }
  #expect(choices.map(\.id) == [good.id, bad.id])
  #expect(choices[0].title == "deploy@10.0.0.5")
  #expect(choices[0].target == "deploy@10.0.0.5")
  #expect(choices[1].target == nil)
}
