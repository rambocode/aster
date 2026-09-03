import Foundation

/// 一行终端文字里被识别出的可点击候选。`range` 是该行的 `Character` 偏移区间，供
/// 宿主映射回终端列；`text` 已裁掉尾随标点，可直接交给 `TargetResolver`。
public struct InlineTargetCandidate: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// `scheme://…` 或 `mailto:` 形式的 URL，scheme 已小写。
    case url(scheme: String)
    /// 绝对、`~/`、相对或裸文件名形式的本地路径，可带 `:line[:column]` 后缀。
    case path
  }

  public let text: String
  public let range: Range<Int>
  public let kind: Kind

  public init(text: String, range: Range<Int>, kind: Kind) {
    self.text = text
    self.range = range
    self.kind = kind
  }
}

/// 扫描单行终端文字，枚举 URL 与路径候选（Command 下划线、悬停预览、Command 点击共用）。
///
/// 扫描器只做语法切分，不访问文件系统也不判断 scheme 授权：裸相对路径（`site`、
/// `Makefile`）几乎和普通单词无法区分，必须由调用方按当前目录做存在性校验后再采信；
/// URL 是否可点击由 `LinkSchemePolicy` 决定。
public enum TerminalInlineTargetScanner {
  /// 单行超过该字符数时放弃扫描，避免异常长行拖慢主线程。
  public static let maximumLineCharacters = 4_096
  /// 单个候选的最大字符数，与 `TargetResolver.maximumInputBytes` 同量级。
  public static let maximumCandidateCharacters = 1_024

  /// scheme 前必须是 token 边界：`\nhttps://…` 里的 `nhttps` 与 `foo/https://` 都不算 URL；
  /// 反斜杠也不进入 URL 主体，避免把 shell 转义的 `\n` 拖进目标。
  private static let urlExpression = try? NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9+.\-_/@\\])(?:[A-Za-z][A-Za-z0-9+.-]*://|mailto:)[^\s\\<>"'`，。；：！？（）【】「」《》]+"#
  )
  /// URL 末尾常见的句读与右括号：`https://a.com/x).` 只取到 `x`。
  private static let trailingPunctuation = Set(".,;:!?)]}>'\"`")
  /// 路径候选末尾同样裁掉句读；右括号也裁，路径里极少以括号结尾。
  private static let trailingPathPunctuation = Set(".,;:!?)]}'\"`")
  /// 把一行切成 token 的分隔符：空白、引号、括号、管道以及中英文标点。
  private static let tokenDelimiters: Set<Character> = Set("<>\"'`()[]{}|,;，。；：！？（）【】「」《》、")

  /// 返回该行全部候选，按起始偏移升序、互不重叠。
  public static func candidates(in line: String) -> [InlineTargetCandidate] {
    guard !line.isEmpty, line.count <= maximumLineCharacters else { return [] }
    let characters = Array(line)
    var results: [InlineTargetCandidate] = []
    var occupied: [Range<Int>] = []

    // 第一遍：URL。先于路径切分，避免 `https://a/b.c` 被按 `/` 路径规则拆开。
    if let expression = urlExpression {
      let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
      for match in expression.matches(in: line, range: nsRange) {
        guard let swiftRange = Range(match.range, in: line) else { continue }
        var lower = line.distance(from: line.startIndex, to: swiftRange.lowerBound)
        var upper = line.distance(from: line.startIndex, to: swiftRange.upperBound)
        while upper > lower, trailingPunctuation.contains(characters[upper - 1]) { upper -= 1 }
        // 行内 `(https://…)` 的左括号已由字符类排除；这里只需处理裁剪后为空的极端情况。
        guard upper - lower >= 4, upper - lower <= maximumCandidateCharacters else { continue }
        let text = String(characters[lower..<upper])
        guard let scheme = urlScheme(of: text) else { continue }
        lower = max(lower, 0)
        results.append(.init(text: text, range: lower..<upper, kind: .url(scheme: scheme)))
        occupied.append(lower..<upper)
      }
    }

    // 第二遍：路径 token。仅做形态过滤，存在性由调用方校验。
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace || tokenDelimiters.contains(character) {
        index += 1
        continue
      }
      var end = index
      while end < characters.count, !characters[end].isWhitespace,
        !tokenDelimiters.contains(characters[end])
      {
        end += 1
      }
      defer { index = end }
      if occupied.contains(where: { $0.overlaps(index..<end) }) { continue }
      guard let candidate = pathCandidate(characters, index..<end) else { continue }
      results.append(candidate)
    }

    return results.sorted { $0.range.lowerBound < $1.range.lowerBound }
  }

  /// 从一个 token 中提炼路径候选：剥离 `@` 之类前缀与尾随句读，排除旗标、纯数字、
  /// 单字符与 `.`/`..` 这类不值得下划线的形态。
  private static func pathCandidate(_ characters: [Character], _ range: Range<Int>)
    -> InlineTargetCandidate?
  {
    var lower = range.lowerBound
    var upper = range.upperBound
    // `@site`、`=path` 之类的前缀符号不属于路径本身。
    while lower < upper, !isPathLeadingCharacter(characters[lower]) {
      // 以 `-` 开头的是命令行旗标（`--files`、`-g`），整个 token 跳过。
      if characters[lower] == "-" { return nil }
      lower += 1
    }
    while upper > lower, trailingPathPunctuation.contains(characters[upper - 1]) { upper -= 1 }
    let length = upper - lower
    guard length >= 2, length <= maximumCandidateCharacters else { return nil }
    let text = String(characters[lower..<upper])
    // glob（`*node_modules*`）与 URL 片段不是路径；纯数字/句点/冒号（`17:17`、`...`）也不是。
    guard text != "..", !text.contains("://"), !text.contains("*"),
      !text.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." })
    else { return nil }
    // `path:line[:column]` 之外的冒号形态（`key:value`、`17:17`）不当作路径。
    if let colon = text.firstIndex(of: ":") {
      let suffix = text[colon...].dropFirst()
      guard !suffix.isEmpty,
        suffix.split(separator: ":", omittingEmptySubsequences: false).count <= 2,
        suffix.split(separator: ":", omittingEmptySubsequences: false)
          .allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
      else { return nil }
      guard colon > text.startIndex else { return nil }
    }
    return .init(text: text, range: lower..<upper, kind: .path)
  }

  private static func isPathLeadingCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "."
      || character == "~" || character == "/"
  }

  private static func urlScheme(of text: String) -> String? {
    if text.lowercased().hasPrefix("mailto:") { return "mailto" }
    guard let separator = text.range(of: "://") else { return nil }
    let scheme = String(text[..<separator.lowerBound])
    return scheme.isEmpty ? nil : scheme.lowercased()
  }
}
