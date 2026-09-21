// AI 用量浮动窗的窗口层：置顶面板、每次都贴回状态栏图标、展开动画、鼠标离开自动收起。
import AppKit
import AsterCore
import Foundation

/// 用量浮动窗。
///
/// 面板配方与可交互画中画一致：不激活 Aster 也能成为键盘窗口、跨 Space、盖在全屏应用
/// 之上。交互模型照菜单栏 popover 做：点状态栏图标从图标正下方展开，指针离开面板后
/// 自动收起。关闭按钮的语义是「收起」而不是销毁，窗口实例复用，页面靠
/// `onVisibilityChanged` 走到 `suspend()`。
@MainActor
final class UsagePanelController: NSObject, NSWindowDelegate {
  /// 默认尺寸。配额页的窗口行是两行（标签 + 进度条 + 百分比 / 重置时间），380pt 宽下仍然读得
  /// 清楚，再宽只是多留白；高度取到能一眼看全三四张卡片即可。
  static let defaultSize = NSSize(width: 440, height: 600)
  static let minimumSize = NSSize(width: 380, height: 340)
  /// 尺寸的持久化键。位置不再记忆——面板每次都回到状态栏图标下方。
  static let sizeDefaultsKey = "aster.usage.panel-size.v1"
  /// 0.6.9 的整块 frame 持久化键。只读不写，用来把老用户调过的**尺寸**迁过来。
  static let legacyFrameDefaultsKey = "aster.usage.panel-frame.v1"
  /// 面板顶边与状态栏按钮底边的间隙。
  private static let anchorGap: CGFloat = 6
  private static let screenMargin: CGFloat = 8
  /// 展开与收起的动画时长。展开稍长一点才看得出是「从菜单栏拉出来」。
  static let expandDuration: TimeInterval = 0.18
  static let collapseDuration: TimeInterval = 0.12
  /// 展开动画的起始高度比例：顶边钉在锚点下方不动，只有底边往下长。
  private static let collapsedHeightRatio: CGFloat = 0.55
  /// 指针离开面板到收起之间的宽限时间。手滑划出边界马上回来不应该把窗口弄没；
  /// 再长就会让人觉得窗口「赖着不走」——真机上算上采样与淡出，0.35 秒对应到手感约 0.8 秒。
  static let autoHideDelay: TimeInterval = 0.35
  /// 指针位置的采样周期。
  private static let pointerPollInterval: TimeInterval = 0.12
  /// 判定「还在面板上」时对边界的外扩量，避免贴边像素的抖动误判为离开。
  static let pointerSlack: CGFloat = 4

  private let defaults: UserDefaults
  private let anchor: @MainActor () -> NSRect?
  private let panel: UsageFloatingPanel
  private let content: NSViewController
  private let clip: UsagePanelClipView
  /// 展开/收起动画的代次：旧动画的收尾不能作用在新一轮展示上。
  private var animationGeneration = 0
  /// 逻辑上的显示态。动画期间 `panel.isVisible` 还是 true，对外一律以它为准。
  private var isPresented = false
  private var pointerTimer: Timer?
  /// 指针是否进入过面板。没进过就不自动收起——菜单命令打开时指针根本不在这儿。
  private var hasEnteredPanel = false
  /// 指针离开面板的起始时刻；回到面板内清空。
  private var pointerLeftAt: Date?
  /// 当前这次展示的目标尺寸。展开动画进行中窗口 frame 是中间态，落盘只能用它。
  private var presentedSize: NSSize

  /// 窗口显隐回调。收起（含点关闭按钮、自动收起）时带 false，宿主据此挂起当前页。
  var onVisibilityChanged: ((Bool) -> Void)?

  /// 供宿主接线与测试读取；不要用它直接操作窗口生命周期。
  var window: NSWindow { panel }
  var isVisible: Bool { isPresented }

