// DocumentTextSearch 的匹配区间与跳转下标测试。
import AsterCore
import Foundation
import Testing

@Test func documentSearchFindsAllPlainMatchesIgnoringCase() {
  let ranges = DocumentTextSearch.ranges(
    of: "foo", in: "Foo bar foo FOO", caseSensitive: false, regularExpression: false)
  #expect(ranges == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
    NSRange(location: 12, length: 3)])
}

@Test func documentSearchRespectsCaseSensitivity() {
  let ranges = DocumentTextSearch.ranges(
    of: "foo", in: "Foo bar foo FOO", caseSensitive: true, regularExpression: false)
  #expect(ranges == [NSRange(location: 8, length: 3)])
}

@Test func documentSearchUsesUTF16RangesForEmojiAndCJK() {
  let ranges = DocumentTextSearch.ranges(
    of: "查找", in: "😀 查找 与 查找", caseSensitive: false, regularExpression: false)
  // 😀 占两个 UTF-16 单元，NSTextView 选中时必须用这个口径。
  #expect(ranges == [NSRange(location: 3, length: 2), NSRange(location: 8, length: 2)])
}

@Test func documentSearchSupportsRegexAndSkipsEmptyMatches() {
  let ranges = DocumentTextSearch.ranges(
    of: "a\\d*", in: "a1 b a22 ^", caseSensitive: true, regularExpression: true)
  #expect(ranges == [NSRange(location: 0, length: 2), NSRange(location: 5, length: 3)])
  #expect(DocumentTextSearch.ranges(
    of: "^", in: "line\nline", caseSensitive: true, regularExpression: true).isEmpty)
}

@Test func documentSearchReturnsNothingForInvalidRegexOrEmptyQuery() {
  #expect(DocumentTextSearch.ranges(
    of: "(", in: "(a)", caseSensitive: false, regularExpression: true).isEmpty)
  #expect(DocumentTextSearch.ranges(
    of: "", in: "abc", caseSensitive: false, regularExpression: false).isEmpty)
}

@Test func documentSearchStopsAtLimit() {
  let ranges = DocumentTextSearch.ranges(
    of: "a", in: String(repeating: "a", count: 50), caseSensitive: false,
    regularExpression: false, limit: 10)
  #expect(ranges.count == 10)
}

@Test func documentSearchMatchIndexMovesAndWraps() {
  let matches = [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3),
    NSRange(location: 12, length: 3)]
  // 选中第二处时，下一个跳第三处，上一个回第一处。
  #expect(DocumentTextSearch.matchIndex(
    in: matches, selection: matches[1], direction: .forward) == 2)
  #expect(DocumentTextSearch.matchIndex(
    in: matches, selection: matches[1], direction: .backward) == 0)
  // 到头回绕。
  #expect(DocumentTextSearch.matchIndex(
    in: matches, selection: matches[2], direction: .forward) == 0)
  #expect(DocumentTextSearch.matchIndex(
    in: matches, selection: matches[0], direction: .backward) == 2)
  // 实时查找把选区起点处的匹配算作命中，输入时不会跳走。
  #expect(DocumentTextSearch.matchIndex(
    in: matches, selection: NSRange(location: 8, length: 2), direction: .incremental) == 1)
  // 光标在两个匹配之间。
  #expect(DocumentTextSearch.matchIndex(
    in: matches, selection: NSRange(location: 5, length: 0), direction: .forward) == 1)
  #expect(DocumentTextSearch.matchIndex(in: [], selection: NSRange(), direction: .forward) == nil)
}
