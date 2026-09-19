// 可交互画中画：把当前 Pane 的真实终端视图搬进置顶小窗，支持完整键盘输入。
import AppKit
import AsterCore
import Combine

/// 一个 Ghostty surface 只能挂在一个 `NSView` 上，所以这里不是镜像而是「借走」终端 Host：
/// 展示期间 `AppModel.floatingPaneID` 让工作区改画占位，关闭时清空它，工作区下一轮重建
/// 自然把 Host 挂回原 Pane。PTY、会话与 Pane 身份全程不变，只有网格尺寸跟随小窗。
/// 只支持固定当前 Pane；「跟随活动 Pane」在小窗内输入时语义自相矛盾，仍走系统镜像。
@MainActor
final class PaneFloatingTerminalController: NSObject, PictureInPicturePresenting, NSWindowDelegate {
  /// 低于这个尺寸终端已无法阅读，同时给 Ghostty surface 留出有效网格。
  static let minimumSize = NSSize(width: 320, height: 180)
  static let defaultSize = NSSize(width: 560, height: 340)
  private static let screenMargin: CGFloat = 16

  private let model: AppModel
  private let preferences: AppPreferences
  private let paneID: UUID?
  private var panel: FloatingTerminalPanel?
  private var container: NSView?
  private weak var session: TerminalSession?
  private weak var host: NSView?
  private weak var ownerWindow: NSWindow?
  private var subscriptions: Set<AnyCancellable> = []
  private(set) var isClosed = false
  var onFailure: ((String) -> Void)?
  var onClose: (() -> Void)?

  /// 测试与 AppDelegate 的按键路由用；外部不应直接操作窗口生命周期。
  var window: NSWindow? { panel }
  /// 小窗是当前键盘窗口时，⌘W 应收回小窗而不是关掉工作区里的活动 Pane。
  var ownsKeyWindow: Bool { panel?.isKeyWindow == true }

  init(model: AppModel, preferences: AppPreferences) {
    self.model = model
    self.preferences = preferences
    paneID = model.selectedTab?.activePaneID
    super.init()
  }

  func matches(model: AppModel, mode: PanePictureInPictureController.Mode) -> Bool {
    self.model === model && mode == .currentPane && !isClosed
  }

  func show() {
    guard !isClosed, panel == nil else { return }
    guard let paneID,
      let tab = model.tabs.first(where: { $0.runtime(for: paneID) != nil }),
      let session = tab.runtime(for: paneID)?.terminalSession
    else {
      fail(L("当前 Pane 不是终端，无法放入画中画小窗"))
      return
    }
    self.session = session
    let sourceHost = session.makeTerminalHost(preferences: preferences)
    ownerWindow = sourceHost.window

    let panel = makePanel(title: tab.title)
    let container = NSView()
    container.wantsLayer = true
    panel.contentView = container
    self.panel = panel
    self.container = container
    panel.setFrame(initialFrame(), display: false)
    synchronizeAppearance()

    // 顺序不能反：先登记占用，工作区之后的任何重建才会改画占位而不是抢回 Host。
    model.setFloatingPane(paneID)
    install(sourceHost)
    session.setPaneActive(true)
    panel.makeKeyAndOrderFront(nil)
    session.setWindowActive(panel.isKeyWindow)
    _ = session.focus()
    observe(tab: tab)
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    subscriptions.removeAll()
    if let panel {
      preferences.pictureInPictureFloatingFrame = panel.frame
      panel.delegate = nil
      panel.orderOut(nil)
    }
    // 会话可能已经结束（Pane 被关闭）：`stop()` 不会把 Host 摘出视图树，这里统一清空容器。
    container?.subviews.forEach { $0.removeFromSuperview() }
    container = nil
    panel = nil
    // 回到工作区后窗口活动状态重新跟随源窗口；Pane 活动状态由工作区重建时写回。
    session?.setWindowActive(ownerWindow?.isKeyWindow ?? false)
    if model.floatingPaneID == paneID { model.setFloatingPane(nil) }
    onClose?()
  }

  // MARK: - Panel

  /// 与 Quick Terminal 同一套置顶面板配方：不激活 Aster 也能成为键盘窗口，跨 Space 并盖在
  /// 全屏应用之上。保留小标题栏：它同时是拖动把手和关闭（收回）入口。
  private func makePanel(title: String) -> FloatingTerminalPanel {
    let panel = FloatingTerminalPanel(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.title = title
    // 只留关闭（收回）按钮：小窗没有「最小化到 Dock」和「缩放到全屏」的语义。
    for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
      panel.standardWindowButton(button)?.isHidden = true
    }
    panel.contentMinSize = Self.minimumSize
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isExcludedFromWindowsMenu = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.delegate = self
    return panel
  }

