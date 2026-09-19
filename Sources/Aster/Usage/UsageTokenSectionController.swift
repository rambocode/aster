// 浮动窗「Token」页：区间切换、按项目 / 按 Agent 排行、活动热力图。
import AppKit
import AsterCore

@MainActor
final class UsageTokenSectionController: UsageSectionController {
  private let service: TokenStatsService

  init(service: TokenStatsService) {
    self.service = service
  }

  // 骨架：由「Token 页」任务实现。
  private(set) lazy var view: NSView = NSView()

  func activate() {}

  func suspend() {}
}
