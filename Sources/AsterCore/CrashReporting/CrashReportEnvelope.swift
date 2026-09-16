import Foundation

/// 崩溃采集用的 Sentry DSN 解析结果：只保留发送 envelope 所需的公钥与接入地址。
/// DSN 里的 key 是公开写入客户端的 public key，不是 secret。
public struct SentryDSN: Equatable, Sendable {
  public let publicKey: String
  public let envelopeURL: URL

  /// 解析 `https://<key>@<host>/<projectID>` 形式的 DSN；格式不符返回 nil。
  public init?(string: String) {
    guard let url = URL(string: string), let scheme = url.scheme, let host = url.host,
      let key = url.user, !key.isEmpty
    else { return nil }
    let projectID = url.lastPathComponent
    guard !projectID.isEmpty, projectID != "/" else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    components.path = "/api/\(projectID)/envelope/"
    guard let envelopeURL = components.url else { return nil }
    publicKey = key
    self.envelopeURL = envelopeURL
  }

  /// `X-Sentry-Auth` 请求头的值。
  public func authorizationHeader(clientVersion: String) -> String {
    "Sentry sentry_version=7, sentry_client=aster/\(clientVersion), sentry_key=\(publicKey)"
  }
}

/// 生成 Sentry 事件时需要的运行环境信息；由调用方在应用层收集，纯逻辑层不碰 Bundle。
public struct CrashReportContext: Equatable, Sendable {
  public var appVersion: String
  public var appBuild: String
  public var environment: String
  public var osVersion: String
  public var architecture: String

  public init(appVersion: String, appBuild: String, environment: String, osVersion: String, architecture: String) {
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.environment = environment
    self.osVersion = osVersion
    self.architecture = architecture
  }

  /// Sentry release 标识，格式对齐 sentry-cli 的 `package@version+build`。
  public var release: String { "aster@\(appVersion)+\(appBuild)" }
}

/// Sentry envelope 的最小编解码：头部 JSON 行 + 若干 item（各自一行头 + 载荷）。
/// 只实现上传自有事件与改写 Ghostty 崩溃 envelope 所需的子集。
public enum SentryEnvelope {
  public struct Item: Equatable, Sendable {
    public var header: [String: JSONValue]
    public var payload: Data

    public init(header: [String: JSONValue], payload: Data) {
      self.header = header
      self.payload = payload
    }

    public var type: String? { header["type"]?.stringValue }
  }

  public struct Parsed: Equatable, Sendable {
    public var header: [String: JSONValue]
    public var items: [Item]
  }

  public enum ParseError: Error, Equatable {
    case missingHeader
    case malformedItemHeader
    case truncatedPayload
  }

  /// 序列化：每个 item 头都写入准确的 `length`，接收端按长度切分，载荷里的换行不会破坏格式。
  public static func serialize(header: [String: JSONValue], items: [Item]) -> Data {
    var data = Data()
    data.append(JSONValue.object(header).encoded())
    data.append(0x0A)
    for item in items {
      var itemHeader = item.header
      itemHeader["length"] = .number(Double(item.payload.count))
      data.append(JSONValue.object(itemHeader).encoded())
      data.append(0x0A)
      data.append(item.payload)
      data.append(0x0A)
    }
    return data
  }

  /// 解析 sentry-native 写盘的 envelope。带 `length` 的 item 按字节切；不带的按行切。
  public static func parse(_ data: Data) throws -> Parsed {
    var cursor = data.startIndex
    guard let headerLine = readLine(data, from: &cursor), let header = JSONValue.decodeObject(headerLine)
    else { throw ParseError.missingHeader }
    var items: [Item] = []
    while cursor < data.endIndex {
      guard let itemHeaderLine = readLine(data, from: &cursor) else { break }
      if itemHeaderLine.isEmpty { continue }
      guard let itemHeader = JSONValue.decodeObject(itemHeaderLine) else { throw ParseError.malformedItemHeader }
      let payload: Data
      if let length = itemHeader["length"]?.doubleValue {
        let count = Int(length)
        guard count >= 0, data.distance(from: cursor, to: data.endIndex) >= count else {
          throw ParseError.truncatedPayload
        }
        payload = data.subdata(in: cursor..<data.index(cursor, offsetBy: count))
        cursor = data.index(cursor, offsetBy: count)
        // 跳过载荷后的换行分隔符（文件末尾可能没有）。
        if cursor < data.endIndex, data[cursor] == 0x0A { cursor = data.index(after: cursor) }
      } else {
        payload = readLine(data, from: &cursor) ?? Data()
      }
      items.append(Item(header: itemHeader, payload: payload))
    }
    return Parsed(header: header, items: items)
  }

