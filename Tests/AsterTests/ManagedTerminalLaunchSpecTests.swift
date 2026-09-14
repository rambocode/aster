import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// P4 §6.9 的回归：进程级设置 `ASTER_REMOTE_SSH_TARGET` 时，Local 初始标签走的是
// `ManagedTerminalCoordinator.shared`；它此时是一个 **SSH 协调器**，因此发给服务端的
// `terminal create` 参数里绝不能出现本机 cwd 或本机 `$SHELL`。
//
// 设计判断（为什么不是「Local 标签根本不走远端路径」）：
// `ManagedTerminalCoordinator.shared` 的传输面由**进程环境**决定，这正是 P3 的形态
// （A10–A12：整个 App 通过一个进程级 SSH target 连到远端，Local 标签就是那台远端上的
// 受管终端）。若改成「machineProfileID == Local 就强制走本机传输」，P3 已验收的整条
// 链路会当场失效。因此正确的修法是：**按传输面而不是按机器 ID 决定 cwd/Shell 的归属**，
// 并把这条规则收敛到 `ManagedTerminalLaunchSpec` 这一个入口，让机器侧栏路径与 Pane
// 绑定路径不再分叉。

/// 一个 SSH 传输的协调器，机器身份仍是 Local——正是出问题的那条路径。
@MainActor
private func makeProcessLevelRemoteCoordinator() -> ManagedTerminalCoordinator {
  ManagedTerminalCoordinator(
    environment: [
      RemoteEnvironmentKeys.remoteTarget: "root@ubuntu@orb",
      RemoteEnvironmentKeys.binary: "/root/.local/state/aster-test/spec/bin/aster-session",
      RemoteEnvironmentKeys.stateDirectory: "/root/.local/state/aster-test/spec/state",
      RemoteEnvironmentKeys.sessionName: "launchspec",
      // 不生成私有临时 SSH 配置：本用例只看参数拼装，不建立任何连接。
      RemoteSSHPolicy.manageSSHConfigEnvironmentKey: "0",
    ],
    machineProfileID: MachineProfile.localProfileID)
}

@Test("managedTerminalLaunchSpec：进程级 SSH target 下 Local 标签的 terminal create 不含本机路径与本机 $SHELL")
@MainActor
func managedTerminalLaunchSpecKeepsLocalPathsOffRemoteCreate() throws {
  let coordinator = makeProcessLevelRemoteCoordinator()
  #expect(coordinator.isRemote, "进程级 ASTER_REMOTE_SSH_TARGET 必须让 shared 变成 SSH 协调器")
  let endpoint = try #require(coordinator.endpoint)

  // Local 初始标签的真实输入：本机 Pane 目录 + 本机登录 Shell。
  let localWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  let localShell = "/opt/homebrew/bin/zsh"
  let launch = ManagedTerminalLaunchSpec.resolve(
    coordinator: coordinator,
    localWorkingDirectory: localWorkingDirectory,
    localShell: localShell)

  // 断言落在**真正发出去的 argv** 上，而不是中间结构：这才是 §6.9 里被 ps 抓到的东西。
  let arguments = ManagedSessionCommand.terminalCreate(
    endpoint, workingDirectory: launch.workingDirectory, argv: launch.argv)
  let commandLine = arguments.joined(separator: " ")

  #expect(!commandLine.contains(localWorkingDirectory), "远端 create 不得携带本机 cwd：\(commandLine)")
  #expect(!commandLine.contains(localShell), "远端 create 不得携带本机 $SHELL：\(commandLine)")
  #expect(!commandLine.contains("/Users/"), "远端 create 不得出现任何本机 home 路径：\(commandLine)")
  #expect(!commandLine.contains("/opt/homebrew/"), "远端 create 不得出现任何本机 Homebrew 路径：\(commandLine)")

  // cwd 只能是 POSIX 保证存在的根目录；落脚点交给远端自己的 $HOME。
  #expect(launch.workingDirectory == "/")
  #expect(launch.argv.first == "/bin/sh")
  let script = try #require(launch.argv.last)
  #expect(script.contains("cd \"$HOME\""), "落脚目录必须由远端展开：\(script)")
  #expect(script.contains("${SHELL:-/bin/sh}"), "Shell 必须由远端决定：\(script)")
}

