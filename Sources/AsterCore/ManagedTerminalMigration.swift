import Foundation

/// 旧布局“托管到后台”的迁移事务。
///
/// 固定语义（`docs/developer/remote-work.md` §3.3 与 P2.6）：迁移只搬布局并创建
/// 新的受管终端，绝不声称收养旧 PTY。旧进程一律保留到用户自己关闭；任意一步失败
/// 都回滚配置到备份，并清理本次已创建的新终端，旧终端不受影响。

/// 迁移候选：一个尚未托管的本地终端 Pane。
public struct ManagedMigrationCandidate: Equatable, Sendable {
  public let tabID: UUID
  public let paneID: UUID
  public let workingDirectory: String

  public init(tabID: UUID, paneID: UUID, workingDirectory: String) {
    self.tabID = tabID
    self.paneID = paneID
    self.workingDirectory = workingDirectory
  }
}

/// 迁移结果。失败时 `tabs` 是回滚后的原始布局。
public struct ManagedMigrationOutcome: Sendable {
  public let tabs: [WorkspaceTabSnapshot]
  public let created: [UUID: ManagedTerminalReference]
  public let backupURL: URL?
  public let failure: ManagedMigrationError?

  public var succeeded: Bool { failure == nil }
}

public enum ManagedMigrationError: Error, Equatable, Sendable {
  /// 后台服务不可达；不保存任何迁移结果。
  case serverUnreachable(String)
  /// 创建受管终端失败，已回滚。
  case terminalCreationFailed(paneID: UUID, reason: String)
  /// 备份或持久化失败，已回滚。
  case persistenceFailed(String)
}

public enum ManagedTerminalMigration {
  /// 找出可迁移的 Pane：仅终端类且尚未持有受管引用。
  ///
  /// 文件、编辑器、预览与 Web Pane 由客户端管理，不进入共享结构，因此排除在外。
  public static func candidates(in tabs: [WorkspaceTabSnapshot]) -> [ManagedMigrationCandidate] {
    tabs.flatMap { tab in
      tab.layout.allPanes.compactMap { pane in
        guard pane.kind == .terminal, pane.managedTerminal == nil else { return nil }
        return ManagedMigrationCandidate(
          tabID: tab.id, paneID: pane.id, workingDirectory: pane.workingDirectory)
      }
    }
  }

  /// 执行迁移事务。
  ///
  /// - Parameters:
  ///   - tabs: 迁移前的布局快照，同时作为回滚基线。
  ///   - endpoint: 目标命名会话。
  ///   - client: 会话客户端；只做创建与失败清理，不结束任何旧本地进程。
  ///   - shellArguments: 新受管终端的 argv（通常是登录 Shell）。
  ///   - backupURL: 备份文件位置；写入失败即视为事务失败。
  /// - Returns: 成功时返回带受管引用的新布局；失败时返回原布局与失败原因。
  public static func migrate(
    tabs: [WorkspaceTabSnapshot],
    endpoint: ManagedSessionEndpoint,
    client: any ManagedSessionClient,
    shellArguments: [String],
    backupURL: URL?
  ) -> ManagedMigrationOutcome {
    let candidates = candidates(in: tabs)
    guard !candidates.isEmpty else {
      return ManagedMigrationOutcome(
        tabs: tabs, created: [:], backupURL: nil, failure: nil)
    }

    // 先写备份再动任何东西：回滚必须有一份与迁移前完全一致的磁盘副本。
    var writtenBackup: URL?
    if let backupURL {
      do {
        let data = try JSONEncoder().encode(tabs)
        try data.write(to: backupURL, options: [.atomic, .completeFileProtection])
        writtenBackup = backupURL
      } catch {
        return ManagedMigrationOutcome(
          tabs: tabs, created: [:], backupURL: nil,
          failure: .persistenceFailed(String(describing: error)))
      }
    }

    let server: SessionServerReference
    do {
      server = try client.ensureServer(endpoint)
    } catch {
      return ManagedMigrationOutcome(
        tabs: tabs, created: [:], backupURL: writtenBackup,
        failure: .serverUnreachable(String(describing: error)))
    }
    _ = server

    var created: [UUID: ManagedTerminalReference] = [:]
    for candidate in candidates {
      do {
        let status = try client.createTerminal(
          endpoint, workingDirectory: candidate.workingDirectory, argv: shellArguments)
        created[candidate.paneID] = status.reference
      } catch {
        // 回滚：只结束本次事务创建的新终端，旧 PTY 与旧进程保持不动。
        rollbackCreated(created, endpoint: endpoint, client: client)
        return ManagedMigrationOutcome(
          tabs: tabs, created: [:], backupURL: writtenBackup,
          failure: .terminalCreationFailed(
            paneID: candidate.paneID, reason: String(describing: error)))
      }
    }

    let migrated = tabs.map { tab in
      var updated = tab
      for pane in tab.layout.allPanes {
        guard let reference = created[pane.id] else { continue }
        updated.layout = updated.layout.updatingPane(paneID: pane.id) { descriptor in
          var next = descriptor
          next.managedTerminal = reference
          return next
        }
      }
      return updated
    }
    return ManagedMigrationOutcome(
      tabs: migrated, created: created, backupURL: writtenBackup, failure: nil)
  }

  /// 从备份文件恢复迁移前布局；供“恢复入口”与失败后手动回滚使用。
  public static func restore(from backupURL: URL) throws -> [WorkspaceTabSnapshot] {
    let data = try Data(contentsOf: backupURL)
    return try JSONDecoder().decode([WorkspaceTabSnapshot].self, from: data)
  }

  /// 尽力清理本次已创建的受管终端。清理失败不改变回滚结论，但要保留原始失败原因。
  private static func rollbackCreated(
    _ created: [UUID: ManagedTerminalReference],
    endpoint: ManagedSessionEndpoint,
    client: any ManagedSessionClient
  ) {
    for reference in created.values {
      _ = try? client.terminateTerminal(endpoint, terminalID: reference.terminalID)
    }
  }
}
