import Darwin
import Foundation
import Highlighter

/// 发布脚本使用的无窗口资源自检。该入口从最终 `.app` 可执行文件内部运行，因此能同时
/// 验证资源复制位置和实际运行时代码；它不会创建 `NSApplication`、窗口或用户数据。
enum PackagedResourceVerifier {
  static let command = "--verify-packaged-resources"

  static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
    guard Array(arguments.dropFirst()) == [command] else { return false }

    let failures = verify()
    if failures.isEmpty {
      write("Aster packaged resources: OK\n", to: .standardOutput)
      return true
    }
    for failure in failures {
      write("Aster packaged resources: \(failure)\n", to: .standardError)
    }
    Darwin.exit(EXIT_FAILURE)
  }

  /// 返回稳定、不含用户路径的失败描述；空数组表示 Ghostty 和代码高亮资源均可使用。
  static func verify(fileManager: FileManager = .default) -> [String] {
    var failures: [String] = []

    if let bundle = PackagedResourceBundle.locate(named: "AsterTerminal_Aster.bundle"),
      let root = bundle.resourceURL
    {
      let required = [
        root.appendingPathComponent("ghostty/shell-integration", isDirectory: true),
        root.appendingPathComponent("terminfo/78/xterm-ghostty"),
      ]
      if required.contains(where: { !fileManager.fileExists(atPath: $0.path) }) {
        failures.append("libghostty resource bundle is incomplete")
      }
    } else {
      failures.append("libghostty resource bundle is missing")
    }

    guard let highlighter = Highlighter(), highlighter.setTheme("panda-syntax-light") else {
      failures.append("Highlighter resource bundle is missing or incomplete")
      return failures
    }
    return failures
  }

  private static func write(_ value: String, to handle: FileHandle) {
    if let data = value.data(using: .utf8) {
      handle.write(data)
    }
  }
}
