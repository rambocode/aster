import Foundation
import Testing

@testable import AsterCore

@Test("目录匹配等级优先于 frecency，等级内按分数排序")
func frequentFoldersRanksNameMatchesBeforePathMatches() throws {
  let now = Date(timeIntervalSince1970: 2_000_000)
  var folders = FrequentFolders(capacity: 100)
  for offset in 1...8 {
    let recorded = folders.record(
      "/work/api-archive/client-" + String(offset),
      at: now.addingTimeInterval(-60)
    )
    #expect(recorded)
  }
  let recordedExact = folders.record("/work/API", at: now.addingTimeInterval(-3_600))
  let recordedPrefix = folders.record("/work/api-server", at: now.addingTimeInterval(-120))
  #expect(recordedExact)
  #expect(recordedPrefix)

  let matches = folders.ranked(matching: "api", now: now)

  #expect(matches.first?.path == "/work/API")
  #expect(matches.dropFirst().first?.path == "/work/api-server")
}

@Test("frecency 按一小时、一天和一周时间窗衰减")
func frequentFoldersAppliesDocumentedRecencyWeights() throws {
  let now = Date(timeIntervalSince1970: 3_000_000)
  var folders = FrequentFolders(capacity: 100)
  let recordedRecent = folders.record("/work/recent", at: now.addingTimeInterval(-30 * 60))
  #expect(recordedRecent)
  for day in 8...17 {
    let recorded = folders.record(
      "/work/old", at: now.addingTimeInterval(-Double(day) * 86_400))
    #expect(recorded)
  }

  let ranked = folders.ranked(matching: "work", now: now)

  #expect(ranked.map(\.path) == ["/work/recent", "/work/old"])
  #expect(ranked[0].score == 4)
  #expect(ranked[1].score == 2.5)
}

@Test("忽略目录会移除现有记录并阻止自动学习，取消忽略后可重新记录")
func frequentFoldersKeepsIgnoreListSticky() throws {
  let now = Date(timeIntervalSince1970: 4_000_000)
  var folders = FrequentFolders(capacity: 100)
  let initiallyRecorded = folders.record("~/tmp/scratch", at: now)
  #expect(initiallyRecorded)

  let ignored = folders.ignore("~/tmp/scratch")
  let recordedWhileIgnored = folders.record("~/tmp/scratch", at: now.addingTimeInterval(60))
  #expect(ignored)
  #expect(!recordedWhileIgnored)
  #expect(folders.ranked(matching: "scratch", now: now).isEmpty)

  let unignored = folders.unignore("~/tmp/scratch")
  let recordedAgain = folders.record("~/tmp/scratch", at: now.addingTimeInterval(120))
  #expect(unignored)
  #expect(recordedAgain)
  #expect(folders.ranked(matching: "scratch", now: now.addingTimeInterval(120)).count == 1)
}

@Test("目录数据库限制为最高分的 100 项并可持久化往返")
func frequentFoldersTrimsAndRoundTrips() throws {
  let now = Date(timeIntervalSince1970: 5_000_000)
  var folders = FrequentFolders(capacity: 100)
  for index in 0..<120 {
    let recorded = folders.record(
      "/work/project-" + String(index),
      at: now.addingTimeInterval(Double(index))
    )
    #expect(recorded)
  }

  #expect(folders.entries.count == 100)
  #expect(!folders.entries.contains { $0.path == "/work/project-19" })
  #expect(folders.entries.contains { $0.path == "/work/project-20" })
  #expect(folders.entries.contains { $0.path == "/work/project-119" })
  let restored = try JSONDecoder().decode(
    FrequentFolders.self,
    from: JSONEncoder().encode(folders)
  )
  #expect(restored == folders)
  #expect(restored.ranked(matching: "project", now: now.addingTimeInterval(120)).count == 100)
}

@Test("目录持久化入口在 JSON 解码前拒绝超大数据")
func frequentFolderStoreRejectsOversizedDataBeforeDecoding() {
  let oversized = Data(
    repeating: 0x20,
    count: FrequentFolderStore.maximumEncodedBytes + 1
  )

  #expect(throws: FrequentFolderStoreError.fileTooLarge) {
    try FrequentFolderStore.decode(oversized)
  }
}

@Test("非法、相对和控制字符路径不会进入目录数据库")
func frequentFoldersRejectsUnsafePaths() {
  var folders = FrequentFolders()

  let recordedRelative = folders.record("relative/path")
  let recordedControl = folders.record("/tmp/bad\npath")
  let ignoredEmpty = folders.ignore("")
  #expect(!recordedRelative)
  #expect(!recordedControl)
  #expect(!ignoredEmpty)
  #expect(folders.entries.isEmpty)
}

@Test("外部数据库解码时合并重复项并丢弃非法分数和忽略项")
func frequentFoldersNormalizesDecodedData() throws {
  struct EncodedDatabase: Encodable {
    let entries: [FrequentFolderEntry]
    let capacity: Int
    let ignoredPaths: [String]
  }

  let date = Date(timeIntervalSince1970: 6_000_000)
  let encoded = try JSONEncoder().encode(
    EncodedDatabase(
      entries: [
        .init(path: "/work/api", rawScore: 2, lastVisitedAt: date),
        .init(path: "/work/api", rawScore: 3, lastVisitedAt: date.addingTimeInterval(60)),
        .init(path: "/work/ignored", rawScore: 10, lastVisitedAt: date),
        .init(path: "/work/negative", rawScore: -1, lastVisitedAt: date),
        .init(path: "relative", rawScore: 1, lastVisitedAt: date),
      ],
      capacity: 500,
      ignoredPaths: ["/work/ignored"]
    ))

  let decoded = try JSONDecoder().decode(FrequentFolders.self, from: encoded)

  #expect(decoded.capacity == 100)
  #expect(decoded.entries == [
    .init(path: "/work/api", rawScore: 5, lastVisitedAt: date.addingTimeInterval(60))
  ])
  #expect(decoded.isIgnored("/work/ignored"))
}
