import Foundation

/// 规则可选的屏幕区域，移植自 herdr `manifest.rs` 的 `region()` 及其切分函数。
///
/// 切分全部基于“行”：先按 `\n` 把屏幕拆成行（语义等价 Rust `str::lines()`，
/// 末尾空片段不算一行），再用行的起始 `String.Index` 回切原字符串。这样返回的
/// Substring 保留原文里的换行（例如 `bottom_lines` 的结果以 `\n` 结尾时不会被吃掉），
/// 与 herdr 按字节偏移切片的结果逐字一致，正则里的 `\n` / `$` 语义不受影响。
public enum AgentDetectionRegion: Hashable, Sendable {
  case wholeRecent
  case oscTitle
  case oscProgress
  case bottomLines(Int)
  case bottomNonEmptyLines(Int)
  case topNonEmptyLines(Int)
  case afterLastPromptMarker
  case beforeCurrentPromptMarker
  case wholeRecentWithoutCurrentPromptMarker
  case currentPromptBlockMarker
  case afterCurrentPromptBlockMarker
  case promptBoxBody
  case abovePromptBox
  case lastNonEmptyAbovePromptBox
  case afterLastHorizontalRule

  /// `top_non_empty_lines(N)` 的 N 上限（herdr 用 u16::MAX）。
  static let maxTopRegionLineCount = Int(UInt16.max)

