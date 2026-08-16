import Foundation

/// 可持久化的会话元数据。它只保留 Resume/Fork 所需身份与用户可搜索字段，不保存
/// PID、文件描述符或 pane 实例等不可重建运行态。
public struct AgentSessionMetadata: Codable, Equatable, Sendable {
  public let id: String
  public let configuration: AgentSessionConfiguration
  public let projectDirectory: String
  public let title: String
  public let createdAt: Date
  public let updatedAt: Date
  public let transcriptFileURL: URL

  public init(
    id: String,
    configuration: AgentSessionConfiguration,
    projectDirectory: String,
    title: String,
    createdAt: Date,
    updatedAt: Date,
    transcriptFileURL: URL
  ) {
    self.id = id
    self.configuration = configuration
    self.projectDirectory = projectDirectory
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.transcriptFileURL = transcriptFileURL
  }

  /// 运行中的会话应聚焦原 pane；只有会话已停止时才规划 provider 原生 Resume。
  public func resumeDescriptor(isCurrentlyRunning: Bool) -> AgentSessionResumeDescriptor {
    AgentSessionResumeDescriptor(
      sessionID: id,
      configuration: configuration,
      projectDirectory: projectDirectory,
      title: title,
      action: isCurrentlyRunning ? .focusLiveSession : .launchNativeResume
    )
  }
}

public enum AgentSessionResumeAction: Equatable, Sendable {
  case focusLiveSession
  case launchNativeResume
}

public struct AgentSessionResumeDescriptor: Equatable, Sendable {
  public let sessionID: String
  public let configuration: AgentSessionConfiguration
  public let projectDirectory: String
  public let title: String
  public let action: AgentSessionResumeAction
}

public enum AgentTranscriptRole: String, Codable, Equatable, Sendable {
  case user
  case assistant
  case system
}

/// 从 transcript 用户消息推导列表标题的清洗规则。
///
/// provider 会把 caveat、系统提醒、协作路由等模板内容包在 XML 风格标签里，
/// 以 user 角色原样存进 transcript；直接取首条用户消息当标题会把
/// `<local-command-caveat>…` 这类包装串显示到历史列表里。清洗策略分两级：
/// 纯模板噪音的标签**连内文整段丢弃**，承载真实内容的标签只剥壳保留内文。
public enum AgentSessionTitleCleaner {
  /// 整段丢弃的包装标签：标签与内文都是模板噪音，不含用户意图。
  private static let noiseSpanTags: [String] = [
    "local-command-caveat", "system-reminder", "command-name", "command-args",
    "command-message", "command-contents", "local-command-stdout",
  ]

  /// 清洗单条用户消息：剔除噪音 span → 其余标签剥壳留内文 → 压成单行。
  /// 清洗后为空返回 nil，调用方应尝试下一条消息。
  public static func cleaned(_ raw: String) -> String? {
    var text = raw
    for tag in noiseSpanTags {
      // 先删完整 span；provider 截断可能造成只有开标签没有闭标签，
      // 此时该标签起的剩余部分全是模板文，一并删除。
      text = replacing(pattern: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", in: text)
      text = replacing(pattern: "<\(tag)\\b[^>]*>[\\s\\S]*", in: text)
    }
    // 其余标签（如 teammate-message、untrusted-context）只剥壳：内文才是正文。
    text = replacing(pattern: "</?[A-Za-z][^<>]{0,256}>", in: text)
    let condensed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return condensed.isEmpty ? nil : condensed
  }

  /// 按时间顺序尝试每条用户消息，取第一条清洗后非空的作为标题；全部为空用 fallback。
  public static func title(
    from userTexts: [String], fallback: String, maxLength: Int = 120
  ) -> String {
    for raw in userTexts {
      if let cleaned = cleaned(raw) {
        return String(cleaned.prefix(maxLength))
      }
    }
    return fallback
  }

  /// 正则替换为单空格。pattern 是本文件内的常量组合，编译失败视为编程错误，
  /// 此时返回原文以保证清洗永不让标题变得更糟。
  private static func replacing(pattern: String, in text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    return regex.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
  }
}

/// Transcript 保留用户可读内容的语义类型；tool 输入不直接展开，避免把可能含有大块
/// 二进制或敏感参数的任意 JSON 注入历史视图和搜索索引。
public enum AgentTranscriptEntryKind: Equatable, Sendable {
  case message(role: AgentTranscriptRole)
  case reasoning
  case toolCall(name: String)
  case attachment(name: String?)
}

public struct AgentTranscriptEntry: Equatable, Sendable {
  public let sourceRecordIndex: Int
  public let kind: AgentTranscriptEntryKind
  public let timestamp: Date?
  public let text: String

