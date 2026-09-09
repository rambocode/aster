import AsterCore
import Foundation

/// 托管迁移的 App 侧支撑：备份位置与新布局的身份重建。
///
/// 迁移不收养旧 PTY，所以迁移结果必须落在**新的**标签与 Pane 身份上；旧标签保持
/// 原样，由用户自行关闭。复用旧 paneID 会让同一 ID 同时对应旧本地 PTY 和新受管
/// 终端，破坏 Composer、CLI selector 与录制的键唯一性。
@MainActor
enum ManagedMigrationSupport {
  /// 迁移备份目录。失败回滚与“恢复入口”都从这里读取迁移前布局。
  static func backupDirectory() -> URL? {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    let directory = base.appendingPathComponent("Aster/RemoteMigrations", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return directory
  }

  /// 生成本次迁移的备份文件路径。
  static func makeBackupURL(now: Date = Date()) -> URL? {
    guard let directory = backupDirectory() else { return nil }
    let stamp = Int(now.timeIntervalSince1970)
    return directory.appendingPathComponent("workspace-\(stamp).json")
  }

  /// 列出可恢复的备份，最新在前。
  static func availableBackups() -> [URL] {
    guard let directory = backupDirectory(),
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return entries.filter { $0.pathExtension == "json" }.sorted { $0.path > $1.path }
  }

  /// 为迁移结果重建标签/Pane 身份，并只保留确实产生了受管终端的标签。
  ///
  /// 受管引用随描述符一起搬到新身份上；本地文件/编辑器/Web Pane 保留其描述符，
  /// 由客户端各自重建视图，不上传任何本地资源内容。
  static func rebased(_ tabs: [WorkspaceTabSnapshot]) -> [WorkspaceTabSnapshot] {
    tabs.compactMap { tab in
      guard tab.layout.allPanes.contains(where: { $0.managedTerminal != nil }) else { return nil }
      var rebuilt = tab
      rebuilt.layout = rebase(tab.layout)
      return WorkspaceTabSnapshot(
        id: UUID(),
        title: tab.title,
        layout: rebuilt.layout,
        titleState: tab.titleState,
        createdAt: Date(),
        updatedAt: Date(),
        // Agent 会话与恢复命令属于旧进程，不能搬到新受管实例上。
        agentSessions: nil,
        restoreCommands: nil
      )
    }
  }

  private static func rebase(_ layout: PaneLayout) -> PaneLayout {
    switch layout {
    case .leaf(let pane):
      return .leaf(
        PaneDescriptor(
          kind: pane.kind,
          workingDirectory: pane.workingDirectory,
          resourcePath: pane.resourcePath,
          managedTerminal: pane.managedTerminal
        ))
    case .split(let axis, let first, let second, let ratio):
      return .split(axis: axis, first: rebase(first), second: rebase(second), ratio: ratio)
    }
  }
}