  /// 解析清单里的 region 字符串；未知名字返回 nil（对应 herdr `validate_region_name`）。
  public init?(spec: String) {
    let trimmed = spec.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "whole_recent": self = .wholeRecent
    case "osc_title": self = .oscTitle
    case "osc_progress": self = .oscProgress
    case "after_last_prompt_marker": self = .afterLastPromptMarker
    case "before_current_prompt_marker": self = .beforeCurrentPromptMarker
    case "whole_recent_without_current_prompt_marker": self = .wholeRecentWithoutCurrentPromptMarker
    case "current_prompt_block_marker": self = .currentPromptBlockMarker
    case "after_current_prompt_block_marker": self = .afterCurrentPromptBlockMarker
    case "prompt_box_body": self = .promptBoxBody
    case "above_prompt_box": self = .abovePromptBox
    case "last_non_empty_above_prompt_box": self = .lastNonEmptyAbovePromptBox
    case "after_last_horizontal_rule": self = .afterLastHorizontalRule
    default:
      if let count = Self.regionCount(trimmed, name: "bottom_lines") {
        self = .bottomLines(count)
      } else if let count = Self.regionCount(trimmed, name: "bottom_non_empty_lines") {
        self = .bottomNonEmptyLines(count)
      } else if let count = Self.topRegionCount(trimmed) {
        self = .topNonEmptyLines(count)
      } else {
        return nil
      }
    }
  }

  /// `name(N)` 形式的计数解析：Rust `parse::<usize>` 宽松（接受 `+1`、前导零）。
  static func regionCount(_ spec: String, name: String) -> Int? {
    guard spec.hasPrefix(name) else { return nil }
    var rest = spec.dropFirst(name.count)
    guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
    rest = rest.dropFirst().dropLast()
    // Rust usize::from_str 允许前导 `+`，不允许 `-` 与空串。
    var digits = Substring(rest)
    if digits.hasPrefix("+") { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(digits)
  }

  /// `top_non_empty_lines(N)` 要求规范正整数：无前导零、纯 ASCII 数字、≤ u16::MAX。
  static func topRegionCount(_ spec: String) -> Int? {
    let name = "top_non_empty_lines"
    guard spec.hasPrefix(name) else { return nil }
    var rest = spec.dropFirst(name.count)
    guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
    rest = rest.dropFirst().dropLast()
    guard !rest.isEmpty, !rest.hasPrefix("0"),
      rest.allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    guard let count = Int(rest), count <= maxTopRegionLineCount else { return nil }
    return count
  }

  /// 从输入中切出本区域的文本。OSC 区域取专用字段，其余区域切屏幕内容。
  public func slice(_ input: AgentDetectionInput) -> Substring {
    slice(input, lines: AgentScreenLines(input.screen))
  }

  /// 同上，但复用调用方已经拆好的行视图（引擎对同一输入的多条规则共用一次拆行）。
  public func slice(_ input: AgentDetectionInput, lines: AgentScreenLines) -> Substring {
    switch self {
    case .oscTitle: return Substring(input.oscTitle)
    case .oscProgress: return Substring(input.oscProgress)
    default: break
    }
    let content = input.screen
    switch self {
    case .wholeRecent, .oscTitle, .oscProgress:
      return Substring(content)
    case .bottomLines(let count):
      return lines.suffix(fromLine: lines.count - min(count, lines.count))
    case .bottomNonEmptyLines(let count):
      return Self.bottomNonEmptyLines(lines, count: count)
    case .topNonEmptyLines(let count):
      return Self.topNonEmptyLines(lines, count: count)
    case .afterLastPromptMarker:
      guard let index = lines.lastIndex(where: Self.isCodexPromptLine) else {
        return Substring(content)
      }
      return lines.suffix(fromLine: index + 1)
    case .beforeCurrentPromptMarker:
      guard let index = Self.currentCodexPromptIndex(lines) else { return Substring(content) }
      return lines.prefix(toLine: index)
    case .wholeRecentWithoutCurrentPromptMarker:
      return Self.currentCodexPromptIndex(lines) == nil ? Substring(content) : ""
    case .currentPromptBlockMarker:
      guard let promptIndex = Self.currentCodexPromptIndex(lines),
        let blockIndex = lines.lastIndex(before: promptIndex, where: Self.isCodexBlockMarkerLine)
      else { return "" }
      return lines[blockIndex]
    case .afterCurrentPromptBlockMarker:
      guard let promptIndex = Self.currentCodexPromptIndex(lines),
        let blockIndex = lines.lastIndex(before: promptIndex, where: Self.isCodexBlockMarkerLine)
      else { return "" }
      return lines.suffix(fromLine: blockIndex)
    case .promptBoxBody:
      return Self.promptBoxBody(lines) ?? ""
    case .abovePromptBox:
      return Self.abovePromptBox(lines)
    case .lastNonEmptyAbovePromptBox:
      return Self.lastNonEmptyLine(of: Self.abovePromptBox(lines))
    case .afterLastHorizontalRule:
      guard let index = lines.lastIndex(where: Self.isHorizontalRule) else {
        return Substring(content)
      }
      return lines.suffix(fromLine: index + 1)
    }
  }

  // MARK: - 切分实现

  /// 从底部数 `count` 个非空行，取最上面那个非空行到末尾（空行夹在其中也保留）。
  static func bottomNonEmptyLines(_ lines: AgentScreenLines, count: Int) -> Substring {
    var remaining = count
    var start: Int?
    var index = lines.count - 1
    while index >= 0, remaining > 0 {
      if !lines.isBlank(index) {
        start = index
        remaining -= 1
      }
      index -= 1
    }
    guard let start else { return "" }
    return lines.suffix(fromLine: start)
  }

  /// 从顶部数 `count` 个非空行，取开头到最后那个非空行（含其换行）。
  static func topNonEmptyLines(_ lines: AgentScreenLines, count: Int) -> Substring {
    var remaining = count
    var end: Int?
    for index in 0..<lines.count where remaining > 0 {
      if !lines.isBlank(index) {
        end = index
        remaining -= 1
      }
    }
    guard let end else { return "" }
    return lines.prefix(toLine: end + 1)
  }

  /// codex 的输入提示行：单独一个 `›` 或以 `› ` 开头。
  static func isCodexPromptLine(_ line: Substring) -> Bool {
    line == "›" || line.hasPrefix("› ")
  }

  /// codex 的输出块起始标记：`•`（回复）、`■`（中断）、`✗` / `✓`（工具结果）。
  static func isCodexBlockMarkerLine(_ line: Substring) -> Bool {
    guard let first = line.first else { return false }
    return first == "•" || first == "■" || first == "✗" || first == "✓"
  }

  /// “当前”提示行 = 最后一个提示行，且其后不再出现任何块标记（否则说明该提示已被回复，不是当前输入）。
  static func currentCodexPromptIndex(_ lines: AgentScreenLines) -> Int? {
    guard let promptIndex = lines.lastIndex(where: isCodexPromptLine) else { return nil }
    for index in (promptIndex + 1)..<max(promptIndex + 1, lines.count)
    where isCodexBlockMarkerLine(lines[index]) {
      return nil
    }
    return promptIndex
  }

  /// 提示框主体：上边框（倒数第二条横线）之后、下一条横线之前的行。
  static func promptBoxBody(_ lines: AgentScreenLines) -> Substring? {
    guard let top = promptBoxTopBorderIndex(lines) else { return nil }
    var endIndex = lines.count
    for index in (top + 1)..<max(top + 1, lines.count) where isHorizontalRule(lines[index]) {
      endIndex = index
      break
    }
    return lines.range(fromLine: top + 1, toLine: endIndex)
  }

  /// 提示框上边框之前的全部内容；没有提示框则返回整屏。
  static func abovePromptBox(_ lines: AgentScreenLines) -> Substring {
    guard let top = promptBoxTopBorderIndex(lines) else { return Substring(lines.content) }
    return lines.prefix(toLine: top)
  }

  /// 文本中最后一个非空行（不含换行）。
  static func lastNonEmptyLine(of text: Substring) -> Substring {
    let lines = AgentScreenLines(String(text))
    guard let index = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else {
      return ""
    }
    return lines[index]
  }

  /// 提示框上边框 = 从底部往上数第二条横线（最后一条是下边框）。
  static func promptBoxTopBorderIndex(_ lines: AgentScreenLines) -> Int? {
    var borderCount = 0
    var index = lines.count - 1
    while index >= 0 {
      if isHorizontalRule(lines[index]) {
        borderCount += 1
        if borderCount == 2 { return index }
      }
      index -= 1
    }
    return nil
  }

  /// 横线判定：去两端空白后以 `─` 开头；要么整行只有 `─`，要么至少 3 个 `─`（允许尾随注解，
  /// 例如 devin 的 `──── (bypass permissions on) ─`）。
  static func isHorizontalRule(_ line: Substring) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return false }
    let ruleChars = trimmed.prefix(while: { $0 == "─" }).count
    if ruleChars == 0 { return false }
    let suffix = trimmed.dropFirst(ruleChars).drop(while: \.isWhitespace)
    return suffix.isEmpty || ruleChars >= 3
  }
}

