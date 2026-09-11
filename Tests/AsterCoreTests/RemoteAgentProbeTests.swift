import Testing

@testable import AsterCore

// RemoteAgentProbe 的版本身份二次确认与解析测试。

@Suite("RemoteAgentProbe")
struct RemoteAgentProbeTests {

  // MARK: - verifyVersionIdentity

  @Test("grok 版本输出确认 grokBuild 身份")
  func grokVersionConfirmsGrokBuild() {
    #expect(
      RemoteAgentProbe.verifyVersionIdentity(
        version: "grok 1.0.24 (68e414c661e3)", provider: .grokBuild))
  }

  @Test("grok 版本输出拒绝 cursorCLI（commandName 冲突）")
  func grokVersionRejectsCursorCLI() {
    // /usr/local/bin/agent 实际是 grok 的符号链接，版本输出以 "grok" 开头
    #expect(
      !RemoteAgentProbe.verifyVersionIdentity(
        version: "grok 1.0.24 (68e414c661e3)", provider: .cursorCLI))
  }

  @Test("claude 版本输出确认 claudeCode 身份")
  func claudeVersionConfirmsClaudeCode() {
    #expect(
      RemoteAgentProbe.verifyVersionIdentity(
        version: "claude 2.1.266", provider: .claudeCode))
  }

  @Test("codex 版本输出确认 codex 身份")
  func codexVersionConfirmsCodex() {
    #expect(
      RemoteAgentProbe.verifyVersionIdentity(
        version: "codex 0.1.2505301703", provider: .codex))
  }

  @Test("无版本输出 → 未安装")
  func nilVersionMeansNotInstalled() {
    #expect(!RemoteAgentProbe.verifyVersionIdentity(version: nil, provider: .grokBuild))
    #expect(!RemoteAgentProbe.verifyVersionIdentity(version: "", provider: .claudeCode))
  }

  @Test("无 token 的 provider 在版本输出不含已知冲突时视为已安装")
  func unknownProviderWithNoConflictIsInstalled() {
    #expect(
      RemoteAgentProbe.verifyVersionIdentity(
        version: "gemini-cli 1.2.3", provider: .gemini))
  }

  @Test("无 token 的 provider 在版本输出包含另一 provider 的 token 时拒绝")
  func unknownProviderWithConflictIsRejected() {
    // 假设某个 provider 的 commandName 指向了 grok 的二进制
    #expect(
      !RemoteAgentProbe.verifyVersionIdentity(
        version: "grok 1.0.24", provider: .gemini))
  }

  // MARK: - parse（集成级）

  @Test("parse 正确处理 grok/agent 冲突场景")
  func parseHandlesGrokAgentCollision() {
    // 模拟真实远端探测输出：grok 安装器把 /usr/local/bin/agent 创建为 grok 的符号链接
    let output = """
      ASTER_AGENT_PROBE_V1
      agent=claude\t
      agent=codex\t
      agent=opencode\t
      agent=agent\tgrok 1.0.24 (68e414c661e3)
      agent=kimi\t
      agent=pi\t
      agent=omp\t
      agent=grok\tgrok 1.0.24 (68e414c661e3)
      agent=gemini\t
      agent=copilot\t
      agent=amp\t
      agent=droid\t
      agent=devin\t
      agent=kiro-cli\t
      agent=qodercli\t
      agent=qwen\t
      agent=hermes\t
      agent=agy\t
      agent=maki\t
      agent=muse\t
      agent=cline\t
      agent=kilo\t
      end
      """
    let result = RemoteAgentProbe.parse(output)
    #expect(result != nil)
    guard let result else { return }

    // grokBuild 应识别为已安装
    let grok = result.entries[.grokBuild]
    #expect(grok?.installed == true)
    #expect(grok?.version == "grok 1.0.24 (68e414c661e3)")

    // cursorCLI 不应误报为已安装（agent 命令实际是 grok）
    let cursor = result.entries[.cursorCLI]
    #expect(cursor?.installed == false)
    #expect(cursor?.version == nil)

    // 其余 provider 全部未安装
    for provider in AgentProvider.allCases
    where provider != .grokBuild && provider != .cursorCLI {
      #expect(result.entries[provider]?.installed == false, "provider \(provider) 不应误报为已安装")
    }
  }

  @Test("parse 返回 nil 当缺少标记行")
  func parseMissingMarker() {
    let output = "agent=grok\tgrok 1.0.24\nend\n"
    #expect(RemoteAgentProbe.parse(output) == nil)
  }
}
