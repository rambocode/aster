import Foundation
import Testing

@testable import Aster

@Test("外部终端集成写入 settings.json 并保留其它键,拒绝改写 JSONC")
func externalTerminalIntegrationUpdatesSettingsFile() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-ext-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("Code/User/settings.json")

  // 不存在时新建
  #expect(try ExternalTerminalIntegration.updateSettingsFile(at: url, executable: "/Applications/Aster.app"))
  var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  #expect(object?["terminal.external.osxExec"] as? String == "/Applications/Aster.app")

  // 已有其它键时保留,且相同值不重复写
  try Data(#"{"editor.fontSize": 14, "terminal.external.osxExec": "iTerm.app"}"#.utf8).write(to: url)
  #expect(try ExternalTerminalIntegration.updateSettingsFile(at: url, executable: "/Applications/Aster.app"))
  object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  #expect(object?["editor.fontSize"] as? Int == 14)
  #expect(object?["terminal.external.osxExec"] as? String == "/Applications/Aster.app")
  #expect(try !ExternalTerminalIntegration.updateSettingsFile(at: url, executable: "/Applications/Aster.app"))

  // 带注释的 JSONC 不能解析时必须失败而不是覆盖
  try Data("// comment\n{\"a\": 1}".utf8).write(to: url)
  #expect(throws: ExternalTerminalIntegration.SettingsError.self) {
    try ExternalTerminalIntegration.updateSettingsFile(at: url, executable: "x")
  }

  let editor = ExternalTerminalIntegration.editors[0]
  let sublime = ExternalTerminalIntegration.editors.last!
  let outcomes = ExternalTerminalIntegration.configure(
    [editor, sublime], applicationSupport: root.appendingPathComponent("fresh"), executable: "Aster.app")
  #expect(outcomes[0] == .configured(editor))
  #expect(outcomes[1] == .unsupported(sublime))
  #expect(ExternalTerminalIntegration.summary(outcomes).contains("已配置：VS Code"))
}
