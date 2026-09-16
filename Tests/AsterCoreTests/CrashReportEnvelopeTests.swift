import Foundation
import Testing

@testable import AsterCore

/// 崩溃上报纯逻辑的行为验证：DSN 解析、envelope 编解码、Ghostty 崩溃文件改写、上传选择策略。
@Suite("CrashReportEnvelope")
struct CrashReportEnvelopeTests {
  private let context = CrashReportContext(
    appVersion: "0.6.4", appBuild: "23", environment: "release", osVersion: "27.0.0", architecture: "arm64")

  @Test("DSN 解析出 envelope 地址与认证头")
  func parsesDSN() throws {
    let dsn = try #require(SentryDSN(string: "https://abc123@o1.ingest.us.sentry.io/4512"))
    #expect(dsn.publicKey == "abc123")
    #expect(dsn.envelopeURL.absoluteString == "https://o1.ingest.us.sentry.io/api/4512/envelope/")
    #expect(dsn.authorizationHeader(clientVersion: "0.6.4") == "Sentry sentry_version=7, sentry_client=aster/0.6.4, sentry_key=abc123")
    #expect(SentryDSN(string: "https://o1.ingest.us.sentry.io/4512") == nil)
    #expect(SentryDSN(string: "not a url") == nil)
  }

  @Test("envelope 序列化后可以按 length 原样解析回来，载荷里的换行不破坏结构")
  func roundTripsEnvelope() throws {
    let payload = Data("line1\nline2\n".utf8)
    let binary = Data([0x00, 0x0A, 0xFF, 0x0A])
    let data = SentryEnvelope.serialize(
      header: ["event_id": .string("e1")],
      items: [
        .init(header: ["type": .string("event")], payload: payload),
        .init(header: ["type": .string("attachment"), "attachment_type": .string("event.minidump")], payload: binary),
      ])
    let parsed = try SentryEnvelope.parse(data)
    #expect(parsed.header["event_id"]?.stringValue == "e1")
    #expect(parsed.items.count == 2)
    #expect(parsed.items[0].payload == payload)
    #expect(parsed.items[0].header["length"]?.doubleValue == Double(payload.count))
    #expect(parsed.items[1].payload == binary)
    #expect(parsed.items[1].type == "attachment")
  }

