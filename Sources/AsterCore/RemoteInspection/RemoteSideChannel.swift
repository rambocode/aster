import CryptoKit
import Foundation

/// 远端巡检旁路通道：在不打扰前台终端的前提下，对同一台远端机器执行只读脚本与文件传输。
///
/// 两个来源共用同一套调用面：
/// - 场景 A（本地 Pane 手敲 `ssh host`）：`SSHControlPathInvocation` 借用前台连接已建立的
///   ControlMaster socket，因此不需要再次认证。
/// - 场景 B（远程工作模式受管终端）：直接复用 `RemoteSessionTransport` 的私有配置。
///
/// 安全边界：远端路径与文件名是不可信输入，只经 `RemoteSSHInvocation.quote` 或 `$1`
/// 位置参数进入远端 Shell，从不参与本地命令行拼接，也从不当作本地路径使用。

/// 旁路通道身份。`key` 用于缓存、CPU 差分样本与迟到结果的身份校验；`label` 只用于界面显示。
public struct RemoteSideChannelIdentity: Hashable, Sendable {
  /// 稳定标识：同一台远端、同一套连接参数必须得到同一个 key。
  public let key: String
  /// 界面显示用的短标签（通常是 host 或机器名）。
  public let label: String

  public init(key: String, label: String) {
    self.key = key
    self.label = label
  }
}

public struct RemoteSideChannel: Sendable {
  public let identity: RemoteSideChannelIdentity
  /// 由远端 argv 生成完整 ssh argv。两种场景的差异全部封在这个闭包里。
  public let sshArguments: @Sendable ([String]) -> [String]
  /// 短命命令执行器（脚本巡检）。
  public let runner: any RemoteSSHRunning
  /// 流式执行器（上传、下载）。
  public let streamRunner: any RemoteSSHStreaming
  /// 复用可用性探测 argv（`ssh -O check`）。只有场景 A 有；场景 B 自带私有配置，无需探测。
  public let controlCheckArguments: [String]?

  public init(
    identity: RemoteSideChannelIdentity,
    sshArguments: @escaping @Sendable ([String]) -> [String],
    runner: any RemoteSSHRunning,
    streamRunner: any RemoteSSHStreaming,
    controlCheckArguments: [String]? = nil
  ) {
    self.identity = identity
    self.sshArguments = sshArguments
    self.runner = runner
    self.streamRunner = streamRunner
    self.controlCheckArguments = controlCheckArguments
  }

  // MARK: - 脚本执行

  /// 在远端执行一段 POSIX sh 脚本。
  ///
  /// 脚本本身是常量，用户数据只经 `arguments` 走 `$1`、`$2`……位置参数，因此远端不存在
  /// 二次解释。argv 里的 `"sh"` 是 `sh -c` 的 `$0`，缺了它第一个参数会被当成 `$0` 丢失。
  ///
  /// 退出码不为 0 **不一定**是失败（远端脚本用 exit 2 表达“目录不存在”这类业务结果），
  /// 因此只有 OpenSSH 自身的 255 才抛错，其余情况交调用方按协议解析。
  public func run(
    script: String,
    arguments: [String] = [],
    timeout: TimeInterval,
    maximumOutputBytes: Int
  ) throws -> RemoteSSHResult {
    let remoteCommand = ["/bin/sh", "-c", script, "sh"] + arguments
    let result = try runner.run(arguments: sshArguments(remoteCommand), timeout: timeout)
    if result.standardOutput.utf8.count > maximumOutputBytes {
      throw RemoteSSHError(
        kind: .transportFailure,
        target: identity.label,
        detail: "远端输出超过 \(maximumOutputBytes) 字节上限"
      )
    }
    if result.exitStatus == 255 {
      throw RemoteSSHError(
        kind: RemoteSSHDiagnostics.classify(
          standardError: result.standardError, exitStatus: result.exitStatus),
        target: identity.label,
        detail: RemoteSSHDiagnostics.redact(result.standardError),
        exitStatus: result.exitStatus
      )
    }
    return result
  }

  // MARK: - 下载

