// Pane 顶条的放大／还原控件；布局状态和快捷键仍由工作区与设置管理。
import AppKit
import AsterCore

@MainActor
final class PaneZoomButton: NSButton {
  private let zoomAction: () -> Void
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { if oldValue != isHovered { updateAppearance() } }
  }
  /// 与顶条其它控件同步显示；隐藏时不拦截终端点击。
  var isRevealed = false {
    didSet { if oldValue != isRevealed { updateAppearance() } }
  }

  init(isZoomed: Bool, shortcut: String, onZoom: @escaping () -> Void) {
    zoomAction = onZoom
    super.init(frame: .zero)
    isBordered = false
    imagePosition = .imageOnly
    let label = L("缩放拆分")
    image = NSImage(
      systemSymbolName: isZoomed
        ? "arrow.down.right.and.arrow.up.left.circle.fill"
        : "arrow.up.left.and.arrow.down.right.circle.fill",
      accessibilityDescription: label
    )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    setAccessibilityLabel(label)
    updateShortcut(shortcut)
    contentTintColor = .secondaryLabelColor
    target = self
    action = #selector(performZoomAction)
    alphaValue = 0
  }

  required init?(coder: NSCoder) { nil }

  @objc private func performZoomAction() { zoomAction() }

  /// 设置窗口修改组合键时就地更新提示，不为快捷键变化重建分屏树。
  func updateShortcut(_ shortcut: String) {
    toolTip = "\(L("缩放拆分"))  \(shortcut)"
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    isRevealed ? super.hitTest(point) : nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }
  override func cursorUpdate(with event: NSEvent) {
    if isRevealed { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
  }

  private func updateAppearance() {
    contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
      context.allowsImplicitAnimation = true
      animator().alphaValue = isRevealed ? 1 : 0
    }
  }
}
