import AsterCore
import Foundation

/// 把 Pane 描述符与后台受管终端绑定起来。
///
/// 三条固定规则：
/// 1. 受管模式未显式开启时完全不介入，默认终端策略保持不变（P2 退出门槛）。
/// 2. 新建 Pane 创建受管终端；创建失败只显示明确错误，不落地未标识的本地 Shell。
/// 3. 旧布局里没有受管引用的 Pane 不自动托管——托管必须走 P2.6 的显式迁移事务。
@MainActor
enum ManagedTerminalBinder {
  /// 受管终端使用的登录 Shell argv。与本地终端一致，保证行为可比。
  static func shellArguments(shell: String) -> [String] {
    switch URL(fileURLWithPath: shell).lastPathComponent {
    case "bash": [shell, "--login", "-i"]
    case "fish": [shell, "--login", "--interactive"]
    default: [shell, "-l", "-i"]
    }
  }

  /// 绑定一个终端 Pane。
  ///
  /// - Parameters:
  ///   - session: 尚未挂载 surface 的终端会话。
  ///   - descriptor: Pane 描述符，可能已带受管引用。
  ///   - isRestored: 是否来自持久化恢复；恢复的旧 Pane 不自动创建受管终端。
  ///   - shell: 登录 Shell 路径。
  ///   - onBind: 新建成功后把引用写回布局，使其被持久化。
  static func bind(
    session: TerminalSession,
    descriptor: PaneDescriptor,
    isRestored: Bool,
    shell: String,
    onBind: (ManagedTerminalReference) -> Void
  ) {
    let coordinator = ManagedTerminalCoordinator.shared
    guard coordinator.isEnabled else { return }

    if let existing = descriptor.managedTerminal {
      // 重开 App 必须查服务端真实状态；持久化的引用本身不是运行证据。
      let resolution = coordinator.reconcile(
        references: [existing], persistedServerEpoch: nil)[existing]
      switch resolution {
      case .attached:
        session.bindManagedTerminal(existing)
      case .exited(let status):
        session.markManagedFailure(
          "受管终端已退出（exit \(status.exitCode.map(String.init) ?? "未知")）。")
      case .serverRestarted:
        session.markManagedFailure("后台会话服务已重启，原终端实例不再有效。")
      case .missing:
        session.markManagedFailure("后台会话服务中找不到该终端。")
      case .unreachable(_, let reason):
        session.markManagedFailure("无法连接后台会话服务：\(reason)")
      case nil:
        session.markManagedFailure("受管终端状态未知。")
      }
      return
    }

    // 旧布局的非受管 Pane 保持原样，等待显式迁移。
    guard !isRestored else { return }

    do {
      let status = try coordinator.createTerminal(
        workingDirectory: descriptor.workingDirectory,
        argv: shellArguments(shell: shell)
      )
      session.bindManagedTerminal(status.reference)
      onBind(status.reference)
    } catch {
      session.markManagedFailure(String(describing: error))
    }
  }
}
