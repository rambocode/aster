// PiTokenSource 的行为测试：字段映射、按 id 去重、项目归属与缺目录处理。
import Foundation
import Testing

@testable import AsterCore

@Suite("TokenSource Pi 会话解析")
struct TokenSourcePiTests {
  /// 手写脱敏夹具：只保留结构和数字，正文字段一律用占位符。
  private func makeHome() -> TemporaryDirectory {
    let home = TemporaryDirectory()
    let lines = [
      "{\"type\":\"session\",\"version\":\"1\",\"id\":\"s-1\",\"timestamp\":\"2026-06-20T17:21:35.633Z\",\"cwd\":\"/work/alpha\"}",
      "{\"type\":\"model_change\",\"id\":\"m-0\",\"timestamp\":\"2026-06-20T17:21:36.000Z\"}",
      "{\"type\":\"message\",\"id\":\"a-1\",\"timestamp\":\"2026-06-20T17:21:38.888Z\",\"message\":{\"role\":\"assistant\",\"content\":\"…\",\"usage\":{\"input\":100,\"output\":20,\"cacheRead\":300,\"cacheWrite\":40,\"reasoning\":8,\"totalTokens\":460}}}",
      // 与上一行同 id 的重放记录，必须只计一次。
      "{\"type\":\"message\",\"id\":\"a-1\",\"timestamp\":\"2026-06-20T17:21:38.888Z\",\"message\":{\"role\":\"assistant\",\"content\":\"…\",\"usage\":{\"input\":100,\"output\":20,\"cacheRead\":300,\"cacheWrite\":40,\"reasoning\":8,\"totalTokens\":460}}}",
      "{\"type\":\"message\",\"id\":\"a-2\",\"timestamp\":\"2026-06-21T00:30:00.000Z\",\"message\":{\"role\":\"assistant\",\"content\":\"…\",\"usage\":{\"input\":7,\"output\":3,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":10}}}",
      "{\"type\":\"message\",\"id\":\"u-1\",\"timestamp\":\"2026-06-21T00:31:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"…\"}}",
      "{\"type\":\"message\",\"id\":\"bad\",\"timestamp\":\"2026-06-21T00:32:00.000Z\",\"message\":{\"usage\":{",
    ]
    home.write(
      lines.joined(separator: "\n") + "\n",
      to: ".pi/agent/sessions/--work-alpha--/session-1.jsonl")
    return home
  }

  @Test("四列直接映射，reasoning 不重复计入 output")
  func mapsUsageColumns() {
    let home = makeHome()
    let source = PiTokenSource()
    let context = FixedTokenScanContext()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)

    let buckets = source.buckets(of: files[0], context: context)
    let first = totals(in: buckets, day: 20624)
    #expect(first == TokenTotals(input: 100, cacheWrite: 40, cacheRead: 300, output: 20))
    // 若误把 reasoning 加进 output，这里会变成 28。
    #expect(first?.total == 460)
  }

  @Test("同一条记录 id 只计一次")
  func deduplicatesByRecordID() {
    let home = makeHome()
    let buckets = PiTokenSource().buckets(
      of: PiTokenSource().discoverFiles(homeDirectory: home.url)[0],
      context: FixedTokenScanContext())
    #expect(totals(in: buckets, day: 20624)?.input == 100)
  }

  @Test("按时间戳分到不同的本地日")
  func splitsByDay() {
    let home = makeHome()
    let source = PiTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    #expect(buckets.count == 2)
    #expect(totals(in: buckets, day: 20625) == TokenTotals(input: 7, output: 3))
  }

  @Test("项目取会话头行的 cwd")
  func usesSessionWorkingDirectory() {
    let home = makeHome()
    let source = PiTokenSource()
    let context = FixedTokenScanContext()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: context)
    #expect(buckets.allSatisfy { $0.project == "/work/alpha" })
    #expect(context.requestedDirectories == ["/work/alpha"])
  }

  @Test("缺少会话头行时归到其他")
  func fallsBackToOtherProject() {
    let home = TemporaryDirectory()
    home.write(
      "{\"type\":\"message\",\"id\":\"a-1\",\"timestamp\":\"2026-06-20T17:21:38.888Z\",\"message\":{\"usage\":{\"input\":5,\"output\":1,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":6}}}\n",
      to: ".pi/agent/sessions/orphan/session-1.jsonl")
    let source = PiTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    #expect(buckets.map(\.project) == [TokenProject.otherKey])
  }

  @Test("数据目录不存在时返回空")
  func missingDirectoryYieldsNothing() {
    let home = TemporaryDirectory()
    #expect(PiTokenSource().discoverFiles(homeDirectory: home.url).isEmpty)
  }
}
