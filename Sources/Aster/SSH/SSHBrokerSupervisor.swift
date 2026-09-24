import AsterCore
import Foundation

// aster-ssh broker 的生命周期与控制通道（P0 骨架：接口已定，实现由引擎接入包补全）。

/// broker 不可用的原因。
enum SSHBrokerError: Error, Equatable {
  /// 找不到 aster-ssh 可执行文件。
  case executableMissing
  /// broker 启动失败或未在超时内报告 ready。
  case startFailed(String)
}

/// aster-ssh broker 监管者。每个 App 实例一个。
@MainActor
final class SSHBrokerSupervisor {
  static let shared = SSHBrokerSupervisor()

  /// 当前引擎：环境变量 `ASTER_SSH_ENGINE` 优先，其次设置项；由 App 在偏好变化时更新。
  var engine: SSHEngine = .native

  /// 定位 aster-ssh：`ASTER_SSH_BINARY` → App 包 `Contents/MacOS/aster-ssh` →
  /// 开发构建 `SshRuntime/target/{release,debug}/aster-ssh`。
  static func executableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
  ) -> URL? {
    let fileManager = FileManager.default
    if let override = environment["ASTER_SSH_BINARY"], fileManager.isExecutableFile(atPath: override) {
      return URL(fileURLWithPath: override)
    }
    let bundled = bundle.bundleURL.appendingPathComponent("Contents/MacOS/aster-ssh")
    if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
    return nil
  }

  /// 返回可用的原生端点，必要时拉起 broker。引擎为 openssh 时调用方不应走到这里。
  func nativeEndpoint() throws -> NativeSSHEndpoint {
    throw SSHBrokerError.executableMissing
  }

  /// 读取 `~/.ssh/config` 解析结果（`aster-ssh config list --json`）。
  func configListing() async throws -> SSHConfigListing {
    throw SSHBrokerError.executableMissing
  }

  /// 把最新主机规格推给 broker（`profiles.sync`）。broker 未运行时忽略。
  func syncProfiles() {}
}
