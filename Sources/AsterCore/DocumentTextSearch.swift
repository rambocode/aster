// 打开文件的内容查找：计算全部匹配区间，并按当前选区决定下一处匹配。
import Foundation

/// 单个文档内的文本查找规则。与终端查找共用「区分大小写 / 正则」两个开关；
/// 区间使用 UTF-16（`NSRange`），可直接交给 `NSTextView` 选中和滚动。
public enum DocumentTextSearch {
  /// 查找方向。`incremental` 用于输入时实时搜索：当前选区起点处的匹配也算命中，
  /// 光标不会因为每敲一个字符就跳到下一处。
  public enum Direction: Sendable {
    case forward
    case backward
    case incremental
  }

  /// 返回 `text` 中全部匹配区间（按位置升序，最多 `limit` 个）。
  ///
  /// 空查询、超长查询或非法正则返回空数组，不抛错；调用方把它当作「无结果」显示。
  /// 零长度的正则匹配（如 `^`）没有可选中的文字，会被跳过。
  public static func ranges(
    of query: String,
    in text: String,
    caseSensitive: Bool,
    regularExpression: Bool,
    limit: Int = 10_000
  ) -> [NSRange] {
    guard !query.isEmpty, query.utf8.count <= 4_096, limit > 0 else { return [] }
    let source = text as NSString
    let whole = NSRange(location: 0, length: source.length)
    if regularExpression {
      let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
      guard let expression = try? NSRegularExpression(pattern: query, options: options) else {
        return []
      }
      var result: [NSRange] = []
      expression.enumerateMatches(in: text, range: whole) { match, _, stop in
        guard let range = match?.range, range.length > 0 else { return }
        result.append(range)
        if result.count >= limit { stop.pointee = true }
      }
      return result
    }
    let options: NSString.CompareOptions =
      caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
    var result: [NSRange] = []
    var searchRange = whole
    while searchRange.length > 0, result.count < limit {
      let found = source.range(of: query, options: options, range: searchRange)
      guard found.location != NSNotFound, found.length > 0 else { break }
      result.append(found)
      let next = NSMaxRange(found)
      searchRange = NSRange(location: next, length: whole.length - next)
    }
    return result
  }

  /// 在升序的 `matches` 中按当前选区选出目标下标；到头后回绕。无匹配时返回 nil。
  public static func matchIndex(
    in matches: [NSRange],
    selection: NSRange,
    direction: Direction
  ) -> Int? {
    guard !matches.isEmpty else { return nil }
    switch direction {
    case .incremental:
      return matches.firstIndex { $0.location >= selection.location } ?? 0
    case .forward:
      // 从选区末尾往后找；选区正好是一处匹配时，这样会跳到下一处而不是停在原地。
      return matches.firstIndex { $0.location >= NSMaxRange(selection) && $0 != selection } ?? 0
    case .backward:
      return matches.lastIndex { $0.location < selection.location } ?? matches.count - 1
    }
  }
}
