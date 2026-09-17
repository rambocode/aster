// 远端检查请求的身份：异步结果回写前用它确认「还是当初那次请求」。

import Foundation

/// 一次远端检查请求的身份。
///
/// 远端采集全部异步，返回时用户可能已经切 Tab、切 Pane、换目录或重连（channelKey 变了）。
/// 提交结果前必须整体比对这个身份，否则会把 A 机器的数据写进 B Pane 的面板。
public struct RemoteInspectionRequestIdentity: Equatable, Sendable {
  /// 发起请求时的 Tab。
  public var tabID: UUID
  /// 发起请求时的 Pane。
  public var paneID: UUID
  /// 旁路通道标识（受管终端为 `managed:…`，手敲 ssh 为 `ssh:…`）；重连后会变。
  public var channelKey: String
  /// 目录类请求的目标目录；监控类请求为 nil。
  public var directory: String?
  /// 同一 Pane 内的请求序号，用于丢弃迟到结果。
  public var generation: UInt64

  public init(
    tabID: UUID,
    paneID: UUID,
    channelKey: String,
    directory: String? = nil,
    generation: UInt64
  ) {
    self.tabID = tabID
    self.paneID = paneID
    self.channelKey = channelKey
    self.directory = directory
    self.generation = generation
  }

  /// 换一个目录、沿用同一 Pane 与通道的后继请求身份。
  public func advanced(toDirectory directory: String?, generation: UInt64) -> Self {
    RemoteInspectionRequestIdentity(
      tabID: tabID,
      paneID: paneID,
      channelKey: channelKey,
      directory: directory,
      generation: generation
    )
  }
}
