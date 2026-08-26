import AppKit
import Foundation

/// 把 Aster 写进常用编辑器的「外部终端」设置(对应设置页「为常用应用设为默认终端」)。
/// VS Code 系编辑器共用 `terminal.external.osxExec` 键;Sublime Text 没有内置外部终端
/// 设置,只能提示用户安装 Terminal 包后手动指向 Aster。
enum ExternalTerminalIntegration {
  struct Editor: Equatable {
    let name: String
    let bundleIdentifiers: [String]
    /// 相对 ~/Library/Application Support 的 settings.json 路径;nil 表示不支持自动写入。
    let settingsRelativePath: String?
  }

  static let editors: [Editor] = [
    Editor(name: "VS Code", bundleIdentifiers: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"],
      settingsRelativePath: "Code/User/settings.json"),
    Editor(name: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
      settingsRelativePath: "Cursor/User/settings.json"),
    Editor(name: "Windsurf", bundleIdentifiers: ["com.exafunction.windsurf"],
      settingsRelativePath: "Windsurf/User/settings.json"),
    Editor(name: "VSCodium", bundleIdentifiers: ["com.vscodium"],
      settingsRelativePath: "VSCodium/User/settings.json"),
    Editor(name: "Trae", bundleIdentifiers: ["com.trae.app"],
      settingsRelativePath: "Trae/User/settings.json"),
    Editor(name: "Sublime Text", bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3"],
      settingsRelativePath: nil),
  ]

  static let settingKey = "terminal.external.osxExec"

  enum Outcome: Equatable {
    case configured(Editor)
    case alreadyConfigured(Editor)
    case unsupported(Editor)
    case failed(Editor, String)
  }

  /// 已安装的编辑器:按 bundle ID 查 LaunchServices;开发时也可能一个都没装。
  static func installedEditors(workspace: NSWorkspace = .shared) -> [Editor] {
    editors.filter { editor in
      editor.bundleIdentifiers.contains { workspace.urlForApplication(withBundleIdentifier: $0) != nil }
    }
  }

  /// VS Code 用 `open -a <osxExec>` 启动外部终端;打包后写绝对路径最稳,开发运行时退回名称。
  static var executableValue: String {
    let bundleURL = Bundle.main.bundleURL
    return bundleURL.pathExtension == "app" ? bundleURL.path : "Aster.app"
  }

  /// 对每个编辑器写入设置,返回逐项结果供设置页汇总展示。
  static func configure(
    _ editors: [Editor],
    applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
    executable: String = executableValue
  ) -> [Outcome] {
    editors.map { editor in
      guard let relative = editor.settingsRelativePath else { return .unsupported(editor) }
      let url = applicationSupport.appendingPathComponent(relative)
      do {
        return try updateSettingsFile(at: url, executable: executable) ? .configured(editor) : .alreadyConfigured(editor)
      } catch {
        return .failed(editor, error.localizedDescription)
      }
    }
  }

  enum SettingsError: LocalizedError {
    case notAnObject
    case unparsable

    var errorDescription: String? {
      switch self {
      case .notAnObject: "settings.json 顶层不是对象"
      case .unparsable: "settings.json 含注释或语法错误,无法安全改写"
      }
    }
  }

  /// 读改写 settings.json。返回 false 表示已经是目标值、无需写入。
  /// 文件不存在时新建;含注释/尾逗号的 JSONC 无法用 JSONSerialization 解析,宁可失败也不
  /// 覆盖用户的手写配置。
  @discardableResult
  static func updateSettingsFile(at url: URL, executable: String) throws -> Bool {
    let fileManager = FileManager.default
    var object: [String: Any] = [:]
    if let data = try? Data(contentsOf: url), !data.isEmpty {
      guard let parsed = try? JSONSerialization.jsonObject(with: data) else { throw SettingsError.unparsable }
      guard let dictionary = parsed as? [String: Any] else { throw SettingsError.notAnObject }
      object = dictionary
    }
    if object[settingKey] as? String == executable { return false }
    object[settingKey] = executable
    let encoded = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded.write(to: url, options: .atomic)
    return true
  }

  /// 把结果汇总成一行状态文案。
  static func summary(_ outcomes: [Outcome]) -> String {
    var parts: [String] = []
    let configured = outcomes.compactMap { if case .configured(let e) = $0 { e.name } else { nil } }
    let already = outcomes.compactMap { if case .alreadyConfigured(let e) = $0 { e.name } else { nil } }
    let unsupported = outcomes.compactMap { if case .unsupported(let e) = $0 { e.name } else { nil } }
    let failed = outcomes.compactMap { if case .failed(let e, let reason) = $0 { "\(e.name)（\(reason)）" } else { nil } }
    if !configured.isEmpty { parts.append("已配置：" + configured.joined(separator: "、")) }
    if !already.isEmpty { parts.append("已是 Aster：" + already.joined(separator: "、")) }
    if !unsupported.isEmpty {
      parts.append(unsupported.joined(separator: "、") + " 没有内置外部终端设置，请安装 Terminal 包后手动指向 Aster")
    }
    if !failed.isEmpty { parts.append("失败：" + failed.joined(separator: "、")) }
    return parts.isEmpty ? "未检测到支持的应用" : parts.joined(separator: "；")
  }
}