  /// 把远端文件下载到本地路径。
  ///
  /// 先取远端大小再传输：`cat` 本身不会报告长度，只靠流式上限会先写掉几百 MiB 再放弃，
  /// 既浪费带宽也要清理半截文件。落盘先写同目录下的隐藏临时文件，成功后再原子改名，
  /// 保证用户看到的目标文件要么不存在，要么是完整副本。
  public func download(
    remotePath: String,
    to localURL: URL,
    maximumBytes: Int,
    timeout: TimeInterval
  ) throws {
    let sizeResult = try run(
      script: "stat -c %s -- \"$1\" 2>/dev/null || stat -f %z -- \"$1\"",
      arguments: [remotePath],
      timeout: min(timeout, 15),
      maximumOutputBytes: 1024
    )
    guard sizeResult.exitStatus == 0,
      let size = Int(sizeResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw RemoteSSHError(
        kind: .transportFailure, target: identity.label, detail: "远端文件不可读")
    }
    guard size <= maximumBytes else {
      throw RemoteSSHError(
        kind: .transportFailure,
        target: identity.label,
        detail: "远端文件超过 \(maximumBytes) 字节上限"
      )
    }

    let directory = localURL.deletingLastPathComponent()
    let staging = directory.appendingPathComponent(
      ".\(localURL.lastPathComponent).aster-download")
    let remoteCommand = ["/bin/sh", "-c", "exec cat -- \"$1\"", "sh", remotePath]
    let result = try streamRunner.stream(
      arguments: sshArguments(remoteCommand),
      stdinFile: nil,
      stdoutFile: staging,
      maximumBytes: maximumBytes,
      timeout: timeout
    )
    guard result.exitStatus == 0 else {
      // 半截临时文件必须删掉，留着会在下次下载时被当成已有内容。
      try? FileManager.default.removeItem(at: staging)
      throw RemoteSSHError(
        kind: RemoteSSHDiagnostics.classify(
          standardError: result.standardError, exitStatus: result.exitStatus),
        target: identity.label,
        detail: RemoteSSHDiagnostics.redact(result.standardError),
        exitStatus: result.exitStatus
      )
    }
    do {
      if FileManager.default.fileExists(atPath: localURL.path) {
        _ = try FileManager.default.replaceItemAt(localURL, withItemAt: staging)
      } else {
        try FileManager.default.moveItem(at: staging, to: localURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw RemoteSSHError(
        kind: .transportFailure, target: identity.label, detail: "无法写入本地文件")
    }
  }

  // MARK: - 上传

  /// 把本地文件上传到远端目录。
  ///
  /// 写 staging 再 `mv -f` 而不是直接写目标：中途失败（断连、磁盘满）不会留下一个
  /// 半截的同名文件覆盖远端既有内容。`umask 022` 保证新文件权限可预期。
  public func upload(
    localURL: URL,
    toDirectory directory: String,
    fileName: String,
    maximumBytes: Int,
    timeout: TimeInterval
  ) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
    guard let size = (attributes[.size] as? NSNumber)?.intValue else {
      throw RemoteSSHError(kind: .transportFailure, target: identity.label, detail: "本地文件不可读")
    }
    guard size <= maximumBytes else {
      throw RemoteSSHError(
        kind: .transportFailure,
        target: identity.label,
        detail: "本地文件超过 \(maximumBytes) 字节上限"
      )
    }
    let finalPath = RemoteSideChannel.remotePath(directory: directory, name: fileName)
    let stagingPath = RemoteSideChannel.remotePath(
      directory: directory, name: ".\(fileName).aster-upload")

    let remoteCommand = [
      "/bin/sh", "-c", "umask 022; cat > \"$1\" && mv -f -- \"$1\" \"$2\"", "sh",
      stagingPath, finalPath,
    ]
    do {
      let result = try streamRunner.stream(
        arguments: sshArguments(remoteCommand),
        stdinFile: localURL,
        stdoutFile: nil,
        // 远端只该保持沉默；留一点余量容纳偶发提示，超出即判失败。
        maximumBytes: 64 * 1024,
        timeout: timeout
      )
      guard result.exitStatus == 0 else {
        throw RemoteSSHError(
          kind: RemoteSSHDiagnostics.classify(
            standardError: result.standardError, exitStatus: result.exitStatus),
          target: identity.label,
          detail: RemoteSSHDiagnostics.redact(result.standardError),
          exitStatus: result.exitStatus
        )
      }
    } catch let error as RemoteSSHError {
      // 失败路径统一在这里收尾：无论是流式执行器抛错还是远端非零退出，staging 都要清掉。
      removeRemoteStaging(stagingPath)
      throw error
    }
  }

  /// 尽力删除残留 staging。失败无法补救也不影响用户可见结果，因此不向上传播；
  /// 不清理反而会在远端留下让人误判成“已上传”的隐藏文件。
  private func removeRemoteStaging(_ path: String) {
    _ = try? run(
      script: "rm -f -- \"$1\"", arguments: [path], timeout: 10, maximumOutputBytes: 4096)
  }

  /// 拼远端绝对路径。只在本地做字符串拼接，拼完仍作为位置参数传入，不进入远端 Shell 解析。
  static func remotePath(directory: String, name: String) -> String {
    directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
  }

  // MARK: - 工厂

  /// 场景 A：借用用户前台 `ssh` 连接的 ControlMaster socket。
  public static func ssh(
    invocation: SSHCommandInvocation,
    controlDirectory: String,
    label: String,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner(),
    streamRunner: any RemoteSSHStreaming = RemoteSSHStreamRunner()
  ) -> RemoteSideChannel {
    let control = SSHControlPathInvocation(
      configurationArguments: invocation.configurationArguments,
      controlDirectory: controlDirectory
    )
    return RemoteSideChannel(
      identity: RemoteSideChannelIdentity(
        key: "ssh:" + digest(invocation.configurationArguments), label: label),
      sshArguments: { control.arguments(remoteCommand: $0) },
      runner: runner,
      streamRunner: streamRunner,
      controlCheckArguments: control.checkArguments()
    )
  }

  /// 场景 B：远程工作模式受管终端，直接复用已有私有配置与 ControlMaster。
  public static func managed(
    transport: RemoteSessionTransport,
    profileKey: String,
    label: String,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner(),
    streamRunner: any RemoteSSHStreaming = RemoteSSHStreamRunner()
  ) -> RemoteSideChannel {
    RemoteSideChannel(
      identity: RemoteSideChannelIdentity(key: "managed:" + profileKey, label: label),
      sshArguments: { transport.sshArguments(remoteCommand: $0, multiplexed: true) },
      runner: runner,
      streamRunner: streamRunner
    )
  }

  /// argv 摘要。用 `\0` 连接而不是空格：参数内部可能含空格，直接拼接会让不同 argv
  /// 撞成同一个 key，从而把两台机器的缓存与 CPU 差分样本混在一起。
  static func digest(_ arguments: [String]) -> String {
    let joined = arguments.joined(separator: "\u{0}")
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
