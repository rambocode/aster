import Foundation

/// 场景 A（用户在本地 Pane 手敲 `ssh host`）的旁路 argv 构造。
///
/// 与 `RemoteSSHInvocation` 的分工：后者要求已校验的 `RemoteSSHTarget`，只服务远程
/// 工作模式；本类型直接复用**用户原始 argv 前缀**（`SSHCommandInvocation.configurationArguments`，
/// 截止到 destination），因此用户写的 `-p/-i/-J/-F` 全部原样生效，旁路连接与前台
/// 交互连接落在同一个 `%C` 连接哈希上，可以命中同一个 ControlMaster socket。

/// ControlMaster 目录的取值策略。socket 完整路径受 `sockaddr_un` 104 字节限制，
/// 因此目录必须短且固定在 `/tmp` 下，不能用 `$TMPDIR`（macOS 下是很长的随机路径）。
public enum SSHControlDirectoryPolicy {
  /// 目录路径上限（字节）。`%C` 展开是 64 位十六进制摘要（64 字符），加上分隔符后
  /// 仍需落在 104 字节以内，所以目录本身限制在 64 字节。
  public static let maximumPathBytes = 64

  /// 校验 ControlMaster 目录路径是否可用。失败时调用方放弃复用，不做修复。
  public static func validate(path: String) -> Bool {
    guard !path.isEmpty, path.utf8.count <= maximumPathBytes else { return false }
    guard path.hasPrefix("/tmp/"), path.count > "/tmp/".count else { return false }
    guard !path.hasSuffix("/") else { return false }
    // 控制字符会破坏 argv 与日志，也说明路径来源不可信。
    return path.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }
}

/// 复用既有 ControlMaster socket 的一次旁路 `ssh` 调用描述。
public struct SSHControlPathInvocation: Equatable, Sendable {
  /// 用户原始 argv 从第 1 个 token 到 destination（含）为止。
  public let configurationArguments: [String]
  /// ControlMaster socket 所在目录。
  public let controlDirectory: String

  public init(configurationArguments: [String], controlDirectory: String) {
    self.configurationArguments = configurationArguments
    self.controlDirectory = controlDirectory
  }

  /// 旁路固定选项。
  ///
  /// 必须**前置**：OpenSSH 命令行上同一关键字取首次出现的值，放在用户 argv 之前
  /// 才能保证旁路永远不当 master、永远非交互、永远有短超时；用户自己写的同名选项
  /// 由此被我们覆盖，而其余选项（`-p`、`-i`、`-J`、`-F`）仍然原样生效。
  /// `ControlMaster=no` 只是不创建 master，仍然会连接已存在的 socket，这正是复用所需。
  private var optionPrefix: [String] {
    [
      "-o", "ControlMaster=no",
      "-o", "ControlPath=\(controlDirectory)/%C",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=5",
      "-o", "ServerAliveInterval=5",
    ]
  }

  /// 生成执行远端命令的 argv。远端命令整体做 POSIX 单引号转义后作为一个参数追加，
  /// 因为 OpenSSH 必然把它交给远端登录 Shell。
  public func arguments(remoteCommand: [String]) -> [String] {
    var argv = optionPrefix
    argv += configurationArguments
    if !remoteCommand.isEmpty {
      argv.append(RemoteSSHInvocation.shellQuoted(remoteCommand))
    }
    return argv
  }

  /// 生成 `-O check` 的 argv：用于判定复用 socket 是否已存在且可用。
  ///
  /// `-O` 是控制命令，不执行远端命令，因此不追加 remoteCommand。
  public func checkArguments() -> [String] {
    optionPrefix + ["-O", "check"] + configurationArguments
  }
}
