// 标题栏的「还原缩放拆分」胶囊按钮；放大真值仍在标签运行态，按钮只转发点击。
import AppKit
import AsterCore

/// 放大态下常显在标题栏右侧的还原入口。放大后 Pane 顶条不再有分屏控件，
/// 这颗常显的胶囊同时提示「当前处于放大态」，不需要悬停才能发现。
@MainActor
final class PaneZoomRestoreButton: NSButton {
  /// 胶囊尺寸：宽于高，与标题栏其它 24pt 图标按钮同一中心线。
  static let size = NSSize(width: 30, height: 18)

  private let restoreAction: () -> Void
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { if oldValue != isHovered { applyAppearance() } }
  }
  /// 非悬停时的图标色，由调用方按主题的标题栏前景色传入。
  var restingTint: NSColor = AsterTheme.secondaryInk {
    didSet { applyAppearance() }
  }

  /// - Parameters:
  ///   - shortcut: 当前配置的缩放拆分组合键，只用于提示。
  ///   - onRestore: 点击时退出放大态。
  init(shortcut: String, onRestore: @escaping () -> Void) {
    restoreAction = onRestore
    super.init(frame: .zero)
    isBordered = false
    imagePosition = .imageOnly
    let label = L("缩放拆分")
    image = NSImage(
      systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: label
    )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    setAccessibilityLabel(label)
    updateShortcut(shortcut)
    wantsLayer = true
    layer?.cornerRadius = Self.size.height / 2
    layer?.cornerCurve = .continuous
    target = self
    action = #selector(performRestoreAction)
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  @objc private func performRestoreAction() { restoreAction() }

  /// 设置窗口修改组合键时就地更新提示，不为快捷键变化重建工作区。
  func updateShortcut(_ shortcut: String) {
    toolTip = "\(L("缩放拆分"))  \(shortcut)"
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  /// CGColor 只在赋值当下解析；明暗外观切换后要重新落一次底色。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  /// 胶囊底色常显，悬停时底色与图标一起加深。
  private func applyAppearance() {
    contentTintColor = isHovered ? AsterTheme.ink : restingTint
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor =
        AsterTheme.ink.withAlphaComponent(isHovered ? 0.18 : 0.10).cgColor
    }
  }
}
