// 浮动窗「会话」页：所有在跑 Agent 的状态卡，附 CPU / 内存占用。
import AppKit
import AsterCore

@MainActor
final class UsageSessionBoardSectionController: UsageSectionController {
  private let dataSource: UsageSessionBoardDataSource

  init(dataSource: UsageSessionBoardDataSource) {
    self.dataSource = dataSource
  }

  // 骨架：由「会话看板」任务实现。
  private(set) lazy var view: NSView = NSView()

  func activate() {}

  func suspend() {}
}
