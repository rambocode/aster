// 详情面板远端模式的异步边界：把阻塞的 ssh 调用挪到后台任务，并把 SSH 层错误
// 翻译成面板语义。所有远端脚本文本都是常量，用户数据只走位置参数。

import AsterCore
import Foundation

/// 远端只读检查与文件传输的执行入口。
///
/// 每个动作都是一次短命 `ssh` exec（≈ fork + 往返 30–80ms），因此统一放在
/// `Task.detached(priority: .utility)` 上，并用 `withTaskCancellationHandler`
/// 把调用方的取消传递进去——`Task.detached` 不会自动继承等待方后续收到的取消。
enum RemoteInspectionService {
  // MARK: - 上限

  /// 目录脚本超时。
  static let directoryTimeout: TimeInterval = 10
  /// 监控脚本超时。
  static let monitorTimeout: TimeInterval = 8
  /// 单次传输超时：大文件走流式，超时按整体计。
  static let transferTimeout: TimeInterval = 600
  /// 单个文件传输上限。
  static let maximumTransferBytes = 512 * 1_024 * 1_024

  // MARK: - 目录

  static func listDirectory(
    channel: RemoteSideChannel, directory: String
  ) async -> Result<RemoteDirectoryListing, RemoteInspectionFailure> {
    await detachedValue {
      do {
        let result = try channel.run(
          script: RemoteDirectoryListingScript.script,
          arguments: [directory],
          timeout: directoryTimeout,
          maximumOutputBytes: RemoteDirectoryListingScript.remoteByteLimit
        )
        let listing = try RemoteDirectoryListingParser.parse(Data(result.standardOutput.utf8))
        return .success(markLossyNames(listing))
      } catch let error as RemoteDirectoryListingError {
        return .failure(RemoteInspectionFailure.from(error))
      } catch let error as RemoteSSHError {
        return .failure(classify(error, channel: channel))
      } catch {
        return .failure(.transport(L("未知错误")))
      }
    }
  }

  /// 补标有损解码的文件名。
  ///
  /// 旁路执行器把 stdout 解码成 `String` 后才交给解析器，非法 UTF-8 字节此时已经变成
  /// U+FFFD，解析器再也判断不出「原名不是合法 UTF-8」。带替换字符的名字回传远端已经
  /// 不是原来那个文件，必须禁止进入与下载，所以这里按替换字符补标记。
  private static func markLossyNames(_ listing: RemoteDirectoryListing) -> RemoteDirectoryListing {
    var listing = listing
    for index in listing.entries.indices where listing.entries[index].name.contains("\u{FFFD}") {
      listing.entries[index].nameDecodedLossy = true
    }
    return listing
  }

  // MARK: - 监控

  static func monitor(
    channel: RemoteSideChannel, pid: Int32?
  ) async -> Result<RemoteHostMonitorSnapshot, RemoteInspectionFailure> {
    await detachedValue {
      do {
        let result = try channel.run(
          script: RemoteHostMonitorScript.script,
          arguments: pid.map { [String($0)] } ?? [],
          timeout: monitorTimeout,
          maximumOutputBytes: RemoteHostMonitorScript.outputByteLimit
        )
        let snapshot = try RemoteHostMonitorParser.parse(
          Data(result.standardOutput.utf8), now: Date())
        return .success(snapshot)
      } catch is RemoteHostMonitorError {
        return .failure(.malformed)
      } catch let error as RemoteSSHError {
        return .failure(classify(error, channel: channel))
      } catch {
        return .failure(.transport(L("未知错误")))
      }
    }
  }

  // MARK: - 传输

  static func download(
    channel: RemoteSideChannel, remotePath: String, localURL: URL
  ) async -> Result<Void, RemoteInspectionFailure> {
    await detachedValue {
      do {
        try channel.download(
          remotePath: remotePath,
          to: localURL,
          maximumBytes: maximumTransferBytes,
          timeout: transferTimeout
        )
        return .success(())
      } catch let error as RemoteSSHError {
        return .failure(RemoteInspectionFailure.from(error))
      } catch {
        return .failure(.transport(L("未知错误")))
      }
    }
  }

  static func upload(
    channel: RemoteSideChannel, localURL: URL, directory: String, fileName: String
  ) async -> Result<Void, RemoteInspectionFailure> {
    await detachedValue {
      do {
        try channel.upload(
          localURL: localURL,
          toDirectory: directory,
          fileName: fileName,
          maximumBytes: maximumTransferBytes,
          timeout: transferTimeout
        )
        return .success(())
      } catch let error as RemoteSSHError {
        return .failure(RemoteInspectionFailure.from(error))
      } catch {
        return .failure(.transport(L("未知错误")))
      }
    }
  }

  /// 远端是否已存在该路径。判定不了时返回 true：宁可多问一次「是否覆盖」，
  /// 也不能在探测失败时默默盖掉远端文件。
  static func fileExists(channel: RemoteSideChannel, remotePath: String) async -> Bool {
    await detachedValue {
      guard
        let result = try? channel.run(
          script: "[ -e \"$1\" ]",
          arguments: [remotePath],
          timeout: 10,
          maximumOutputBytes: 4_096
        )
      else { return true }
      return result.exitStatus == 0
    }
  }

  // MARK: - 远端集成

