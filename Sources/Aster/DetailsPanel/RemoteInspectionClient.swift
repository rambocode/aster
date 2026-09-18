// 详情面板远端模式的注入边界：失败分类、宿主快照、闭包式远端检查接口。
// 仿 `WorkspaceInspectionClient`：控制器只依赖这些闭包，测试注入假实现即可覆盖
// 去抖、身份校验与轮询语义，不必真的建立 SSH 连接。

import AppKit
import AsterCore
import Foundation

// MARK: - 失败分类

/// 远端检查的失败原因。按「用户的下一步动作」分类，不合并成一句「读取失败」。
enum RemoteInspectionFailure: Error, Equatable, Sendable {
  /// 需要认证或主机密钥未知：`BatchMode=yes` 下立即失败，绝不弹交互认证。
  case authenticationRequired
  /// 连接不通或超时：可以直接重试。
  case unreachable(String)
  /// 旁路通道无法建立（ControlMaster 目录不可用、受管传输缺失）。
  case channelUnavailable
  /// 远端目录不存在。
  case directoryMissing
  /// 远端目录存在但不可读、或不是目录。
  case directoryNotReadable
  /// 远端输出不符合协议。
  case malformed
  /// 其它传输层失败，`detail` 已脱敏。
  case transport(String)

  /// 面板上展示的一句话原因。
  var message: String {
    switch self {
    case .authenticationRequired: L("需要认证：开启「SSH 连接复用」并重新连接")
    case .unreachable(let detail):
      detail.isEmpty ? L("连接失败") : L("连接失败：\(detail)")
    case .channelUnavailable: L("无法建立远端旁路连接")
    case .directoryMissing: L("远端目录不存在")
    case .directoryNotReadable: L("远端目录不可读")
    case .malformed: L("远端返回了无法解析的输出")
    case .transport(let detail):
      // OpenSSH 的 stderr 经脱敏后常常为空（没命中白名单标记），此时补一句尾随冒号
      // 只会显示成「连接失败：」，读起来像文案被截断。
      detail.isEmpty ? L("连接失败") : L("连接失败：\(detail)")
    }
  }

  /// 是否值得给一颗「重试」按钮。认证与目录类失败重试没有意义，用户得先改别的东西。
  var isRetryable: Bool {
    switch self {
    case .unreachable, .transport, .malformed, .channelUnavailable: true
    case .authenticationRequired, .directoryMissing, .directoryNotReadable: false
    }
  }

  /// 把 SSH 层错误翻译成面板语义。
  static func from(_ error: RemoteSSHError) -> RemoteInspectionFailure {
    switch error.kind {
    case .authenticationRequired, .hostKeyUnknown, .hostKeyChanged: .authenticationRequired
    case .hostUnreachable: .unreachable(error.detail)
    case .timeout: .unreachable(L("超时"))
    case .cancelled: .transport(error.detail)
    case .remoteCommandMissing: .transport(error.detail)
    case .transportFailure: .transport(error.detail)
    }
  }

  /// 把目录脚本的业务错误翻译成面板语义。
  static func from(_ error: RemoteDirectoryListingError) -> RemoteInspectionFailure {
    switch error {
    case .missing: .directoryMissing
    case .notDirectory, .permissionDenied: .directoryNotReadable
    case .malformed: .malformed
    case .remoteFailure(let code): .transport(code)
    }
  }
}

// MARK: - 宿主快照

/// 远端子控制器每次激活时从主控制器拿到的宿主快照。
///
/// 子控制器不反向持有 `AppModel`：所有身份信息（Tab、Pane、通道、当前远端目录）
/// 在激活时一次性传入，异步结果回写前拿它比对，避免把 A 机器的数据写进 B Pane。
struct RemoteInspectionHost: Equatable {
  var tabID: UUID
  var paneID: UUID
  var context: RemoteInspectionContext
  var channelKey: String
  /// 远端 Shell 上报的当前目录；未收到上报时为 nil。
  var workingDirectory: RemoteWorkingDirectory?

  /// 是否换了「另一条通道」。目录变化不算：那只需要重新请求，不必重置整页状态。
  func addressesSameChannel(as other: RemoteInspectionHost) -> Bool {
    tabID == other.tabID && paneID == other.paneID && channelKey == other.channelKey
  }
}

// MARK: - 远端模式来源

/// 远端模式的唯一来源。默认读当前 Pane 的终端会话；测试注入固定值，免得真的去连 SSH。
struct RemoteInspectionSource {
  var context: @MainActor (TerminalTabItem?) -> RemoteInspectionContext?
  var workingDirectory: @MainActor (TerminalTabItem?) -> RemoteWorkingDirectory?

