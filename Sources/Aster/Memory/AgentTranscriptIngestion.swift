import AsterCore
import AsterMemory
import Foundation

/// 从 provider 自己落盘的 transcript 补录 Agent 侧语义事件（工具调用与文件读写）。
///
/// 终端侧事件（命令、退出码、输出摘录）由 `SessionRecordingService` 实时记录；本服务只负责
/// 补上终端看不见的那一半。transcript 缺失、格式漂移或超限时**静默降级**：库里已有的终端
/// 事件不受影响，只留一条不含路径与命令的诊断计数（PRD §12.1：Intelligence can fail.
/// Terminal cannot.）。
enum AgentTranscriptIngestion {
  /// 定位 transcript 时最多考察的文件数，沿用历史发现的同一量级上限。
  static let maximumScannedFiles = 2_000

  /// 摄取失败的原因。只用于诊断计数，不携带任何路径或内容。
  enum Failure: String, Error {
    case providerHasNoTranscriptRoot = "no_transcript_root"
    case transcriptNotFound = "not_found"
    case transcriptUnreadable = "unreadable"
    case noToolInvocations = "no_tool_calls"
  }

  /// 把某个 Agent 会话的工具调用补录进指定 Session。
  ///
  /// 调用方负责保证 recording 已开启且该 Session 已入库；本方法只追加事件，
  /// 序号从库里已有事件的最大值之后继续，因此不会与终端事件冲突。
  static func ingest(
    sessionID: UUID,
    provider: AgentProvider,
    agentSessionID: String,
    projectPath: String,
    writer: EventWriter,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) async {
    guard !agentSessionID.isEmpty else { return }

    // 终端事件此前已入库；先取一次现状，既定序号起点，也保证重复摄取幂等
    //（同一 Session 关闭重试、或恢复后再次触发都不应该产生第二份工具调用）。
    let existing = await writer.recordedEvents(sessionID: sessionID)
    guard !existing.contains(where: { $0.source == .transcript }) else { return }
    var sequence = existing.map(\.sequence).max() ?? 0

    let located = await Task.detached(priority: .utility) {
      locateTranscript(
        provider: provider, agentSessionID: agentSessionID, homeDirectory: homeDirectory)
    }.value
    guard case .success(let url) = located else {
      if case .failure(let reason) = located { report(reason, provider: provider) }
      return
    }

    let extracted = await Task.detached(priority: .utility) {
      // mappedIfSafe：大 transcript 不整体驻留内存；失败与「解析不出工具调用」是两种
      // 不同的降级原因，诊断上要能分开看。
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        return Result<[AgentToolInvocation], Failure>.failure(.transcriptUnreadable)
      }
      return .success(AgentTranscriptToolExtraction.invocations(from: data))
    }.value
    guard case .success(let invocations) = extracted else {
      report(.transcriptUnreadable, provider: provider)
      return
    }
    guard !invocations.isEmpty else {
      report(.noToolInvocations, provider: provider)
      return
    }

    let fallbackTimestamp = Date()

