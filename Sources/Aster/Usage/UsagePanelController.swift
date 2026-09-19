// AI 用量浮动窗的窗口层：置顶面板、贴靠状态栏图标、记住位置与尺寸。
import AppKit
import AsterCore
import Foundation

/// 用量浮动窗。
///
/// 面板配方与可交互画中画一致：不激活 Aster 也能成为键盘窗口、跨 Space、盖在全屏应用
/// 之上。关闭按钮的语义是「收起」而不是销毁，窗口实例复用，页面靠 `onVisibilityChanged`
/// 走到 `suspend()`。
@MainActor
final class UsagePanelController: NSObject, NSWindowDelegate {
  /// 默认尺寸。配额页的窗口行是两行（标签 + 进度条 + 百分比 / 重置时间），380pt 宽下仍然读得
  /// 清楚，再宽只是多留白；高度取到能一眼看全三四张卡片即可。
  static let defaultSize = NSSize(width: 440, height: 600)
  static let minimumSize = NSSize(width: 380, height: 340)
  /// 位置与尺寸的持久化键。
  static let frameDefaultsKey = "aster.usage.panel-frame.v1"
  /// 面板顶边与状态栏按钮底边的间隙。
  private static let anchorGap: CGFloat = 6
  private static let screenMargin: CGFloat = 8

  private let defaults: UserDefaults
  private let anchor: @MainActor () -> NSRect?
  private let panel: UsageFloatingPanel
  /// 只在第一次显示时定位；之后完全听用户拖动的结果。
  private var hasPositioned = false

  /// 窗口显隐回调。收起（含点关闭按钮）时带 false，宿主据此挂起当前页。
  var onVisibilityChanged: ((Bool) -> Void)?

  /// 供宿主接线与测试读取；不要用它直接操作窗口生命周期。
  var window: NSWindow { panel }
  var isVisible: Bool { panel.isVisible }

  init(content: NSViewController, defaults: UserDefaults, anchor: @escaping @MainActor () -> NSRect?)
  {
    self.defaults = defaults
    self.anchor = anchor
    panel = UsageFloatingPanel(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [
        .titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView,
      ],
      backing: .buffered, defer: false)
    super.init()
    panel.identifier = NSUserInterfaceItemIdentifier("usage-panel")
    panel.title = L("AI 用量")
    // 标题由表头自己画（主题色、左对齐、和页签同一行体系）；系统标题居中绘制，留着会和
    // 表头文字重叠。`title` 仍然设置，窗口菜单与辅助功能要用它。
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.contentViewController = content
    panel.contentMinSize = Self.minimumSize
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    // 磨砂要透出窗后的内容，窗体本身就必须是透明的：留着默认的不透明底色，
    // 根视图的 `NSVisualEffectView` 采样到的只会是这块底色。阴影反过来要留着，
    // 否则透明面板压在浅色桌面上完全没有边界。
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isFloatingPanel = true
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.isExcludedFromWindowsMenu = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    // 小面板没有「最小化到 Dock」和「缩放到全屏」的语义，只留关闭（收起）。
    for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }
    panel.delegate = self
  }

  // MARK: - 显隐

  func show() {
    if !hasPositioned {
      hasPositioned = true
      panel.setFrame(
        Self.resolveFrame(saved: savedFrame(), anchor: anchor(), screens: Self.visibleFrames()),
        display: false)
    }
    let wasVisible = panel.isVisible
    panel.makeKeyAndOrderFront(nil)
    guard !wasVisible else { return }
    onVisibilityChanged?(true)
  }

  func hide() {
    guard panel.isVisible else { return }
    rememberFrame()
    panel.orderOut(nil)
    onVisibilityChanged?(false)
  }

  // MARK: - 位置

  /// 优先沿用上次的 frame（并夹回仍然存在的屏幕）；否则贴在状态栏按钮正下方，
  /// 右边缘不出屏。两条路径都以屏幕可见区域收尾，保证标题栏永远够得着。
  static func resolveFrame(saved: NSRect?, anchor: NSRect?, screens: [NSRect]) -> NSRect {
    let fallback = NSRect(origin: .zero, size: defaultSize)
    if let saved, let screen = screens.first(where: { $0.intersects(saved) }) {
      return clamp(saved, to: screen)
    }
    // 状态栏按钮在菜单栏里，也就是在某块屏幕可见区域的**上方**。不满足这一点的锚点不可信：
    // 状态栏条目刚创建的那一拍，它的窗口还没被系统摆到菜单栏，换算出来的是 (0,0) 附近的
    // 矩形，照着它定位会把浮动窗夹到屏幕左下角（菜单命令「开启功能并立刻显示」正好踩中）。
    // 这时退回默认的右上角，那里本来就是状态栏图标所在的一侧。
    let hostScreen = anchor.flatMap { anchor in
      screens.first { visible in
        visible.minX <= anchor.midX && anchor.midX <= visible.maxX && anchor.minY >= visible.maxY - 1
      }
    }
    let anchor = hostScreen == nil ? nil : anchor
    let screen = hostScreen ?? screens.first ?? fallback
    var origin = NSPoint(
      x: screen.maxX - defaultSize.width - screenMargin,
      y: screen.maxY - defaultSize.height - screenMargin)
    if let anchor {
      origin.x = anchor.midX - defaultSize.width / 2
      origin.y = anchor.minY - anchorGap - defaultSize.height
    }
    return clamp(NSRect(origin: origin, size: defaultSize), to: screen)
  }

  /// 把窗口夹进可见区域：先收尺寸再移位置。
  static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
    var result = frame
    result.size.width = min(
      max(frame.width, minimumSize.width), max(visible.width, minimumSize.width))
    result.size.height = min(
      max(frame.height, minimumSize.height), max(visible.height, minimumSize.height))
    result.origin.x = min(
      max(frame.minX, visible.minX), max(visible.maxX - result.width, visible.minX))
    result.origin.y = min(
      max(frame.minY, visible.minY), max(visible.maxY - result.height, visible.minY))
    return result
  }

  private static func visibleFrames() -> [NSRect] {
    NSScreen.screens.map(\.visibleFrame)
  }

  private func savedFrame() -> NSRect? {
    guard let raw = defaults.string(forKey: Self.frameDefaultsKey) else { return nil }
    let frame = NSRectFromString(raw)
    guard frame.width > 0, frame.height > 0 else { return nil }
    return frame
  }

  private func rememberFrame() {
    guard panel.isVisible else { return }
    defaults.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
  }

  // MARK: - NSWindowDelegate

  /// 关闭按钮＝收起：窗口实例留着复用，只把页面挂起。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  func windowDidMove(_ notification: Notification) { rememberFrame() }
  func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }
}

/// `.nonactivatingPanel` 默认不接收键盘焦点；浮动窗里有可点内容与滚动区，需要成为 key。
@MainActor
private final class UsageFloatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