@Test("managedTerminalLaunchSpec：本机协调器仍用本机 cwd 与本机 $SHELL，A08 语义不变")
@MainActor
func managedTerminalLaunchSpecKeepsLocalTransportUnchanged() throws {
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      RemoteEnvironmentKeys.binary: "/tmp/aster/bin/aster-session",
      RemoteEnvironmentKeys.stateDirectory: "/tmp/aster/state",
    ],
    machineProfileID: MachineProfile.localProfileID)
  #expect(!coordinator.isRemote)

  let launch = ManagedTerminalLaunchSpec.resolve(
    coordinator: coordinator,
    localWorkingDirectory: "/tmp/work",
    localShell: "/bin/zsh")
  #expect(launch.workingDirectory == "/tmp/work")
  #expect(launch.argv == ["/bin/zsh", "-l", "-i"])
  // 与 P2 起沿用的 `shellArguments` 必须逐字相同：它是 A08 保活用例的启动形状。
  #expect(launch.argv == ManagedTerminalBinder.shellArguments(shell: "/bin/zsh"))
}

@Test("managedTerminalLaunchSpec：机器侧栏事务与 Pane 绑定共用同一份远端启动规则")
@MainActor
func managedTerminalLaunchSpecSharesOneRemoteRule() throws {
  // 侧栏路径有服务端上报的权威 cwd，因此直接用它，不再 cd 到远端 $HOME。
  let spec = ManagedTerminalLaunchSpec.remoteSpec(cwd: "/root/project")
  #expect(spec.cwd == "/root/project")
  #expect(spec.argv == ["/bin/sh", "-lc", "exec \"${SHELL:-/bin/sh}\" -l -i"])

  // 两条路径的 Shell 决策必须是同一份文本，避免再次分叉。
  let bound = ManagedTerminalLaunchSpec.remoteArgv(landsInHome: true)
  #expect(bound.first == spec.argv.first)
  #expect(try #require(bound.last).hasSuffix(try #require(spec.argv.last)))
}

@Test("本机新建 Pane 默认原生 PTY；开关、显式端点或远端机器才自动托管；恢复的 Pane 永不自动托管")
@MainActor
func managedTerminalBinderAutoManagePolicy() {
  // 本机 + 自动解析端点 + 开关关闭 → 原生 PTY。
  #expect(!ManagedTerminalBinder.shouldAutoManage(
    isRestored: false, isLocal: true, endpointIsExplicit: false, localManagedEnabled: false))
  // 用户打开「本机后台保活」→ 托管。
  #expect(ManagedTerminalBinder.shouldAutoManage(
    isRestored: false, isLocal: true, endpointIsExplicit: false, localManagedEnabled: true))
  // 环境变量显式指定端点（测试/开发）→ 托管，不看开关。
  #expect(ManagedTerminalBinder.shouldAutoManage(
    isRestored: false, isLocal: true, endpointIsExplicit: true, localManagedEnabled: false))
  // 远端机器 → 始终托管。
  #expect(ManagedTerminalBinder.shouldAutoManage(
    isRestored: false, isLocal: false, endpointIsExplicit: false, localManagedEnabled: false))
  // 恢复的旧 Pane → 永不自动托管，走显式迁移。
  #expect(!ManagedTerminalBinder.shouldAutoManage(
    isRestored: true, isLocal: false, endpointIsExplicit: true, localManagedEnabled: true))
  // 配置默认值：关闭。
  #expect(ShellConfiguration().resolvedLocalManagedTerminals == false)
}