  public init(
    sourceRecordIndex: Int,
    kind: AgentTranscriptEntryKind,
    timestamp: Date?,
    text: String
  ) {
    self.sourceRecordIndex = sourceRecordIndex
    self.kind = kind
    self.timestamp = timestamp
    self.text = text
  }
}

/// 所有限制都在 JSON 反序列化之前按字节执行。默认值足以显示正常会话，同时避免
/// 外部 session 文件通过超长单行、记录洪泛或超大文本无界占用内存。
public struct AgentTranscriptLimits: Equatable, Sendable {
  public static let `default` = AgentTranscriptLimits()

  public let maximumInputBytes: Int
  public let maximumRecordBytes: Int
  public let maximumRecords: Int
  public let maximumEntries: Int
  public let maximumEntryBytes: Int

  public init(
    maximumInputBytes: Int = 4 * 1_024 * 1_024,
    maximumRecordBytes: Int = 256 * 1_024,
    maximumRecords: Int = 10_000,
    maximumEntries: Int = 10_000,
    maximumEntryBytes: Int = 64 * 1_024
  ) {
    self.maximumInputBytes = max(maximumInputBytes, 1)
    self.maximumRecordBytes = max(maximumRecordBytes, 1)
    self.maximumRecords = max(maximumRecords, 1)
    self.maximumEntries = max(maximumEntries, 1)
    self.maximumEntryBytes = max(maximumEntryBytes, 1)
  }
}

public enum AgentTranscriptError: Error, Equatable {
  case inputTooLarge(maximumBytes: Int)
  case recordTooLarge(index: Int, maximumBytes: Int)
  case tooManyRecords(maximum: Int)
}

public struct AgentTranscriptReport: Equatable, Sendable {
  public static let empty = AgentTranscriptReport(
    entries: [],
    skippedRecordCount: 0,
    truncatedEntryCount: 0
  )

  public let entries: [AgentTranscriptEntry]
  public let skippedRecordCount: Int
  public let truncatedEntryCount: Int
  public let reachedEntryLimit: Bool

  public init(
    entries: [AgentTranscriptEntry],
    skippedRecordCount: Int,
    truncatedEntryCount: Int,
    reachedEntryLimit: Bool = false
  ) {
    self.entries = entries
    self.skippedRecordCount = skippedRecordCount
    self.truncatedEntryCount = truncatedEntryCount
    self.reachedEntryLimit = reachedEntryLimit
  }
}

public enum AgentTranscriptParser {
  /// 解析 Claude/Codex 风格 JSONL，同时容忍单条顶层 JSON 数组。损坏的局部记录会被
  /// 计入 skipped 并跳过；资源上限违反则整体失败，调用方不能把不完整结果当可信历史。
  public static func parse(
    _ data: Data,
    provider _: AgentProvider,
    limits: AgentTranscriptLimits = .default
  ) throws -> AgentTranscriptReport {
    guard data.count <= limits.maximumInputBytes else {
      throw AgentTranscriptError.inputTooLarge(maximumBytes: limits.maximumInputBytes)
    }

    var entries: [AgentTranscriptEntry] = []
    var skippedRecordCount = 0
    var truncatedEntryCount = 0
    var parsedRecordCount = 0
    var reachedEntryLimit = false
    let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)

    lineLoop: for rawLine in rawLines {
      let line = rawLine.drop(while: Self.isJSONWhitespace)
        .reversed().drop(while: Self.isJSONWhitespace).reversed()
      guard !line.isEmpty else { continue }
      guard parsedRecordCount < limits.maximumRecords else {
        throw AgentTranscriptError.tooManyRecords(maximum: limits.maximumRecords)
      }
      guard line.count <= limits.maximumRecordBytes else {
        throw AgentTranscriptError.recordTooLarge(
          index: parsedRecordCount,
          maximumBytes: limits.maximumRecordBytes
        )
      }

      let object: Any
      do {
        object = try JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed])
      } catch {
        parsedRecordCount += 1
        skippedRecordCount += 1
        continue
      }

