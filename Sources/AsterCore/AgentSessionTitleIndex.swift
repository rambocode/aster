import Foundation

/// provider 自己维护的会话名。有它就不必拿首条 prompt 截断当标题：
/// - Claude Code 在 transcript 里追加 `ai-title`（自动生成）与 `custom-title`（`/rename`）记录；
/// - Codex 把 AI 生成的线程名写在 `~/.codex/session_index.jsonl`（rollout 本身没有标题记录）。
public enum AgentSessionTitleIndex {
  /// Claude transcript 里找到的标题记录。
  public struct ClaudeTitles: Equatable, Sendable {
    public var customTitle: String?
    public var aiTitle: String?
    /// 用户手动起的名优先于自动标题。
    public var preferred: String? { customTitle ?? aiTitle }
    public init(customTitle: String? = nil, aiTitle: String? = nil) {
      self.customTitle = customTitle
      self.aiTitle = aiTitle
    }
  }

  private static let claudeMarkers: [(marker: Data, type: String, key: String)] = [
    (Data("\"custom-title\"".utf8), "custom-title", "customTitle"),
    (Data("\"ai-title\"".utf8), "ai-title", "aiTitle"),
  ]

  /// 扫描 Claude transcript 片段（文件头 + 文件尾）：只对含标题标记的行做 JSON 解码，
  /// 其余行按字节跳过，几 MB 也只是一次线性扫描。同类记录以最后一条为准——`/rename`
  /// 会追加新的 `custom-title`，AI 标题也可能重新生成。
  public static func claudeTitles(in chunks: [Data]) -> ClaudeTitles {
    var titles = ClaudeTitles()
    for chunk in chunks {
      for line in chunk.split(separator: 0x0A, omittingEmptySubsequences: true) {
        for entry in claudeMarkers where line.range(of: entry.marker) != nil {
          guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            object["type"] as? String == entry.type,
            let value = sanitizedTitle(object[entry.key] as? String)
          else { continue }
          if entry.type == "custom-title" { titles.customTitle = value } else { titles.aiTitle = value }
        }
      }
    }
    return titles
  }

  /// 解析 Codex `session_index.jsonl`：每行 `{"id","thread_name","updated_at"}`，追加写，
  /// 同一 id 以最后一条为准。损坏行跳过。
  public static func codexThreadNames(from data: Data) -> [String: String] {
    var names: [String: String] = [:]
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let id = object["id"] as? String, !id.isEmpty,
        let name = sanitizedTitle(object["thread_name"] as? String)
      else { continue }
      names[id] = name
    }
    return names
  }

  /// 标题只保留单行可打印文本，并与 prompt 兜底同样限长；空串视为没有标题。
  public static func sanitizedTitle(_ raw: String?, maxLength: Int = 120) -> String? {
    guard let raw else { return nil }
    let filtered = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let condensed = String(String.UnicodeScalarView(filtered))
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return condensed.isEmpty ? nil : String(condensed.prefix(maxLength))
  }
}