  static let live = RemoteInspectionSource(
    context: { $0?.activeSession?.remoteInspectionContext },
    workingDirectory: { $0?.activeSession?.remoteWorkingDirectory }
  )
}

// MARK: - 检查接口

/// 详情面板远端模式依赖的异步接口。生产实现解析旁路通道后交给 `RemoteInspectionService`。
///
/// 只有目录与监控是每次都会用到的，其余动作给出保守默认实现，测试因此不必逐个声明。
struct RemoteInspectionClient {
  /// 列远端目录。
  var listDirectory:
    @MainActor (_ context: RemoteInspectionContext, _ directory: String) async -> Result<
      RemoteDirectoryListing, RemoteInspectionFailure
    >
  /// 采一次主机监控快照；`pid` 为受管终端的远端 Shell 进程号。
  var monitor:
    @MainActor (_ context: RemoteInspectionContext, _ pid: Int32?) async -> Result<
      RemoteHostMonitorSnapshot, RemoteInspectionFailure
    >
  /// 下载远端文件到本地路径。
  var download:
    @MainActor (_ context: RemoteInspectionContext, _ remotePath: String, _ localURL: URL) async ->
      Result<Void, RemoteInspectionFailure> = { _, _, _ in .failure(.channelUnavailable) }
  /// 上传本地文件到远端目录。
  var upload:
    @MainActor (
      _ context: RemoteInspectionContext, _ localURL: URL, _ directory: String, _ fileName: String
    ) async -> Result<Void, RemoteInspectionFailure> = { _, _, _, _ in
      .failure(.channelUnavailable)
    }
  /// 远端是否已存在该路径（覆盖确认用）。判定不了时返回 true，宁可多问一次。
  var fileExists: @MainActor (_ context: RemoteInspectionContext, _ remotePath: String) async ->
    Bool = { _, _ in true }
  /// 探测远端 Shell 集成安装状态。
  var inspectIntegration:
    @MainActor (_ context: RemoteInspectionContext) async -> Result<
      RemoteShellIntegrationStatus, RemoteInspectionFailure
    > = { _ in .failure(.channelUnavailable) }
  /// 安装远端 Shell 集成。
  var installIntegration:
    @MainActor (_ context: RemoteInspectionContext, _ shells: [RemoteShellIntegrationShell]) async
      -> Result<Void, RemoteInspectionFailure> = { _, _ in .failure(.channelUnavailable) }
  /// 通道标识。缓存、CPU 差分样本与迟到结果的身份校验都用它。
  var channelKey: @MainActor (_ context: RemoteInspectionContext) -> String = {
    RemoteSideChannelResolver.channelKey(for: $0)
  }

  static let live = RemoteInspectionClient(
    listDirectory: { context, directory -> Result<RemoteDirectoryListing, RemoteInspectionFailure> in
      guard let channel = RemoteSideChannelResolver.resolve(context) else {
        return .failure(.channelUnavailable)
      }
      return await RemoteInspectionService.listDirectory(channel: channel, directory: directory)
    },
    monitor: { context, pid -> Result<RemoteHostMonitorSnapshot, RemoteInspectionFailure> in
      guard let channel = RemoteSideChannelResolver.resolve(context) else {
        return .failure(.channelUnavailable)
      }
      return await RemoteInspectionService.monitor(channel: channel, pid: pid)
    },
    download: { context, remotePath, localURL -> Result<Void, RemoteInspectionFailure> in
      guard let channel = RemoteSideChannelResolver.resolve(context) else {
        return .failure(.channelUnavailable)
      }
      return await RemoteInspectionService.download(
        channel: channel, remotePath: remotePath, localURL: localURL)
    },
    upload: { context, localURL, directory, fileName -> Result<Void, RemoteInspectionFailure> in
      guard let channel = RemoteSideChannelResolver.resolve(context) else {
        return .failure(.channelUnavailable)
      }
      return await RemoteInspectionService.upload(
        channel: channel, localURL: localURL, directory: directory, fileName: fileName)
    },
    fileExists: { context, remotePath -> Bool in
      guard let channel = RemoteSideChannelResolver.resolve(context) else { return true }
      return await RemoteInspectionService.fileExists(channel: channel, remotePath: remotePath)
    },
    inspectIntegration: { context -> Result<RemoteShellIntegrationStatus, RemoteInspectionFailure> in
      guard let channel = RemoteSideChannelResolver.resolve(context) else {
        return .failure(.channelUnavailable)
      }
      return await RemoteInspectionService.inspectIntegration(channel: channel)
    },
    installIntegration: { context, shells -> Result<Void, RemoteInspectionFailure> in
      guard let channel = RemoteSideChannelResolver.resolve(context) else {
        return .failure(.channelUnavailable)
      }
      return await RemoteInspectionService.installIntegration(channel: channel, shells: shells)
    }
  )
}
