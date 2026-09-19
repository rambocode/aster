import Foundation
import Testing

@testable import AsterCore

@Test("空提示符上的单行剪贴板文本可以作为建议")
func clipboardSuggestionAcceptsSingleLineText() {
  #expect(
    ClipboardSuggestionPolicy.suggestion(clipboard: "brew install ripgrep", line: "")
      == "brew install ripgrep")
  // 复制时带上的前后空格是用户自己的选择，原样保留，不做 trim。
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: " ls -al ", line: "") == " ls -al ")
}

@Test("输入行已有内容时不提示剪贴板")
func clipboardSuggestionRequiresEmptyLine() {
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "ls", line: "gi") == nil)
}

@Test("空白、多行与超长剪贴板内容不提示")
func clipboardSuggestionRejectsUnusableText() {
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "   \n  ", line: "") == nil)
  // 多行内容里的换行写进 PTY 会被 Shell 当作提交，直接绕过「回车只粘贴不执行」。
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "cd /tmp\nls", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "ls\r", line: "") == nil)
  // 命令带一长串参数时，长度卡在上限而不是首词上。
  let argument = { (total: Int) in "git " + String(repeating: "a", count: total - 4) }
  let long = argument(ClipboardSuggestionPolicy.maximumLength + 1)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: long, line: "") == nil)
  let atLimit = argument(ClipboardSuggestionPolicy.maximumLength)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: atLimit, line: "") == atLimit)
  // 首词本身过长（超过 64 字符）也不像命令名。
  #expect(
    ClipboardSuggestionPolicy.suggestion(clipboard: String(repeating: "a", count: 65), line: "")
      == nil)
}

@Test("含控制字符的剪贴板内容不提示")
func clipboardSuggestionRejectsControlCharacters() {
  // 转义序列可以在 ghost 里伪装成人畜无害的文本，却在写入终端时改变行为。
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "ls\u{1B}[31m", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "ls\u{07}", line: "") == nil)
}

@Test("一段话、URL、选项片段不会被当成命令")
func clipboardSuggestionRejectsNonCommandText() {
  // 用户最常复制的恰恰是这类内容；结构上它们和命令没差别，靠首词规则挡住。
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "帮我看一下这个报错", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "这是一段说明文字", line: "") == nil)
  #expect(
    ClipboardSuggestionPolicy.suggestion(clipboard: "https://example.com/a/b", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "--verbose --json", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "12345", line: "") == nil)
  #expect(ClipboardSuggestionPolicy.suggestion(clipboard: "Hello, world!", line: "") == nil)
}

@Test("命令名结构判定取出首词")
func clipboardSuggestionExtractsCommandToken() {
  #expect(ClipboardSuggestionPolicy.commandToken(in: "git status --short") == "git")
  #expect(ClipboardSuggestionPolicy.commandToken(in: "  npm run build") == "npm")
  #expect(ClipboardSuggestionPolicy.commandToken(in: "./scripts/test.sh") == "./scripts/test.sh")
  // 结构上合法但不是已知命令；是否提示由调用方再查一次规格库 / PATH 决定。
  #expect(ClipboardSuggestionPolicy.commandToken(in: "Please review this") == "Please")
}

@Test("写法自证是命令的内容不必核对首词")
func clipboardSuggestionRecognizesSelfEvidentCommands() {
  // 本机不认识 uvx / some-tool 也要能提示：要求首词一定已知太严格。
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("uvx ruff check --fix"))
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("some-tool -v"))
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("NODE_ENV=production npm start"))
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("cd ~/project && ls"))
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("cat a.log | grep err"))
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("./build.sh"))
  #expect(ClipboardSuggestionPolicy.isSelfEvidentCommand("htop"))
  // 几个普通单词既像命令也像一句话，必须回去核对首词。
  #expect(!ClipboardSuggestionPolicy.isSelfEvidentCommand("Please review this"))
  #expect(!ClipboardSuggestionPolicy.isSelfEvidentCommand("git status"))
}

@Test("路径形式的首词直接认定为可执行文件")
func clipboardSuggestionRecognizesPathLikeCommands() {
  #expect(ClipboardSuggestionPolicy.isPathLikeCommand("./build.sh"))
  #expect(ClipboardSuggestionPolicy.isPathLikeCommand("/usr/bin/env"))
  #expect(ClipboardSuggestionPolicy.isPathLikeCommand("~/bin/tool"))
  #expect(!ClipboardSuggestionPolicy.isPathLikeCommand("git"))
}

@Test("提权命令仍然提示：回车只写入不执行")
func clipboardSuggestionAllowsPrivilegeEscalation() {
  // sudo 的风险来自「执行」，而这里的回车只把文本写进输入行，整行明文可见，
  // 真正执行仍需用户再按一次回车。
  #expect(
    ClipboardSuggestionPolicy.suggestion(clipboard: "sudo apt install jq", line: "")
      == "sudo apt install jq")
}
