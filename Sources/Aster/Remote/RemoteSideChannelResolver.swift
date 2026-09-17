// 把 Pane 的远端上下文翻译成可执行的旁路通道。两种场景的差异只在这里收敛一次。

import AsterCore
import Foundation

/// `RemoteInspectionContext` → `RemoteSideChannel`。
///
/// 通道本身是 `Sendable` 的值，解析在主线程完成（需要读受管协调器），真正的阻塞
/// 调用都发生在 `RemoteInspectionService` 的 detached 任务里。
enum RemoteSideChannelResolver {
  /// 通道标识。控制器拿它做目录缓存、CPU 差分样本与迟到结果的身份校验。
  ///
  /// 场景 A 的 key 是 argv 摘要，算法在 `AsterCore` 内部。这里刻意**不重算一遍哈希**，
  /// 而是用工厂造一个只读身份的通道实例：两边算法一旦分叉，就会把两台机器的缓存
  /// 和差分样本混在一起。工厂本身只装配闭包，不建立任何连接；`controlDirectory`
  /// 不参与 key，所以这里传占位值也不影响结果。
  static func channelKey(for context: RemoteInspectionContext) -> String {
    switch context {
    case .ssh(let invocation, let endpoint):
      return RemoteSideChannel.ssh(
        invocation: invocation,
        controlDirectory: SSHControlDirectory.defaultPath,
        label: endpoint.hostName
      ).identity.key
    case .managed(let reference, _, _):
      return "managed:" + managedProfileKey(for: reference)
    }
  }

  /// 受管终端的通道键：机器 + 服务实例。同一台机器换服务实例后连接参数也变了，
  /// 因此 serverID 必须参与，否则重装服务后仍会命中旧缓存。
  private static func managedProfileKey(for reference: ManagedTerminalReference) -> String {
    "\(reference.server.machineProfileID.uuidString):\(reference.server.serverID)"
  }

  /// 解析出可用的旁路通道；任何前置条件不满足都返回 nil，由调用方显示「无法建立远端旁路连接」。
  @MainActor
  static func resolve(_ context: RemoteInspectionContext) -> RemoteSideChannel? {
    switch context {
    case .ssh(let invocation, let endpoint):
      // 场景 A 完全依赖 ControlMaster socket 目录：目录校验不过就放弃复用，
      // 绝不降级去建一条新的交互连接（那会在后台弹口令提示）。
      guard let controlDirectory = SSHControlDirectory.prepare() else { return nil }
      return RemoteSideChannel.ssh(
        invocation: invocation,
        controlDirectory: controlDirectory,
        label: endpoint.hostName
      )
    case .managed(let reference, let label, _):
      let coordinator = ManagedTerminalCoordinatorRegistry.coordinator(for: reference)
      guard let transport = coordinator.remoteTransport else { return nil }
      return RemoteSideChannel.managed(
        transport: transport,
        profileKey: managedProfileKey(for: reference),
        label: label
      )
    }
  }

  /// 判定 ControlMaster socket 是否已存在且可用（`ssh -O check`）。
  ///
  /// 结果只用于诊断与失败归类：返回 false 时仍然允许尝试真正的调用，因为用户可能
  /// 刚刚建立连接、socket 还没落盘。阻塞调用，必须在后台任务里跑。
  static func controlMasterIsAvailable(_ channel: RemoteSideChannel) -> Bool {
    guard let arguments = channel.controlCheckArguments else {
      // 场景 B 自带私有配置与复用策略，没有需要探测的外部 socket。
      return true
    }
    guard let result = try? channel.runner.run(arguments: arguments, timeout: 5) else {
      return false
    }
    return result.exitStatus == 0
  }
}
