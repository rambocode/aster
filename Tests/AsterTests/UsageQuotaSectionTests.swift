import AppKit
import AsterCore
import Testing

@testable import Aster

/// 一个带 5 小时窗口与重置时间的账号，用来触发倒计时文字、档位徽标与严重度分支。
@MainActor
private func makeQuotaAccount(
  id: String = "claudeCode:default",
  label: String = "Claude",
  plan: String? = nil,
  usedPercent: Double = 63,
  fetchedAt: Date? = Date()
) throws -> UsageAccountSnapshot {
  let window = try #require(
    AgentUsageWindow(
      kind: .fiveHour, usedPercent: usedPercent, resetsAt: Date().addingTimeInterval(3_600)))
  return UsageAccountSnapshot(
    id: id, provider: .claudeCode, label: label, plan: plan, windows: [window],
    fetchedAt: fetchedAt)
}

/// 按 identifier 在视图树里找一个视图。
@MainActor
private func findQuotaView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for child in root.subviews {
    if let match = findQuotaView(identifier, in: child) { return match }
  }
  return nil
}

/// 默认账号那一行的两行窗口条。
@MainActor
private func requireWindowRow(in section: UsageQuotaSectionController) throws
  -> UsageQuotaWindowRow
{
  try #require(
    findQuotaView("usage-quota-window-claudeCode:default-fiveHour", in: section.view)
      as? UsageQuotaWindowRow)
}

@Suite("UsageQuota 配额页生命周期")
@MainActor
struct UsageQuotaLifecycleTests {
  @Test("有倒计时内容时排下一次刷新，挂起后取消")
  func 挂起取消倒计时() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeQuotaAccount()])
    #expect(section.hasScheduledTick)
    section.suspend()
    #expect(!section.hasScheduledTick)
  }

  @Test("没有配额数据时不排任何任务")
  func 空数据无任务() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    #expect(!section.hasScheduledTick)
    section.suspend()
  }

  @Test("没激活过的配额页不排任何任务")
  func 未激活无任务() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    #expect(!section.hasScheduledTick)
  }

  @Test("挂起后再收到快照也不会重新排任务")
  func 挂起后不复活() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.suspend()
    section.render([try makeQuotaAccount()])
    #expect(!section.hasScheduledTick)
  }
}

@Suite("UsageQuota 配额卡结构")
@MainActor
struct UsageQuotaCardLayoutTests {
  @Test("每个窗口占两行，下行有接近上限与重置倒计时两个位置")
  func 两行结构() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeQuotaAccount(usedPercent: 97)])
    let suffix = "claudeCode:default-fiveHour"
    #expect(findQuotaView("usage-quota-percent-\(suffix)", in: section.view) != nil)
    #expect(findQuotaView("usage-quota-track-\(suffix)", in: section.view) != nil)
    let alert = try #require(
      findQuotaView("usage-quota-alert-\(suffix)", in: section.view) as? NSTextField)
    let reset = try #require(
      findQuotaView("usage-quota-reset-\(suffix)", in: section.view) as? NSTextField)
    #expect(!alert.stringValue.isEmpty)
    #expect(reset.stringValue.contains("后重置"))
    section.suspend()
  }

  @Test("只有危险级别才显示接近上限")
  func 接近上限显隐() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeQuotaAccount(usedPercent: 50)])
    #expect(!(try requireWindowRow(in: section)).isAlertVisible)

    // 换一个已用百分比会改变结构签名，卡片重建后取新的一行。
    section.render([try makeQuotaAccount(usedPercent: 97)])
    #expect(try requireWindowRow(in: section).isAlertVisible)
    section.suspend()
  }

  @Test("有订阅档位时显示徽标")
  func 档位徽标显示() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeQuotaAccount(plan: "Max 20x")])
    let badge = try #require(
      findQuotaView("usage-quota-plan-claudeCode:default", in: section.view)
        as? UsagePlanBadgeView)
    #expect(!badge.isHidden)
    #expect(badge.text == "Max 20x")
    section.suspend()
  }

  @Test("没有订阅档位时隐藏徽标")
  func 档位缺失隐藏徽标() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    var account = try makeQuotaAccount(plan: nil)
    section.render([account])
    let badge = try #require(
      findQuotaView("usage-quota-plan-claudeCode:default", in: section.view)
        as? UsagePlanBadgeView)
    #expect(badge.isHidden)
    #expect(badge.text.isEmpty)

    // 纯空白与 nil 同样处理，不留一个空胶囊。
    account.plan = "   "
    section.render([account])
    #expect(badge.isHidden)
    section.suspend()
  }

  @Test("档位从无到有时原地出现，卡片实例不变")
  func 档位原地更新() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    // 同一份账号只改 plan：新建账号会带上新的 `resetsAt`，那属于结构变化。
    var account = try makeQuotaAccount(plan: nil)
    section.render([account])
    let card = try #require(
      findQuotaView("usage-quota-card-claudeCode:default", in: section.view))
    let badge = try #require(
      findQuotaView("usage-quota-plan-claudeCode:default", in: section.view)
        as? UsagePlanBadgeView)
    #expect(badge.isHidden)

    account.plan = "Pro"
    section.render([account])
    #expect(!badge.isHidden)
    #expect(badge.text == "Pro")
    #expect(findQuotaView("usage-quota-card-claudeCode:default", in: section.view) === card)
    section.suspend()
  }

  @Test("窗口结构变化仍然重建卡片")
  func 结构变化重建卡片() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    var account = try makeQuotaAccount(usedPercent: 10)
    section.render([account])
    let card = try #require(
      findQuotaView("usage-quota-card-claudeCode:default", in: section.view))

    account.windows = [
      try #require(
        AgentUsageWindow(
          kind: .fiveHour, usedPercent: 80, resetsAt: account.windows[0].resetsAt))
    ]
    section.render([account])
    #expect(findQuotaView("usage-quota-card-claudeCode:default", in: section.view) !== card)
    section.suspend()
  }

  @Test("数据时刻超过两分钟才显示，并跟随新的取得时刻更新")
  func 更新时刻文字() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    var account = try makeQuotaAccount(fetchedAt: Date())
    section.render([account])
    let stamp = try #require(
      findQuotaView("usage-quota-stamp-claudeCode:default", in: section.view) as? NSTextField)
    #expect(stamp.isHidden)

    account.fetchedAt = Date().addingTimeInterval(-3_600)
    section.render([account])
    #expect(!stamp.isHidden)
    #expect(stamp.stringValue.contains("前更新"))

    account.fetchedAt = Date()
    section.render([account])
    #expect(stamp.isHidden)
    section.suspend()
  }
}

