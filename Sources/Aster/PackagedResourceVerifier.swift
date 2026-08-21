import AsterCore
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

    // 主资源目录的 terminfo 由 build-app.sh 生成：61/ 为品牌条目（aster、aster-direct），
    // 67/78 为引擎条目；auto 的 TERM 解析依赖 78/xterm-ghostty 存在。
    if let resources = Bundle.main.resourceURL {
      let terminfo = resources.appendingPathComponent("terminfo", isDirectory: true)
      let entries = ["61/aster", "61/aster-direct", "67/ghostty", "78/xterm-ghostty"]
      if entries.contains(where: {
        !fileManager.fileExists(atPath: terminfo.appendingPathComponent($0).path)
      }) {
        failures.append("bundled terminfo database is incomplete")
      }
    }

    // 主题种子：数量必须与代码内真值表对齐。少一套就意味着 build-app.sh 漏拷或
    // 仓库基线被删，用户首次启动会静默回落到序列化版本，问题要到肉眼比色才暴露。
    if let resources = Bundle.main.resourceURL {
      let themes = resources.appendingPathComponent("themes", isDirectory: true)
      let seeds = (try? fileManager.contentsOfDirectory(atPath: themes.path)) ?? []
      let count = seeds.filter { $0.hasSuffix(".astertheme") }.count
      if count != TerminalThemeCatalog.builtIns.count {
        failures.append("bundled theme seeds are incomplete")
      }
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
