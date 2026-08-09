import AppKit
import AsterCore
import Highlighter
import Markdown

/// File Pane 后台渲染的值类型结果。跨 actor 只传递 `String` / `Data`，避免把
/// `NSAttributedString`、WebKit 或 Highlighter 的非 Sendable 对象带回主线程。
enum FileRenderArtifact: Sendable {
  case highlightedRTF(Data)
  case webBody(String)
}

/// File Pane 只依赖这一条窄渲染边界。生产实现由 actor 串行执行，测试可注入轻量
/// renderer 验证过期结果丢弃等时序，而不需要启动真实 JavaScript 高亮器。
protocol FileRendering: Sendable {
  func renderSource(_ text: String, language: String?) async -> FileRenderArtifact?
  func renderPreview(_ text: String, kind: FilePresentationKind) async -> FileRenderArtifact?
}

/// 一个工作区窗口持有一个实例。actor 的串行隔离既把 CPU 密集的 Markdown 和语法
/// 高亮移出主线程，也避免 Highlighter 内部 JavaScriptContext 被并发访问。
actor FileRenderPipeline: FileRendering {
  func renderSource(_ text: String, language: String?) -> FileRenderArtifact? {
    guard !Task.isCancelled, let highlighter = Highlighter() else { return nil }
    // HighlighterSwift 3.1 内置的旧 `xcode` CSS 缺少新版 highlight.js 会输出的
    // `hljs-operator`，Debug 构建会为每个运算符打印警告。`panda-syntax-light`
    // 同时显式定义 params/operator 等新 token，并保持适合浅色编辑器的对比度。
    _ = highlighter.setTheme("panda-syntax-light")
    guard let highlighted = highlighter.highlight(text, as: language), !Task.isCancelled,
      let data = try? highlighted.data(
        from: NSRange(location: 0, length: highlighted.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
      )
    else { return nil }
    return .highlightedRTF(data)
  }

  func renderPreview(_ text: String, kind: FilePresentationKind) -> FileRenderArtifact? {
    guard !Task.isCancelled else { return nil }
    let body: String
    switch kind {
    case .markdown:
      body = HTMLFormatter.format(text)
    case .restructuredText:
      body = Self.restructuredTextHTML(text)
    case .html, .svg:
      body = text
    default:
      return nil
    }
    return Task.isCancelled ? nil : .webBody(body)
  }

  private static func restructuredTextHTML(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var output: [String] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if index + 1 < lines.count, !line.isEmpty,
        !lines[index + 1].isEmpty,
        Set(lines[index + 1]).isSubset(of: Set("=-~^\"`:+*#")),
        lines[index + 1].count >= line.count
      {
        let level = lines[index + 1].first == "=" ? 1 : 2
        output.append("<h\(level)>\(escapeHTML(line))</h\(level)>")
        index += 2
      } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
        output.append("<p>• \(escapeHTML(String(line.dropFirst(2))))</p>")
        index += 1
      } else {
        output.append(line.isEmpty ? "<br>" : "<p>\(escapeHTML(line))</p>")
        index += 1
      }
    }
    return output.joined(separator: "\n")
  }

  private static func escapeHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
