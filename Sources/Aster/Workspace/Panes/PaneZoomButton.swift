// Pane 顶条的放大控件；布局状态和快捷键仍由工作区与设置管理。还原入口在标题栏，见 PaneZoomRestoreButton。
import AppKit
import AsterCore

/// Pane 顶条的放大按钮：与关闭按钮同款无底细线图标、同一套灰度，放在它左侧。
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

  /// - Parameters:
  ///   - shortcut: 当前配置的缩放拆分组合键，只用于提示。
  ///   - onZoom: 点击时放大所属 Pane。
  init(shortcut: String, onZoom: @escaping () -> Void) {
    zoomAction = onZoom
    super.init(frame: .zero)
    isBordered = false
    imagePosition = .imageOnly
    let label = L("缩放拆分")
    image = NSImage(
      systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: label
    )?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    setAccessibilityLabel(label)
    updateShortcut(shortcut)
    contentTintColor = .tertiaryLabelColor
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

  /// 淡入淡出 + 悬停加深，灰度与关闭按钮一致。
  private func updateAppearance() {
    contentTintColor = isHovered ? .secondaryLabelColor : .tertiaryLabelColor
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
      context.allowsImplicitAnimation = true
      animator().alphaValue = isRevealed ? 1 : 0
    }
  }
}