  private func install(_ host: NSView) {
    guard let container else { return }
    host.removeFromSuperview()
    container.addSubview(host)
    host.pinEdges(to: container)
    self.host = host
  }

  /// 内容区四周露出的是窗口背景，必须跟着终端主题走，否则换主题后留一圈系统窗口色。
  private func synchronizeAppearance() {
    let color = NSColor(preferences.activeTheme.palette.windowBackground)
    panel?.appearance = preferences.preferredAppearance
    panel?.backgroundColor = color
    container?.layer?.backgroundColor = color.cgColor
  }

  /// 优先沿用上次的位置与尺寸，并夹回仍然存在的屏幕；否则停在源窗口所在屏幕的右下角。
  private func initialFrame() -> NSRect {
    if let saved = preferences.pictureInPictureFloatingFrame,
      let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) })
    {
      return Self.clamp(saved, to: screen.visibleFrame)
    }
    let visible = (ownerWindow?.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(origin: .zero, size: Self.defaultSize)
    let origin = NSPoint(
      x: visible.maxX - Self.defaultSize.width - Self.screenMargin,
      y: visible.minY + Self.screenMargin)
    return Self.clamp(NSRect(origin: origin, size: Self.defaultSize), to: visible)
  }

  /// 把窗口夹进可见区域：先收尺寸再移位置，保证标题栏始终够得着。
  static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
    var result = frame
    result.size.width = min(max(frame.width, minimumSize.width), max(visible.width, minimumSize.width))
    result.size.height = min(max(frame.height, minimumSize.height), max(visible.height, minimumSize.height))
    result.origin.x = min(max(frame.minX, visible.minX), max(visible.maxX - result.width, visible.minX))
    result.origin.y = min(max(frame.minY, visible.minY), max(visible.maxY - result.height, visible.minY))
    return result
  }

  // MARK: - Observation

  private func observe(tab: TerminalTabItem) {
    // `objectWillChange` 在变更生效前发出；让出一轮后再读取模型，才能看到 Pane 是否还在。
    model.objectWillChange
      .sink { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
      .store(in: &subscriptions)
    tab.objectWillChange
      .sink { [weak self] _ in DispatchQueue.main.async { self?.reconcile() } }
      .store(in: &subscriptions)
    tab.titleChanged
      .sink { [weak self] title in self?.panel?.title = title }
      .store(in: &subscriptions)
    preferences.objectWillChange
      .sink { [weak self] _ in DispatchQueue.main.async { self?.applyPreferences() } }
      .store(in: &subscriptions)
    // 源工作区窗口关闭时模型可能直接释放、不再发变更通知；小窗不能带着已结束的终端留在屏幕上。
    if let ownerWindow {
      NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: ownerWindow)
        .sink { [weak self] _ in self?.close() }
        .store(in: &subscriptions)
    }
  }

  /// 源 Pane 被关闭、Shell 退出收尾或整个标签移到别的窗口，都是正常生命周期：收起小窗，
  /// 不弹错误。Host 若被其他路径挂走（例如视图绑定修复），原位装回。
  private func reconcile() {
    guard !isClosed, let paneID else { return }
    guard model.tabs.contains(where: { $0.runtime(for: paneID) != nil }) else {
      close()
      return
    }
    if let host, host.superview !== container { install(host) }
  }

  /// 主题、字号等偏好只通过已有终端生效；Host 由 session 长期复用，重建后要确认仍在小窗里。
  private func applyPreferences() {
    guard !isClosed, let session else { return }
    let current = session.makeTerminalHost(preferences: preferences)
    if current.superview !== container { install(current) }
    synchronizeAppearance()
  }

  private func fail(_ message: String) {
    let handler = onFailure
    close()
    handler?(message)
  }

  // MARK: - NSWindowDelegate

  /// 关闭按钮的语义是「收回到工作区」，不是结束 Shell；统一走 `close()` 归还 Host。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    close()
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) {
    session?.setWindowActive(true)
    _ = session?.focus()
  }

  func windowDidResignKey(_ notification: Notification) {
    session?.setWindowActive(false)
  }

  func windowDidMove(_ notification: Notification) { rememberFrame() }
  func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }

  private func rememberFrame() {
    guard !isClosed, let panel else { return }
    preferences.pictureInPictureFloatingFrame = panel.frame
  }
}

/// 默认的 utility 面板在 `.nonactivatingPanel` 下不一定接收键盘焦点；终端输入要求它成为 key。
@MainActor
private final class FloatingTerminalPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
