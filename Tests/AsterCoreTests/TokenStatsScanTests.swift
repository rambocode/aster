// JSONScan 的浅层遍历与 LocalDayStamper 的日期换算。夹具全部是手写的假数据。
import Foundation
import Testing

@testable import AsterCore

/// 在一段 JSON 字面量的字节上运行 `body`，范围覆盖整个缓冲区。
private func withScan<R>(_ json: String, _ body: (JSONScan, Range<Int>) -> R) -> R {
  let bytes = Array(json.utf8)
  return bytes.withUnsafeBytes { raw in body(JSONScan(bytes: raw), 0..<raw.count) }
}

/// 把一个对象的顶层成员读成 `[key: 原始值文本]`。
private func members(_ json: String) -> [(String, String)] {
  withScan(json) { scan, range in
    var out: [(String, String)] = []
    scan.forEachMember(in: range) { key, value in
      let name = String(decoding: scan.bytes[key], as: UTF8.self)
      let text = String(decoding: scan.bytes[value], as: UTF8.self)
      out.append((name, text))
    }
    return out
  }
}

@Suite("TokenStats JSON 字节扫描")
struct TokenStatsJSONScanTests {
  @Test("顶层成员按顺序读出，嵌套对象与数组被整体跳过")
  func readsTopLevelMembersAndStepsOverNesting() {
    let read = members(#"{"a":{"b":{"c":1}},"d":[1,[2],{"e":3}],"f":"x"}"#)
    #expect(read.map(\.0) == ["a", "d", "f"])
    #expect(read[0].1 == #"{"b":{"c":1}}"#)
    #expect(read[1].1 == #"[1,[2],{"e":3}]"#)
    #expect(read[2].1 == #""x""#)
  }

  @Test("字符串里的花括号和方括号不参与结构计数")
  func bracesInsideStringsDoNotBreakValueSkipping() {
    let read = members(#"{"a":"}{[]","b":2}"#)
    #expect(read.map(\.0) == ["a", "b"])
    #expect(read[1].1 == "2")
  }

  @Test("写了一半的行停在截断处，已读成员仍然有效")
  func truncatedLineKeepsWhatWasAlreadyRead() {
    // 活跃 transcript 的最后一行常见形态：写入方刚 flush 到下一个 key 的开引号。
    #expect(members(#"{"a":1,"b"#).map(\.0) == ["a"])
    #expect(members(#"{"a":1,"b":"#).map(\.0) == ["a"])
    #expect(members(#"{"a":1,"b":{"c""#).map(\.0) == ["a", "b"])
  }

  @Test("畸形输入不抛错也不越界，只是提前停下")
  func malformedInputStopsQuietly() {
    #expect(members("{").isEmpty)
    #expect(members("").isEmpty)
    #expect(members("[1,2]").isEmpty)
    #expect(members(#"{"a" 1}"#).isEmpty)  // 缺冒号
    #expect(members(#"{"a":1,,"b":2}"#).map(\.0) == ["a", "b"])
  }

  @Test("整数成员只接受纯非负整数")
  func integerMemberRejectsAnythingElse() {
    withScan(#"{"i":42,"n":null,"f":1.5,"s":"7","neg":-3}"#) { scan, range in
      func value(_ key: StaticString) -> Int64? {
        scan.member(key, in: range).flatMap { scan.int64($0) }
      }
      #expect(value("i") == 42)
      #expect(value("n") == nil)
      #expect(value("f") == nil)
      #expect(value("s") == nil)
      #expect(value("neg") == nil)
    }
  }

  @Test("字符串成员反转义常见转义并保留 Unicode 转义原文")
  func stringMemberUnescapes() {
    // 反斜杠由标量拼出来，避免源码里出现会被编辑器再解释一次的 \u 序列。
    let escape = String(UnicodeScalar(0x5C)!)
    let json = #"{"p":"/a\/b\nc\"d","u":""# + escape + #"u4e2d"}"#
    withScan(json) { scan, range in
      let path = scan.member("p", in: range).flatMap { scan.string($0) }
      #expect(path == "/a/b\nc\"d")
      // 只有路径和时间戳会被读成字符串，\uXXXX 原样保留即可，不必实现完整反转义。
      let unicode = scan.member("u", in: range).flatMap { scan.string($0) }
      #expect(unicode == "u4e2d")
    }
  }

  @Test("member 找不到时返回 nil")
  func memberLookupMissing() {
    withScan(#"{"a":1}"#) { scan, range in
      #expect(scan.member("b", in: range) == nil)
    }
  }
}

@Suite("TokenStats 本地日换算")
struct TokenStatsLocalDayStamperTests {
  /// 把一个 ISO 时间戳包成 JSON 字符串值再解析，和真实解析路径一致。
  private func epochSeconds(_ iso: String) -> Int64? {
    withScan("\"\(iso)\"") { scan, range in LocalDayStamper.epochSeconds(scan, range) }
  }

  private func day(_ iso: String, zone: String) -> Int? {
    withScan("\"\(iso)\"") { scan, range in
      var stamper = LocalDayStamper(zone: TimeZone(identifier: zone)!)
      return stamper.day(fromISO: scan, range)
    }
  }

  @Test("ISO 前缀解析出的秒数与 Foundation 一致")
  func epochSecondsMatchesFoundation() {
    let formatter = ISO8601DateFormatter()
    let expected = formatter.date(from: "2026-07-17T11:52:33Z")!.timeIntervalSince1970
    #expect(epochSeconds("2026-07-17T11:52:33.310Z") == Int64(expected))
    #expect(epochSeconds("2026-07-17T11:52:33Z") == Int64(expected))
  }

  @Test("形态不符的时间戳返回 nil")
  func malformedTimestampIsRejected() {
    #expect(epochSeconds("2026-07-17") == nil)  // 太短
    #expect(epochSeconds("2026-07-17T11:52:3xZ") == nil)  // 非数字
    #expect(epochSeconds("2026-13-17T11:52:33Z") == nil)  // 月份越界
    #expect(epochSeconds("2026-07-00T11:52:33Z") == nil)  // 日越界
  }

  @Test("1970-01-01 是第 0 天，公历换算与已知日期对齐")
  func daysFromCivilAnchors() {
    #expect(LocalDayStamper.daysFromCivil(1970, 1, 1) == 0)
    #expect(LocalDayStamper.daysFromCivil(1969, 12, 31) == -1)
    #expect(LocalDayStamper.daysFromCivil(2000, 3, 1) == 11_017)
    // 闰年 2 月 29 日存在且紧接 3 月 1 日。
    #expect(
      LocalDayStamper.daysFromCivil(2024, 3, 1) - LocalDayStamper.daysFromCivil(2024, 2, 29) == 1)
  }

  @Test("跨午夜的同一时刻在不同时区落到不同的本地日")
  func sameInstantSplitsAcrossZones() {
    // UTC 17:00 在东八区已经是第二天 01:00。
    let utc = day("2026-07-17T17:00:00Z", zone: "UTC")
    let shanghai = day("2026-07-17T17:00:00Z", zone: "Asia/Shanghai")
    #expect(utc == LocalDayStamper.daysFromCivil(2026, 7, 17))
    #expect(shanghai == LocalDayStamper.daysFromCivil(2026, 7, 18))

    // 西五区则还停在前一天。
    let newYork = day("2026-07-17T02:00:00Z", zone: "America/New_York")
    #expect(newYork == LocalDayStamper.daysFromCivil(2026, 7, 16))
  }

  @Test("时区偏移按 UTC 小时缓存，连续调用结果仍然正确")
  func cachedOffsetStaysCorrectAcrossHours() {
    var stamper = LocalDayStamper(zone: TimeZone(identifier: "Asia/Shanghai")!)
    let base = LocalDayStamper.daysFromCivil(2026, 7, 17)
    // 同一小时内多次调用走缓存；跨小时后必须重新取偏移。
    let seconds = Int64(
      ISO8601DateFormatter().date(from: "2026-07-17T15:30:00Z")!.timeIntervalSince1970)
    #expect(stamper.day(forEpochSeconds: seconds) == base)
    #expect(stamper.day(forEpochSeconds: seconds + 60) == base)
    #expect(stamper.day(forEpochSeconds: seconds + 3_600) == base + 1)  // 本地 00:30
    #expect(stamper.day(forEpochSeconds: seconds) == base)
  }

  @Test("纪元之前的时间戳向下取整而不是向零取整")
  func negativeEpochFloorsDownward() {
    var stamper = LocalDayStamper(zone: TimeZone(identifier: "UTC")!)
    #expect(stamper.day(forEpochSeconds: -1) == -1)
    #expect(stamper.day(forEpochSeconds: 0) == 0)
  }
}
