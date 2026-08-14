import Foundation

/// Agent transcript → Session Memory 的纯函数映射层：项目归属还原与工具调用抽取。
/// 本文件不触碰文件系统（存在性判定由调用方注入闭包），因此全部规则都能用真值表测试。

/// 项目归属的判定依据。展示与检索时据此标注可信度：transcript 自报的 cwd 是 provider
/// 写下的事实，目录名反解只是文件系统佐证过的推测。
public enum AgentProjectAttributionConfidence: String, Codable, Equatable, Sendable {
  /// transcript 记录里 provider 自己写下的工作目录，最可靠。
  case transcriptWorkingDirectory = "transcript_cwd"
  /// 由 provider 的编码目录名反解并经文件系统校验，存在同名歧义的残余风险。
  case decodedDirectoryName = "decoded_directory_name"
}

/// 一次 Agent 会话的项目归属结论。取不到时调用方必须得到 nil，不允许回落到主目录，
/// 否则所有 Agent 会话会塌缩成同一个伪项目（PRD「按项目组织 session」的直接阻碍）。
public struct AgentProjectAttribution: Equatable, Sendable {
  public let path: String
  public let confidence: AgentProjectAttributionConfidence

  public init(path: String, confidence: AgentProjectAttributionConfidence) {
    self.path = path
    self.confidence = confidence
  }
}

/// provider 会话文件 → 项目目录的还原规则集合。
public enum AgentTranscriptProjectMapping {
  /// 单个路径值的硬上限，与 `DetectedTarget` 的外部输入边界一致。
  public static let maximumPathBytes = 4_096
  /// 反解时最多考察的编码 token 数；超过即判定为不可信输入直接放弃。
  public static let maximumEncodedTokens = 32
  /// 一个路径分量最多可以由多少个 token 合并而成（`cortex-org` 是 2 个）。
  public static let maximumTokensPerComponent = 8
  /// 反解过程允许的文件系统存在性判定次数上限，避免病态输入把后台线程拖死。
  public static let maximumExistenceChecks = 2_048
  /// 扫描 transcript 找 cwd 时最多解析的记录数；cwd 一律出现在会话开头。
  public static let maximumScannedRecordsForWorkingDirectory = 64

  /// 会话文件的项目归属。优先用 transcript 自报的 cwd，其次才按 provider 的编码目录名
  /// 反解；两者都拿不到时返回 nil。
  ///
  /// `directoryExists` 由调用方注入，既让规则可测，也把唯一的磁盘访问集中在一处便于限流。
  public static func attribution(
    provider: AgentProvider,
    sessionFileURL: URL,
    homeDirectory: URL,
    transcriptWorkingDirectory: String?,
    directoryExists: (String) -> Bool
  ) -> AgentProjectAttribution? {
    if let cwd = normalizedAbsolutePath(transcriptWorkingDirectory) {
      return AgentProjectAttribution(path: cwd, confidence: .transcriptWorkingDirectory)
    }
    // Codex/openCode/cursorCLI/kimiCode 的目录层级里没有项目信息（cursor 用毫秒时间戳，
    // codex 用日期分桶），只有 Claude Code 把项目路径编码进了目录名。
    guard provider == .claudeCode,
      let encoded = claudeCodeEncodedDirectoryName(
        sessionFileURL: sessionFileURL, homeDirectory: homeDirectory),
      let decoded = decodedProjectPath(
        fromEncodedDirectoryName: encoded, directoryExists: directoryExists)
    else { return nil }
    return AgentProjectAttribution(path: decoded, confidence: .decodedDirectoryName)
  }

  /// Claude Code 的目录名编码：非 ASCII 字母数字的字符一律变成 `-`
  ///（`/Users/mike/.claude` → `-Users-mike--claude`）。提供正向编码是为了让反解规则
  /// 能用「编码后再反解」的往返真值表锁定。
  public static func encodedDirectoryName(forProjectPath path: String) -> String {
    String(
      path.map { character in
        character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
      })
  }

