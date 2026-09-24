import Foundation
import Testing

@testable import AsterCore

// HostUsageLedger：frecency 打分、排序、清理与 UserDefaults 往返（独立 suite）。

/// 每个用例一个独立 UserDefaults suite，结束后整域删除。
private func withLedgerDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
  let suite = "HostUsageLedgerTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  try body(defaults)
}

@Test("使用次数越多、越近分数越高")
func hostUsageScoresByCountAndRecency() {
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  let a = UUID()
  let b = UUID()
  var ledger = HostUsageLedger()
  ledger.record(.id(a), at: now.addingTimeInterval(-60))
  ledger.record(.id(a), at: now.addingTimeInterval(-30))
  ledger.record(.id(b), at: now.addingTimeInterval(-10 * 86_400))
  #expect(ledger.entries[.id(a)]?.count == 2)
  #expect(ledger.score(for: .id(a), now: now) == 8)
  #expect(ledger.score(for: .id(b), now: now) == 0.25)
  #expect(ledger.score(for: .id(UUID()), now: now) == 0)
}

@Test("刚用过一次的主机排在很久以前用过多次的主机前面")
func hostUsageRecentBeatsStale() {
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  let recent = HostUsageKey.target("recent")
  let stale = HostUsageKey.target("stale")
  var ledger = HostUsageLedger()
  for _ in 0..<3 { ledger.record(stale, at: now.addingTimeInterval(-30 * 86_400)) }
  ledger.record(recent, at: now.addingTimeInterval(-10))
  #expect(ledger.ranked([stale, recent], now: now) == [recent, stale])
}

@Test("同分保持输入顺序")
func hostUsageRankingIsStable() {
  let keys: [HostUsageKey] = [.target("b"), .target("a"), .target("c")]
  #expect(HostUsageLedger().ranked(keys) == keys)
}

@Test("清理只删除不存在的 ID，文本键保留")
func hostUsagePruneRemovesMissingIDs() {
  let kept = UUID()
  let gone = UUID()
  var ledger = HostUsageLedger()
  ledger.record(.id(kept))
  ledger.record(.id(gone))
  ledger.record(.target("orb"))
  let changed = ledger.prune(keepingIDs: [kept])
  #expect(changed)
  #expect(Set(ledger.entries.keys) == [.id(kept), .target("orb")])
  let changedAgain = ledger.prune(keepingIDs: [kept])
  #expect(!changedAgain)
}

@Test("文本键超过上限时淘汰分数最低者")
func hostUsageTrimsTargetKeys() {
  let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
  var ledger = HostUsageLedger()
  ledger.record(.target("old"), at: now.addingTimeInterval(-30 * 86_400))
  for index in 0..<HostUsageLedger.targetCapacity { ledger.record(.target("t\(index)"), at: now) }
  #expect(ledger.entries.count == HostUsageLedger.targetCapacity)
  #expect(ledger.entries[.target("old")] == nil)
}

@Test("UserDefaults 往返，键为 aster.hosts.usage.v1")
func hostUsagePersistsToDefaults() throws {
  try withLedgerDefaults { defaults in
    #expect(try HostUsageLedger.load(from: defaults) == HostUsageLedger())
    let id = UUID()
    var ledger = HostUsageLedger()
    let date = Date(timeIntervalSinceReferenceDate: 12_345)
    ledger.record(.id(id), at: date)
    ledger.record(.target("deploy@box"), at: date)
    try ledger.save(to: defaults)
    #expect(defaults.data(forKey: "aster.hosts.usage.v1") != nil)
    #expect(try HostUsageLedger.load(from: defaults) == ledger)
  }
}

@Test("损坏数据抛错，非法条目在读取时丢弃")
func hostUsageRejectsCorruptData() throws {
  try withLedgerDefaults { defaults in
    defaults.set(Data("not json".utf8), forKey: HostUsageLedger.defaultsKey)
    #expect(throws: (any Error).self) { try HostUsageLedger.load(from: defaults) }

    let raw = #"{"bogus":{"count":1,"lastUsed":0},"target:ok":{"count":2,"lastUsed":0},"target:zero":{"count":0,"lastUsed":0}}"#
    defaults.set(Data(raw.utf8), forKey: HostUsageLedger.defaultsKey)
    let ledger = try HostUsageLedger.load(from: defaults)
    #expect(Array(ledger.entries.keys) == [.target("ok")])
  }
}
