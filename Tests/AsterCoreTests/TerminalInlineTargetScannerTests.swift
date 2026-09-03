import Foundation
import Testing

@testable import AsterCore

/// 扫描器只切语法，不 stat 也不授权：这里验证各类形态的边界裁剪与排除规则。
private func texts(_ line: String) -> [String] {
  TerminalInlineTargetScanner.candidates(in: line).map(\.text)
}

@Test("URL 裁掉尾随句读并保留 scheme 与 mailto")
func scannerExtractsURLs() {
  let line = "Tip: visit https://chatgpt.com/codex?app-landing-page=true. or mailto:a@b.com,"
  let candidates = TerminalInlineTargetScanner.candidates(in: line)
  let urls = candidates.filter { if case .url = $0.kind { return true } else { return false } }
  #expect(urls.map(\.text) == ["https://chatgpt.com/codex?app-landing-page=true", "mailto:a@b.com"])
  #expect(urls.first?.kind == .url(scheme: "https"))
  #expect(urls.last?.kind == .url(scheme: "mailto"))
}

@Test("反引号包裹的 URL 不把引号算进目标")
func scannerStripsBacktickQuotes() {
  #expect(texts("@site 网站没有更新 `https://tidy.talkwork.vip/` cloudflare")
    .contains("https://tidy.talkwork.vip/"))
}

@Test("scheme 前必须是 token 边界，反斜杠不进入 URL")
func scannerRequiresURLBoundary() {
  // 命令回显里的 `'\nhttps://…\n'` 既不能匹配成 `nhttps://`，也不能把 `\n` 拖进 URL。
  #expect(texts("printf '\\nhttps://example.com/x\\n'") == ["printf"])
  #expect(texts("(https://example.com/x)") == ["https://example.com/x"])
}

@Test("路径候选覆盖绝对、主目录、相对、裸文件名与行列后缀")
func scannerExtractsPathCandidates() {
  let line = "Read MEMORY.md, ~/source/project/tidy /dev/null site/tools/lib/markdown.mjs:18: Makefile"
  #expect(
    texts(line) == [
      "Read", "MEMORY.md", "~/source/project/tidy", "/dev/null",
      "site/tools/lib/markdown.mjs:18", "Makefile",
    ])
}

@Test("前缀符号、旗标、纯数字、时间与单字符不进入路径候选")
func scannerRejectsNonPathTokens() {
  let line = "@site rg --files -g '!*node_modules*' | sed -n '1,120p' 17:17 21s a key:value .. ..."
  #expect(texts(line) == ["site", "rg", "sed", "120p", "21s"])
}

@Test("URL 区域不会再被路径规则重复切分")
func scannerDoesNotOverlapURLAndPath() {
  let candidates = TerminalInlineTargetScanner.candidates(in: "see https://a.io/x/y.md now")
  #expect(candidates.map(\.text) == ["see", "https://a.io/x/y.md", "now"])
  #expect(candidates.map(\.range) == [0..<3, 4..<23, 24..<27])
}

@Test("行列后缀只接受 path:line 或 path:line:column")
func scannerAcceptsOnlyNumericLocationSuffix() {
  #expect(texts("src/lib.rs:42:5 src/lib.rs:42:5:9 src/lib.rs:abc") == ["src/lib.rs:42:5"])
}

@Test("超长行直接放弃扫描")
func scannerSkipsOversizedLines() {
  let line = String(repeating: "a", count: TerminalInlineTargetScanner.maximumLineCharacters + 1)
  #expect(TerminalInlineTargetScanner.candidates(in: line).isEmpty)
}
