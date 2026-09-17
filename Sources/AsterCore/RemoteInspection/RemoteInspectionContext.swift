// 详情面板远端模式的上下文取值。只描述「这个 Pane 连到哪台远端、怎么复用连接」，
// 不持有任何 AppKit 对象或连接资源，便于跨隔离边界传递与在测试中构造。

import Foundation

/// 一个 Pane 当前所处的远端上下文。
///
/// 两种来源互斥：
/// - `ssh`：本地 Pane 里用户手敲 `ssh …`（场景 A）。旁路连接靠用户原始 argv +
///   ControlMaster 复用，因此必须同时带上原始 invocation 与 `ssh -G` 解析结果。
/// - `managed`：远程工作模式的受管远端终端（场景 B）。旁路连接由受管传输提供，
///   `pid` 是服务端上报的远端 Shell 进程号，用于 `readlink /proc/<pid>/cwd` 兜底。
public enum RemoteInspectionContext: Equatable, Sendable {
  case ssh(invocation: SSHCommandInvocation, endpoint: SSHResolvedEndpoint)
  case managed(reference: ManagedTerminalReference, label: String, pid: Int32?)

  /// 界面上标识远端的显示名。场景 A 用 `ssh -G` 解析出的最终主机名，场景 B 用机器标签。
  public var displayLabel: String {
    switch self {
    case .ssh(_, let endpoint): endpoint.hostName
    case .managed(_, let label, _): label
    }
  }
}
