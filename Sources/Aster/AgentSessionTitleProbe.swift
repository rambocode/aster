// 只读「一个已绑定会话」的 provider 标题。与全量历史扫描分开：正在运行的会话要在首条
// prompt 后几秒内拿到标题，而全量扫描要枚举上千个 transcript，不能按这个频率跑。

import AsterCore
import Foundation

/// 单会话标题探测：按 provider + session ID 直接定位文件，只读文件头与文件尾。
enum AgentSessionTitleProbe {
  /// 每次探测读的文件头上限。首个 `ai-title` 紧跟首轮回复，通常落在这个范围内；
  /// 落在后面的（prompt 带大图）由文件尾覆盖——Claude 每轮都会重新追加标题记录。
  static let headBytes = 256 * 1_024

  /// 只有这两个 provider 自己维护会话名，其余 provider 仍走历史扫描的 prompt 推导。
  static func supports(_ provider: AgentProvider) -> Bool {
    provider == .claudeCode || provider == .codex
  }

  /// 后台读取标题，不占用主线程；没有标题（会话还没产生首条 prompt、文件不存在）返回 nil。
  static func title(
    provider: AgentProvider, sessionID: String, workingDirectory: String, homeDirectory: URL
  ) async -> String? {
    await Task.detached(priority: .utility) {
      titleSynchronously(
        provider: provider, sessionID: sessionID, workingDirectory: workingDirectory,
        homeDirectory: homeDirectory)
    }.value
  }

  /// 同步实现，供后台任务与测试调用。
  static func titleSynchronously(
    provider: AgentProvider, sessionID: String, workingDirectory: String, homeDirectory: URL
  ) -> String? {
    switch provider {
    case .claudeCode:
      guard
        let url = claudeTranscriptURL(
          sessionID: sessionID, workingDirectory: workingDirectory, homeDirectory: homeDirectory)
      else { return nil }
      return claudeTitle(at: url)
    case .codex:
      // Codex 的线程名在一个小索引文件里；session ID 是 rollout 文件名末尾的 UUID。
      return AgentHistoryDiscoveryService.codexThreadNames(homeDirectory: homeDirectory)
        .first { sessionID.hasSuffix($0.key) }?.value
    default:
      return nil
    }
  }

  /// 定位 `~/.claude/projects/<编码目录>/<session-id>.jsonl`。
  ///
  /// Claude 按**启动目录**归档，而 Pane 的当前目录可能已经 `cd` 走了：先按当前目录直接
  /// 命中，落空再遍历 projects 下一级目录找同名文件（几十个目录，各一次 stat）。
  /// session ID 来自 hook，属于外部输入，拼路径前必须限定字符集，杜绝目录穿越。
  static func claudeTranscriptURL(
    sessionID: String, workingDirectory: String, homeDirectory: URL
  ) -> URL? {
    guard isSafeFileComponent(sessionID) else { return nil }
    let root = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
    let fileName = "\(sessionID).jsonl"
    if let normalized = AgentProjectSessionRegistry.normalizePath(workingDirectory) {
      let direct = root
        .appendingPathComponent(
          AgentSessionFileLocator.claudeProjectDirectoryName(for: normalized), isDirectory: true)
        .appendingPathComponent(fileName)
      if isRegularFile(direct) { return direct }
    }
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return nil }
    return directories.lazy.map { $0.appendingPathComponent(fileName) }.first(where: isRegularFile)
  }

  /// 读文件头 + 文件尾扫描标题记录；单次最多读 `headBytes + claudeTitleTailBytes`。
  static func claudeTitle(at url: URL) -> String? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
      let handle = try? FileHandle(forReadingFrom: url)
    else { return nil }
    var head = (try? handle.read(upToCount: headBytes)) ?? Data()
    try? handle.close()
    guard !head.isEmpty else { return nil }
    var chunks: [Data] = []
    if size > head.count {
      // 文件头没读完整个文件：退到最后一个换行，半条 JSONL 不交给解析；其余由文件尾补。
      if let newline = head.lastIndex(of: 0x0A) { head = head.prefix(through: newline) }
      chunks.append(head)
      if let tail = AgentHistoryDiscoveryService.transcriptTail(
        at: url, from: head.count, size: size)
      {
        chunks.append(tail)
      }
    } else {
      chunks.append(head)
    }
    return AgentSessionTitleIndex.claudeTitles(in: chunks).preferred
  }

  /// 只接受 `[A-Za-z0-9._-]` 且不以点开头的短名字。
  private static func isSafeFileComponent(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128, !value.hasPrefix(".") else { return false }
    return value.utf8.allSatisfy { byte in
      (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        || byte == 0x2D || byte == 0x5F || byte == 0x2E
    }
  }

  /// 普通文件且不是符号链接：与历史扫描同一条边界，不通过链接读到受信根目录之外。
  private static func isRegularFile(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }
}
