// GrokTokenSource 的行为测试：缓存量从 input 里扣除、子 agent 回合保留、目录名解码。
import Foundation
import Testing

@testable import AsterCore

@Suite("TokenSource Grok 事件流解析")
struct TokenSourceGrokTests {
  /// 手写脱敏夹具：一条主回合、一条后台任务回合、一条重复 prompt_id、若干无关事件。
  private func makeHome() -> TemporaryDirectory {
    let home = TemporaryDirectory()
    let lines = [
      "{\"timestamp\":1781976095,\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"text\":\"…\"}}}",
      "{\"timestamp\":1781976095,\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p-1\",\"stop_reason\":\"end\",\"usage\":{\"inputTokens\":1000,\"outputTokens\":50,\"totalTokens\":1050,\"cachedReadTokens\":700,\"cacheCreationTokens\":100,\"reasoningTokens\":20,\"modelCalls\":3}}}}",
      // 同一 prompt_id 重复落盘，必须只计一次。
      "{\"timestamp\":1781976096,\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p-1\",\"usage\":{\"inputTokens\":1000,\"outputTokens\":50,\"totalTokens\":1050,\"cachedReadTokens\":700,\"cacheCreationTokens\":100,\"reasoningTokens\":20}}}}",
      "{\"timestamp\":1781976097,\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"task-completed-call-abc\",\"usage\":{\"inputTokens\":500,\"outputTokens\":8,\"totalTokens\":508,\"cachedReadTokens\":480,\"cacheCreationTokens\":0,\"reasoningTokens\":2}}}}",
      "{\"timestamp\":1782000600,\"params\":{\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p-2\",\"usage\":{\"inputTokens\":30,\"outputTokens\":4,\"totalTokens\":34,\"cachedReadTokens\":0,\"cacheCreationTokens\":0}}}}",
      "{\"timestamp\":1782000601,\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"title\":\"…\"}}}",
    ]
    home.write(
      lines.joined(separator: "\n") + "\n",
      to: ".grok/sessions/%2Fwork%2Falpha/01a0-session/updates.jsonl")
    // sessions/ 下混放的 sqlite 文件不应该被当成项目目录。
    home.write("x", to: ".grok/sessions/session_search.sqlite")
    return home
  }

  @Test("只取 turn_completed，忽略其它事件与目录下的非目录项")
  func discoversOnlySessionUpdates() {
    let home = makeHome()
    let files = GrokTokenSource().discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)
    #expect(files[0].path.hasSuffix("01a0-session/updates.jsonl"))
  }

  @Test("inputTokens 已含缓存，四列换算后总量守恒")
  func subtractsCacheFromInput() {
    let home = makeHome()
    let source = GrokTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    // 主回合 1000-700-100=200，后台任务回合 500-480-0=20。
    #expect(
      totals(in: buckets, day: 20624)
        == TokenTotals(input: 220, cacheWrite: 100, cacheRead: 1180, output: 58))
    // 和等于两条记录 totalTokens 之和 1050+508。
    #expect(totals(in: buckets, day: 20624)?.total == 1558)
  }

  @Test("task-completed 回合计入，不按子 agent 排除")
  func keepsBackgroundTaskTurns() {
    let home = makeHome()
    let source = GrokTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    // 若把 task-completed-* 排除，input 会掉到 200、cacheRead 掉到 700。
    #expect(totals(in: buckets, day: 20624)?.input == 220)
    #expect(totals(in: buckets, day: 20624)?.cacheRead == 1180)
  }

  @Test("同一 prompt_id 只计一次")
  func deduplicatesByPromptID() {
    let home = makeHome()
    let source = GrokTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    #expect(totals(in: buckets, day: 20625) == TokenTotals(input: 30, output: 4))
  }

  @Test("项目路径由目录名 percent-decode 得到")
  func decodesWorkingDirectory() {
    let home = makeHome()
    let source = GrokTokenSource()
    let context = FixedTokenScanContext()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: context)
    #expect(buckets.allSatisfy { $0.project == "/work/alpha" })
  }

  @Test("数据目录不存在时返回空")
  func missingDirectoryYieldsNothing() {
    let home = TemporaryDirectory()
    #expect(GrokTokenSource().discoverFiles(homeDirectory: home.url).isEmpty)
  }
}