  static func inspectIntegration(
    channel: RemoteSideChannel
  ) async -> Result<RemoteShellIntegrationStatus, RemoteInspectionFailure> {
    await detachedValue {
      do {
        let result = try runCommand(
          channel,
          RemoteShellIntegrationInstall.inspectCommand(),
          timeout: directoryTimeout,
          maximumOutputBytes: 64 * 1_024
        )
        guard let status = RemoteShellIntegrationInstall.parseInspect(result.standardOutput) else {
          return .failure(.malformed)
        }
        return .success(status)
      } catch let error as RemoteSSHError {
        return .failure(RemoteInspectionFailure.from(error))
      } catch {
        return .failure(.transport(L("未知错误")))
      }
    }
  }

  static func installIntegration(
    channel: RemoteSideChannel, shells: [RemoteShellIntegrationShell]
  ) async -> Result<Void, RemoteInspectionFailure> {
    let scripts = RemoteIntegrationScripts.load(shells: shells)
    guard !scripts.isEmpty else { return .failure(.transport(L("缺少远端集成脚本资源"))) }
    return await detachedValue {
      do {
        let result = try runCommand(
          channel,
          RemoteShellIntegrationInstall.installCommand(scripts: scripts),
          timeout: 30,
          maximumOutputBytes: 64 * 1_024
        )
        guard
          result.exitStatus == 0,
          result.standardOutput.contains(RemoteShellIntegrationInstall.installSuccessMarker)
        else {
          return .failure(.transport(RemoteSSHDiagnostics.redact(result.standardError)))
        }
        return .success(())
      } catch let error as RemoteSSHError {
        return .failure(RemoteInspectionFailure.from(error))
      } catch {
        return .failure(.transport(L("未知错误")))
      }
    }
  }

  // MARK: - 失败归类

  /// 把 SSH 层失败翻译成面板语义，必要时用 `ssh -O check` 补一次判定。
  ///
  /// 探测只在**失败路径**上做：正常 tick 每 3 秒一次，happy path 再加一次往返不划算。
  /// 复用 socket 已经不在时，`BatchMode=yes` 下的失败一定是「需要重新认证」，
  /// 给出这个结论比一句泛化的传输失败更能指向下一步动作。
  private static func classify(
    _ error: RemoteSSHError, channel: RemoteSideChannel
  ) -> RemoteInspectionFailure {
    let failure = RemoteInspectionFailure.from(error)
    guard case .transport = failure else { return failure }
    guard RemoteSideChannelResolver.controlMasterIsAvailable(channel) else {
      return .authenticationRequired
    }
    return failure
  }

  // MARK: - 命令执行

  /// 用旁路通道执行一条已经构造好的远端命令 argv。
  ///
  /// `RemoteSideChannel.run` 只接受脚本文本，而远端集成的探测/安装脚本文本留在
  /// `AsterCore` 内部（只对外暴露完整 argv），因此这里单独走一遍同样的输出上限与
  /// 255 归类：退出码非 0 不一定是失败，只有 OpenSSH 自身的 255 才算连接层出错。
  private static func runCommand(
    _ channel: RemoteSideChannel,
    _ remoteCommand: [String],
    timeout: TimeInterval,
    maximumOutputBytes: Int
  ) throws -> RemoteSSHResult {
    let result = try channel.runner.run(
      arguments: channel.sshArguments(remoteCommand), timeout: timeout)
    if result.standardOutput.utf8.count > maximumOutputBytes {
      throw RemoteSSHError(
        kind: .transportFailure,
        target: channel.identity.label,
        detail: "远端输出超过 \(maximumOutputBytes) 字节上限"
      )
    }
    if result.exitStatus == 255 {
      throw RemoteSSHError(
        kind: RemoteSSHDiagnostics.classify(
          standardError: result.standardError, exitStatus: result.exitStatus),
        target: channel.identity.label,
        detail: RemoteSSHDiagnostics.redact(result.standardError),
        exitStatus: result.exitStatus
      )
    }
    return result
  }

  // MARK: - 任务包装

  /// `Task.detached` 不继承等待方后续收到的取消；统一包装后，控制器取消请求会同步
  /// 取消真正执行阻塞 `Process` 工作的 detached task。
  private static func detachedValue<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
  ) async -> Value {
    let task = Task.detached(priority: .utility, operation: operation)
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

/// 应用包内的远端集成脚本原文。安装时整段作为 `printf '%s'` 的单引号参数传给远端，
/// 远端不对内容做任何展开。
enum RemoteIntegrationScripts {
  /// 读取指定 Shell 的脚本原文；缺失的条目直接跳过，由调用方判断是否还有内容可装。
  static func load(
    shells: [RemoteShellIntegrationShell],
    fileManager: FileManager = .default
  ) -> [RemoteShellIntegrationShell: String] {
    guard let resources = AsterResourceLocations.resourcesDirectory(fileManager: fileManager) else {
      return [:]
    }
    let directory = resources.appendingPathComponent("shell-integration/remote", isDirectory: true)
    var scripts: [RemoteShellIntegrationShell: String] = [:]
    for shell in shells {
      let url = directory.appendingPathComponent("aster-remote.\(shell.rawValue)")
      guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
      scripts[shell] = contents
    }
    return scripts
  }
}
