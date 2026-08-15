import AsterCore
import Foundation
import Markdown

/// Agent transcript → 无脚本 HTML 正文（Otty 对齐的会话渲染）。
///
/// 角色靠视觉区分：用户消息进浅色圆角卡片（原文转义、保留换行），Claude 消息按
/// Markdown 渲染；连续的工具调用 / Reasoning / System 折叠成一行 `<details>` 摘要
/// （「Claude · 30×Bash, 26×Edit · 12,345 chars」），展开是原生 HTML 行为，不需要
/// JavaScript。输出只在 File Pane 的加固 WKWebView（无 JS、CSP 锁死、无网络）中
/// 展示，安全边界与既有 Markdown 预览一致。
enum AgentTranscriptHTML {
  /// 单条与总量双重上限，与纯文本渲染同一口径：超限必须显式说明，不做静默截断。
  static let entryDisplayLimit = 4_000
  static let totalDisplayLimit = 400_000

  /// 折叠组的中间聚合。`orderedNames` 保持首次出现顺序，摘要才能稳定可读。
  private struct CollapsedGroup {
    var counts: [String: Int] = [:]
    var orderedNames: [String] = []
    var text = ""
    var isEmpty: Bool { orderedNames.isEmpty }

    mutating func add(name: String, text entryText: String) {
      if counts[name] == nil { orderedNames.append(name) }
      counts[name, default: 0] += 1
      if !entryText.isEmpty {
        text += (text.isEmpty ? "" : "\n\n") + entryText
      }
    }

    var summary: String {
      var parts = orderedNames.map { "\(counts[$0] ?? 0)×\($0)" }
      if !text.isEmpty { parts.append("\(text.count) chars") }
      return "Claude · " + parts.joined(separator: ", ")
    }
  }

  /// 拼装 transcript 正文 HTML。可能在主线程外调用；DateFormatter 非线程安全，
  /// 因此按调用局部创建，不做共享静态实例。
  static func body(entries: [AgentTranscriptEntry]) -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm:ss"
    func timeSuffix(_ date: Date?) -> String {
      guard let date else { return "" }
      return " · " + timeFormatter.string(from: date)
    }
    var html = ""
    var group = CollapsedGroup()
    var renderedCharacters = 0
    var renderedEntries = 0

    func flushGroup() {
      guard !group.isEmpty else { return }
      let bounded = group.text.count > entryDisplayLimit
        ? String(group.text.prefix(entryDisplayLimit)) + "\n…（已截断，共 \(group.text.count) 字符）"
        : group.text
      html += "<details class=\"tools\"><summary>\(escape(group.summary))</summary>"
      if !bounded.isEmpty { html += "<pre>\(escape(bounded))</pre>" }
      html += "</details>\n"
      group = CollapsedGroup()
    }

    for entry in entries {
      if renderedCharacters >= totalDisplayLimit {
        flushGroup()
        html += "<p class=\"notice\">— transcript 过长，其余 \(entries.count - renderedEntries) 条未显示；完整内容见会话文件 —</p>\n"
        return html
      }
      switch entry.kind {
      case .message(let role):
        flushGroup()
        let bounded = boundedText(entry.text)
        switch role {
        case .user:
          html += "<section class=\"you\"><header>You\(timeSuffix(entry.timestamp))</header>"
          html += "<div class=\"bubble\">\(escape(bounded))</div></section>\n"
        case .assistant:
          html += "<section class=\"claude\"><header>Claude\(timeSuffix(entry.timestamp))</header>"
          html += "<div class=\"md\">\(HTMLFormatter.format(bounded))</div></section>\n"
        case .system:
          // System 消息是模板噪音，与工具组同级折叠，不占正文视觉层级。
          group.add(name: "System", text: entry.text)
          flushGroup()
        }
        renderedCharacters += entry.text.count
      case .toolCall(let name):
        group.add(name: name, text: entry.text)
        renderedCharacters += entry.text.count
      case .reasoning:
        group.add(name: "Reasoning", text: entry.text)
        renderedCharacters += entry.text.count
      case .attachment(let name):
        flushGroup()
        html += "<div class=\"chip\">📎 \(escape(name ?? "Image"))</div>\n"
      }
      renderedEntries += 1
    }
    flushGroup()
    return html
  }

  /// 完整 HTML 文档：与 Markdown 预览同一条 CSP（无脚本、无网络、内联样式）。
  /// 颜色跟随系统明暗，与既有 web 预览一样属于主题令牌规则的显式例外。
  static func document(body: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src file: data:; style-src 'unsafe-inline'">
    <style>
    :root{color-scheme:light dark}
    body{font:14px -apple-system;margin:0;padding:10px 24px 40px;line-height:1.55;color:#2d3033;background:transparent}
    section{margin:14px 0}
    section header{font-size:11px;color:#8a9096;margin-bottom:5px}
    .you .bubble{background:rgba(64,160,112,.10);border-radius:10px;padding:10px 14px;white-space:pre-wrap;overflow-wrap:anywhere;font:12.5px ui-monospace,monospace}
    .claude .md{overflow-wrap:anywhere}
    .claude .md h1,.claude .md h2,.claude .md h3{line-height:1.25;margin:1.1em 0 .4em;font-size:1.05em}
    .claude .md pre{font:12.5px ui-monospace,monospace;padding:12px;overflow:auto;background:rgba(127,127,127,.11);border-radius:7px}
    .claude .md code{font:12.5px ui-monospace,monospace}
    .claude .md blockquote{border-left:3px solid #999;padding-left:12px;color:#666;margin-left:0}
    .claude .md table{border-collapse:collapse} .claude .md th,.claude .md td{border:1px solid #aaa;padding:5px 8px}
    .claude .md img{max-width:100%;height:auto}
    details.tools{margin:8px 0;font-size:12px;color:#8a9096}
    details.tools summary{cursor:pointer;user-select:none}
    details.tools pre{font:11.5px ui-monospace,monospace;background:rgba(127,127,127,.09);padding:10px;border-radius:8px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;color:#5a6066}
    .chip{display:inline-block;background:rgba(127,127,127,.13);border-radius:6px;padding:2px 9px;font-size:11px;color:#5a6066;margin:2px 0}
    .notice{font-size:11.5px;color:#8a9096;text-align:center}
    @media(prefers-color-scheme:dark){body{color:#ddd} .claude .md blockquote{color:#aaa} details.tools pre{color:#a8adb3} .chip{color:#a8adb3}}
    </style></head><body>\(body)</body></html>
    """
  }

  private static func boundedText(_ text: String) -> String {
    guard text.count > entryDisplayLimit else { return text }
    return String(text.prefix(entryDisplayLimit)) + "\n\n…（本条已截断，共 \(text.count) 字符）"
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
