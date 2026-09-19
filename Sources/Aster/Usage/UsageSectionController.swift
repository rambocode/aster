// AI 用量浮动窗里每一页的统一生命周期。
import AppKit
import AsterCore

/// 浮动窗的一页。页面不可见时必须零开销：`suspend()` 之后不得留下任何轮询、
/// 后台扫描或订阅回调。
@MainActor
protocol UsageSectionController: AnyObject {
  /// 页面根视图。首次访问时才构建。
  var view: NSView { get }
  /// 页面变为可见：开始取数。可重复调用。
  func activate()
  /// 页面不可见（切页、关窗、功能关闭）：取消所有在途任务。可重复调用。
  func suspend()
  /// 「已用 / 剩余」口径变化。页面可见与不可见时都可能收到，实现要幂等。
  func apply(displayMode: UsageDisplayMode)
  /// 用户点了表头的刷新按钮。默认不做事；有自己数据源的页覆盖它。
  func refreshRequested()
}

extension UsageSectionController {
  /// 只有配额页关心口径；其余页默认忽略。
  func apply(displayMode: UsageDisplayMode) {}
  /// 默认把刷新视作重新激活一次。
  func refreshRequested() { activate() }
}