    for invocation in invocations {
      let timestamp = invocation.timestamp ?? fallbackTimestamp
      // 路径同样过一遍 secret 遮盖：临时目录名、token 化的路径片段都可能带敏感串。
      let redactedPath = resolvedPath(invocation.filePath, projectPath: projectPath)
        .map { AgentContextRedactor.redact($0).value }
      let payload = payloadJSON(tool: invocation.name, path: redactedPath)

      sequence += 1
      await writer.record(
        .appendEvent(
          RecordedEvent(
            sessionID: sessionID,
            sequence: sequence,
            timestamp: timestamp,
            kind: .agentToolCall,
            command: invocation.name,
            workingDirectory: projectPath,
            source: .transcript,
            payload: payload
          )))

      // 只有拿到可判定路径时才派生文件事件；没有路径的读写工具不猜测目标。
      guard let redactedPath else { continue }
      let derived: MemoryEventKind
      switch invocation.effect {
      case .read: derived = .fileRead
      case .modify: derived = .fileModified
      case .other: continue
      }
      sequence += 1
      await writer.record(
        .appendEvent(
          RecordedEvent(
            sessionID: sessionID,
            sequence: sequence,
            timestamp: timestamp,
            kind: derived,
            command: invocation.name,
            workingDirectory: projectPath,
            source: .transcript,
            payload: payload
          )))
    }
    await writer.flush()
  }

  /// 把工具参数里的路径统一成绝对路径。Claude Code 的 `Read`/`Edit` 给绝对路径，但
  /// `Grep`/`Glob` 的 `path` 常是相对会话工作目录的片段；不补全就没法回答「Agent 动过
  /// 哪些文件」。这里只做字符串拼接与长度校验，不访问磁盘、也不解析 `..`。
  static func resolvedPath(_ path: String?, projectPath: String) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let absolute: String
    if path.hasPrefix("/") {
      absolute = path
    } else if projectPath.hasPrefix("/") {
      absolute = (projectPath as NSString).appendingPathComponent(path)
    } else {
      absolute = path
    }
    guard absolute.utf8.count <= AgentTranscriptProjectMapping.maximumPathBytes else { return nil }
    return absolute
  }

  /// 事件 payload：只有工具名与目标路径两个字段。工具参数全文、prompt 与 Agent 输出
  /// 在抽取阶段就已经被丢弃，这里不存在把它们写进去的路径。
  static func payloadJSON(tool: String, path: String?) -> String? {
    var object: [String: String] = ["tool": String(tool.prefix(120))]
    if let path { object["path"] = String(path.prefix(1_024)) }
    // sortedKeys 让 payload 可稳定比对；withoutEscapingSlashes 避免路径被写成 `\/`，
    // 下游（Timeline UI 与 MCP 输出）直接可读。
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }

  /// 按 provider 的已知根目录定位会话文件。只接受受信根目录内的普通文件，跳过符号链接，
  /// 并用 `AgentProvider.detect` 复核路径形状——定位逻辑不得成为绕过发现层安全边界的后门。
  static func locateTranscript(
    provider: AgentProvider,
    agentSessionID: String,
    homeDirectory: URL
  ) -> Result<URL, Failure> {
    guard let root = transcriptRoot(for: provider, homeDirectory: homeDirectory) else {
      return .failure(.providerHasNoTranscriptRoot)
    }
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    guard
      let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in true })
    else { return .failure(.transcriptNotFound) }

    var visited = 0
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: keys) else { continue }
      if values.isDirectory == true {
        if values.isSymbolicLink == true { enumerator.skipDescendants() }
        continue
      }
      visited += 1
      guard visited <= maximumScannedFiles else { break }
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= AgentTranscriptLimits.default.maximumInputBytes,
        matchesSessionIdentifier(url: url, agentSessionID: agentSessionID),
        AgentProvider.detect(sessionFileURL: url, homeDirectory: homeDirectory) == provider
      else { continue }
      return .success(url)
    }
    return .failure(.transcriptNotFound)
  }

  /// 文件名是否属于该会话。Claude Code / openCode 用 `<session-id>.<ext>`，Codex 用
  /// `rollout-<时间戳>-<session-id>.jsonl`，因此除等值外还接受 `-<id>` 后缀。
  static func matchesSessionIdentifier(url: URL, agentSessionID: String) -> Bool {
    let stem = url.deletingPathExtension().lastPathComponent
    return stem == agentSessionID || stem.hasSuffix("-" + agentSessionID)
  }

  /// provider 的会话根目录。Pi 与 omp 没有稳定历史根目录，只能靠运行时 hook 上报，
  /// 这里明确返回 nil 而不是去猜一个看似合理的路径。
  static func transcriptRoot(for provider: AgentProvider, homeDirectory: URL) -> URL? {
    switch provider {
    case .claudeCode:
      homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
    case .codex:
      homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    case .openCode:
      homeDirectory.appendingPathComponent(
        ".local/share/opencode/storage/session", isDirectory: true)
    case .cursorCLI:
      homeDirectory.appendingPathComponent(".cursor/projects", isDirectory: true)
    case .kimiCode:
      homeDirectory.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
    case .pi, .omp:
      nil
    }
  }

  /// 诊断只记 provider 与失败原因这类计数字段。DiagnosticsCenter 会剔除含 path/command/
  /// content 的键，这里从源头就不构造它们。
  private static func report(_ failure: Failure, provider: AgentProvider) {
    DiagnosticsCenter.shared.record(
      "agent.transcript.ingest.skipped",
      level: .debug,
      category: .integration,
      attributes: ["provider": provider.rawValue, "reason": failure.rawValue]
    )
  }
}
