import Foundation
import Testing

@testable import Aster

// P4 真机验收的原生 SSH 开关：`ASTER_P4_NATIVE=1` 时先拉起 aster-ssh broker 并发布端点，
// 之后生产传输工厂读到的就是原生引擎，同一批真机用例因此能在两种引擎下各跑一遍。
// 需要同时用 `ASTER_SSH_BINARY` 指向已构建的 aster-ssh（scripts/build-ssh-runtime.sh）。

/// 按环境变量决定是否在真机用例前启用原生 SSH 引擎。
@MainActor
enum RemoteWorkP4NativeEngine {
  /// 开关打开时拉起 broker 并等待 ready；关闭时什么都不做，用例走 OpenSSH。
  static func startIfRequested() async throws {
    guard ProcessInfo.processInfo.environment["ASTER_P4_NATIVE"] == "1" else { return }
    let supervisor = SSHBrokerSupervisor.shared
    supervisor.start(preferredEngine: .native)
    try await supervisor.waitUntilReady()
    #expect(supervisor.engine == .native, "原生引擎没有启用，用例会退回 OpenSSH")
  }
}