@Suite("UsageQuota 配额页展示口径")
@MainActor
struct UsageQuotaDisplayModeTests {
  @Test("剩余口径显示 100 减已用，进度条同时变短")
  func 剩余口径数字与条宽() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeQuotaAccount(usedPercent: 63)])
    let row = try requireWindowRow(in: section)
    #expect(row.percentText == "63%")
    #expect(abs(row.fillFraction - 0.63) < 0.001)

    section.apply(displayMode: .remaining)
    #expect(row.percentText == "37%")
    #expect(abs(row.fillFraction - 0.37) < 0.001)
    section.suspend()
  }

  @Test("口径切换只原地更新，不重建卡片")
  func 口径切换不重建() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeQuotaAccount(usedPercent: 63)])
    let card = try #require(
      findQuotaView("usage-quota-card-claudeCode:default", in: section.view))
    let row = try requireWindowRow(in: section)

    section.apply(displayMode: .remaining)
    #expect(findQuotaView("usage-quota-card-claudeCode:default", in: section.view) === card)
    #expect(try requireWindowRow(in: section) === row)
    section.suspend()
  }

  @Test("严重度只认已用百分比，不随口径变")
  func 严重度不随口径变() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    // 已用 96% 是危险级别；按「剩余 4%」去判会掉回 normal，那条快用光的配额就会变成绿色。
    section.render([try makeQuotaAccount(usedPercent: 96)])
    let row = try requireWindowRow(in: section)
    #expect(row.severity == .critical)
    #expect(row.isAlertVisible)

    section.apply(displayMode: .remaining)
    #expect(row.severity == .critical)
    #expect(row.isAlertVisible)
    section.suspend()
  }

  @Test("切过口径后新建的卡片沿用当前口径")
  func 新卡片沿用口径() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.apply(displayMode: .remaining)
    section.render([try makeQuotaAccount(usedPercent: 20)])
    #expect(try requireWindowRow(in: section).percentText == "80%")
    section.suspend()
  }
}

@Suite("UsageQuota 配额页分栏")
@MainActor
struct UsageQuotaColumnTests {
  @Test("宽度跨过阈值时切换列数，卡片实例不变")
  func 宽度切换列数() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([
      try makeQuotaAccount(),
      try makeQuotaAccount(id: "codex:default", label: "Codex", usedPercent: 20),
    ])
    #expect(section.columnCount == 1)
    let card = try #require(findQuotaView("usage-quota-card-codex:default", in: section.view))

    section.applyWidth(700)
    #expect(section.columnCount == 2)
    #expect(findQuotaView("usage-quota-card-codex:default", in: section.view) === card)

    section.applyWidth(400)
    #expect(section.columnCount == 1)
    #expect(findQuotaView("usage-quota-card-codex:default", in: section.view) === card)
    section.suspend()
  }
}