/// 屏幕文本的行视图：每行是指向原字符串的 Substring，可用行号回切原文。
///
/// 拆分语义等价 Rust `str::lines()`：以 `\n` 分隔，若文本以 `\n` 结尾则末尾不产生空行。
/// （`\r` 由读屏侧预先去掉，这里不处理。）
public struct AgentScreenLines {
  public let content: String
  public let lines: [Substring]

  public init(_ content: String) {
    self.content = content
    var parts = content.split(separator: "\n", omittingEmptySubsequences: false)
    if let last = parts.last, last.isEmpty { parts.removeLast() }
    lines = parts
  }

  public var count: Int { lines.count }

  public subscript(_ index: Int) -> Substring { lines[index] }

  /// 行是否全为空白。
  func isBlank(_ index: Int) -> Bool { lines[index].allSatisfy(\.isWhitespace) }

  /// 从第 `index` 行开头到文本末尾（保留原文换行）；index 越界返回空。
  func suffix(fromLine index: Int) -> Substring {
    guard index < lines.count else { return "" }
    return content[lines[index].startIndex...]
  }

  /// 从文本开头到第 `index` 行开头（不含该行）；index 越界即整段文本。
  func prefix(toLine index: Int) -> Substring {
    content[..<lineStart(index)]
  }

  /// 第 `from` 行开头到第 `to` 行开头之间的文本。
  func range(fromLine from: Int, toLine to: Int) -> Substring {
    let start = lineStart(from)
    let end = lineStart(to)
    return start <= end ? content[start..<end] : ""
  }

  /// 第 `index` 行的起始位置；越界返回文本末尾（等价 herdr `line_start_offset` 的 min 处理）。
  func lineStart(_ index: Int) -> String.Index {
    index < lines.count ? lines[index].startIndex : content.endIndex
  }

  func lastIndex(where predicate: (Substring) -> Bool) -> Int? {
    lines.lastIndex(where: predicate)
  }

  /// `before` 之前（不含）的最后一个满足条件的行。
  func lastIndex(before: Int, where predicate: (Substring) -> Bool) -> Int? {
    lines[..<min(before, lines.count)].lastIndex(where: predicate)
  }
}
