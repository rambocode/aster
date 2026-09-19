// Codex rollout 解析。夹具全部是手写的假数据，不含任何真实对话内容。
// 共用夹具定义在 TokenStatsClaudeSourceTests.swift。
import Foundation
import Testing

@testable import AsterCore

@Suite("TokenStats Codex 数据源")
struct TokenStatsCodexSourceTests {
  private func tokenCount(
    timestamp: String, input: Int64, cached: Int64, output: Int64
  ) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":\
    {"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
    "output_tokens":\(output)}}}}
    """
  }

  @Test("累计计数取相邻差分，并把 cached 从 input 里扣出来")
  func cumulativeCountersAreDifferenced() throws {
    let (file, directory) = try makeTokenStatsTranscript(
      [
        #"{"timestamp":"2026-07-17T09:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/fixture/project-a"}}"#,
        tokenCount(timestamp: "2026-07-17T10:00:00Z", input: 100, cached: 60, output: 10),
        tokenCount(timestamp: "2026-07-17T10:05:00Z", input: 300, cached: 200, output: 50),
      ], name: "rollout-2026-07-17.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = CodexTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.count == 1)
    // 首条没有前值，整条当新值：input 100-60=40、cacheRead 60、output 10。
    // 第二条 Δinput=200、Δcached=140 → input 60、cacheRead 140、output 40。
    #expect(buckets.first?.project == "/fixture/project-a")
    #expect(buckets.first?.totals == TokenTotals(input: 100, cacheRead: 200, output: 50))
  }

  @Test("任一列变小视为计数器重置，整条当新值而不是负消费")
  func counterResetIsTreatedAsFreshValue() throws {
    let (file, directory) = try makeTokenStatsTranscript(
      [
        #"{"timestamp":"2026-07-17T09:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/fixture/project-a"}}"#,
        tokenCount(timestamp: "2026-07-17T10:00:00Z", input: 300, cached: 200, output: 50),
        tokenCount(timestamp: "2026-07-17T11:00:00Z", input: 50, cached: 20, output: 5),
      ], name: "rollout-2026-07-17.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = CodexTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    // 第一条 input 100 / cacheRead 200 / output 50；重置后再加 30 / 20 / 5。
    #expect(buckets.first?.totals == TokenTotals(input: 130, cacheRead: 220, output: 55))
  }

  @Test("跨午夜的会话按事件时间拆到两天")
  func sessionSplitsAcrossMidnight() throws {
    let (file, directory) = try makeTokenStatsTranscript(
      [
        #"{"timestamp":"2026-07-17T23:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/fixture/project-a"}}"#,
        tokenCount(timestamp: "2026-07-17T23:30:00Z", input: 100, cached: 0, output: 10),
        tokenCount(timestamp: "2026-07-18T00:30:00Z", input: 150, cached: 0, output: 25),
      ], name: "rollout-2026-07-17.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = CodexTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.count == 2)
    #expect(buckets[0].totals == TokenTotals(input: 100, output: 10))
    #expect(buckets[1].totals == TokenTotals(input: 50, output: 15))
  }

  @Test("没有 session_meta 时归入「其他」")
  func missingSessionMetaGoesToOther() throws {
    let (file, directory) = try makeTokenStatsTranscript(
      [tokenCount(timestamp: "2026-07-17T10:00:00Z", input: 10, cached: 0, output: 2)],
      name: "rollout-2026-07-17.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    let buckets = CodexTokenSource().buckets(of: file, context: tokenStatsUTCContext())
    #expect(buckets.map(\.project) == [TokenProject.otherKey])
  }

  @Test("只收 rollout- 前缀的 jsonl，sessions 与 archived_sessions 都要读")
  func discoversLiveAndArchivedRollouts() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let manager = FileManager.default
    let live = home.appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
    let archived = home.appendingPathComponent(
      ".codex/archived_sessions/2026/07/01", isDirectory: true)
    try manager.createDirectory(at: live, withIntermediateDirectories: true)
    try manager.createDirectory(at: archived, withIntermediateDirectories: true)
    try "{}\n".write(to: live.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
    try "{}\n".write(
      to: archived.appendingPathComponent("rollout-b.jsonl"), atomically: true, encoding: .utf8)
    try "{}\n".write(to: live.appendingPathComponent("other.jsonl"), atomically: true, encoding: .utf8)

    let names = CodexTokenSource().discoverFiles(homeDirectory: home)
      .map { ($0.path as NSString).lastPathComponent }.sorted()
    #expect(names == ["rollout-a.jsonl", "rollout-b.jsonl"])
  }
}
