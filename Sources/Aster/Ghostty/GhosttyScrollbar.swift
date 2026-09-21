// 终端 Pane 右侧滚动条：按 libghostty 上报的 scrollback 位置显示，并把拖动换算成视口行。
import AppKit

/// libghostty `GHOSTTY_ACTION_SCROLLBAR` 的值拷贝，单位都是行。
struct GhosttyScrollbarState: Equatable {
  /// scrollback 加活动屏幕的总行数。
  var total: UInt64
  /// 视口首行在总行数里的位置，0 表示最顶端。
  var offset: UInt64
  /// 视口行数。
  var length: UInt64

  /// 内容超出视口高度时才有可滚动的范围。
  var isScrollable: Bool { total > length }
  /// 视口顶端可到达的最大行号。
  var maximumOffset: UInt64 { total > length ? total - length : 0 }
  /// 滑块占轨道的比例。
  var knobProportion: Double { total == 0 ? 1 : min(1, Double(length) / Double(total)) }
  /// 滑块位置，0 在顶端、1 在底端。
  var position: Double {
    maximumOffset == 0 ? 1 : min(1, Double(offset) / Double(maximumOffset))
  }

  /// 把滑块位置换算成视口首行。
  func row(at position: Double) -> UInt64 {
    let clamped = min(max(position, 0), 1)
    return UInt64((clamped * Double(maximumOffset)).rounded())
  }
}

/// 贴在终端右边缘的 overlay 滚动条。
///
/// 只在内容超出视口时显示；不占终端网格宽度，避免显示或隐藏时触发 reflow。
/// 拖动期间忽略 libghostty 回传的位置，否则异步回写会让滑块在指针下来回抖。
@MainActor
final class GhosttyScrollbar: NSScroller {
  /// 用户拖动或点击轨道后回调目标视口首行。
  var onScrollToRow: ((UInt64) -> Void)?
  private(set) var state = GhosttyScrollbarState(total: 0, offset: 0, length: 0)
  private var isTracking = false
  private var cursorTrackingArea: NSTrackingArea?

  /// 滚动条占用的宽度，与系统 overlay 滚动条一致。
  static var width: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollerStyle = .overlay
    knobStyle = .default
    isEnabled = true
    isHidden = true
    target = self
    action = #selector(scrollerMoved(_:))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 应用 libghostty 上报的新位置；内容不足一屏时隐藏。
  func apply(_ newState: GhosttyScrollbarState) {
    state = newState
    isHidden = !newState.isScrollable
    guard !isTracking, newState.isScrollable else { return }
    knobProportion = newState.knobProportion
    doubleValue = newState.position
  }

  override func trackKnob(with event: NSEvent) {
    isTracking = true
    defer { isTracking = false }
    super.trackKnob(with: event)
  }

  @objc private func scrollerMoved(_ sender: NSScroller) {
    switch hitPart {
    case .decrementPage:
      scrollByPage(-1)
    case .incrementPage:
      scrollByPage(1)
    default:
      onScrollToRow?(state.row(at: doubleValue))
    }
  }

  /// 点击轨道空白处时按一屏翻页，与系统「点击滚动条跳到下一页」的默认行为一致。
  private func scrollByPage(_ direction: Int) {
    let current = Int64(state.offset)
    let target = current + Int64(direction) * Int64(state.length)
    let clamped = min(max(target, 0), Int64(state.maximumOffset))
    onScrollToRow?(UInt64(clamped))
  }

  // MARK: - Cursor

  /// 终端视图的 tracking area 覆盖整个 Pane，会把指针设成 I-beam；滚动条上要恢复箭头。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
    let area = NSTrackingArea(
      rect: bounds, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    cursorTrackingArea = area
  }

  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}
