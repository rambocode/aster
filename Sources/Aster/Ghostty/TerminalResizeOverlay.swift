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

  private let label = NSTextField(labelWithString: "")
  private var hideTask: DispatchWorkItem?
  private var removeTask: DispatchWorkItem?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]
    wantsLayer = true

    label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.wantsLayer = true
    label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    label.layer?.cornerRadius = 6
    addSubview(label)

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

  private func layoutLabel() {
    let size = label.intrinsicContentSize
    let width = max(70, size.width + 22)
    let height = max(28, size.height + 10)
    label.frame = NSRect(
      x: (bounds.width - width) / 2,
      y: (bounds.height - height) / 2,
      width: width,
      height: height
    )
  }
}

/// 决定何时提示网格尺寸：首次网格不提示，surface 建立初期的自动调整也不提示。
///
/// Ghostty surface 刚创建时会从默认网格连续收敛到真实网格，那些变化不是用户操作；
/// 开窗即闪一次提示只会干扰。稳定期过后才把行列变化当成用户调整窗口或分栏。
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
  mutating func shouldAnnounce(columns: Int, rows: Int, now: Date = Date()) -> Bool {
    let grid = GridSize(columns: columns, rows: rows)
    defer {
      lastGrid = grid
      if firstSeen == nil { firstSeen = now }
    }
    guard let firstSeen else { return false }
    guard now.timeIntervalSince(firstSeen) >= Self.settleInterval else { return false }
    return lastGrid != grid
  }
}