      let objects: [Any]
      if let array = object as? [Any] {
        objects = array
      } else {
        objects = [object]
      }
      let recordIncrement = max(objects.count, 1)
      guard recordIncrement <= limits.maximumRecords - parsedRecordCount else {
        throw AgentTranscriptError.tooManyRecords(maximum: limits.maximumRecords)
      }
      let firstSourceRecordIndex = parsedRecordCount
      parsedRecordCount += recordIncrement

      for (offset, item) in objects.enumerated() {
        guard let dictionary = item as? [String: Any] else {
          skippedRecordCount += 1
          continue
        }
        let sourceRecordIndex = firstSourceRecordIndex + offset
        let candidates = transcriptEntries(
          from: dictionary,
          sourceRecordIndex: sourceRecordIndex
        )
        if candidates.isEmpty {
          skippedRecordCount += 1
          continue
        }
        for candidate in candidates {
          guard entries.count < limits.maximumEntries else {
            reachedEntryLimit = true
            break lineLoop
          }
          let bounded = boundedUTF8(candidate.text, maximumBytes: limits.maximumEntryBytes)
          guard !bounded.value.isEmpty else { continue }
          if bounded.wasTruncated { truncatedEntryCount += 1 }
          entries.append(
            AgentTranscriptEntry(
              sourceRecordIndex: candidate.sourceRecordIndex,
              kind: candidate.kind,
              timestamp: candidate.timestamp,
              text: bounded.value
            )
          )
        }
      }
    }

    return AgentTranscriptReport(
      entries: entries,
      skippedRecordCount: skippedRecordCount,
      truncatedEntryCount: truncatedEntryCount,
      reachedEntryLimit: reachedEntryLimit
    )
  }

  private static func transcriptEntries(
    from record: [String: Any],
    sourceRecordIndex: Int
  ) -> [AgentTranscriptEntry] {
    let root: [String: Any]
    if record["type"] as? String == "response_item",
      let payload = record["payload"] as? [String: Any]
    {
      root = payload
    } else {
      root = record
    }
    let timestamp = parseTimestamp(record["timestamp"] ?? root["timestamp"])

    if let message = root["message"] as? [String: Any] {
      let role = role(from: message["role"] ?? root["type"])
      return contentEntries(
        message["content"],
        defaultRole: role,
        timestamp: timestamp,
        sourceRecordIndex: sourceRecordIndex
      )
    }

    // 部分受支持的历史文件把 user 内容直接放在顶层 `message` 字符串。把它收敛到
    // 与嵌套 message 相同的标准 entry，Outline 与 History 就不会维护两套 JSONL 契约。
    if let role = role(from: root["role"] ?? root["type"]),
      let message = root["message"] as? String
    {
      return [entry(index: sourceRecordIndex, kind: .message(role: role), timestamp: timestamp, text: message)]
    }

    if let role = role(from: root["role"] ?? root["type"]), root["content"] != nil {
      return contentEntries(
        root["content"],
        defaultRole: role,
        timestamp: timestamp,
        sourceRecordIndex: sourceRecordIndex
      )
    }

    let type = (root["type"] as? String)?.lowercased()
    if type == "thinking" || type == "reasoning" {
      let text = firstString(in: root, keys: ["thinking", "reasoning", "text", "summary"])
      return text.map {
        [entry(index: sourceRecordIndex, kind: .reasoning, timestamp: timestamp, text: $0)]
      } ?? []
    }
    if ["tool_use", "tool_call", "function_call"].contains(type),
      let name = firstString(in: root, keys: ["name", "tool_name"])
    {
      return [
        entry(
          index: sourceRecordIndex,
          kind: .toolCall(name: name),
          timestamp: timestamp,
          text: name
        )
      ]
    }
    return []
  }

  private static func contentEntries(
    _ content: Any?,
    defaultRole: AgentTranscriptRole?,
    timestamp: Date?,
    sourceRecordIndex: Int
  ) -> [AgentTranscriptEntry] {
    if let text = content as? String, let defaultRole {
      return [
        entry(
          index: sourceRecordIndex,
          kind: .message(role: defaultRole),
          timestamp: timestamp,
          text: text
        )
      ]
    }
    guard let blocks = content as? [Any] else { return [] }

    var result: [AgentTranscriptEntry] = []
    for block in blocks {
      if let text = block as? String, let defaultRole {
        result.append(
          entry(
            index: sourceRecordIndex,
            kind: .message(role: defaultRole),
            timestamp: timestamp,
            text: text
          )
        )
        continue
      }
      guard let dictionary = block as? [String: Any] else { continue }
      let type = (dictionary["type"] as? String)?.lowercased() ?? ""
      switch type {
      case "thinking", "reasoning":
        if let text = firstString(
          in: dictionary,
          keys: ["thinking", "reasoning", "text", "summary"]
        ) {
          result.append(
            entry(
              index: sourceRecordIndex,
              kind: .reasoning,
              timestamp: timestamp,
              text: text
            )
          )
        }
      case "tool_use", "tool_call", "function_call":
        if let name = firstString(in: dictionary, keys: ["name", "tool_name"]) {
          result.append(
            entry(
              index: sourceRecordIndex,
              kind: .toolCall(name: name),
              timestamp: timestamp,
              text: name
            )
          )
        }
      case "image", "document", "attachment", "input_image":
        let name = firstString(in: dictionary, keys: ["name", "filename", "path"])
        result.append(
          entry(
            index: sourceRecordIndex,
            kind: .attachment(name: name),
            timestamp: timestamp,
            text: name ?? "Attachment"
          )
        )
      default:
        if let defaultRole,
          let text = firstString(in: dictionary, keys: ["text", "content", "output_text"])
        {
          result.append(
            entry(
              index: sourceRecordIndex,
              kind: .message(role: defaultRole),
              timestamp: timestamp,
              text: text
            )
          )
        }
      }
    }
    return result
  }

  private static func entry(
    index: Int,
    kind: AgentTranscriptEntryKind,
    timestamp: Date?,
    text: String
  ) -> AgentTranscriptEntry {
    AgentTranscriptEntry(
      sourceRecordIndex: index,
      kind: kind,
      timestamp: timestamp,
      text: text
    )
  }

  private static func role(from value: Any?) -> AgentTranscriptRole? {
    guard let value = value as? String else { return nil }
    return AgentTranscriptRole(rawValue: value.lowercased())
  }

  private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = dictionary[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }

  private static func parseTimestamp(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    return ISO8601DateFormatter().date(from: value)
  }

  private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
  }
}

