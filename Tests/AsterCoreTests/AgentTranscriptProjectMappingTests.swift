import Foundation
import Testing

@testable import AsterCore

// MARK: - 测试替身

/// 用固定集合模拟磁盘上的目录，让反解规则可以在没有真实文件系统的情况下断言。
private func existence(_ paths: Set<String>) -> (String) -> Bool {
  { paths.contains($0) }
}

private func home() -> URL { URL(fileURLWithPath: "/Users/mike") }

private func claudeSession(_ encodedDirectory: String) -> URL {
  URL(fileURLWithPath: "/Users/mike/.claude/projects/\(encodedDirectory)/session.jsonl")
}

/// Agent transcript 的项目归属还原与工具调用抽取真值表。
@Suite("AgentTranscriptProjectMapping")
struct AgentTranscriptProjectMappingTests {
  // MARK: - 目录名编码

  @Test("Claude Code 目录名把所有非字母数字字符编码成连字符")
  func encodedDirectoryNameReplacesEveryNonAlphanumeric() {
    #expect(
      AgentTranscriptProjectMapping.encodedDirectoryName(forProjectPath: "/Users/mike/src/foo")
        == "-Users-mike-src-foo")
    #expect(
      AgentTranscriptProjectMapping.encodedDirectoryName(forProjectPath: "/Users/mike/.claude")
        == "-Users-mike--claude")
    #expect(
      AgentTranscriptProjectMapping.encodedDirectoryName(forProjectPath: "/tmp/a-b/c_d")
        == "-tmp-a-b-c-d")
  }

  // MARK: - 目录名反解

  @Test("无歧义的编码目录名按文件系统逐层还原")
  func decodesUnambiguousDirectoryName() {
    let resolved = AgentTranscriptProjectMapping.decodedProjectPath(
      fromEncodedDirectoryName: "-a-b-c",
      directoryExists: existence(["/a", "/a/b", "/a/b/c"])
    )
    #expect(resolved == "/a/b/c")
  }

  @Test("项目路径本身含连字符时按实际存在的目录还原")
  func decodesLiteralHyphenComponent() {
    let resolved = AgentTranscriptProjectMapping.decodedProjectPath(
      fromEncodedDirectoryName: "-Users-mike-cortex-org-app",
      directoryExists: existence([
        "/Users", "/Users/mike", "/Users/mike/cortex-org", "/Users/mike/cortex-org/app",
      ])
    )
    #expect(resolved == "/Users/mike/cortex-org/app")
  }

  @Test("同时存在多种切分时取合并 token 更多的最长匹配")
  func decodesPrefersLongestComponentMatch() {
    let resolved = AgentTranscriptProjectMapping.decodedProjectPath(
      fromEncodedDirectoryName: "-a-b-c",
      directoryExists: existence(["/a", "/a/b", "/a/b/c", "/a-b", "/a-b/c"])
    )
    #expect(resolved == "/a-b/c")
  }

  @Test("以点开头的目录（.claude）能从相邻连字符还原")
  func decodesLeadingDotComponent() {
    let resolved = AgentTranscriptProjectMapping.decodedProjectPath(
      fromEncodedDirectoryName: "-Users-mike--claude-worktrees",
      directoryExists: existence([
        "/Users", "/Users/mike", "/Users/mike/.claude", "/Users/mike/.claude/worktrees",
      ])
    )
    #expect(resolved == "/Users/mike/.claude/worktrees")
  }

  @Test("最长匹配走不通时回溯到更短的分量")
  func decodesBacktracksWhenLongestMatchIsDeadEnd() {
    // `/a-b` 存在但其下没有 `c`，只有 `/a/b/c` 是完整解释；贪心不回溯就会漏掉。
    let resolved = AgentTranscriptProjectMapping.decodedProjectPath(
      fromEncodedDirectoryName: "-a-b-c",
      directoryExists: existence(["/a-b", "/a", "/a/b", "/a/b/c"])
    )
    #expect(resolved == "/a/b/c")
  }

  @Test("无法在磁盘上找到任何解释时返回 nil 而不是编造路径")
  func decodingFailsClosedWhenNothingExists() {
    #expect(
      AgentTranscriptProjectMapping.decodedProjectPath(
        fromEncodedDirectoryName: "-a-b-c", directoryExists: existence([])) == nil)
    // 编码名必须以连字符（原始的根斜杠）开头，否则不是合法的编码目录名。
    #expect(
      AgentTranscriptProjectMapping.decodedProjectPath(
        fromEncodedDirectoryName: "a-b", directoryExists: existence(["/a", "/a/b"])) == nil)
  }

  // MARK: - transcript 自报工作目录

  @Test("Claude Code 记录顶层的 cwd 被优先采纳")
  func readsTopLevelWorkingDirectory() {
    let jsonl = """
      {"type":"user","cwd":"/Users/mike/src/foo","message":{"role":"user","content":"hi"}}
      """
    #expect(
      AgentTranscriptProjectMapping.workingDirectory(inTranscript: Data(jsonl.utf8))
        == "/Users/mike/src/foo")
  }

  @Test("Codex 的 session_meta 把 cwd 放在 payload 里也能取到")
  func readsPayloadWorkingDirectory() {
    let jsonl = """
      {"timestamp":"2026-06-22T10:42:38.978Z","type":"event_msg","payload":{"type":"task_started"}}
      {"timestamp":"2026-06-22T10:42:38.979Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/mike/src/Tandem"}}
      """
    #expect(
      AgentTranscriptProjectMapping.workingDirectory(inTranscript: Data(jsonl.utf8))
        == "/Users/mike/src/Tandem")
  }

  @Test("相对路径、控制字符与超长路径都不被当作工作目录")
  func rejectsUnsafeWorkingDirectoryValues() {
    #expect(AgentTranscriptProjectMapping.normalizedAbsolutePath("relative/path") == nil)
    #expect(AgentTranscriptProjectMapping.normalizedAbsolutePath("/tmp/a\u{0007}b") == nil)
    #expect(
      AgentTranscriptProjectMapping.normalizedAbsolutePath(
        "/" + String(repeating: "a", count: 5_000)) == nil)
    #expect(AgentTranscriptProjectMapping.normalizedAbsolutePath("/tmp/project/") == "/tmp/project")
  }

  // MARK: - 归属主入口

  @Test("transcript 自报的 cwd 优先于目录名反解")
  func attributionPrefersTranscriptWorkingDirectory() {
    let attribution = AgentTranscriptProjectMapping.attribution(
      provider: .claudeCode,
      sessionFileURL: claudeSession("-a-b-c"),
      homeDirectory: home(),
      transcriptWorkingDirectory: "/Users/mike/real/project",
      directoryExists: existence(["/a", "/a/b", "/a/b/c"])
    )
    #expect(attribution?.path == "/Users/mike/real/project")
    #expect(attribution?.confidence == .transcriptWorkingDirectory)
  }

  @Test("没有 cwd 时 Claude Code 回落到目录名反解并标注较低置信度")
  func attributionFallsBackToDecodedDirectoryName() {
    let attribution = AgentTranscriptProjectMapping.attribution(
      provider: .claudeCode,
      sessionFileURL: claudeSession("-a-b-c"),
      homeDirectory: home(),
      transcriptWorkingDirectory: nil,
      directoryExists: existence(["/a", "/a/b", "/a/b/c"])
    )
    #expect(attribution?.path == "/a/b/c")
    #expect(attribution?.confidence == .decodedDirectoryName)
  }

  @Test("路径不含项目信息的 provider 判不出归属时返回 nil，绝不回落主目录")
  func attributionNeverFabricatesHomeDirectory() {
    let codex = URL(
      fileURLWithPath: "/Users/mike/.codex/sessions/2026/08/14/rollout-2026-08-14T01-00-00-abc.jsonl")
    #expect(
      AgentTranscriptProjectMapping.attribution(
        provider: .codex,
        sessionFileURL: codex,
        homeDirectory: home(),
        transcriptWorkingDirectory: nil,
        directoryExists: { _ in true }) == nil)

    let cursor = URL(
      fileURLWithPath: "/Users/mike/.cursor/projects/1778224212505/agent-transcripts/s.jsonl")
    #expect(
      AgentTranscriptProjectMapping.attribution(
        provider: .cursorCLI,
        sessionFileURL: cursor,
        homeDirectory: home(),
        transcriptWorkingDirectory: nil,
        directoryExists: { _ in true }) == nil)
  }

  // MARK: - 工具调用抽取

  @Test("Claude Code 的 tool_use 块抽出工具名与文件路径")
  func extractsClaudeCodeToolUse() {
    let jsonl = """
      {"type":"assistant","timestamp":"2026-08-14T01:00:00.000Z","cwd":"/p","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/Sources/A.swift"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/p/Sources/B.swift","old_string":"secret body","new_string":"x"}}]}}
      """
    let invocations = AgentTranscriptToolExtraction.invocations(from: Data(jsonl.utf8))

    #expect(invocations.count == 2)
    #expect(invocations[0].name == "Read")
    #expect(invocations[0].filePath == "/p/Sources/A.swift")
    #expect(invocations[0].effect == .read)
    #expect(invocations[0].timestamp != nil)
    #expect(invocations[1].name == "Edit")
    #expect(invocations[1].filePath == "/p/Sources/B.swift")
    #expect(invocations[1].effect == .modify)
  }

  @Test("Codex 的 function_call 参数是 JSON 字符串也能取到路径")
  func extractsCodexFunctionCall() {
    let jsonl = """
      {"timestamp":"2026-08-14T01:00:00.000Z","type":"response_item","payload":{"type":"function_call","name":"read_file","arguments":"{\\"path\\":\\"/p/main.rs\\"}"}}
      {"timestamp":"2026-08-14T01:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch"}}
      """
    let invocations = AgentTranscriptToolExtraction.invocations(from: Data(jsonl.utf8))

    #expect(invocations.count == 2)
    #expect(invocations[0].name == "read_file")
    #expect(invocations[0].filePath == "/p/main.rs")
    #expect(invocations[0].effect == .read)
    // apply_patch 的输入是补丁正文而不是结构化路径：不许猜，只留工具名。
    #expect(invocations[1].name == "apply_patch")
    #expect(invocations[1].filePath == nil)
    #expect(invocations[1].effect == .modify)
  }

  @Test("抽取只取白名单路径键，命令与提示词正文不会被带出")
  func extractionNeverCarriesCommandOrPromptText() {
    let jsonl = """
      {"type":"user","message":{"role":"user","content":"请帮我修复登录 bug，密码是 hunter2"}}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"curl -H 'token: abc' https://x","description":"call api"}}]}}
      """
    let invocations = AgentTranscriptToolExtraction.invocations(from: Data(jsonl.utf8))

    #expect(invocations.count == 1)
    #expect(invocations[0].name == "Bash")
    #expect(invocations[0].filePath == nil)
    #expect(invocations[0].effect == .other)
  }

  @Test("工具语义分类覆盖读写工具并剥掉 MCP 前缀")
  func classifiesToolEffects() {
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "Read") == .read)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "Glob") == .read)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "Grep") == .read)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "Write") == .modify)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "MultiEdit") == .modify)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "NotebookEdit") == .modify)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "mcp__fs__write_file") == .modify)
    #expect(AgentTranscriptToolExtraction.effect(ofToolNamed: "WebSearch") == .other)
  }

  @Test("超过输入上限的 transcript 整体放弃，不返回半截结果")
  func extractionRefusesOversizedTranscript() {
    let limits = AgentTranscriptLimits(maximumInputBytes: 16)
    let jsonl = """
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/A.swift"}}]}}
      """
    #expect(
      AgentTranscriptToolExtraction.invocations(from: Data(jsonl.utf8), limits: limits).isEmpty)
  }
}
