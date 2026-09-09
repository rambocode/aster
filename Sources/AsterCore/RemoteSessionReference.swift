import Foundation

/// 远程工作模式的稳定资源引用与客户端连接状态值类型。
///
/// 依据 `docs/developer/remote-work.md` §3.3：跨机器引用只能由
/// `(machineProfileID, serverID, sessionID, paneID/terminalID)` 组成；hostname、端口、
/// 显示名和 PID 都不能单独作为资源身份。`serverEpoch` 只用于并发/事件校验与诊断，
/// 不参与身份判等，所以本文件把它与身份字段分开建模。

/// 客户端侧机器配置的最小模型。P2 只使用 Local；远端字段在 P3/P4 扩展。
///
/// 配置目录是这些字段的权威位置，且不保存任何凭据（密码、私钥、临时 socket 路径）。
public struct MachineProfile: Codable, Equatable, Sendable, Identifiable {
  /// 本地执行机器使用的固定配置 ID，保证旧数据升级后引用稳定。
  public static let localProfileID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

  public let id: UUID
  /// 用户可见标签；重命名只改这里，不触发重连。
  public var label: String
  /// 原始 SSH target 文本；Local 为 nil。不做二次 Shell 解释。
  public var sshTarget: String?
  /// 该配置绑定的命名会话；一个配置只绑定一个会话，不隐式汇总主机上全部会话。
  public var sessionName: String
  public var enabled: Bool

  public init(
    id: UUID = UUID(),
    label: String,
    sshTarget: String? = nil,
    sessionName: String = "default",
    enabled: Bool = true
  ) {
    self.id = id
    self.label = label
    self.sshTarget = sshTarget
    self.sessionName = sessionName
    self.enabled = enabled
  }

  /// 本地默认配置。P2 只向专用测试配置开放受管终端，默认终端策略保持不变。
  public static func local(sessionName: String = "default") -> MachineProfile {
    MachineProfile(
      id: localProfileID,
      label: "Local",
      sshTarget: nil,
      sessionName: sessionName,
      enabled: true
    )
  }
}

/// 一个具体后台会话服务实例的身份。
///
/// `serverID` 持久、`sessionID` 由服务端握手返回；两者共同定位资源。
public struct SessionServerReference: Codable, Equatable, Hashable, Sendable {
  public var machineProfileID: UUID
  public var serverID: String
  public var sessionID: String

  public init(machineProfileID: UUID, serverID: String, sessionID: String) {
    self.machineProfileID = machineProfileID
    self.serverID = serverID
    self.sessionID = sessionID
  }
}

/// 指向后台服务中某个受管终端的稳定引用。
///
/// `terminalID` 与进程生命周期绑定：冷恢复产生新进程时必须换新 ID，所以本类型
/// 不能用来证明原进程仍存活；存活与否由 `ManagedTerminalStatus` 的实测结果决定。
public struct ManagedTerminalReference: Codable, Equatable, Hashable, Sendable {
  public var server: SessionServerReference
  public var terminalID: String

  public init(server: SessionServerReference, terminalID: String) {
    self.server = server
    self.terminalID = terminalID
  }
}

/// 客户端连接状态。终端退出不得表示成整机离线，所以与 `ManagedTerminalState` 分开。
public enum SessionConnectionState: String, Codable, Sendable, CaseIterable {
  case disconnected
  case connecting
  case online
  case reconnecting
  case attention
  case disabled
}

/// 受管终端的运行状态；`unavailable` 表示服务或引用已失效，不等于进程已退出。
public enum ManagedTerminalState: String, Codable, Sendable, CaseIterable {
  case running
  case exited
  case unavailable
}

/// 服务端查询回来的受管终端真实状态。
///
/// 重开 App 后必须用这个结构展示真实情况，不能用本地持久化的最后一次状态冒充。
public struct ManagedTerminalStatus: Codable, Equatable, Sendable {
  public var reference: ManagedTerminalReference
  public var state: ManagedTerminalState
  /// 服务端上报的受管进程 PID。仅用于验收证据与诊断，不作为资源身份。
  public var pid: Int32?
  public var cwd: String?
  public var exitCode: Int32?
  /// 服务实例本次启动的 epoch；与持久化记录不同即表示服务已冷重启。
  public var serverEpoch: String?

  public init(
    reference: ManagedTerminalReference,
    state: ManagedTerminalState,
    pid: Int32? = nil,
    cwd: String? = nil,
    exitCode: Int32? = nil,
    serverEpoch: String? = nil
  ) {
    self.reference = reference
    self.state = state
    self.pid = pid
    self.cwd = cwd
    self.exitCode = exitCode
    self.serverEpoch = serverEpoch
  }
}

/// 受管终端的结束原因。分离与结束必须能被区分，录制层据此决定是否写结束事件。
public enum ManagedTerminalDisposition: String, Codable, Sendable {
  /// 客户端分离：释放租约与订阅，服务端进程和布局保留。
  case detached
  /// 显式结束该资源：结束远端进程。
  case terminated
}
