import AsterCore
import Foundation

/// 按机器实例化受管终端协调器的注册表（P4.2）。
///
/// P2/P3 的 `ManagedTerminalCoordinator.shared` 是**进程级单端点单例**。远程工作模式
/// 下同时存在多台机器的受管终端，远端 Pane 若继续拿本机协调器对账，就会把远端引用与
/// 本机服务比对，结果必然是「找不到该终端」，Pane 被误判成已结束。
///
/// 两条硬约束（A08 保活的前提，不能动）：
/// 1. Local 机器**必须**继续返回 `ManagedTerminalCoordinator.shared` 本身，包括测试
///    替换 `shared` 之后——不缓存、不复制，读的永远是当前的 `shared`。
/// 2. 没有机器引用、机器不存在、或远端运行时未配置时，一律回落到 Local 协调器，
///    行为与今天完全一致；这里绝不抛错，也绝不返回 nil。
@MainActor
enum ManagedTerminalCoordinatorRegistry {
  /// 远端机器的协调器缓存。Local 不进这张表。
  private static var remote: [UUID: ManagedTerminalCoordinator] = [:]

  /// 远端协调器工厂。生产环境按机器配置 + 环境变量构造 SSH 协调器；测试注入替身。
  static var factory: (UUID) -> ManagedTerminalCoordinator? = { defaultFactory($0) }

  /// 取某台机器的协调器。
  static func coordinator(forMachine machineProfileID: UUID) -> ManagedTerminalCoordinator {
    guard machineProfileID != MachineProfile.localProfileID else {
      return ManagedTerminalCoordinator.shared
    }
    if let cached = remote[machineProfileID] { return cached }
    guard let made = factory(machineProfileID) else { return ManagedTerminalCoordinator.shared }
    remote[machineProfileID] = made
    return made
  }

  /// 按受管终端引用取协调器。引用缺失时落到 Local。
  static func coordinator(for reference: ManagedTerminalReference?) -> ManagedTerminalCoordinator {
    guard let reference else { return ManagedTerminalCoordinator.shared }
    return coordinator(forMachine: reference.server.machineProfileID)
  }

  /// 显式登记一台机器的协调器。测试与真实机器装载都走它，避免重复握手。
  static func register(_ coordinator: ManagedTerminalCoordinator, for machineProfileID: UUID) {
    guard machineProfileID != MachineProfile.localProfileID else { return }
    remote[machineProfileID] = coordinator
  }

  /// 清空远端缓存。只用于测试与机器配置整体重载；Local 不受影响。
  static func reset() { remote.removeAll() }

  /// 生产工厂：把机器配置翻译成一份「只覆盖运行时四个键」的环境。
  ///
  /// 覆盖而不是新建整份环境：`RemoteSSHPolicy.fromEnvironment` 还要读用户的 SSH 策略
  /// 变量，凭空造一份空环境会把这些设置全部丢掉。
  private static func defaultFactory(_ machineProfileID: UUID) -> ManagedTerminalCoordinator? {
    guard
      let profile = MachineFleetModel.shared.profiles.first(where: { $0.id == machineProfileID }),
      let target = profile.sshTarget, !target.isEmpty
    else { return nil }
    var environment = ProcessInfo.processInfo.environment
    // 运行时位置：环境变量覆盖优先，否则用设置事务写进机器配置的实测值。
    guard
      let runtime = try? RemoteRuntimeLocation.resolve(profile: profile, environment: environment)
    else { return nil }
    environment[ManagedTerminalCoordinator.binaryEnvironmentKey] = runtime.binaryPath
    environment[ManagedTerminalCoordinator.stateDirectoryEnvironmentKey] = runtime.stateParentPath
    environment[ManagedTerminalCoordinator.sessionNameEnvironmentKey] = profile.sessionName
    environment[ManagedTerminalCoordinator.remoteTargetEnvironmentKey] = target
    return ManagedTerminalCoordinator(
      environment: environment, machineProfileID: machineProfileID)
  }
}