  private static func readLine(_ data: Data, from cursor: inout Data.Index) -> Data? {
    guard cursor < data.endIndex else { return nil }
    let slice = data[cursor...]
    if let newline = slice.firstIndex(of: 0x0A) {
      let line = data.subdata(in: cursor..<newline)
      cursor = data.index(after: newline)
      return line
    }
    let line = data.subdata(in: cursor..<data.endIndex)
    cursor = data.endIndex
    return line
  }
}

/// 上次会话异常结束时发出的事件。它覆盖崩溃 SDK 抓不到的情况（如今天这种 `exit(1)`），
/// 用最后一段诊断日志当面包屑，帮助回答「退出前在做什么」。
public enum AbnormalExitEvent {
  public static let maximumBreadcrumbs = 50

  /// 生成完整 envelope。`breadcrumbLines` 是 DiagnosticsCenter 的 JSONL 原始行（已经过敏感键过滤）。
  public static func makeEnvelope(
    reason: String,
    crashCount: Int,
    decision: String,
    pendingMinidumps: Int,
    breadcrumbLines: [String],
    context: CrashReportContext,
    timestamp: Date = Date()
  ) -> Data {
    let eventID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let breadcrumbs = breadcrumbLines.suffix(maximumBreadcrumbs).compactMap(breadcrumb(fromRecordLine:))
    let event: [String: JSONValue] = [
      "event_id": .string(eventID),
      "timestamp": .string(ISO8601DateFormatter().string(from: timestamp)),
      "platform": .string("cocoa"),
      "level": .string("error"),
      "logger": .string("aster.session"),
      "release": .string(context.release),
      "environment": .string(context.environment),
      "message": .object(["formatted": .string("Previous session ended abnormally (\(reason))")]),
      // 按原因与恢复决策聚合，而不是按时间戳散成一堆 issue。
      "fingerprint": .array([.string("aster-abnormal-exit"), .string(reason), .string(decision)]),
      "tags": .object([
        "session.end_reason": .string(reason),
        "session.crash_count": .string(String(crashCount)),
        "session.recovery_decision": .string(decision),
        "crash.pending_minidumps": .string(String(pendingMinidumps)),
        // 没有配套 minidump 就是「无声退出」：进程既没崩也没走正常退出流程。
        "crash.kind": .string(pendingMinidumps > 0 ? "native" : "silent_exit"),
      ]),
      "contexts": .object([
        "os": .object(["name": .string("macOS"), "version": .string(context.osVersion)]),
        "device": .object(["arch": .string(context.architecture)]),
        "app": .object([
          "app_version": .string(context.appVersion), "app_build": .string(context.appBuild),
        ]),
      ]),
      "breadcrumbs": .object(["values": .array(breadcrumbs)]),
      "sdk": .object(["name": .string("aster.crash-reporting"), "version": .string(context.appVersion)]),
    ]
    let header: [String: JSONValue] = [
      "event_id": .string(eventID),
      "sent_at": .string(ISO8601DateFormatter().string(from: timestamp)),
    ]
    let payload = JSONValue.object(event).encoded()
    return SentryEnvelope.serialize(
      header: header,
      items: [SentryEnvelope.Item(header: ["type": .string("event"), "content_type": .string("application/json")], payload: payload)]
    )
  }

  /// 把一条诊断 JSONL 记录映射成 Sentry breadcrumb；解析失败的行直接丢弃。
  static func breadcrumb(fromRecordLine line: String) -> JSONValue? {
    guard let data = line.data(using: .utf8), let record = JSONValue.decodeObject(data),
      let event = record["event"]?.stringValue
    else { return nil }
    var crumb: [String: JSONValue] = [
      "type": .string("default"),
      "category": .string(record["category"]?.stringValue ?? "diagnostics"),
      "level": .string(sentryLevel(record["level"]?.stringValue)),
      "message": .string(event),
    ]
    if let timestamp = record["timestamp"] { crumb["timestamp"] = timestamp }
    if case .object(let attributes)? = record["attributes"], !attributes.isEmpty {
      crumb["data"] = .object(attributes)
    }
    return .object(crumb)
  }