  /// 从会话文件路径取出 Claude Code 的编码目录名（`~/.claude/projects/<编码名>/<uuid>.jsonl`）。
  public static func claudeCodeEncodedDirectoryName(
    sessionFileURL: URL,
    homeDirectory: URL
  ) -> String? {
    let session = sessionFileURL.standardizedFileURL.pathComponents
    let home = homeDirectory.standardizedFileURL.pathComponents
    guard session.count == home.count + 4,
      session.prefix(home.count).elementsEqual(home),
      session[home.count] == ".claude",
      session[home.count + 1] == "projects"
    else { return nil }
    let name = session[home.count + 2]
    return name.isEmpty ? nil : name
  }

  /// 反解编码目录名。编码是有损的（`/`、`-`、`.`、`_` 全部变成 `-`），因此 `-a-b-c` 既可能
  /// 是 `/a/b/c` 也可能是 `/a-b/c`。这里不做组合爆炸式枚举，而是逐层向下：每一层用
  /// `directoryExists` 确认某个分量真实存在才继续，优先尝试合并更多 token 的「最长匹配」，
  /// 失败再回溯。这样搜索被真实目录结构剪枝，代价可控且结果一定落在磁盘上存在的路径。
  ///
  /// 仍然找不到完整解释时返回 nil —— 宁可没有归属，也不能给出一个编造的项目路径。
  public static func decodedProjectPath(
    fromEncodedDirectoryName name: String,
    directoryExists: (String) -> Bool
  ) -> String? {
    guard name.hasPrefix("-") else { return nil }
    let tokens = String(name.dropFirst()).components(separatedBy: "-")
    guard !tokens.isEmpty, tokens.count <= maximumEncodedTokens else { return nil }

    var checks = 0
    func walk(from index: Int, base: String) -> String? {
      guard index < tokens.count else { return base }
      let maximumSpan = min(maximumTokensPerComponent, tokens.count - index)
      // 由长到短尝试：先假设更多 token 属于同一个分量，实现「取最长匹配」的优先级。
      for span in stride(from: maximumSpan, through: 1, by: -1) {
        for component in componentCandidates(tokens: tokens, at: index, span: span) {
          guard checks < maximumExistenceChecks else { return nil }
          checks += 1
          let candidate = base + "/" + component
          guard directoryExists(candidate) else { continue }
          if let resolved = walk(from: index + span, base: candidate) { return resolved }
        }
      }
      return nil
    }
    return walk(from: 0, base: "")
  }

  /// 一段 token 可能还原成的路径分量。空 token 表示原字符不是 `/`（编码后相邻两个 `-`），
  /// 最常见的是 `.claude`/`_build` 这类以点或下划线开头的目录，因此额外给出这两种还原。
  private static func componentCandidates(
    tokens: [String],
    at index: Int,
    span: Int
  ) -> [String] {
    let segment = Array(tokens[index..<(index + span)])
    var candidates: [String] = []
    let joined = segment.joined(separator: "-")
    if !joined.isEmpty { candidates.append(joined) }
    if segment[0].isEmpty, span >= 2 {
      let rest = segment.dropFirst().joined(separator: "-")
      if !rest.isEmpty {
        candidates.append("." + rest)
        candidates.append("_" + rest)
      }
    }
    return candidates
  }

