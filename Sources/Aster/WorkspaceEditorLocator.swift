import AppKit

/// 详情面板「Open in …」动作探测到的本机编辑器。
struct DetectedEditor: Equatable {
  let name: String
  let bundleIdentifier: String
  let appURL: URL
}

/// 按固定 bundle ID 表探测已安装的编辑器；lookup 可注入，测试不依赖本机真实安装。
/// 打开动作走 NSWorkspace 显式指定应用，不经过 scheme 猜测或 shell 命令。
enum WorkspaceEditorLocator {
  /// 展示顺序固定：VS Code（含 Insiders 作为独立条目不重复）、Cursor、Xcode、Zed。
  private static let knownEditors: [(name: String, bundleIdentifier: String)] = [
    ("VS Code", "com.microsoft.VSCode"),
    ("Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Xcode", "com.apple.dt.Xcode"),
    ("Zed", "dev.zed.Zed"),
  ]

  static func detect(
    lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
  ) -> [DetectedEditor] {
    knownEditors.compactMap { candidate in
      guard let url = lookup(candidate.bundleIdentifier) else { return nil }
      return DetectedEditor(
        name: candidate.name, bundleIdentifier: candidate.bundleIdentifier, appURL: url)
    }
  }

  /// 在指定编辑器中打开目录；失败静默（面板动作不提供错误通道，用户可从 Finder 重试）。
  static func open(directory: URL, in editor: DetectedEditor) {
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open(
      [directory], withApplicationAt: editor.appURL, configuration: configuration)
  }
}