  /// DiagnosticsCenter 的级别名与 Sentry 级别名之间只有 notice → info 一处差异。
  static func sentryLevel(_ level: String?) -> String {
    switch level {
    case "debug": return "debug"
    case "warning": return "warning"
    case "error": return "error"
    default: return "info"
    }
  }
}

/// Ghostty 内置 Breakpad 写盘的 `.ghosttycrash` 就是一个完整的 Sentry envelope（事件 + minidump 附件）。
/// 上传前把事件里的 release/environment 改成 Aster 的，并去掉可能含身份信息的字段。
public enum GhosttyCrashEnvelope {
  public enum RewriteError: Error, Equatable {
    case missingEventItem
    case malformedEvent
  }

  /// 事件里不应上传的键：主机名与用户身份都属于诊断规则禁止记录的信息。
  static let strippedEventKeys: Set<String> = ["server_name", "user"]

  public static func rewrite(_ data: Data, context: CrashReportContext, sentAt: Date = Date()) throws -> Data {
    var parsed = try SentryEnvelope.parse(data)
    guard let index = parsed.items.firstIndex(where: { $0.type == "event" }) else {
      throw RewriteError.missingEventItem
    }
    guard var event = JSONValue.decodeObject(parsed.items[index].payload) else {
      throw RewriteError.malformedEvent
    }
    let originalRelease = event["release"]?.stringValue
    event["release"] = .string(context.release)
    event["environment"] = .string(context.environment)
    for key in strippedEventKeys { event.removeValue(forKey: key) }
    var tags: [String: JSONValue]
    if case .object(let existing)? = event["tags"] { tags = existing } else { tags = [:] }
    tags["crash.kind"] = .string("native")
    tags["crash.source"] = .string("ghostty-breakpad")
    if let originalRelease { tags["ghostty.release"] = .string(originalRelease) }
    event["tags"] = .object(tags)
    parsed.items[index].payload = JSONValue.object(event).encoded()
    var header = parsed.header
    header["sent_at"] = .string(ISO8601DateFormatter().string(from: sentAt))
    return SentryEnvelope.serialize(header: header, items: parsed.items)
  }
}

/// 决定这次启动上传哪些崩溃文件：新的优先、跳过已传、超大文件不传、每次最多几个，避免启动期抢带宽。
public enum CrashReportUploadPolicy {
  public struct Candidate: Equatable, Sendable {
    public var name: String
    public var byteCount: Int
    public var modifiedAt: Date

    public init(name: String, byteCount: Int, modifiedAt: Date) {
      self.name = name
      self.byteCount = byteCount
      self.modifiedAt = modifiedAt
    }
  }

  public static let maximumPerLaunch = 5
  /// Sentry 对 minidump 附件的上限是 20 MiB；留出改写事件后的余量。
  public static let maximumByteCount = 19 * 1_024 * 1_024

  public static func select(
    _ candidates: [Candidate], alreadyUploaded: Set<String>,
    limit: Int = maximumPerLaunch, maximumByteCount: Int = maximumByteCount
  ) -> [Candidate] {
    candidates
      .filter { $0.name.hasSuffix(".ghosttycrash") && !alreadyUploaded.contains($0.name) && $0.byteCount <= maximumByteCount && $0.byteCount > 0 }
      .sorted { $0.modifiedAt > $1.modifiedAt }
      .prefix(limit)
      .map { $0 }
  }
}

/// 崩溃上报对 `JSONValue` 的两个便利入口：解析对象与稳定编码（键排序、不转义 `/`）。
extension JSONValue {
  /// 解析任意 JSON 对象；非对象或非法 JSON 返回 nil。
  static func decodeObject(_ data: Data) -> [String: JSONValue]? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
    return value.objectValue
  }

  /// 编码为 UTF-8 JSON；失败时退回空对象，调用方不会因编码问题中断上传流程。
  func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }
}
