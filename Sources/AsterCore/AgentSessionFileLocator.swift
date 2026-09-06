import Foundation

/// 不依赖 lifecycle hook，直接从 Agent 自己落盘的会话文件推断「这个 Pane 刚结束的会话」。
///
/// 为什么需要它：Claude Code 2.1.x 启动 hook 时没有控制终端，hook 信号经常到不了 Aster；
/// 没装 hook 的用户更是从没有 session ID。但 Claude / Codex 都会把每个会话写成本地文件，
/// 文件名或首行元数据里就有 session ID，按「项目目录 + 命令开始之后修改过」筛选即可定位。
public enum AgentSessionFileLocator {
  /// 定位结果。`latestUnknown` 表示该项目确实有会话文件，但没有一个落在本次运行的时间窗内
  /// （例如刚跑了 `claude --version`）；调用方可退化为 provider 的「续上最近一次」命令。
  public enum Resolution: Equatable, Sendable {
    case session(id: String)
    case latestUnknown
    case none
  }

  /// 单个项目目录最多检查的文件数；会话目录可能积累数千个 jsonl，超出即放弃继续扫描。
  public static let maximumScannedFiles = 4_000
  /// 文件系统时间戳与进程启动时刻之间允许的偏差。
  public static let startTolerance: TimeInterval = 5
  /// Codex 会话按 `年/月/日` 分目录；只回看这么多天，避免全盘扫描。
  public static let codexLookbackDays = 3
  /// 只读 rollout 首行元数据所需的字节数。
  static let codexMetadataBytes = 8_192

  /// Claude Code 的项目目录名：路径里所有非 ASCII 字母数字的字符都换成 `-`
  /// （`/Users/me/.claude` → `-Users-me--claude`），与 Claude 自己的编码一致。
  public static func claudeProjectDirectoryName(for projectDirectory: String) -> String {
    String(
      projectDirectory.unicodeScalars.map { scalar -> Character in
        let value = scalar.value
        let isAlphanumeric =
          (0x30...0x39).contains(value) || (0x41...0x5A).contains(value)
          || (0x61...0x7A).contains(value)
        return isAlphanumeric ? Character(scalar) : "-"
      })
  }

  /// 找出该项目目录里最近一次会话。`startedAfter` 是 Agent 命令开始的时刻；传 nil 时只按
  /// 修改时间取最新。只支持 Claude Code 与 Codex，其它 provider 返回 `.none`。
  public static func resolve(
    provider: AgentProvider,
    projectDirectory: String,
    homeDirectory: URL,
    startedAfter: Date?
  ) -> Resolution {
    guard let normalized = AgentProjectSessionRegistry.normalizePath(projectDirectory) else {
      return .none
    }
    switch provider {
    case .claudeCode:
      return resolveClaude(projectDirectory: normalized, homeDirectory: homeDirectory, startedAfter: startedAfter)
    case .codex:
      return resolveCodex(projectDirectory: normalized, homeDirectory: homeDirectory, startedAfter: startedAfter)
    default:
      return .none
    }
  }

  // MARK: - Claude Code

  /// `~/.claude/projects/<编码目录>/<session-id>.jsonl`：文件名就是 session ID。
  private static func resolveClaude(
    projectDirectory: String, homeDirectory: URL, startedAfter: Date?
  ) -> Resolution {
    let directory = homeDirectory
      .appendingPathComponent(".claude/projects", isDirectory: true)
      .appendingPathComponent(claudeProjectDirectoryName(for: projectDirectory), isDirectory: true)
    let candidates = sessionFiles(in: directory).filter { $0.url.pathExtension == "jsonl" }
    guard !candidates.isEmpty else { return .none }
    let matched = candidates.filter { isWithinRun($0.modifiedAt, startedAfter: startedAfter) }
      .max { $0.modifiedAt < $1.modifiedAt }
    guard let matched else { return .latestUnknown }
    let stem = matched.url.deletingPathExtension().lastPathComponent
    return isValidSessionID(stem) ? .session(id: stem) : .latestUnknown
  }

  // MARK: - Codex

  /// `~/.codex/sessions/年/月/日/rollout-<时间>-<id>.jsonl`，首行 `session_meta` 里有 `cwd`。
  /// 按日期目录从今天往回看，命中 cwd 的最新文件即为结果。
  private static func resolveCodex(
    projectDirectory: String, homeDirectory: URL, startedAfter: Date?
  ) -> Resolution {
    let root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var files: [(url: URL, modifiedAt: Date)] = []
    for offset in 0..<codexLookbackDays {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
      let directory = root
        .appendingPathComponent(String(year), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", dayOfMonth), isDirectory: true)
      files += sessionFiles(in: directory).filter {
        $0.url.pathExtension == "jsonl" && $0.url.lastPathComponent.hasPrefix("rollout-")
      }
    }
    guard !files.isEmpty else { return .none }
    // 只对时间窗内、且最新的那些文件读首行，避免为了一个 cwd 匹配去读几百个文件。
    let ordered = files.sorted { $0.modifiedAt > $1.modifiedAt }
    var sawProjectSession = false
    for file in ordered.prefix(64) {
      guard let meta = codexSessionMetadata(at: file.url), meta.cwd == projectDirectory else { continue }
      sawProjectSession = true
      if isWithinRun(file.modifiedAt, startedAfter: startedAfter), isValidSessionID(meta.id) {
        return .session(id: meta.id)
      }
    }
    return sawProjectSession ? .latestUnknown : .none
  }

  /// 读 rollout 首行的 `session_meta`：只取 `payload.id` 与 `payload.cwd`。
  static func codexSessionMetadata(at url: URL) -> (id: String, cwd: String)? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: codexMetadataBytes), !head.isEmpty else { return nil }
    let firstLine = head.prefix { $0 != 0x0A }
    guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
      object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any],
      let id = payload["id"] as? String, let cwd = payload["cwd"] as? String
    else { return nil }
    return (id, (cwd as NSString).standardizingPath)
  }

  // MARK: - 共用

  /// 列出目录里的普通文件及修改时间；目录不存在返回空。跳过符号链接，超出上限即停止。
  static func sessionFiles(in directory: URL) -> [(url: URL, modifiedAt: Date)] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return [] }
    var result: [(url: URL, modifiedAt: Date)] = []
    for url in urls.prefix(maximumScannedFiles) {
      guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
        values.isSymbolicLink != true, let modifiedAt = values.contentModificationDate
      else { continue }
      result.append((url, modifiedAt))
    }
    return result
  }

  /// 文件修改时间是否落在本次运行之内（允许几秒偏差）。
  static func isWithinRun(_ modifiedAt: Date, startedAfter: Date?) -> Bool {
    guard let startedAfter else { return true }
    return modifiedAt >= startedAfter.addingTimeInterval(-startTolerance)
  }

  /// 与 hook 指令相同的 session ID 字符集，保证登记后一定能规划成命令。
  static func isValidSessionID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= AgentTerminalDirective.maximumSessionIDBytes
      && id.utf8.allSatisfy { byte in
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
          || (0x61...0x7A).contains(byte) || [0x2D, 0x2E, 0x3A, 0x5F].contains(byte)
      }
  }
}