  @Test("缺少 length 的 item 按行切分；载荷被截断时报错")
  func parsesLineDelimitedItemsAndRejectsTruncation() throws {
    let text = "{\"event_id\":\"e2\"}\n{\"type\":\"event\"}\n{\"a\":1}\n"
    let parsed = try SentryEnvelope.parse(Data(text.utf8))
    #expect(parsed.items.count == 1)
    #expect(parsed.items[0].payload == Data("{\"a\":1}".utf8))

    let truncated = "{\"event_id\":\"e3\"}\n{\"type\":\"attachment\",\"length\":10}\nabc"
    #expect(throws: SentryEnvelope.ParseError.truncatedPayload) {
      try SentryEnvelope.parse(Data(truncated.utf8))
    }
  }

  @Test("异常退出事件带上原因、决策、面包屑，并按 kind 区分无声退出与原生崩溃")
  func buildsAbnormalExitEvent() throws {
    let lines = [
      "{\"timestamp\":\"2026-09-16T15:15:51Z\",\"level\":\"warning\",\"category\":\"integration\",\"event\":\"claude_quota.rate_limited\",\"attributes\":{\"retry_after_seconds\":\"120\"}}",
      "not json",
      "{\"timestamp\":\"2026-09-16T15:16:00Z\",\"level\":\"notice\",\"category\":\"workspace\",\"event\":\"workspace.saved\",\"attributes\":{}}",
    ]
    let data = AbnormalExitEvent.makeEnvelope(
      reason: "crash", crashCount: 3, decision: "startFreshAfterCrashLoop", pendingMinidumps: 0,
      breadcrumbLines: lines, context: context)
    let parsed = try SentryEnvelope.parse(data)
    let event = try #require(JSONValue.decodeObject(parsed.items[0].payload))
    #expect(event["release"]?.stringValue == "aster@0.6.4+23")
    #expect(event["platform"]?.stringValue == "cocoa")
    let tags = try #require(event["tags"]?.objectValue)
    #expect(tags["crash.kind"]?.stringValue == "silent_exit")
    #expect(tags["session.crash_count"]?.stringValue == "3")
    #expect(tags["session.recovery_decision"]?.stringValue == "startFreshAfterCrashLoop")
    #expect(event["fingerprint"]?.arrayValue?.compactMap(\.stringValue) == ["aster-abnormal-exit", "crash", "startFreshAfterCrashLoop"])
    let crumbs = try #require(event["breadcrumbs"]?.objectValue?["values"]?.arrayValue)
    #expect(crumbs.count == 2)
    #expect(crumbs[0].objectValue?["message"]?.stringValue == "claude_quota.rate_limited")
    #expect(crumbs[0].objectValue?["level"]?.stringValue == "warning")
    #expect(crumbs[0].objectValue?["data"]?.objectValue?["retry_after_seconds"]?.stringValue == "120")
    // notice 不是 Sentry 级别，映射为 info；空 attributes 不带 data。
    #expect(crumbs[1].objectValue?["level"]?.stringValue == "info")
    #expect(crumbs[1].objectValue?["data"] == nil)

    let native = AbnormalExitEvent.makeEnvelope(
      reason: "crash", crashCount: 1, decision: "restoreSnapshot", pendingMinidumps: 2, breadcrumbLines: [], context: context)
    let nativeEvent = try #require(JSONValue.decodeObject(try SentryEnvelope.parse(native).items[0].payload))
    #expect(nativeEvent["tags"]?.objectValue?["crash.kind"]?.stringValue == "native")
  }

  @Test("面包屑数量不超过上限，只保留最后的记录")
  func limitsBreadcrumbs() throws {
    let lines = (0..<80).map { "{\"level\":\"info\",\"category\":\"terminal\",\"event\":\"e\($0)\"}" }
    let data = AbnormalExitEvent.makeEnvelope(
      reason: "forceQuit", crashCount: 1, decision: "restoreSnapshot", pendingMinidumps: 0,
      breadcrumbLines: lines, context: context)
    let event = try #require(JSONValue.decodeObject(try SentryEnvelope.parse(data).items[0].payload))
    let crumbs = try #require(event["breadcrumbs"]?.objectValue?["values"]?.arrayValue)
    #expect(crumbs.count == AbnormalExitEvent.maximumBreadcrumbs)
    #expect(crumbs.first?.objectValue?["message"]?.stringValue == "e30")
    #expect(crumbs.last?.objectValue?["message"]?.stringValue == "e79")
  }

  @Test("Ghostty 崩溃 envelope 改写为 Aster 的 release，去掉主机与用户字段，minidump 附件原样保留")
  func rewritesGhosttyEnvelope() throws {
    let eventJSON = """
      {"event_id":"1c89e2a0381049 39d8cf195fad5789a9","platform":"native","level":"fatal","release":"1.3.2-HEAD-+4dcb09ada","environment":"production","server_name":"MacBook-Pro","user":{"id":"x"},"sdk":{"name":"sentry.native"},"tags":{"build-mode":"ReleaseFast"}}
      """
    let minidump = Data([0x4D, 0x44, 0x4D, 0x50, 0x0A, 0x00, 0x0A])
    let original = SentryEnvelope.serialize(
      header: ["event_id": .string("1c89")],
      items: [
        .init(header: ["type": .string("event")], payload: Data(eventJSON.utf8)),
        .init(
          header: ["type": .string("attachment"), "attachment_type": .string("event.minidump"), "filename": .string("x.dmp")],
          payload: minidump),
      ])
    let rewritten = try GhosttyCrashEnvelope.rewrite(original, context: context, sentAt: Date(timeIntervalSince1970: 0))
    let parsed = try SentryEnvelope.parse(rewritten)
    #expect(parsed.header["event_id"]?.stringValue == "1c89")
    #expect(parsed.header["sent_at"]?.stringValue == "1970-01-01T00:00:00Z")
    let event = try #require(JSONValue.decodeObject(parsed.items[0].payload))
    #expect(event["release"]?.stringValue == "aster@0.6.4+23")
    #expect(event["environment"]?.stringValue == "release")
    #expect(event["server_name"] == nil)
    #expect(event["user"] == nil)
    #expect(event["platform"]?.stringValue == "native")
    let tags = try #require(event["tags"]?.objectValue)
    #expect(tags["build-mode"]?.stringValue == "ReleaseFast")
    #expect(tags["crash.kind"]?.stringValue == "native")
    #expect(tags["crash.source"]?.stringValue == "ghostty-breakpad")
    #expect(tags["ghostty.release"]?.stringValue == "1.3.2-HEAD-+4dcb09ada")
    #expect(parsed.items[1].payload == minidump)
    #expect(parsed.items[1].header["attachment_type"]?.stringValue == "event.minidump")
  }

  @Test("没有 event item 的 envelope 拒绝改写")
  func rejectsEnvelopeWithoutEvent() {
    let data = SentryEnvelope.serialize(
      header: ["event_id": .string("e")],
      items: [.init(header: ["type": .string("attachment")], payload: Data([1, 2, 3]))])
    #expect(throws: GhosttyCrashEnvelope.RewriteError.missingEventItem) {
      try GhosttyCrashEnvelope.rewrite(data, context: context)
    }
  }

  @Test("上传选择：只取 .ghosttycrash、跳过已传与超大文件、最新优先、数量封顶")
  func selectsUploadCandidates() {
    let base = Date(timeIntervalSince1970: 1_000)
    var candidates = (0..<8).map {
      CrashReportUploadPolicy.Candidate(name: "\($0).ghosttycrash", byteCount: 100, modifiedAt: base.addingTimeInterval(Double($0)))
    }
    candidates.append(.init(name: "huge.ghosttycrash", byteCount: CrashReportUploadPolicy.maximumByteCount + 1, modifiedAt: base.addingTimeInterval(100)))
    candidates.append(.init(name: "empty.ghosttycrash", byteCount: 0, modifiedAt: base.addingTimeInterval(101)))
    candidates.append(.init(name: "notes.txt", byteCount: 10, modifiedAt: base.addingTimeInterval(102)))
    let selected = CrashReportUploadPolicy.select(candidates, alreadyUploaded: ["7.ghosttycrash"])
    #expect(selected.map(\.name) == ["6.ghosttycrash", "5.ghosttycrash", "4.ghosttycrash", "3.ghosttycrash", "2.ghosttycrash"])
  }
}
