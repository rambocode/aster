// 各 Agent 数据源测试共用的脚手架：固定时区的扫描上下文与临时 home 目录。
import Foundation
import Testing

@testable import AsterCore

/// 测试用的扫描上下文：固定按 UTC 归日，项目键原样返回，方便断言。
final class FixedTokenScanContext: TokenScanContext {
  /// 记录被问过的工作目录，用来断言项目归属是从哪里取的。
  private(set) var requestedDirectories: [String] = []

  func localDay(forEpochSeconds seconds: Int64) -> Int {
    Int(floor(Double(seconds) / 86_400))
  }

  func projectKey(forWorkingDirectory path: String) -> String {
    requestedDirectories.append(path)
    return path
  }
}

/// 一次性的临时目录，析构时整棵删掉；用来搭假的 home 目录结构。
final class TemporaryDirectory {
  let url: URL

  init() {
    url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("aster-token-source-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  /// 在相对路径处写入文本，自动补齐中间目录。
  @discardableResult
  func write(_ contents: String, to relativePath: String) -> URL {
    let target = url.appendingPathComponent(relativePath)
    try? FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  /// 覆盖某个文件的修改时间，用于验证按 mtime 归日的数据源。
  func setModificationDate(_ date: Date, at relativePath: String) {
    let target = url.appendingPathComponent(relativePath)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
  }
}

/// 把 bucket 数组按日索引，断言时更直观。
func totals(in buckets: [TokenBucket], day: Int) -> TokenTotals? {
  buckets.first { $0.day == day }?.totals
}

@Suite("TokenSource 公共扫描工具")
struct TokenSourceScannerTests {
  @Test("ISO8601 时间戳按 UTC 解析成 Unix 秒")
  func parsesISO8601() {
    #expect(JSONLTokenScanner.epochSeconds(iso8601: "1970-01-01T00:00:00.000Z") == 0)
    #expect(JSONLTokenScanner.epochSeconds(iso8601: "2026-06-20T17:21:35.633Z") == 1_781_976_095)
    // 带偏移量的时间要换算回 UTC：+08:00 表示比 UTC 早 8 小时。
    #expect(
      JSONLTokenScanner.epochSeconds(iso8601: "2026-06-21T01:21:35+08:00") == 1_781_976_095)
    #expect(JSONLTokenScanner.epochSeconds(iso8601: "not-a-date") == nil)
  }

  @Test("字节预筛只在真正出现子串时命中")
  func findsByteSubstring() {
    let line = Data("{\"type\":\"message\",\"usage\":{}}".utf8)
    #expect(JSONLTokenScanner.contains(line, Array("\"usage\"".utf8)))
    #expect(!JSONLTokenScanner.contains(line, Array("\"tokens\"".utf8)))
    #expect(!JSONLTokenScanner.contains(Data(), Array("x".utf8)))
  }

  @Test("非法 JSON 行被跳过而不是抛错")
  func skipsMalformedLine() {
    #expect(JSONLTokenScanner.object(Data("{\"a\":".utf8)) == nil)
    #expect(JSONLTokenScanner.int64("12") == 12)
    #expect(JSONLTokenScanner.int64(-5) == 0)
    #expect(JSONLTokenScanner.int64(nil) == 0)
  }
}
