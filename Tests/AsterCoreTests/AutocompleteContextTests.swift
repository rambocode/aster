import Foundation
import Testing
@testable import AsterCore

private let contextSpec = AutocompleteCommandSpec(
  name: "tool", subcommands: [.init(name: "deploy")], options: [
    .init(names: ["--region"], args: [.init(name: "region", suggestions: [.init(name: "us-east"), .init(name: "eu-west")])]),
    .init(names: ["--verbose", "-v"]),
  ], arguments: [.init(name: "file", template: ["filepaths"], isOptional: true)])

private func contextSuggestions(_ line: String) -> AutocompleteResult {
  AutocompleteEngine(specDatabase: .init(sourceRevision: "test", commands: [contextSpec]))
    .suggestions(for: .init(line: line, directory: "/project"), learned: [], pinned: [], readmeCommands: [])
}

@Test("空参数位置推荐选项；已用非重复选项不再出现")
func autocompleteContextOffersOnlyApplicableOptions() {
  #expect(contextSuggestions("tool ").candidates.contains { $0.insertText == "--region" })
  #expect(!contextSuggestions("tool --verbose --v").candidates.contains { $0.insertText == "--verbose" })
}

@Test("等号右侧按选项参数补全，不再误当作选项名")
func autocompleteContextCompletesEqualsArgument() {
  let result = contextSuggestions("tool --region=us")
  #expect(result.candidates.first?.appendableSuffix(from: "tool --region=us") == "-east")
}

@Test("双横线终止选项解释，后续文件名不再匹配选项")
func autocompleteContextHonorsOptionTerminator() {
  #expect(contextSuggestions("tool -- --v").candidates.allSatisfy { $0.kind != .option })
}

@Test("未闭合引号内的空格属于当前参数")
func autocompleteContextPreservesQuotedSpace() {
  let result = ShellCommandTokenizer.tokenize("cat 'my ")
  #expect(result.currentToken == "my ")
  #expect(result.currentTokenStart == 4)
}

@Test("带引号的选项值保留已输入内容并正确闭合引号")
func autocompleteContextQuotesOptionValues() {
  let line = "tool --region 'us"
  #expect(contextSuggestions(line).candidates.first?.appendableSuffix(from: line) == "-east'")
}
