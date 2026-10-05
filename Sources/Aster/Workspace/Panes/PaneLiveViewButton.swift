// Pane 顶条的「收起 / 恢复实时画面」控件；能否切换与当前状态仍由 AppModel 与 Session 决定。
import AppKit

/// 顶条上的实时画面开关。Agent TUI 打开鼠标上报后右键菜单弹不出来，这个按钮是
/// 不经过终端鼠标事件的入口：点击落在 AppKit 按钮上，不会被程序吃掉。
@MainActor
final class PaneLiveViewButton: NSButton {
  /// 按钮呈现所需的运行态快照。
  struct State: Equatable {
    /// 实时画面当前是否已收起。
    var collapsed: Bool
    /// 此刻能否切换；画中画占用的 Pane 不能收起。
    var enabled: Bool
  }

  private let stateProvider: () -> State
  private let toggleAction: () -> Void
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { if oldValue != isHovered { updateAppearance() } }
  }
  /// 与顶条其它控件同步显示；隐藏时不拦截终端点击。
  ///
  /// 状态可能被快捷键、菜单或状态卡在别处改掉，按钮不订阅这些来源：它隐藏时没人
  /// 看得见，所以只在每次淡入前向真值重新取一次，图标与提示就不会过期。
  var isRevealed = false {
    didSet {
      guard oldValue != isRevealed else { return }
      if isRevealed { refreshState() }
      updateAppearance()
    }
  }

  /// - Parameters:
  ///   - stateProvider: 返回所属 Pane 当前的收起状态与可用性。
  ///   - onToggle: 点击时翻转所属 Pane 的实时画面。
  init(stateProvider: @escaping () -> State, onToggle: @escaping () -> Void) {
    self.stateProvider = stateProvider
    toggleAction = onToggle
    super.init(frame: .zero)
    isBordered = false
    imagePosition = .imageOnly
    contentTintColor = .tertiaryLabelColor
    target = self
    action = #selector(performToggleAction)
    alphaValue = 0
    refreshState()
  }

  required init?(coder: NSCoder) { nil }

  /// 点击后立即重取状态：指针还停在按钮上，不会再触发一次淡入。
  @objc private func performToggleAction() {
    toggleAction()
    refreshState()
  }

  /// 按真值刷新图标、提示与可用性。
  func refreshState() {
    let state = stateProvider()
    let label = TerminalLiveViewMenu.title(collapsed: state.collapsed)
    image = NSImage(
      systemSymbolName: state.collapsed ? "eye" : "eye.slash",
      accessibilityDescription: label
    )?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
    setAccessibilityLabel(label)
    toolTip = "\(label)  ⇧⌘B"
    isEnabled = state.enabled
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
    if isRevealed, isEnabled { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
  }

  /// 淡入淡出 + 悬停加深，灰度与缩放、关闭按钮一致。
  private func updateAppearance() {
    contentTintColor = isHovered && isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
      context.allowsImplicitAnimation = true
      animator().alphaValue = isRevealed ? 1 : 0
    }
  }
}
