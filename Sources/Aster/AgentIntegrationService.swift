import AsterCore
import Foundation

/// 只读发现受支持 Agent 的本机会话文件。扫描限定在 provider 的已知主目录、普通文件、
/// 数量/单文件/总字节上限内；Pi 与 omp 没有稳定历史根目录，只能由运行时 hook 上报。
enum AgentHistoryDiscoveryService {
  static let maximumFiles = 500
  static let maximumTotalBytes = 32 * 1_024 * 1_024

  static func discover(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) async
    -> [AgentSessionHistory]
  {
    await Task.detached(priority: .utility) {
      discoverSynchronously(homeDirectory: homeDirectory)
    }.value
  }

  private static func discoverSynchronously(homeDirectory: URL) -> [AgentSessionHistory] {
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
            let size = values.fileSize,
            size <= AgentTranscriptLimits.default.maximumInputBytes,
            let provider = AgentProvider.detect(sessionFileURL: url, homeDirectory: homeDirectory)
          else { continue }
          candidates.append((url, values, provider))
          if candidates.count >= maximumFiles { break }
        }
        if candidates.count >= maximumFiles { break }
      }
      candidates.sort {
        ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast)
      }
      var totalBytes = 0
      var histories: [AgentSessionHistory] = []
      for (url, values, provider) in candidates {
        guard let size = values.fileSize, totalBytes <= maximumTotalBytes - size,
          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count == size,
          let transcript = try? AgentTranscriptParser.parse(data, provider: provider)
        else { continue }
        totalBytes += size
        let firstPrompt = transcript.entries.first { entry in
          if case .message(role: .user) = entry.kind { return true }
          return false
        }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = firstPrompt.map { String($0.prefix(120)) }
          ?? url.deletingPathExtension().lastPathComponent
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
