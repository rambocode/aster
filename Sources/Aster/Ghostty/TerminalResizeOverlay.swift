import AppKit
import Foundation

/// 终端网格尺寸提示：行列数变化时在 Pane 中央短暂显示「列 x 行」，停手后自动淡出。
///
/// 覆盖层不接收鼠标事件，也不持有终端状态；调用方只在网格真的变化时调用 `show`。
@MainActor
final class TerminalResizeOverlay: NSView {
  /// 网格稳定后保持显示的时长，与 Ghostty 默认的 resize-overlay-duration 一致。
  static let visibleDuration: TimeInterval = 0.75
  private static let fadeDuration: TimeInterval = 0.2

  /// 胶囊背景与文字分开：NSTextField 在超出自身内容高度的 frame 里贴顶绘制，
  /// 直接把 label 撑高当内边距会让上下留白不对称。
  private let bubble = NSView()
  private let label = NSTextField(labelWithString: "")
  private var hideTask: DispatchWorkItem?
  private var removeTask: DispatchWorkItem?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]
    wantsLayer = true

    bubble.wantsLayer = true
    bubble.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    bubble.layer?.cornerRadius = 6
    addSubview(bubble)

    label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    bubble.addSubview(label)

    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    layoutLabel()
  }

  /// 当前显示的文本，供测试与调试读取。
  var displayedText: String { label.stringValue }

  /// 可见字形到胶囊上下边的留白，供测试校验垂直对称性。
  var glyphVerticalInsets: (top: CGFloat, bottom: CGFloat) {
    let capHeight = label.font?.capHeight ?? label.frame.height
    let baselineY = label.frame.minY + label.frame.height - label.firstBaselineOffsetFromTop
    return (bubble.frame.height - (baselineY + capHeight), baselineY)
  }

  /// 显示一次提示。拖动过程中会被连续调用，每次都顺延隐藏时间，停手后才淡出。
  func show(columns: Int, rows: Int) {
    label.stringValue = "\(columns) x \(rows)"
    layoutLabel()

    hideTask?.cancel()
    removeTask?.cancel()
    // 上一次淡出可能仍在进行；直接落回不透明，避免连续拖动时提示越来越淡。
    layer?.removeAllAnimations()
    alphaValue = 1
    isHidden = false

    let task = DispatchWorkItem { [weak self] in self?.fadeOut() }
    hideTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: task)
  }

  /// 立即收起提示，用于 Pane 被拆除或终端关闭。
  func hideImmediately() {
    hideTask?.cancel()
    removeTask?.cancel()
    hideTask = nil
    removeTask = nil
    layer?.removeAllAnimations()
    alphaValue = 1
    isHidden = true
  }

  private func fadeOut() {
    hideTask = nil
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeDuration
      animator().alphaValue = 0
    }
    // 不依赖动画 completionHandler：动画被新的 `show` 打断时它仍会触发，
    // 那时视图应当留在屏幕上。改用可取消的任务收尾。
    let task = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.removeTask = nil
      self.isHidden = true
      self.alphaValue = 1
    }
    removeTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeDuration, execute: task)
  }

  /// 按文字的光学中心摆放胶囊内容：「147 x 41」这类字形没有下伸部，
  /// 若按整行行盒居中，descender 留白会全部压到上方，看起来文字偏上。
  /// 改用基线加 cap height 求出可见字形的中心，再对齐胶囊中心。
  private func layoutLabel() {
    let size = label.intrinsicContentSize
    let labelHeight = ceil(size.height)
    let width = max(70, ceil(size.width) + 22)
    let height = max(28, labelHeight + 10)

    bubble.frame = NSRect(
      x: ((bounds.width - width) / 2).rounded(),
      y: ((bounds.height - height) / 2).rounded(),
      width: width,
      height: height
    )

    let capHeight = label.font?.capHeight ?? labelHeight
    // firstBaselineOffsetFromTop 由字体度量给出，换算成基线到 label 底边的距离。
    let baselineFromBottom = labelHeight - label.firstBaselineOffsetFromTop
    let glyphCenterFromBottom = baselineFromBottom + capHeight / 2
    label.frame = NSRect(
      x: 0,
      y: (height / 2 - glyphCenterFromBottom).rounded(),
      width: width,
      height: labelHeight
    )
  }
}

/// 决定何时提示网格尺寸：只有用户正在拖动窗口边框改变大小时才提示。
///
/// Ghostty surface 刚创建时会从默认网格连续收敛到真实网格，那些变化不是用户操作；
/// 切换标签或 Pane 时视图重新挂载、重新布局同样会改变网格。这些都不该闪提示，
/// 所以除了首次网格与建立初期的抑制窗口，还要求窗口处于 live resize 状态。
struct TerminalResizeAnnouncer {
  /// surface 建立后的抑制窗口。
  static let settleInterval: TimeInterval = 0.5

  private var firstSeen: Date?
  private var lastGrid: GridSize?

  struct GridSize: Equatable {
    let columns: Int
    let rows: Int
  }

  /// 返回本次网格是否应该提示；无论是否提示都会记录为最新网格。
  ///
  /// - Parameter isLiveResizing: 窗口是否正在被用户拖动改变大小。非拖动期间的网格变化
  ///   （切换标签、切换 Pane、重新挂载 surface）只更新记录，不提示。
  mutating func shouldAnnounce(
    columns: Int,
    rows: Int,
    isLiveResizing: Bool,
    now: Date = Date()
  ) -> Bool {
    let grid = GridSize(columns: columns, rows: rows)
    defer {
      lastGrid = grid
      if firstSeen == nil { firstSeen = now }
    }
    guard isLiveResizing else { return false }
    guard let firstSeen else { return false }
    guard now.timeIntervalSince(firstSeen) >= Self.settleInterval else { return false }
    return lastGrid != grid
  }
}
