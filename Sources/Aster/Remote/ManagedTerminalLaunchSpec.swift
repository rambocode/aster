import AsterCore
import Foundation

/// 受管终端「在哪台机器上、用什么启动」的**唯一**生成入口（P4，修 §6.9）。
///
/// 为什么要收敛成一个入口：cwd 与 Shell 都是**执行机器**上的东西。仓库里原本有两条
/// 各自拼装的路径——机器侧栏事务（`RemoteWorkspaceCoordinator.terminalSpec`）和
/// Pane 绑定（`ManagedTerminalBinder`）。前者修过「不要发本机 `$SHELL`」，后者没有，
/// 于是进程级设置 `ASTER_REMOTE_SSH_TARGET` 时，Local 初始标签会把本机 cwd
/// （`/Users/…`）与本机登录 Shell（`/opt/homebrew/bin/zsh`）发到 Linux 远端，
/// 服务端要么 `cwd_unavailable`、要么 exec 失败。
///
/// 规则只有两条：
/// 1. 传输面是本机 → 用本机 cwd 与本机 `$SHELL`（P2/P3 的 A08 语义一个字节不改）。
/// 2. 传输面是 SSH → cwd 只能来自远端（服务端上报的目录，没有就用 POSIX 保证存在的
///    `/`），Shell 只能由远端自己决定（远端 `$SHELL`，没有就 `/bin/sh`）。
@MainActor
enum ManagedTerminalLaunchSpec {
  /// 一次受管终端创建要发给执行机器的参数。
  struct Resolved: Equatable {
    var workingDirectory: String
    var argv: [String]
  }

  /// 远端受管终端在拿不到服务端 cwd 时的兜底目录。
  ///
  /// 只用 `/`：它是 POSIX 上唯一保证存在且服务端一定能校验通过的目录，而任何本机路径
  /// 在远端都可能不存在。真正的落脚点由 argv 里的 `cd "$HOME"` 在远端完成。
  static let remoteRootDirectory = "/"

  /// 本机受管终端的登录 Shell argv。与本地终端一致，保证行为可比。
  static func localArgv(shell: String) -> [String] {
    switch URL(fileURLWithPath: shell).lastPathComponent {
    case "bash": [shell, "--login", "-i"]
    case "fish": [shell, "--login", "--interactive"]
    default: [shell, "-l", "-i"]
    }
  }

  /// 远端受管终端的 argv。
  ///
  /// **绝不能**照抄本机 `$SHELL`：那是本机上的一个路径，在执行机器上未必存在
  /// （本机 zsh、远端只有 bash 是常态），服务端会直接启动失败。
  /// 因此用 POSIX 保证存在的 `/bin/sh` 引导，再 exec **远端用户自己的**登录 Shell，
  /// 形状仍然是登录 + 交互，与本地终端可比。
  ///
  /// - Parameter landsInHome: 调用方没有权威 cwd 时为 true。此时服务端拿到的是 `/`，
  ///   再由远端 shell 自己 `cd "$HOME"`——把落脚点的决定权完全留在远端，既不需要多一次
  ///   SSH 往返探测 `$HOME`，也不会因为本机与远端的家目录路径不同而落错地方。
  ///   `cd` 失败时留在 `/`，不因此让整个终端启动失败。
  static func remoteArgv(landsInHome: Bool) -> [String] {
    let launch = "exec \"${SHELL:-/bin/sh}\" -l -i"
    return ["/bin/sh", "-lc", landsInHome ? "cd \"$HOME\" 2>/dev/null; \(launch)" : launch]
  }

  /// 远端「以 Agent 身份开标签」的 argv：登录 Shell 里先跑该 CLI，退出后接着 `exec` 用户的
  /// 登录交互 Shell。
  ///
  /// 走登录 Shell 而不是直接 exec 绝对路径：CLI 的位置（`~/.local/bin`、nvm、brew）只有远端
  /// 的 rc 文件知道，服务端也不该替用户猜 PATH。Agent 退出后不结束终端而是落回 Shell：
  /// 用户可以直接在远端继续工作，不想要了敲 `exit` 关掉；否则只剩一张"远端进程已结束"。
  /// 命令名按 POSIX 单引号编码，不经二次解释。
  static func remoteAgentArgv(command: String, arguments: [String] = [], landsInHome: Bool)
    -> [String]
  {
    let quoted = ([command] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let launch = quoted.joined(separator: " ") + "; exec \"${SHELL:-/bin/sh}\" -l -i"
    return ["/bin/sh", "-lc", landsInHome ? "cd \"$HOME\" 2>/dev/null; \(launch)" : launch]
  }

  /// 机器侧栏事务用的规格：cwd 一定来自服务端快照，因此不再 `cd $HOME`。
  static func remoteSpec(cwd: String) -> RemoteTerminalSpec {
    RemoteTerminalSpec(cwd: cwd, argv: remoteArgv(landsInHome: false))
  }

  /// Pane 绑定用的规格：按协调器的真实传输面二选一。
  ///
  /// 判定依据是 `coordinator.isRemote`（传输实现），不是机器 ID：P3 的兼容形态下
  /// `ManagedTerminalCoordinator.shared` 本身就可能是 SSH 协调器，而它的
  /// `machineProfileID` 仍是 Local。按机器 ID 判会漏掉正是出问题的那条路径。
  static func resolve(
    coordinator: ManagedTerminalCoordinator,
    localWorkingDirectory: String,
    localShell: String
  ) -> Resolved {
    guard coordinator.isRemote else {
      return Resolved(workingDirectory: localWorkingDirectory, argv: localArgv(shell: localShell))
    }
    return Resolved(
      workingDirectory: remoteRootDirectory, argv: remoteArgv(landsInHome: true))
  }
}
