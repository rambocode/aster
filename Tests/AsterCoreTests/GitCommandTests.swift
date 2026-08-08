import Testing

@testable import AsterCore

@Test("Git 写操作生成可粘贴的命令文本并引用路径")
func gitCommandsQuoteArgumentsForTerminalInjection() {
  #expect(GitCommand.commit.commandLine == "git commit ")
  #expect(GitCommand.push.commandLine == "git push")
  #expect(GitCommand.pull.commandLine == "git pull")
  #expect(GitCommand.fetch.commandLine == "git fetch")
  #expect(GitCommand.stageAll.commandLine == "git add -A")
  #expect(GitCommand.stage(path: "Sources/App.swift").commandLine == "git add -- 'Sources/App.swift'")
  #expect(
    GitCommand.unstage(path: "Sources/App.swift").commandLine
      == "git restore --staged -- 'Sources/App.swift'")
  #expect(GitCommand.merge(branch: "feature/x").commandLine == "git merge 'feature/x'")
  #expect(GitCommand.rebase(branch: "main").commandLine == "git rebase 'main'")
}

@Test("含 shell 元字符的路径与分支被单引号转义而不是拼进命令")
func gitCommandsEscapeShellMetacharacters() {
  let path = "a b/$(whoami)`id`.txt"
  #expect(GitCommand.stage(path: path).commandLine == "git add -- 'a b/$(whoami)`id`.txt'")
  // 内部单引号必须闭合再转义，否则引用会提前结束并让后半段回到 shell 语法。
  #expect(GitCommand.stage(path: "it's.txt").commandLine == #"git add -- 'it'\''s.txt'"#)
  #expect(GitCommand.merge(branch: "a'b").commandLine == #"git merge 'a'\''b'"#)
}

@Test("非法分支名与路径不生成命令")
func gitCommandsRejectUnsafeArguments() {
  #expect(GitCommand.merge(branch: "  ").commandLine == nil)
  // 以 `-` 开头会被 git 当成选项。
  #expect(GitCommand.rebase(branch: "--onto").commandLine == nil)
  #expect(GitCommand.merge(branch: "a\nb").commandLine == nil)
  #expect(GitCommand.stage(path: "").commandLine == nil)
  #expect(GitCommand.stage(path: "-rf").commandLine == nil)
  #expect(GitCommand.unstage(path: "a\u{0}b").commandLine == nil)
  #expect(GitCommand.sanitizedBranch("  main  ") == "main")
  #expect(GitCommand.sanitizedBranch(String(repeating: "b", count: 256)) == nil)
}

@Test("diff 解析按前缀分类并优先识别文件头")
func gitDiffParserClassifiesLinesByPrefix() {
  let diff = """
    diff --git a/App.swift b/App.swift
    index 1111111..2222222 100644
    --- a/App.swift
    +++ b/App.swift
    @@ -1,3 +1,3 @@
     let a = 1
    -let b = 2
    +let b = 3
    """
  let lines = GitDiffParser.parse(diff)
  #expect(lines.map(\.kind) == [
    .fileHeader, .fileHeader, .fileHeader, .fileHeader, .hunkHeader, .context, .deletion, .addition,
  ])
  #expect(lines.last?.text == "+let b = 3")
}

@Test("diff 超过行数上限时截断并追加提示行")
func gitDiffParserTruncatesBeyondLineLimit() {
  let diff = (1...10).map { " line \($0)" }.joined(separator: "\n")
  let lines = GitDiffParser.parse(diff, lineLimit: 4)
  #expect(lines.count == 5)
  #expect(lines.prefix(4).allSatisfy { $0.kind == .context })
  #expect(lines.last?.kind == .notice)
  #expect(lines.last?.text.contains("6") == true)
  #expect(GitDiffParser.parse("").isEmpty)
}