public struct AgentSessionHistory: Equatable, Sendable {
  public let metadata: AgentSessionMetadata
  public let transcript: AgentTranscriptReport

  public init(metadata: AgentSessionMetadata, transcript: AgentTranscriptReport) {
    self.metadata = metadata
    self.transcript = transcript
  }
}

extension AgentSessionMetadata {
  /// 会话是否归属指定项目目录，供「查看会话历史」按当前项目过滤。
  /// 两侧都经 `normalizedAbsolutePath` 归一化（去尾部斜杠、拒绝相对路径/超限/控制
  /// 字符）后做等值比较；归一化失败一律判不匹配——宁可少显示，也不把别的项目的
  /// 会话混进当前项目视图。
  public func belongsToProject(_ directory: String) -> Bool {
    guard
      let session = AgentTranscriptProjectMapping.normalizedAbsolutePath(projectDirectory),
      let scope = AgentTranscriptProjectMapping.normalizedAbsolutePath(directory)
    else { return false }
    return session == scope
  }
}

public struct AgentHistorySearchResult: Equatable, Sendable {
  public let sessionID: String
  public let metadata: AgentSessionMetadata
  public let snippet: String?
}

public enum AgentHistorySearchError: Error, Equatable {
  case queryTooLarge(maximumBytes: Int)
  case tooManySessions(maximum: Int)
  case invalidResultLimit(maximum: Int)
  case indexTooLarge(maximumBytes: Int)
}

/// Search 也校验调用方手工构造的 report，不能假设所有数据都来自受限 Parser。
public struct AgentHistorySearchLimits: Equatable, Sendable {
  public static let `default` = AgentHistorySearchLimits()

