import Foundation
import Testing

@testable import AsterCore

// 状态栏那一小段文字的纯逻辑：取哪个窗口、什么颜色、按什么顺序排。

@Suite("UsageStatusSummary")
struct UsageStatusSummaryTests {
  /// 造一个账号快照；`windows` 用 (kind, percent) 简写。
  private func account(
    _ provider: AgentProvider, _ windows: [(AgentUsageWindowKind, Double)]
  ) throws -> UsageAccountSnapshot {
    let built = try windows.map {
      try #require(AgentUsageWindow(kind: $0.0, usedPercent: $0.1))
    }
    return UsageAccountSnapshot(
      id: "\(provider.rawValue):default", provider: provider, label: provider.rawValue,
      windows: built, fetchedAt: nil)
  }

  @Test("优先取 5 小时窗口，没有才退到每周窗口")
  func prefersFiveHourAndFallsBackToWeekly() throws {
    let summary = UsageStatusSummary.make(
      accounts: [
        try account(.claudeCode, [(.fiveHour, 12), (.weekly, 77)]),
        try account(.codex, [(.weekly, 64)]),
      ],
      blockedAgents: 0)
    #expect(summary.segments.map(\.provider) == [.claudeCode, .codex])
    #expect(summary.segments.map(\.usedPercent) == [12, 64])
    #expect(!summary.needsAttention)
  }

  @Test("没有账号级窗口的账号不出段")
  func dropsAccountsWithoutAccountWindows() throws {
    let summary = UsageStatusSummary.make(
      accounts: [
        try account(.codex, [(.session, 90)]),
        try account(.claudeCode, []),
      ],
      blockedAgents: 2)
    #expect(summary.segments.isEmpty)
    // 有 Agent 在等输入时仍要亮红点，和有没有配额数据无关。
    #expect(summary.needsAttention)
  }

  @Test("告警阈值 80 / 95")
  func severityThresholds() throws {
    let cases: [(Double, UsageStatusSummary.Severity)] = [
      (0, .normal), (79.9, .normal), (80, .warning), (94.9, .warning), (95, .critical),
      (100, .critical),
    ]
    for (percent, expected) in cases {
      let summary = UsageStatusSummary.make(
        accounts: [try account(.claudeCode, [(.fiveHour, percent)])], blockedAgents: 0)
      #expect(summary.segments.first?.severity == expected, "\(percent)")
    }
  }

  // 状态栏文字很窄，provider 换位置会让人误读数字，所以顺序固定按 AgentProvider 的声明序。
  @Test("段顺序固定按 AgentProvider 声明序，与输入顺序无关")
  func segmentsFollowProviderDeclarationOrder() throws {
    let summary = UsageStatusSummary.make(
      accounts: [
        try account(.codex, [(.fiveHour, 5)]),
        try account(.claudeCode, [(.fiveHour, 6)]),
      ],
      blockedAgents: 0)
    #expect(summary.segments.map(\.provider) == [.claudeCode, .codex])
  }
}
