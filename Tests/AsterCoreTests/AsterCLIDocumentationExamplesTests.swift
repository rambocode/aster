import Foundation
import Testing

@testable import AsterCore

// SKILL.md 与用户手册里的 `aster …` 示例是 agent 与用户照抄的语法真值：
// 把每个 ```bash 代码块里以 `aster ` 开头的行逐条喂给解析器，任何一条被拒绝都算文档或解析器错了。

/// 仓库根目录（Tests/AsterCoreTests/<file> 上溯三层）。
private let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// 抽出 Markdown 里 ```bash 代码块中以 `aster ` 开头的命令行（去掉行尾 `# 注释`）。
private func asterCommandLines(inMarkdownAt path: String) throws -> [String] {
  let markdown = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
  var inBash = false
  var lines: [String] = []
  for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("```") {
      inBash = line.hasPrefix("```bash")
      continue
    }
    guard inBash, line.hasPrefix("aster ") else { continue }
    // 示例里的行尾注释不属于命令；引号内不会出现 ` #`，这里按首个 " #" 截断即可。
    let command = line.components(separatedBy: " #").first ?? line
    lines.append(command.trimmingCharacters(in: .whitespaces))
  }
  return lines
}

/// 极简 shell 切词：处理单/双引号与反斜杠，并把示例占位符替换成合法值。
private func tokenize(_ line: String) -> [String] {
  var tokens: [String] = []
  var current = ""
  var quote: Character?
  var hasToken = false
  var iterator = line.makeIterator()
  while let character = iterator.next() {
    if let active = quote {
      if character == active {
        quote = nil
      } else if character == "\\", active == "\"", let next = iterator.next() {
        current.append(next)
      } else {
        current.append(character)
      }
      continue
    }
    switch character {
    case "'", "\"":
      quote = character
      hasToken = true
    case "\\":
      if let next = iterator.next() { current.append(next) }
    case " ", "\t":
      if hasToken || !current.isEmpty {
        tokens.append(current)
        current = ""
        hasToken = false
      }
    default:
      current.append(character)
      hasToken = true
    }
  }
  if hasToken || !current.isEmpty { tokens.append(current) }
  return tokens.map(substitutePlaceholder)
}

/// 文档占位符 → 解析器可接受的具体值。
private func substitutePlaceholder(_ token: String) -> String {
  switch token {
  case "$ASTER_PANE_ID", "<pane-id>", "$PWD": return "w1:p1"
  case "<agent-args...>": return "--model"
  default: return token
  }
}

@Test("SKILL.md 与用户手册里的每条 aster 示例都能被解析器接受", arguments: [
  "Resources/skills/aster/SKILL.md",
  "docs/user/help.md",
])
func documentedCLIExamplesParse(path: String) throws {
  let lines = try asterCommandLines(inMarkdownAt: path)
  #expect(!lines.isEmpty, "\(path) 里没有找到 aster 示例，抽取逻辑可能失效")
  for line in lines {
    let argv = Array(tokenize(line).dropFirst())
    #expect(throws: Never.self, "\(path): `\(line)`") {
      try AsterCLIArguments.parse(argv)
    }
  }
}

@Test("SKILL.md 的 agent start / send-text 示例落到预期命令而不是 legacy")
func skillExamplesMapToNewSyntax() throws {
  let start = try AsterCLIArguments.parse(
    ["agent", "start", "reviewer", "--kind", "codex", "--pane", "w1:p1", "--", "--model", "x"]).command
  #expect(start == .agentStart(.init(pane: "w1:p1", kind: "codex", name: "reviewer", args: ["--model", "x"])))
  let sendText = try AsterCLIArguments.parse(["pane", "send-text", "w1:p1", "just test", "--enter"]).command
  #expect(sendText == .paneSendText(pane: "w1:p1", text: "just test", enter: true))
  let keys = try AsterCLIArguments.parse(["agent", "send-keys", "reviewer", "ctrl+c"]).command
  #expect(keys == .agentSendKeys(.init(target: "reviewer", keys: ["ctrl+c"])))
}
