import AsterCore
import Foundation

/// 远端设置/连接错误的展示文案（App 侧）。
///
/// `RemoteMachineSetup` 里的同名工具是 `internal`，不属于 App 模块可见范围；这里按
/// 同一语义重建一份，规则不变：文案可直接展示、不含凭据、不承诺自动重试。
enum RemoteSetupDescription {
  /// 任意错误的展示文本。
  static func text(for error: any Error) -> String {
    if let failure = error as? RemoteSetupFailure { return failure.message }
    if let target = error as? RemoteSSHTargetError { return targetText(target) }
    if let ssh = error as? RemoteSSHError { return L("ssh \(ssh.kind.rawValue)：\(ssh.target)") }
    if let managed = error as? ManagedSessionError { return managedText(managed) }
    if let fleet = error as? MachineFleetError {
      switch fleet {
      case .machineNotFound: return L("机器配置不存在。")
      case .localNotRemovable: return L("Local 不能移除。")
      }
    }
    return String(describing: error)
  }

  /// target 校验失败的说明。全部发生在建立连接之前。
  static func targetText(_ error: RemoteSSHTargetError) -> String {
    switch error {
    case .empty: L("SSH target 不能为空。")
    case .optionLike(let text): L("SSH target «\(text)» 以 - 开头，会被当成 ssh 选项，已在连接前拒绝。")
    case .unsupportedCharacter(let character):
      L("SSH target 含不允许的字符 «\(character)»，已在连接前拒绝。")
    case .invalidURI(let text): L("ssh:// URI 结构非法：\(text)")
    case .invalidPort(let text): L("端口非法：\(text)，必须是 1–65535。")
    case .missingHost: L("SSH target 缺少主机段。")
    }
  }

  /// 会话客户端错误的说明。
  static func managedText(_ error: ManagedSessionError) -> String {
    switch error {
    case .runtimeUnavailable(let text): return text
    case .serviceError(let code, let message):
      let suffix = message.map { "：\($0)" } ?? ""
      return L("\(String(code))\(suffix)")
    case .malformedReply(let text): return L("回复格式非法：\(text)")
    case .commandFailed(let status, let output): return L("命令失败（\(String(status))）：\(output)")
    case .launchFailed(let text): return L("启动失败：\(text)")
    }
  }
}

/// 受管/远端模式的环境变量键。
///
/// `ManagedTerminalCoordinator` 上的同名常量绑定 MainActor，无法在非隔离的连接服务里
/// 使用；这里集中一份纯值定义，两处必须保持相同字面量。
enum RemoteEnvironmentKeys {
  static let binary = "ASTER_SESSION_BINARY"
  static let stateDirectory = "ASTER_SESSION_STATE_DIR"
  static let sessionName = "ASTER_SESSION_NAME"
  /// 本地自定义服务产物；安装前同样检查平台、协议与摘要，并标为开发产物。
  static let remoteBinary = "ASTER_REMOTE_BINARY"
  static let remoteTarget = "ASTER_REMOTE_SSH_TARGET"
}