  public let maximumIndexedBytes: Int

  public init(maximumIndexedBytes: Int = 32 * 1_024 * 1_024) {
    self.maximumIndexedBytes = max(maximumIndexedBytes, 1)
  }
}

public enum AgentHistorySearch {
  public static let maximumQueryBytes = 1_024
  public static let maximumSessions = 10_000
  public static let maximumResults = 100
  public static let maximumSnippetBytes = 240

  /// 使用大小写/音调不敏感的普通词匹配，避免把用户查询当正则执行。所有查询词都需
  /// 出现在元数据或 transcript 中，结果按最近更新时间稳定排序。
  public static func search(
    query: String,
    histories: [AgentSessionHistory],
    limit: Int = 20,
    limits: AgentHistorySearchLimits = .default
  ) throws -> [AgentHistorySearchResult] {
    guard query.utf8.count <= maximumQueryBytes else {
      throw AgentHistorySearchError.queryTooLarge(maximumBytes: maximumQueryBytes)
    }
    guard histories.count <= maximumSessions else {
      throw AgentHistorySearchError.tooManySessions(maximum: maximumSessions)
    }
    guard (1...maximumResults).contains(limit) else {
      throw AgentHistorySearchError.invalidResultLimit(maximum: maximumResults)
    }
    var indexedBytes = 0
    for history in histories {
      let fields =
        [
          history.metadata.id,
          history.metadata.title,
          history.metadata.projectDirectory,
          history.metadata.configuration.provider.rawValue,
          history.metadata.configuration.providerIdentifier ?? "",
          history.metadata.configuration.model ?? "",
        ] + history.transcript.entries.map(\.text)
      for field in fields {
        let (sum, overflow) = indexedBytes.addingReportingOverflow(field.utf8.count)
        guard !overflow, sum <= limits.maximumIndexedBytes else {
          throw AgentHistorySearchError.indexTooLarge(
            maximumBytes: limits.maximumIndexedBytes
          )
        }
        indexedBytes = sum
      }
    }

    let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return [] }

    return histories.compactMap { history -> AgentHistorySearchResult? in
      let metadataText = normalized(
        [
          history.metadata.title,
          history.metadata.projectDirectory,
          history.metadata.configuration.provider.rawValue,
          history.metadata.configuration.providerIdentifier ?? "",
          history.metadata.configuration.model ?? "",
        ].joined(separator: "\n")
      )
      let transcriptText = history.transcript.entries.map(\.text).joined(separator: "\n")
      let haystack = metadataText + "\n" + normalized(transcriptText)
      guard terms.allSatisfy(haystack.contains) else { return nil }

      let matchingEntry =
        history.transcript.entries.first { entry in
          let text = normalized(entry.text)
          return terms.allSatisfy(text.contains)
        }
        ?? history.transcript.entries.first { entry in
          terms.contains { normalized(entry.text).contains($0) }
        }
      let snippet = matchingEntry.map {
        boundedUTF8($0.text, maximumBytes: maximumSnippetBytes).value
      }
      return AgentHistorySearchResult(
        sessionID: history.metadata.id,
        metadata: history.metadata,
        snippet: snippet
      )
    }
    .sorted { lhs, rhs in
      if lhs.metadata.updatedAt == rhs.metadata.updatedAt {
        return lhs.sessionID < rhs.sessionID
      }
      return lhs.metadata.updatedAt > rhs.metadata.updatedAt
    }
    .prefix(limit)
    .map { $0 }
  }

  private static func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}

/// 返回不超过指定 UTF-8 字节数的最长 Character 前缀。按 Character 迭代可同时避免
/// 截断多字节 Unicode 和拆开组合字符；调用方仍能得到确定的硬字节上限。
func boundedUTF8(_ value: String, maximumBytes: Int) -> (value: String, wasTruncated: Bool) {
  guard value.utf8.count > maximumBytes else { return (value, false) }
  guard maximumBytes > 0 else { return ("", !value.isEmpty) }
  var result = ""
  var byteCount = 0
  for character in value {
    let text = String(character)
    let nextBytes = text.utf8.count
    guard byteCount + nextBytes <= maximumBytes else { break }
    result.append(character)
    byteCount += nextBytes
  }
  return (result, true)
}
