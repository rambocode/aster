import AsterCore
import Foundation

/// 把 Pane 描述符与后台受管终端绑定起来。
///
/// 三条固定规则：
/// 1. P8.8 起全新终端默认走受管路径（打包 App 自动解析）；环境变量可覆盖。
/// 2. 新建 Pane 创建受管终端；创建失败只显示明确错误，不落地未标识的本地 Shell。
/// 3. 旧布局里没有受管引用的 Pane 不自动托管——托管必须走 P2.6 的显式迁移事务。
@MainActor
enum ManagedTerminalBinder {
  /// 本机受管终端使用的登录 Shell argv。规则收敛在 `ManagedTerminalLaunchSpec`。
  static func shellArguments(shell: String) -> [String] {
    ManagedTerminalLaunchSpec.localArgv(shell: shell)
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
    onBind: @escaping (ManagedTerminalReference) -> Void
  ) {
    // 受管协调器按 Pane 所属机器取；没有受管引用时落到 Local，行为与 P2/P3 一致。
    let coordinator = ManagedTerminalCoordinatorRegistry.coordinator(for: descriptor.managedTerminal)
    guard coordinator.isEnabled else { return }
    // 描述符**已经带**受管引用时，先同步绑上再去对账。
    //
    // 为什么必须同步：surface 的启动命令在 `makeTerminalHost` 那一刻就定死了——
    // 那时 `managedTerminal` 是 nil 就会起一个**本机 Shell**，之后再 `bindManagedTerminal`
    // 也不会重建 surface。而视图刷新（`WorkspaceViewController.scheduleRefresh`）是合并到
    // 下一轮 runloop 的，几乎总是早于一次 SSH 对账往返完成。实测结果就是：远端投影出来的
    // Pane 挂着一个本机 Shell，显示桥 `ssh … terminal attach` 从头到尾没启动过
    // （P4 §6.8 里「ps 采样不到 terminal attach」的根因）。
    // 引用本身来自服务端权威快照或持久化布局，同步采信它是安全的：对账失败会走
    // `markManagedFailure` 明确报错，不会退化成一个未标识的本机 Shell。
    if let existing = descriptor.managedTerminal { session.bindManagedTerminal(existing) }
    // 绑定要么查服务端真实状态、要么创建远端终端，两者在 P3 都可能是 SSH 往返。
    // 必须异步执行：在 MainActor 上同步等待会让新建 Pane 时整个界面随网络延迟卡住。
    Task { @MainActor in
      await bindAsync(
        session: session, descriptor: descriptor, isRestored: isRestored, shell: shell,
        onBind: onBind)
    }
  }

  /// 绑定的异步实现。全部服务查询都在这里完成，调用方不阻塞主线程。
  private static func bindAsync(
    session: TerminalSession,
    descriptor: PaneDescriptor,
    isRestored: Bool,
    shell: String,
    onBind: @escaping (ManagedTerminalReference) -> Void
  ) async {
    let coordinator = ManagedTerminalCoordinatorRegistry.coordinator(for: descriptor.managedTerminal)

    if let existing = descriptor.managedTerminal {
      // 重开 App 必须查服务端真实状态；持久化的引用本身不是运行证据。
      let resolution = await coordinator.reconcileAsync(
        references: [existing], persistedServerEpoch: nil)[existing]
      switch resolution {
      case .attached:
        session.bindManagedTerminal(existing)
        noteCapabilityLimitations(session: session, coordinator: coordinator)
      case .exited(let status):
        let code = status.exitCode.map(String.init) ?? L("未知")
        session.markManagedFailure(
          L("受管终端已退出（exit \(code)）。"))
      case .serverRestarted:
        session.markManagedFailure(L("后台会话服务已重启，原终端实例不再有效。点击「重新启动 Shell」恢复。"))
      case .missing:
        session.markManagedFailure(L("后台会话服务中找不到该终端（服务可能已重启）。点击「重新启动 Shell」恢复。"))
      case .unreachable(_, let reason):
        session.markManagedFailure(L("无法连接后台会话服务：\(reason)"))
      case nil:
        session.markManagedFailure(L("受管终端状态未知。"))
      }
      return
    }

    // 旧布局的非受管 Pane 保持原样，等待显式迁移。
    guard !isRestored else { return }

    // cwd 与 Shell 属于**执行机器**：协调器是 SSH 传输时，本机 Pane 目录与本机 `$SHELL`
    // 在远端都可能不存在（修 §6.9）。两条路径共用同一个入口，不再各拼一份。
    let launch = ManagedTerminalLaunchSpec.resolve(
      coordinator: coordinator,
      localWorkingDirectory: descriptor.workingDirectory,
      localShell: shell)

    do {
      let status = try await coordinator.createTerminalAsync(
        workingDirectory: launch.workingDirectory,
        argv: launch.argv
      )
      session.bindManagedTerminal(status.reference)
      noteCapabilityLimitations(session: session, coordinator: coordinator)
      onBind(status.reference)
    } catch {
      session.markManagedFailure(String(describing: error))
    }
  }

  /// 握手成功后把服务端缺失的可选能力提示出来，避免用户以为对应动作是坏了。
  private static func noteCapabilityLimitations(
    session: TerminalSession,
    coordinator: ManagedTerminalCoordinator
  ) {
    guard let message = coordinator.unavailableCapabilityMessage else { return }
    session.noteManagedCapabilityLimitation(message)
  }
}
