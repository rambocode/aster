// 会话看板的数据入口。看板只认这个协议，不直接碰工作区模型或控制桥。
import AsterCore
import Combine
import Foundation

/// 看板上的一张会话卡。
struct UsageSessionEntry: Equatable, Identifiable {
  /// Pane 的 UUID。
  var id: UUID
  var provider: AgentProvider
  var status: AgentControlStatus
  /// 终端标题；没有就用目录名。
  var title: String?
  var workingDirectory: String?
  /// Pane 的登录 shell PID，进程占用以它为根；拿不到时为 nil。
  var rootProcessIdentifier: Int32?
}

/// 会话看板与状态栏红点的数据源。
@MainActor
protocol UsageSessionBoardDataSource: AnyObject {
  /// 当前所有在跑 Agent 的 Pane（跨全部窗口）。
  func sessions() -> [UsageSessionEntry]
  /// 会话集合或某个会话的状态变化时发一次。事件驱动，不得用定时器实现。
  var changes: AnyPublisher<Void, Never> { get }
  /// 跳到该 Pane 并把所在窗口带到前台。
  func focus(paneID: UUID)
}
