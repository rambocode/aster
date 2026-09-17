import AsterCore
import Foundation

/// 只读发现受支持 Agent 的本机会话文件。扫描限定在 provider 的已知主目录、普通文件、
/// 数量/单文件/总字节上限内；Pi 与 omp 没有稳定历史根目录，只能由运行时 hook 上报。
enum AgentHistoryDiscoveryService {
  static let maximumFiles = 500
  static let maximumTotalBytes = 32 * 1_024 * 1_024

  /// 扫描各 provider 的会话目录。`limits` / `maximumFiles` 只供测试缩小规模，生产用默认值。
  static func discover(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    limits: AgentTranscriptLimits = .default,
    maximumFiles: Int = maximumFiles
  ) async -> [AgentSessionHistory] {
    await Task.detached(priority: .utility) {
      discoverSynchronously(homeDirectory: homeDirectory, limits: limits, maximumFiles: maximumFiles)
    }.value
  }

  private static func discoverSynchronously(
    homeDirectory: URL, limits: AgentTranscriptLimits, maximumFiles: Int
  ) -> [AgentSessionHistory] {
    let roots = [
        homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
        homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true),
        homeDirectory.appendingPathComponent(
          ".local/share/opencode/storage/session", isDirectory: true),
        homeDirectory.appendingPathComponent(".cursor/projects", isDirectory: true),
        homeDirectory.appendingPathComponent(".kimi-code/sessions", isDirectory: true),
      ]
      let manager = FileManager.default
      let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .creationDateKey, .contentModificationDateKey,
      ]
      var candidates: [(URL, URLResourceValues, AgentProvider)] = []
      for root in roots {
        guard let enumerator = manager.enumerator(
          at: root,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles, .skipsPackageDescendants],
          errorHandler: { _, _ in true }
        ) else { continue }
        // 逐级手动放开普通目录，遇到符号链接目录立即 skipDescendants。这样不依赖
        // provider 树深度，也不会通过链接逃离受信根目录。
        for case let url as URL in enumerator {
          guard let values = try? url.resourceValues(forKeys: keys) else { continue }
          if values.isDirectory == true {
            if values.isSymbolicLink == true { enumerator.skipDescendants() }
            continue
          }
          guard values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize != nil,
            let provider = AgentProvider.detect(sessionFileURL: url, homeDirectory: homeDirectory)
          else { continue }
          // 枚举阶段只收集元数据，不设上限：目录里文件超过 maximumFiles 时（Claude
          // 用户几百个会话很常见），先截断再排序会把最新的会话直接漏掉——正在运行的
          // 会话因此没有标题。数量上限在按修改时间排序之后再施加。
          candidates.append((url, values, provider))
        }
      }
      candidates.sort {
        ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast)
      }
      candidates = Array(candidates.prefix(maximumFiles))
      // Codex 的 AI 线程名在一个小索引文件里，整次扫描只读一次。
      let codexThreadNames = codexThreadNames(homeDirectory: homeDirectory)
      var totalBytes = 0
      var histories: [AgentSessionHistory] = []
      for (url, values, provider) in candidates {
        // 超过单文件上限的长会话只读文件头（按行截断）：标题、项目目录都在开头，
        // 整个丢掉会让长会话在列表和标签上都失去名字。超长记录按降级策略跳过。
        guard let size = values.fileSize,
          let data = boundedTranscriptData(at: url, size: size, limits: limits),
          totalBytes <= maximumTotalBytes - data.count,
          let transcript = try? AgentTranscriptParser.parse(
            data, provider: provider, limits: limits, overflow: .degrade)
        else { continue }
        totalBytes += data.count
        // 标题优先取 provider 自己的会话名（Claude 的 custom-title / ai-title、Codex 的
        // 线程名）；没有时才从用户消息序列推导：首条可能是 caveat/系统提醒等包装噪音，
        // 清洗规则见 AgentSessionTitleCleaner，全部为噪音时回落文件名。
        let sessionID = url.deletingPathExtension().lastPathComponent
        let userTexts = transcript.entries.compactMap { entry -> String? in
          if case .message(role: .user) = entry.kind { return entry.text }
          return nil
        }
        let title = providerSessionTitle(
          url: url, provider: provider, sessionID: sessionID, head: data, size: size,
          codexThreadNames: codexThreadNames)
          ?? AgentSessionTitleCleaner.title(from: userTexts, fallback: sessionID)
        let projectDirectory = inferredProjectDirectory(
          url: url, provider: provider, home: homeDirectory, transcriptData: data)
        let metadata = AgentSessionMetadata(
          id: url.deletingPathExtension().lastPathComponent,
          configuration: .init(provider: provider),
          projectDirectory: projectDirectory,
          title: title,
          createdAt: values.creationDate ?? values.contentModificationDate ?? .distantPast,
          updatedAt: values.contentModificationDate ?? values.creationDate ?? .distantPast,
          transcriptFileURL: url
        )
        histories.append(.init(metadata: metadata, transcript: transcript))
      }
    return histories
  }

  /// Claude transcript 尾部扫描长度：`custom-title` 是 `/rename` 时追加的，可能在几十 MB
  /// 之后；`ai-title` 绝大多数在文件头 1MB 内。头 + 尾两段覆盖了实际分布。
  static let claudeTitleTailBytes = 256 * 1_024

  /// provider 自维护的会话名；没有返回 nil，由调用方退回 prompt 推导。
  static func providerSessionTitle(
    url: URL, provider: AgentProvider, sessionID: String, head: Data, size: Int,
    codexThreadNames: [String: String]
  ) -> String? {
    switch provider {
    case .claudeCode:
      var chunks = [head]
      if size > head.count, let tail = transcriptTail(at: url, from: head.count, size: size) {
        chunks.append(tail)
      }
      return AgentSessionTitleIndex.claudeTitles(in: chunks).preferred
    case .codex:
      // Codex 的 session id 是 rollout 文件名末尾的 UUID（`rollout-<时间>-<uuid>.jsonl`）。
      return codexThreadNames.first { sessionID.hasSuffix($0.key) }?.value
    default:
      return nil
    }
  }

  /// 读文件尾供标题扫描：从 `max(headEnd, size - tail)` 读到文件末尾。起点落在行中间时丢掉
  /// 首个半行；起点恰是文件头结束处则已在行首（文件头按换行截断）。
  static func transcriptTail(at url: URL, from headEnd: Int, size: Int) -> Data? {
    let start = max(headEnd, size - claudeTitleTailBytes)
    guard start < size, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: UInt64(start))) != nil,
      let tail = try? handle.readToEnd(), !tail.isEmpty
    else { return nil }
    guard start > headEnd, let newline = tail.firstIndex(of: 0x0A) else { return tail }
    return tail[tail.index(after: newline)...]
  }

  /// `~/.codex/session_index.jsonl`：读不到（未装 Codex / 旧版本）返回空表。
  static func codexThreadNames(homeDirectory: URL) -> [String: String] {
    let url = homeDirectory.appendingPathComponent(".codex/session_index.jsonl")
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      data.count <= AgentTranscriptLimits.default.maximumInputBytes
    else { return [:] }
    return AgentSessionTitleIndex.codexThreadNames(from: data)
  }

  /// 超过单文件上限的会话只读这么多文件头。标题与项目目录都在开头几十 KB 内；读满
  /// 4MB 会让几个巨型会话吃光 `maximumTotalBytes`，把后面几十个正常会话挤出列表。
  static let oversizedTranscriptHeadBytes = 1_024 * 1_024

  /// 读取会话文件用于解析的数据：在上限内整读；超限时只读文件头（见
  /// `oversizedTranscriptHeadBytes`），并退到最后一个换行处，避免把半条 JSONL 记录
  /// 交给解析器（它会被算作损坏记录）。
  static func boundedTranscriptData(at url: URL, size: Int, limits: AgentTranscriptLimits) -> Data? {
    if size <= limits.maximumInputBytes {
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count == size else {
        return nil
      }
      return data
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let headBytes = min(limits.maximumInputBytes, oversizedTranscriptHeadBytes)
    guard let head = try? handle.read(upToCount: headBytes), !head.isEmpty else { return nil }
    guard let newline = head.lastIndex(of: 0x0A) else { return head }
    return head.prefix(through: newline)
  }

  /// 会话的项目归属。规则本身是 `AgentTranscriptProjectMapping` 的纯函数，这里只注入
  /// 文件系统存在性判定并做限流。
  ///
  /// 判不出来时返回空串而**不是**主目录：伪造 home 会让所有 Agent 会话塌缩成同一个假项目，
  /// 按项目组织历史与 Session Memory 就彻底失真。空串对启动路径是安全的——
  /// `TerminalSession` 在启动 PTY 前会校验目录是否存在，不存在即回退主目录并给出提示。
  static func inferredProjectDirectory(
    url: URL,
    provider: AgentProvider,
    home: URL,
    transcriptData: Data
  ) -> String {
    projectAttribution(url: url, provider: provider, home: home, transcriptData: transcriptData)?
      .path ?? ""
  }

  /// 带置信度的项目归属，供 Session Memory 侧标注来源可靠性。
  static func projectAttribution(
    url: URL,
    provider: AgentProvider,
    home: URL,
    transcriptData: Data
  ) -> AgentProjectAttribution? {
    let manager = FileManager.default
    var checks = 0
    return AgentTranscriptProjectMapping.attribution(
      provider: provider,
      sessionFileURL: url,
      homeDirectory: home,
      transcriptWorkingDirectory: AgentTranscriptProjectMapping.workingDirectory(
        inTranscript: transcriptData),
      directoryExists: { path in
        // 反解是有损编码的逆向搜索，必须给磁盘访问一个硬上限；超限即当作判不出来。
        guard checks < AgentTranscriptProjectMapping.maximumExistenceChecks else { return false }
        checks += 1
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
      }
    )
  }
}

enum AgentShellCommandEncoder {
  /// POSIX shell 单引号编码。每个结构化 argument 独立编码，空格、换行、分号与命令
  /// 替换字符都只能作为普通参数内容，不能改变 resume/fork 命令结构。
  static func encode(_ plan: AgentNativeCommandPlan) -> String {
    ([plan.executable] + plan.arguments).map(quote).joined(separator: " ")
  }

  private static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