  /// 从 transcript 开头的若干条记录里取 provider 自报的工作目录。Claude Code 把 `cwd`
  /// 写在每条记录顶层，Codex 写在首条 `session_meta` 的 `payload.cwd`，因此顶层与
  /// payload 两层都要看。只读白名单键，不展开其余任何字段。
  public static func workingDirectory(
    inTranscript data: Data,
    limits: AgentTranscriptLimits = .default
  ) -> String? {
    guard data.count <= limits.maximumInputBytes else { return nil }
    var scanned = 0
    for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard scanned < maximumScannedRecordsForWorkingDirectory else { return nil }
      guard rawLine.count <= limits.maximumRecordBytes else { continue }
      scanned += 1
      guard
        let object = try? JSONSerialization.jsonObject(
          with: Data(rawLine), options: [.fragmentsAllowed])
      else { continue }
      for record in flattenedRecords(object) {
        if let value = workingDirectory(inRecord: record) { return value }
      }
    }
    return nil
  }

  /// 单条记录里的工作目录。顶层优先，其次 `payload`（Codex 的 `session_meta` 形状）。
  public static func workingDirectory(inRecord record: [String: Any]) -> String? {
    let keys = ["cwd", "workdir", "working_directory", "workingDirectory", "projectPath", "project_path"]
    for key in keys {
      if let value = normalizedAbsolutePath(record[key] as? String) { return value }
    }
    if let payload = record["payload"] as? [String: Any] {
      for key in keys {
        if let value = normalizedAbsolutePath(payload[key] as? String) { return value }
      }
    }
    return nil
  }

  /// JSONL 单行既可能是一条记录，也可能是一个记录数组；统一收敛成字典序列。
  static func flattenedRecords(_ object: Any) -> [[String: Any]] {
    if let dictionary = object as? [String: Any] { return [dictionary] }
    if let array = object as? [Any] { return array.compactMap { $0 as? [String: Any] } }
    return []
  }

  /// 路径值的准入校验：必须是有界、无控制字符的绝对路径，并去掉尾部斜杠。
  public static func normalizedAbsolutePath(_ value: String?) -> String? {
    guard var path = value else { return nil }
    path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/"), path.utf8.count <= maximumPathBytes,
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

/// Agent 工具调用的语义分类。只区分「读文件 / 改文件 / 其它」，不解释工具参数含义。
public enum AgentToolEffect: String, Equatable, Sendable {
  case read
  case modify
  case other
}

/// 一次可判定的工具调用。刻意只保留工具名、目标路径与时间戳三项 —— prompt 正文、
/// 工具参数全文与 Agent 输出都不进入这个结构，也就不可能被下游写进事件库。
public struct AgentToolInvocation: Equatable, Sendable {
  public let name: String
  /// 工具输入里可判定的目标路径；无法判定时为 nil，不做猜测。
  public let filePath: String?
  public let timestamp: Date?

  public init(name: String, filePath: String?, timestamp: Date?) {
    self.name = name
    self.filePath = filePath
    self.timestamp = timestamp
  }

  public var effect: AgentToolEffect { AgentTranscriptToolExtraction.effect(ofToolNamed: name) }
}

/// 从 provider transcript 抽取工具调用。
///
/// 不复用 `AgentTranscriptParser`：那个解析器按设计丢弃 tool 输入（避免把任意 JSON 注入
/// 历史视图与搜索索引），因此拿不到文件路径。这里改为自己走一遍同样受限的 JSONL 扫描，
/// 但**只读白名单里的路径键**，其余字段一律不落地——隐私边界从抽取阶段就成立。
public enum AgentTranscriptToolExtraction {
  /// 单次摄取最多补录的工具调用数，防止一个超长会话把事件库刷爆。
  public static let maximumInvocations = 2_000

  /// 工具输入里被认为「就是目标文件路径」的键。含义不明确的键（`pattern`、`query`、
  /// `command`）一律不取，避免把用户内容当路径记下来。
  private static let pathKeys = [
    "file_path", "filePath", "path", "notebook_path", "notebookPath",
    "target_file", "absolute_path", "abs_path",
  ]

  private static let readToolNames: Set<String> = [
    "read", "readfile", "read_file", "read_many_files", "view", "view_file", "open_file",
    "glob", "grep", "search", "file_search", "grep_search", "codebase_search",
    "search_file_content", "list_dir", "ls", "notebookread", "notebook_read",
  ]

  private static let modifyToolNames: Set<String> = [
    "edit", "edit_file", "write", "write_file", "create_file", "multiedit", "multi_edit",
    "notebookedit", "notebook_edit", "apply_patch", "patch_file", "delete_file",
    "str_replace_editor", "str_replace_based_edit_tool", "insert_edit_into_file",
  ]

  /// 工具名 → 语义分类。大小写不敏感；MCP 工具的 `mcp__server__tool` 前缀先剥掉再匹配，
  /// 无法归类的返回 `.other`（仍会记一条 `agentToolCall`，只是不派生文件事件）。
  public static func effect(ofToolNamed name: String) -> AgentToolEffect {
    var normalized = name.lowercased()
    if let range = normalized.range(of: "__", options: .backwards) {
      normalized = String(normalized[range.upperBound...])
    }
    if readToolNames.contains(normalized) { return .read }
    if modifyToolNames.contains(normalized) { return .modify }
    return .other
  }

  /// 扫描 transcript，按出现顺序返回工具调用。上限沿用 `AgentTranscriptLimits`，
  /// 超限即整体放弃（返回空）——不完整的补录不如没有补录。
  public static func invocations(
    from data: Data,
    limits: AgentTranscriptLimits = .default,
    maximumInvocations: Int = AgentTranscriptToolExtraction.maximumInvocations
  ) -> [AgentToolInvocation] {
    guard data.count <= limits.maximumInputBytes else { return [] }
    var result: [AgentToolInvocation] = []
    var records = 0

    for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard records < limits.maximumRecords, result.count < maximumInvocations else { break }
      guard rawLine.count <= limits.maximumRecordBytes else { continue }
      records += 1
      guard
        let object = try? JSONSerialization.jsonObject(
          with: Data(rawLine), options: [.fragmentsAllowed])
      else { continue }
      for record in AgentTranscriptProjectMapping.flattenedRecords(object) {
        let timestamp = parseTimestamp(record["timestamp"])
        for invocation in invocations(inRecord: record, timestamp: timestamp) {
          guard result.count < maximumInvocations else { break }
          result.append(invocation)
        }
      }
    }
    return result
  }

  /// 单条记录里的工具调用。三种形状都要覆盖：Codex 的 `payload.type == "function_call"`、
  /// Claude Code 的 `message.content[]` 里 `type == "tool_use"`、以及裸顶层 tool 记录。
  static func invocations(
    inRecord record: [String: Any],
    timestamp: Date?
  ) -> [AgentToolInvocation] {
    let root = (record["payload"] as? [String: Any]) ?? record
    let effectiveTimestamp = timestamp ?? parseTimestamp(root["timestamp"])

    if let invocation = invocation(inBlock: root, timestamp: effectiveTimestamp) {
      return [invocation]
    }
    let content =
      (root["message"] as? [String: Any])?["content"] ?? root["content"]
    guard let blocks = content as? [Any] else { return [] }
    return blocks.compactMap { block in
      guard let dictionary = block as? [String: Any] else { return nil }
      return invocation(inBlock: dictionary, timestamp: effectiveTimestamp)
    }
  }

  private static let toolBlockTypes: Set<String> = [
    "tool_use", "tool_call", "function_call", "custom_tool_call", "local_shell_call",
  ]

  /// 判断单个 JSON 块是否是工具调用，并只取工具名与白名单路径键。
  private static func invocation(
    inBlock block: [String: Any],
    timestamp: Date?
  ) -> AgentToolInvocation? {
    guard let type = (block["type"] as? String)?.lowercased(), toolBlockTypes.contains(type),
      let name = firstNonEmptyString(in: block, keys: ["name", "tool_name"])
    else { return nil }
    return AgentToolInvocation(
      name: String(name.prefix(120)),
      filePath: filePath(inArguments: block),
      timestamp: timestamp
    )
  }

  /// 工具参数里的目标路径。参数可能是对象（Claude Code 的 `input`）也可能是 JSON 字符串
  /// （Codex 的 `arguments`）；后者需要再解一层，但同样只读白名单键。
  private static func filePath(inArguments block: [String: Any]) -> String? {
    var containers: [[String: Any]] = []
    for key in ["input", "parameters", "args", "arguments"] {
      if let dictionary = block[key] as? [String: Any] {
        containers.append(dictionary)
      } else if let encoded = block[key] as? String,
        encoded.utf8.count <= AgentTranscriptLimits.default.maximumRecordBytes,
        let decoded = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)),
        let dictionary = decoded as? [String: Any]
      {
        containers.append(dictionary)
      }
    }
    for container in containers {
      for key in pathKeys {
        guard let raw = container[key] as? String else { continue }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= AgentTranscriptProjectMapping.maximumPathBytes,
          !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { continue }
        return trimmed
      }
    }
    return nil
  }

  private static func firstNonEmptyString(in block: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = block[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }

  /// Claude Code 与 Codex 的时间戳都带毫秒，默认 formatter 解析不了，必须补一次带
  /// fractional seconds 的尝试。formatter 不是 Sendable，因而按调用现建，不做全局缓存。
  private static func parseTimestamp(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    if let date = ISO8601DateFormatter().date(from: value) { return date }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}
