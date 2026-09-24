import AsterCore
import Foundation
import os

// 当前生效的 SSH 引擎路由：原生端点的线程安全快照。
// 传输工厂分布在 MainActor（受管终端协调器）与后台 actor（机器连接驱动）两侧，
// 都从这里读，而不是各自去问 MainActor 上的 broker 监管者。

/// 原生端点快照。nil 表示走 OpenSSH（引擎为 openssh，或 native 回退）。
final class SSHEngineRouting: Sendable {
  /// App 进程共享的路由；只有 `SSHBrokerSupervisor.shared` 写它，测试用独立实例。
  static let shared = SSHEngineRouting()

  private let state = OSAllocatedUnfairLock<NativeSSHEndpoint?>(initialState: nil)

  /// 当前原生端点。端点（可执行文件 + socket 路径）在一个 App 进程内保持不变，
  /// broker 崩溃重启也沿用同一 socket，因此已经写进 Pane 命令行的桥仍然有效。
  var nativeEndpoint: NativeSSHEndpoint? { state.withLock { $0 } }

  /// 发布或撤销原生端点。
  func publish(_ endpoint: NativeSSHEndpoint?) {
    state.withLock { $0 = endpoint }
  }
}
