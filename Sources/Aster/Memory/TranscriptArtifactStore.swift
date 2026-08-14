import AsterCore
import AsterMemory
import Foundation

/// 命令输出正文的落盘器。
///
/// events 表只留 ≤4KiB 摘录供 FTS；完整正文（`ShellCommandOutputCapture` 已按 128KiB/命令
/// 封顶）写到 `<MemoryRoot>/transcripts/<session-uuid>/<seq>.txt`。
/// 正文可能含命令输出中的敏感片段，因此目录 0700、文件 0600，与数据库同一防线。
///
/// 所有方法都做同步文件 IO，**只能在后台 actor / detached task 上调用**。
struct TranscriptArtifactStore: Sendable {
  private let location: MemoryStoreLocation

  init(location: MemoryStoreLocation) {
    self.location = location
  }

  /// 写入一条已脱敏的输出正文，返回可入库的指针。任何 IO 失败返回 nil：
  /// 正文丢失只降低回溯质量，不能让记录管线中断（PRD §12.1）。
  ///
  /// 文件用 `Data.write(options: .atomic)` 之后再收权限会有一个短暂的 0644 窗口，
  /// 所以这里先在目标路径创建 0600 空文件再写入 —— 正文进入磁盘时权限已经收紧。
  func write(sessionID: UUID, sequence: Int, text: String) -> ArtifactRef? {
    let data = Data(text.utf8)
    guard !data.isEmpty else { return nil }
    let relativePath = MemoryTranscriptLayout.relativePath(
      sessionID: sessionID, sequence: sequence)
    let fileURL = location.rootDirectory.appendingPathComponent(relativePath)
    let directoryURL = fileURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    do {
      try location.prepareDirectory(fileManager: fileManager)
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return nil
    }
    guard
      fileManager.createFile(
        atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { return nil }
    do {
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.write(contentsOf: data)
    } catch {
      try? fileManager.removeItem(at: fileURL)
      return nil
    }
    return ArtifactRef(
      sessionID: sessionID,
      kind: .commandOutput,
      relativePath: relativePath,
      byteCount: data.count
    )
  }

  /// 删除某个 Session 的全部正文目录。用户删除 Session 记录时由上层调用，
  /// 保证「删除」不只是从列表里消失（PRD §101 透明性）。
  func removeSessionDirectory(sessionID: UUID) {
    let url = location.rootDirectory.appendingPathComponent(
      MemoryTranscriptLayout.sessionDirectory(sessionID: sessionID))
    try? FileManager.default.removeItem(at: url)
  }
}
