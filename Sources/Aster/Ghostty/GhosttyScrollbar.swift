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
/// 只在内容超出视口时显示；放在 `window-padding-x` 右侧固定留出的槽位里，不压住文字，
/// 显示或隐藏也不改网格宽度、不触发 reflow。
/// 平时淡出且不接收点击，只在用户滚动视口或指针移到右边缘时淡入，停下一会儿再淡出。
/// 拖动期间忽略 libghostty 回传的位置，否则异步回写会让滑块在指针下来回抖。
@MainActor
final class GhosttyScrollbar: NSScroller {
  /// 用户拖动或点击轨道后回调目标视口首行。
  var onScrollToRow: ((UInt64) -> Void)?
  private(set) var state = GhosttyScrollbarState(total: 0, offset: 0, length: 0)
  /// 当前是否淡入可见；不可见时点击穿透给终端，避免误触翻页或挡住选区。
  private(set) var isRevealed = false
  private var isTracking = false
  private var isHovering = false
  private var cursorTrackingArea: NSTrackingArea?

  /// 停止滚动或指针离开后，保持可见的秒数。
  static let lingerDuration: TimeInterval = 1.0

  /// 终端右侧为滚动条保留的槽宽（point，必须是整数，Ghostty padding 只解析整数），由右侧 padding 让出。
  /// 用固定值而不是系统滚动条宽度：配置在非主线程生成，且系统「始终显示滚动条」切换时不应让网格跟着变。
  nonisolated static let reservedWidth: CGFloat = 14

  /// 滚动条占用的宽度，正好填满保留槽位。
  static var width: CGFloat { reservedWidth }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    scrollerStyle = .overlay
    knobStyle = .default
    isEnabled = true
    isHidden = true
    alphaValue = 0
    target = self
    action = #selector(scrollerMoved(_:))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 应用 libghostty 上报的新位置；内容不足一屏时隐藏。
  func apply(_ newState: GhosttyScrollbarState) {
    let previous = state
    state = newState
    isHidden = !newState.isScrollable
    guard !isTracking, newState.isScrollable else { return }
    knobProportion = newState.knobProportion
    doubleValue = newState.position
    // 只有视口在不变的内容里移动才算用户滚动；
    // 输出增长时 total 与 offset 一起变，不能每次输出都把滚动条闪出来挡字。
    if previous.total == newState.total, previous.length == newState.length,
      previous.offset != newState.offset
    {
      flash()
    }
  }

  /// 淡入并在 `lingerDuration` 后自动淡出。
  func flash() {
    reveal()
    scheduleConceal()
  }

  /// 自绘滑块：独立的 overlay `NSScroller` 不在 `NSScrollView` 里，系统不会把滑块透明度拉起来，
  /// 默认绘制只剩悬停时的轨道；系统「始终显示滚动条」时又会画出不透明轨道。这里只画圆角滑块。
  override func draw(_ dirtyRect: NSRect) {
    let knob = rect(for: .knob).insetBy(dx: 3, dy: 2)
    guard knob.width > 0, knob.height > 0 else { return }
    NSColor.labelColor.withAlphaComponent(isHovering || isTracking ? 0.5 : 0.35).setFill()
    NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
  }

  /// 不可见时让点击落到下面的终端上。
  override func hitTest(_ point: NSPoint) -> NSView? {
    isRevealed ? super.hitTest(point) : nil
  }

  override func trackKnob(with event: NSEvent) {
    isTracking = true
    defer {
      isTracking = false
      scheduleConceal()
    }
    super.trackKnob(with: event)
  }

  // MARK: - Visibility

  private func reveal() {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(conceal), object: nil)
    guard !isRevealed else { return }
    isRevealed = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      animator().alphaValue = 1
    }
  }

  private func scheduleConceal() {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self, selector: #selector(conceal), object: nil)
    perform(#selector(conceal), with: nil, afterDelay: Self.lingerDuration)
  }

  /// 指针仍停在滚动条上或正在拖动时保持可见，离开后再由 `mouseExited` 重新计时。
  @objc private func conceal() {
    guard isRevealed, !isHovering, !isTracking else { return }
    isRevealed = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      animator().alphaValue = 0
    }
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
  /// 同一个 tracking area 也负责指针移到右边缘时淡入。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    cursorTrackingArea = area
  }

  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    needsDisplay = true
    reveal()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    needsDisplay = true
    scheduleConceal()
  }
}