  init(content: NSViewController, defaults: UserDefaults, anchor: @escaping @MainActor () -> NSRect?)
  {
    self.defaults = defaults
    self.anchor = anchor
    self.content = content
    presentedSize = Self.defaultSize
    clip = UsagePanelClipView()
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
    installContent()
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

  /// 内容不直接当 `contentView`，中间垫一层会裁切的容器。
  ///
  /// 展开动画改的是窗口高度，若内容随窗口一起变高，表头 / 卡片 / 滚动区每一帧都要重排，
  /// 既抖又白费算力。垫一层之后内容始终保持最终尺寸、顶边跟着容器走（`.minYMargin`），
  /// 动画期间只是底部被裁掉，视觉上正是「从菜单栏往下展开」。
  ///
  /// 代价是窗口不再托管 `contentViewController`，响应链会断在容器上，所以手动接回去。
  private func installContent() {
    let view = content.view
    view.translatesAutoresizingMaskIntoConstraints = true
    view.frame = NSRect(origin: .zero, size: Self.defaultSize)
    view.autoresizingMask = [.width, .height]
    clip.addSubview(view)
    panel.contentView = clip
    content.nextResponder = panel
    clip.nextResponder = content
  }

  // MARK: - 显隐

  /// 展开面板。已经展开时只把它取到最前，不重播动画、也不挪位置。
  func show() {
    guard !isPresented else {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    isPresented = true
    animationGeneration += 1
    present(at: Self.resolveFrame(
      size: resolvedSize(),
      anchor: anchor(),
      screens: Self.visibleFrames(),
      preferred: preferredScreenFrame()))
    startPointerWatch()
    onVisibilityChanged?(true)
  }

  /// 收起面板。`animated == false` 用于拆除功能等必须立刻生效的路径。
  func hide(animated: Bool = true) {
    guard isPresented || panel.isVisible else { return }
    isPresented = false
    stopPointerWatch()
    rememberSize()
    animationGeneration += 1
    let generation = animationGeneration
    guard animated, Self.animationsEnabled else {
      finishHide()
      onVisibilityChanged?(false)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.collapseDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.animationGeneration == generation, !self.isPresented else { return }
        self.finishHide()
      }
    }
    onVisibilityChanged?(false)
  }

  /// 展开：窗口先落到「顶边对齐、高度打折」的起始 frame，再长到目标 frame 并淡入。
  private func present(at target: NSRect) {
    presentedSize = target.size
    panel.setFrame(target, display: false)
    guard Self.animationsEnabled else {
      panel.alphaValue = 1
      panel.makeKeyAndOrderFront(nil)
      return
    }
    beginClippedLayout(contentHeight: target.height)
    var collapsed = target
    collapsed.size.height = max(target.height * Self.collapsedHeightRatio, 1)
    collapsed.origin.y = target.maxY - collapsed.height
    panel.setFrame(collapsed, display: false)
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    let generation = animationGeneration
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.expandDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(target, display: true)
      panel.animator().alphaValue = 1
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.animationGeneration == generation else { return }
        self.endClippedLayout()
      }
    }
  }

  /// 收尾：动画留下的中间态（alpha、被裁的内容布局）必须还原，否则下次展示从残状态开始。
  private func finishHide() {
    panel.orderOut(nil)
    panel.alphaValue = 1
    endClippedLayout()
  }

  /// 动画期间冻结内容尺寸：高度钉死在最终值，顶边跟着容器，底部交给容器裁切。
  private func beginClippedLayout(contentHeight: CGFloat) {
    let view = content.view
    view.autoresizingMask = [.width, .minYMargin]
    view.frame = NSRect(
      x: 0, y: clip.bounds.height - contentHeight, width: clip.bounds.width, height: contentHeight)
  }

  /// 还原成跟随窗口尺寸，用户此后拖拽调整大小时内容才会跟着长。
  private func endClippedLayout() {
    let view = content.view
    view.autoresizingMask = [.width, .height]
    view.frame = clip.bounds
  }

  private static var animationsEnabled: Bool {
    !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  // MARK: - 自动收起

  /// 指针轮询只在面板可见期间存在，由 `hide()` 停掉；宿主释放控制器前必须先收起面板
  /// （`deinit` 不在主线程隔离上，拿不到 timer）。
  ///
  /// 指针位置用轮询而不是 `NSTrackingArea`：面板之外还要认状态栏按钮那块区域（点图标
  /// 收起时指针正停在上面），而且窗口在其它 Space / 全屏应用之上时 tracking area 的
  /// 进出事件并不可靠。轮询只在面板可见期间存在。
  private func startPointerWatch() {
    stopPointerWatch()
    hasEnteredPanel = false
    pointerLeftAt = nil
    let timer = Timer(timeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollPointer() }
    }
    // 拖动窗口、滚动内容时主 runloop 在 tracking mode，默认模式的 timer 会停摆。
    RunLoop.main.add(timer, forMode: .common)
    pointerTimer = timer
  }

  private func stopPointerWatch() {
    pointerTimer?.invalidate()
    pointerTimer = nil
    hasEnteredPanel = false
    pointerLeftAt = nil
  }

  private func pollPointer() {
    guard isPresented else { return }
    let decision = Self.evaluateAutoHide(
      pointer: NSEvent.mouseLocation,
      panelFrame: panel.frame,
      anchor: anchor(),
      hasEntered: hasEnteredPanel,
      isInteracting: isInteracting,
      leftAt: pointerLeftAt,
      now: Date())
    hasEnteredPanel = decision.hasEntered
    pointerLeftAt = decision.leftAt
    if decision.shouldHide { hide() }
  }

  /// 正在拖尺寸、弹了 sheet 或模态窗时指针可能落在面板之外，这时收起会打断操作。
  private var isInteracting: Bool {
    panel.inLiveResize || panel.attachedSheet != nil || NSApp.modalWindow != nil
  }

  /// 自动收起的判定。纯函数，时间与指针位置都由调用方给，便于测试。
  ///
  /// - Returns: 更新后的「进入过面板」「离开起始时刻」，以及这一拍是否应当收起。
  static func evaluateAutoHide(
    pointer: NSPoint,
    panelFrame: NSRect,
    anchor: NSRect?,
    hasEntered: Bool,
    isInteracting: Bool,
    leftAt: Date?,
    now: Date
  ) -> (hasEntered: Bool, leftAt: Date?, shouldHide: Bool) {
    if panelFrame.insetBy(dx: -pointerSlack, dy: -pointerSlack).contains(pointer) {
      return (true, nil, false)
    }
    // 状态栏图标那块算「还在控件上」：否则指针停在图标上时面板会自己消失，
    // 再点一下又展开，看起来像图标点不动。
    if let anchor, anchor.insetBy(dx: -pointerSlack, dy: -pointerSlack).contains(pointer) {
      return (hasEntered, nil, false)
    }
    if isInteracting { return (hasEntered, nil, false) }
    guard hasEntered else { return (false, nil, false) }
    let since = leftAt ?? now
    return (true, since, now.timeIntervalSince(since) >= autoHideDelay)
  }

  // MARK: - 位置与尺寸

  /// 面板贴在状态栏按钮正下方，右边缘不出屏；锚点不可信时退回「程序所在那块屏」的右上角。
  ///
  /// 状态栏按钮在菜单栏里，也就是在某块屏幕可见区域的**上方**。不满足这一点的锚点不可信：
  /// 状态栏条目刚创建的那一拍，它的窗口还没被系统摆到菜单栏，换算出来的是 (0,0) 附近的
  /// 矩形，照着它定位会把浮动窗夹到屏幕左下角（菜单命令「开启功能并立刻显示」正好踩中）。
  /// 这时按 `preferred`（Aster 当前窗口所在屏）取右上角，那里本来就是状态栏图标所在的一侧。
  static func resolveFrame(
    size: NSSize, anchor: NSRect?, screens: [NSRect], preferred: NSRect? = nil
  ) -> NSRect {
    let fallback = NSRect(origin: .zero, size: size)
    let hostScreen = anchor.flatMap { anchor in
      screens.first { visible in
        visible.minX <= anchor.midX && anchor.midX <= visible.maxX && anchor.minY >= visible.maxY - 1
      }
    }
    let screen =
      hostScreen
      ?? preferred.flatMap { preferred in screens.first { $0.intersects(preferred) } }
      ?? screens.first ?? fallback
    var origin = NSPoint(
      x: screen.maxX - size.width - screenMargin,
      y: screen.maxY - size.height - screenMargin)
    if hostScreen != nil, let anchor {
      origin.x = anchor.midX - size.width / 2
      origin.y = anchor.minY - anchorGap - size.height
    }
    return clamp(NSRect(origin: origin, size: size), to: screen)
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

  /// Aster 自己的窗口所在屏幕；锚点不可信时用它决定面板出现在哪块屏上。
  private func preferredScreenFrame() -> NSRect? {
    let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
      + NSApp.windows.filter(\.isVisible)
    return candidates.first { $0 !== panel }?.screen?.visibleFrame
  }

  /// 用户调过的尺寸；没有记录时（含 0.6.9 只存过整块 frame 的情况）取默认尺寸。
  private func resolvedSize() -> NSSize {
    for key in [Self.sizeDefaultsKey, Self.legacyFrameDefaultsKey] {
      guard let raw = defaults.string(forKey: key) else { continue }
      // 旧键存的是 `{{x, y}, {w, h}}`，`NSSizeFromString` 解析不了，要按 rect 取尺寸。
      let size = key == Self.sizeDefaultsKey ? NSSizeFromString(raw) : NSRectFromString(raw).size
      guard size.width > 0, size.height > 0 else { continue }
      return NSSize(
        width: max(size.width, Self.minimumSize.width),
        height: max(size.height, Self.minimumSize.height))
    }
    return Self.defaultSize
  }

  /// 只记尺寸，不记位置。写的是 `presentedSize`：展开动画进行中窗口高度是打折的中间值，
  /// 这时候收起（点关闭、指针划走）会把那个高度记成用户尺寸。
  private func rememberSize() {
    guard isPresented else { return }
    defaults.set(NSStringFromSize(presentedSize), forKey: Self.sizeDefaultsKey)
  }

  // MARK: - NSWindowDelegate

  /// 关闭按钮＝收起：窗口实例留着复用，只把页面挂起。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    presentedSize = panel.frame.size
    rememberSize()
  }
}

/// `.nonactivatingPanel` 默认不接收键盘焦点；浮动窗里有可点内容与滚动区，需要成为 key。
@MainActor
private final class UsageFloatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// 展开动画期间裁掉超出窗口的内容。自身不画任何东西。
@MainActor
private final class UsagePanelClipView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    identifier = NSUserInterfaceItemIdentifier("usage-panel-clip")
  }

  required init?(coder: NSCoder) { nil }
}
