// Claude transcript 解析。夹具全部是手写的假数据，不含任何真实对话内容。
// 这里的 `makeTokenStatsTranscript` / `tokenStatsUTCContext` 同时供 Codex 数据源测试使用。
import Foundation
import Testing

@testable import AsterCore

/// 把若干行 JSONL 写进临时目录并返回对应的 `TokenSourceFile`。
func makeTokenStatsTranscript(_ lines: [String], name: String = "fixture.jsonl") throws
  -> (file: TokenSourceFile, directory: URL)
{
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("token-stats-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(name)
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
  let file = TokenSourceFile(
    path: url.path, size: Int64(values.fileSize ?? 0),
    modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
  return (file, directory)
}

/// 固定在 UTC，测试里的日整数才和时间戳里的日期一一对应。
func tokenStatsUTCContext() -> TokenProjectResolver {
  TokenProjectResolver(timeZone: TimeZone(identifier: "UTC")!)
}

private func claudeLine(
  cwd: String, timestamp: String, id: String, input: Int64, cacheWrite: Int64 = 0,
  cacheRead: Int64 = 0, output: Int64
) -> String {
  """
  {"type":"assistant","cwd":"\(cwd)","timestamp":"\(timestamp)","message":{"id":"\(id)",\
  "role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\(input),\
  "cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead),\
  "output_tokens":\(output)}}}
  """
}

@Suite("TokenStats Claude 数据源")
struct TokenStatsClaudeSourceTests {
  @Test("同一 message.id 的多行按列取历史最大值，不求和也不只取首行")
  func restatedUsageCountsPeakNotSum() throws {
    // 一个 assistant turn 会写成多行，每行重复「截至此行」的 usage。
    let (file, directory) = try makeTokenStatsTranscript([
      claudeLine(cwd: "/fixture/project-a", timestamp: "2026-07-17T10:00:00Z", id: "m1", input: 100, output: 3),
      claudeLine(cwd: "/fixture/project-a", timestamp: "2026-07-17T10:00:01Z", id: "m1", input: 100, output: 120),
      claudeLine(cwd: "/fixture/project-a", timestamp: "2026-07-17T10:00:02Z", id: "m1", input: 100, output: 450),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = ClaudeTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.count == 1)
    // 求和会得到 300 / 573，只取首行会得到 100 / 3。
    #expect(buckets.first?.totals == TokenTotals(input: 100, output: 450))
  }

  @Test("不同 message.id 各自计数，缓存列同样按列抬升")
  func distinctMessagesAccumulate() throws {
    let (file, directory) = try makeTokenStatsTranscript([
      claudeLine(
        cwd: "/fixture/project-a", timestamp: "2026-07-17T10:00:00Z", id: "m1", input: 10,
        cacheWrite: 5, cacheRead: 1_000, output: 20),
      claudeLine(
        cwd: "/fixture/project-a", timestamp: "2026-07-17T10:00:01Z", id: "m2", input: 7,
        cacheWrite: 0, cacheRead: 2_000, output: 30),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = ClaudeTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.count == 1)
    #expect(
      buckets.first?.totals == TokenTotals(input: 17, cacheWrite: 5, cacheRead: 3_000, output: 50))
  }

  @Test("跨午夜的行拆到两个本地日，不同 cwd 拆到两个项目")
  func splitsByDayAndProject() throws {
    let (file, directory) = try makeTokenStatsTranscript([
      claudeLine(cwd: "/fixture/project-a", timestamp: "2026-07-17T23:59:00Z", id: "m1", input: 10, output: 1),
      claudeLine(cwd: "/fixture/project-a", timestamp: "2026-07-18T00:01:00Z", id: "m2", input: 20, output: 2),
      claudeLine(cwd: "/fixture/project-b", timestamp: "2026-07-18T00:02:00Z", id: "m3", input: 30, output: 3),
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = ClaudeTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.count == 3)
    let day17 = LocalDayStamper.daysFromCivil(2026, 7, 17)
    #expect(buckets.first?.day == day17)
    #expect(buckets.filter { $0.day == day17 + 1 }.map(\.project) == ["/fixture/project-a", "/fixture/project-b"])
  }

  @Test("没有 usage 的行、空行与被截断的尾行都不影响其余统计")
  func skipsUnrelatedAndTruncatedLines() throws {
    let good = claudeLine(
      cwd: "/fixture/project-a", timestamp: "2026-07-17T10:00:00Z", id: "m1", input: 10, output: 2)
    let (file, directory) = try makeTokenStatsTranscript([
      #"{"type":"user","cwd":"/fixture/project-a","timestamp":"2026-07-17T09:59:00Z","message":{"role":"user"}}"#,
      good,
      "",
      #"{"type":"assistant","cwd":"/fixture/project-a","timestamp":"2026-07-17T10:00:03Z","message":{"id":"m2","usage":{"input_toke"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = ClaudeTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.count == 1)
    #expect(buckets.first?.totals == TokenTotals(input: 10, output: 2))
  }

  @Test("没有 cwd 的行归入「其他」")
  func missingWorkingDirectoryGoesToOther() throws {
    let (file, directory) = try makeTokenStatsTranscript([
      #"{"type":"assistant","timestamp":"2026-07-17T10:00:00Z","message":{"id":"m1","usage":{"input_tokens":5,"output_tokens":1}}}"#
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = ClaudeTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.map(\.project) == [TokenProject.otherKey])
  }

  @Test("数据目录不存在时不报错，返回空列表")
  func missingHomeYieldsNoFiles() {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("absent-\(UUID().uuidString)", isDirectory: true)
    #expect(ClaudeTokenSource().discoverFiles(homeDirectory: home).isEmpty)
    #expect(CodexTokenSource().discoverFiles(homeDirectory: home).isEmpty)
  }

  @Test("递归列举 projects 下的子 agent transcript")
  func discoversNestedTranscripts() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let nested = home.appendingPathComponent(
      ".claude/projects/-fixture-project-a/session-1/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "{}\n".write(to: nested.appendingPathComponent("sub.jsonl"), atomically: true, encoding: .utf8)
    try "{}\n".write(
      to: nested.deletingLastPathComponent().appendingPathComponent("main.jsonl"), atomically: true,
      encoding: .utf8)
    try "noise".write(
      to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let files = ClaudeTokenSource().discoverFiles(homeDirectory: home)
    #expect(files.count == 2)
    #expect(files.allSatisfy { $0.path.hasSuffix(".jsonl") })
  }
}
