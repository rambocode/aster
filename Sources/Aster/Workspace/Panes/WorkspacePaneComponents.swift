import AppKit
import AsterCore
import Combine

/// 中央内容 Panel 内的 Pane 树、拖放反馈与活动 Pane 宿主视图。

@MainActor
final class PersistedSplitView: NSSplitView, NSSplitViewDelegate {
  /// 命中区比可见线宽得多：1pt 的线几乎抓不住，Otty 同样用一条细线 + 宽感应带。
  private static let hitThickness: CGFloat = 6
  /// 当前生效的分割比例。初始为持久化值；用户拖动分隔条或双击等分时同步更新,
  /// `layout()` 以它为真值把分隔条收敛到位(见 `layout()` 注释)。
  private var currentRatio: Double
  private let onRatioChanged: (Double) -> Void
  private var isUserResizing = false
  /// `setPosition` 会同步触发下一轮 `layout()`;没有门闩会在帧未就位时无限重入直至爆栈。
  private var isRepositioning = false
  private var isHoveringDivider = false {
    didSet { if oldValue != isHoveringDivider { needsDisplay = true } }
  }
  private var dividerTrackingArea: NSTrackingArea?

  init(axis: SplitAxis, ratio: Double, onRatioChanged: @escaping (Double) -> Void) {
    self.currentRatio = ratio
    self.onRatioChanged = onRatioChanged
    super.init(frame: .zero)
    isVertical = axis == .horizontal
    dividerStyle = .thin
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  override var dividerThickness: CGFloat { Self.hitThickness }

  /// 只画中间 1pt（悬停时 2pt）的线，命中区其余部分留白透出容器底色，
  /// 视觉上仍是 Otty 那条细分隔线。
  override func drawDivider(in rect: NSRect) {
    // 窗口不是键盘焦点窗口时一律画成灰线：非活动窗口不应该有强调色。
    let isHoveringDivider = self.isHoveringDivider && (window?.isKeyWindow ?? false)
    let thickness: CGFloat = isHoveringDivider ? 2 : 1
    let line =
      isVertical
      ? NSRect(x: rect.midX - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
      : NSRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
    // 悬停只加粗、加深灰度,不切换主题强调色:分隔线与把手同属工作区结构控件,
    // 保持系统灰(与 PaneDragHandleView 的配色例外一致)。
    (isHoveringDivider ? NSColor.secondaryLabelColor : AsterTheme.divider).setFill()
    line.fill()
  }

  /// 两个子视图之间的空隙就是分隔条命中区；不依赖 `NSSplitView` 的坐标翻转约定。
  private var dividerHitRect: NSRect? {
    guard arrangedSubviews.count == 2 else { return nil }
    let first = arrangedSubviews[0].frame
    let second = arrangedSubviews[1].frame
    if isVertical {
      return NSRect(
        x: min(first.maxX, second.maxX), y: 0, width: dividerThickness, height: bounds.height)
    }
    return NSRect(
      x: 0, y: min(first.maxY, second.maxY), width: bounds.width, height: dividerThickness)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let dividerTrackingArea { removeTrackingArea(dividerTrackingArea) }
    guard let rect = dividerHitRect else {
      isHoveringDivider = false
      return
    }
    let area = NSTrackingArea(
      rect: rect,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self
    )
    addTrackingArea(area)
    dividerTrackingArea = area
    // 移除感应区不会补发 mouseExited：指针正好停在旧感应区里时高亮会一直卡住。
    // 每次重建后按指针的真实位置对齐一次状态。
    syncHoverState()
  }

  /// 高亮只在「本窗口是键盘焦点窗口，且指针确实压在分隔条命中区上」时成立。
  private func syncHoverState() {
    guard let window, window.isKeyWindow, let rect = dividerHitRect else {
      isHoveringDivider = false
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    isHoveringDivider = rect.contains(point)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncHoverState()
  }

  override func mouseEntered(with event: NSEvent) { isHoveringDivider = true }
  override func mouseExited(with event: NSEvent) { isHoveringDivider = false }

  /// `NSSplitView` 把「分隔条厚度」当作与分隔方向垂直的固有尺寸（水平分隔时固有高度
  /// 只有 1pt），因为它的子视图走 autoresizing、无法反推内容尺寸。放进 `NSStackView`
  /// 后这个固有高度会把整个内容区压成一条线：上下分屏只剩分隔条，两个终端高度都是 0。
  /// 分屏区域的尺寸完全由外层容器给定，这里直接取消固有尺寸。
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  /// 比例针对「扣掉分隔条之后的可用长度」，否则第一块会固定多出一个分隔条的厚度，
  /// 等分看起来是歪的。
  private var contentLength: CGFloat {
    max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
  }

  /// 把分隔条收敛到 `currentRatio`,而不是「首轮拿到尺寸时一次性定位」。
  /// 嵌套分屏时本视图的 `layout()` 会在外层 split 布局事务的中途运行,此时的
  /// `setPosition` 不会落到最终布局上(第二个子视图被 NSSplitView 的
  /// `FallbackSize == 0 @250` 回退约束压成 0,新 Pane 只剩一条分隔线);一次性
  /// 标志会把这个错误永久化。收敛式写法让随后的任何一轮布局自动纠偏,
  /// 目标一致时不再调用 `setPosition`,不会造成布局循环。
  override func layout() {
    super.layout()
    guard !isRepositioning, !isUserResizing, arrangedSubviews.count == 2 else { return }
    // 首轮布局可能在拿到真实尺寸前发生；此时定位分隔条会把比例锁在无效值上。
    guard contentLength > 1 else { return }
    let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
    let target = max(1, contentLength * currentRatio)
    guard abs(first - target) > 0.5 else { return }
    isRepositioning = true
    setPosition(target, ofDividerAt: 0)
    isRepositioning = false
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    // 命中区是由两个子视图的间隙算出来的，自身 frame 不变时 AppKit 不会重建它，
    // 拖完分隔条后感应区就会停在旧位置。
    updateTrackingAreas()
    guard isUserResizing, arrangedSubviews.count == 2 else { return }
    let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
    guard contentLength > 0 else { return }
    // 拖动即用户的新意图:同步更新收敛目标,layout() 才不会把分隔条弹回旧比例。
    currentRatio = min(max(first / contentLength, 0.05), 0.95)
    onRatioChanged(currentRatio)
  }

  override func mouseDown(with event: NSEvent) {
    // 双击分隔条恢复等分，与参考应用一致；单击进入原生拖动，比例在拖动中写回。
    if event.clickCount == 2, let rect = dividerHitRect,
      rect.contains(convert(event.locationInWindow, from: nil))
    {
      guard contentLength > 1 else { return }
      currentRatio = 0.5
      setPosition(contentLength * 0.5, ofDividerAt: 0)
      onRatioChanged(0.5)
      return
    }
    isUserResizing = true
    super.mouseDown(with: event)
    isUserResizing = false
  }
}

/// Pane 拖放的落点几何。与 AppKit 状态无关的纯函数：给定目标面板矩形和指针位置，
/// 得出该落在哪一侧（或中心），以及要高亮的区域。
enum PaneDropGeometry {
  /// 四边各占 25%——比例太小会难以命中，太大则中心的「交换」区域几乎消失。
  static let edgeFraction: CGFloat = 0.25

  /// - Returns: `direction` 为 nil 表示落在中心（交换语义），此时 `rect` 是整个面板。
  static func zone(
    in frame: NSRect,
    at point: NSPoint,
    edgeFraction: CGFloat = edgeFraction
  ) -> (direction: SplitDirection?, rect: NSRect) {
    let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    let halfWidth = frame.width / 2
    let halfHeight = frame.height / 2
    let edgeX = frame.width * edgeFraction
    let edgeY = frame.height * edgeFraction
    // AppKit 非翻转坐标：y 越小越靠近底边，因此 `.down` 用 local.y、`.up` 用其补数。
    let candidates: [(direction: SplitDirection, distance: CGFloat, limit: CGFloat, rect: NSRect)] =
      [
        (
          .left, local.x, edgeX,
          NSRect(x: frame.minX, y: frame.minY, width: halfWidth, height: frame.height)
        ),
        (
          .right, frame.width - local.x, edgeX,
          NSRect(x: frame.midX, y: frame.minY, width: halfWidth, height: frame.height)
        ),
        (
          .down, local.y, edgeY,
          NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: halfHeight)
        ),
        (
          .up, frame.height - local.y, edgeY,
          NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: halfHeight)
        ),
      ]
    guard
      let nearest = candidates.filter({ $0.distance <= $0.limit }).min(by: {
        $0.distance < $1.distance
      })
    else {
      return (nil, frame)
    }
    return (nearest.direction, nearest.rect)
  }
}

/// 拖动 Pane 时覆盖在工作区之上的落点提示层。参考应用用两种颜色区分语义：
/// 面板边缘（强调色）＝插到这一侧，面板中心（绿色）＝与该面板交换位置。
@MainActor
final class PaneDropOverlayView: NSView {
  var highlight: (rect: NSRect, isSwap: Bool)? {
    didSet { needsDisplay = true }
  }

  /// 拖动全程由 `trackEvents` 驱动，覆盖层不参与命中测试。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let highlight else { return }
    let color = highlight.isSwap ? NSColor.systemGreen : AsterTheme.accent
    let path = NSBezierPath(
      roundedRect: highlight.rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
    color.withAlphaComponent(0.20).setFill()
    path.fill()
    color.withAlphaComponent(0.85).setStroke()
    path.lineWidth = 2
    path.stroke()
  }
}

/// Pane 顶边的胶囊拖动把手。参考应用的说法是「move the pointer near the top and a small
/// capsule appears」：靠近顶边淡入短胶囊，指针压在胶囊上时变长并换成抓手光标，
/// 按住即可把整个 Pane 拖到别处。
///
/// 配色是「主题色只经由 ThemeRuntime 进入视图」规则的一处明确例外：把手是工作区
/// 结构控件而不是终端内容，跟随主题会在绿色/彩色主题下变成一条抢眼的彩条,
/// 因此固定用系统灰(仅随明暗外观变化)。
@MainActor
final class PaneDragHandleView: NSView {
  private static let collapsedWidth: CGFloat = 28
  private static let expandedWidth: CGFloat = 56
  private let capsule = NSView()
  private var capsuleWidth: NSLayoutConstraint?
  private var trackingArea: NSTrackingArea?
  private let onDragStart: (NSEvent) -> Void
  /// 指针是否靠近 Pane 顶边（由上层的点击穿透感应带驱动）。
  var isRevealed = false {
    didSet { if oldValue != isRevealed { updateAppearance() } }
  }
  private var isHovered = false {
    didSet { if oldValue != isHovered { updateAppearance() } }
  }

  init(onDragStart: @escaping (NSEvent) -> Void) {
    self.onDragStart = onDragStart
    super.init(frame: .zero)
    wantsLayer = true
    capsule.wantsLayer = true
    capsule.layer?.cornerRadius = 2
    capsule.layer?.cornerCurve = .continuous
    capsule.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
    capsule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(capsule)
    let width = capsule.widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
    capsuleWidth = width
    NSLayoutConstraint.activate([
      capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
      capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
      capsule.heightAnchor.constraint(equalToConstant: 4),
      width,
    ])
    alphaValue = 0
  }

  required init?(coder: NSCoder) { nil }

  /// 完全透明时不参与命中测试，否则 Pane 顶部中央会出现一块点不到终端的死区。
  override func hitTest(_ point: NSPoint) -> NSView? {
    alphaValue > 0.01 ? super.hitTest(point) : nil
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
    if isRevealed { NSCursor.openHand.set() } else { super.cursorUpdate(with: event) }
  }

  override func mouseDown(with event: NSEvent) {
    guard isRevealed else {
      super.mouseDown(with: event)
      return
    }
    onDragStart(event)
  }

  private func updateAppearance() {
    let expanded = isRevealed && isHovered
    // 悬停加深灰度作为可抓取反馈,不换成主题强调色(见类注释的配色例外)。
    capsule.layer?.backgroundColor =
      (expanded ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).cgColor
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.allowsImplicitAnimation = true
      animator().alphaValue = isRevealed ? 1 : 0
      capsuleWidth?.animator().constant = expanded ? Self.expandedWidth : Self.collapsedWidth
      superview?.layoutSubtreeIfNeeded()
    }
  }
}

/// Pane 顶条最右侧的关闭按钮：与拖动把手一同淡入,点击关闭所属 Pane。
/// 与把手同属工作区结构控件,配色固定用系统灰、不跟随终端主题;
/// 完全透明时不参与命中测试,避免 Pane 右上角出现点不到终端的死区。
@MainActor
final class PaneCloseButton: NSButton {
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { if oldValue != isHovered { updateAppearance() } }
  }
  /// 指针是否靠近 Pane 顶边(由宿主的顶边感应带驱动),控制淡入与命中。
  var isRevealed = false {
    didSet { if oldValue != isRevealed { updateAppearance() } }
  }

  init(onClose: @escaping () -> Void) {
    closeAction = onClose
    super.init(frame: .zero)
    isBordered = false
    imagePosition = .imageOnly
    image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "关闭 Pane"
    )?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    contentTintColor = .tertiaryLabelColor
    target = self
    action = #selector(performCloseAction)
    alphaValue = 0
  }

  required init?(coder: NSCoder) { nil }

  private let closeAction: () -> Void

  /// 点击转发给宿主提供的关闭回调。
  @objc private func performCloseAction() { closeAction() }

  /// 隐藏时不参与命中测试,终端在这一角的点击与拖选不受影响。
  override func hitTest(_ point: NSPoint) -> NSView? {
    alphaValue > 0.01 ? super.hitTest(point) : nil
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

  /// 淡入淡出 + 悬停加深,与拖动把手的反馈语义一致。
  private func updateAppearance() {
    contentTintColor = isHovered ? .secondaryLabelColor : .tertiaryLabelColor
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.allowsImplicitAnimation = true
      animator().alphaValue = isRevealed ? 1 : 0
    }
  }
}

/// 全点击穿透的透明悬停带：只承载 tracking area 探测鼠标进入窗口顶部，
/// 自身与子视图不参与命中测试，不会拦截下方终端的点击与拖选。
final class ClickThroughStripView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 侧栏悬停动作按钮的容器：自身不参与命中测试，只把点击交给真正可见的按钮子视图。
/// 两个按钮都隐藏时，这块区域仍然属于标题栏，用户可以在上面拖动窗口。
final class HoverActionsContainerView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// 外部对象落在 Pane 边缘的语义。最靠边的蓝区打开对象 Pane；相邻的绿色内半区仅对
/// 目录有效，用该目录创建终端。文本不区分区域，始终粘贴到目标终端。
struct ExternalPaneDropZone: Equatable {
  let direction: SplitDirection
  let opensTerminal: Bool
}

@MainActor
final class ActivePaneHostView: NSView {
  /// 所属面板的 ID：窗口级点击监视器沿 superview 链命中本视图后据此激活对应面板。
  /// 顶边感应带与把手的高度：太矮抓不到，太高会让顶部一整条都在触发淡入。
  private static let handleRevealHeight: CGFloat = 14
  /// 安装顶条控件(把手/关闭按钮)后内容让出的高度:顶条自身 14pt + 与内容的间距,
  /// 避免胶囊和按钮压在终端首行文本上。
  private static let chromeContentInset: CGFloat = 18
  let paneID: UUID
  private let activation: () -> Void
  private let onExternalDrop: (NSPasteboard, ExternalPaneDropZone) -> Bool
  private var dragHandle: PaneDragHandleView?
  private var closeButton: PaneCloseButton?
  private var handleTrackingArea: NSTrackingArea?
  private var externalDropZone: ExternalPaneDropZone?
  private weak var contentView: NSView?
  private var contentTopConstraint: NSLayoutConstraint?
  private var contentBottomConstraint: NSLayoutConstraint?
  private var bottomAccessory: NSView?
  /// 非聚焦 Pane 的内容整体透明度。用 alpha 而不是颜色遮罩：透明主题的 window 色
  /// 自带 alpha，`withAlphaComponent` 会把它画成近黑色块；alpha 褪色让内容朝下层
  /// 主题材质本身淡出，任何主题下语义一致，也不需要点击穿透的遮罩视图。
  private static let inactiveContentAlpha: CGFloat = 0.55
  /// 焦点状态由容器保存，供关闭、移动和 first responder 路由使用；切换只翻转内容
  /// 透明度（未聚焦 Pane 变灰），不重建视图树。
  var isActivePane: Bool {
    didSet { applyActivationAppearance() }
  }

  /// 把当前焦点状态落到内容视图透明度上；拖动把手与底部附件不参与褪色。
  private func applyActivationAppearance() {
    contentView?.alphaValue = isActivePane ? 1 : Self.inactiveContentAlpha
  }

  init(
    paneID: UUID,
    isActive: Bool,
    onExternalDrop: @escaping (NSPasteboard, ExternalPaneDropZone) -> Bool,
    activation: @escaping () -> Void
  ) {
    self.paneID = paneID
    self.activation = activation
    self.onExternalDrop = onExternalDrop
    isActivePane = isActive
    super.init(frame: .zero)
    wantsLayer = true
    registerForDraggedTypes([.fileURL, .URL, .string])
  }

  required init?(coder: NSCoder) { nil }

  /// 安装 Pane 主体内容。底边单独保留可替换的约束，底部附件出现时把内容顶上去，
  /// 而不是压在内容之上。
  func installContent(_ view: NSView) {
    addSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    let top = view.topAnchor.constraint(equalTo: topAnchor)
    let bottom = view.bottomAnchor.constraint(equalTo: bottomAnchor)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: leadingAnchor),
      view.trailingAnchor.constraint(equalTo: trailingAnchor),
      top,
      bottom,
    ])
    contentView = view
    contentTopConstraint = top
    contentBottomConstraint = bottom
    // 恢复/重建工作区时 host 以初始焦点状态创建，didSet 不会触发，这里补一次。
    applyActivationAppearance()
  }

  /// 安装或移除底部附件（当前只有 Prompt Queue）。附件必须占据布局空间：覆盖在
  /// 终端上会挡住最后几行输出，用户恰好看不到刚发出去那条命令的结果。传 nil 时
  /// 内容底边回到 Pane 底边，终端随之恢复原有行数。
  func setBottomAccessory(_ accessory: NSView?, inset: CGFloat = 8) {
    guard bottomAccessory !== accessory else { return }
    bottomAccessory?.removeFromSuperview()
    bottomAccessory = accessory
    contentBottomConstraint?.isActive = false
    guard let contentView else { return }
    guard let accessory else {
      let bottom = contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
      bottom.isActive = true
      contentBottomConstraint = bottom
      return
    }
    addSubview(accessory)
    accessory.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      accessory.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      accessory.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
    ])
    let bottom = contentView.bottomAnchor.constraint(
      equalTo: accessory.topAnchor, constant: -inset)
    bottom.isActive = true
    contentBottomConstraint = bottom
  }

  override func mouseDown(with event: NSEvent) {
    activation()
    super.mouseDown(with: event)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateExternalDropZone(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateExternalDropZone(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    externalDropZone = nil
    layer?.borderWidth = 0
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { draggingExited(sender) }
    guard let externalDropZone else { return false }
    activation()
    return onExternalDrop(sender.draggingPasteboard, externalDropZone)
  }

  private func updateExternalDropZone(_ sender: NSDraggingInfo) -> NSDragOperation {
    let point = convert(sender.draggingLocation, from: nil)
    guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return [] }
    let distances: [(SplitDirection, CGFloat)] = [
      (.left, point.x), (.right, bounds.width - point.x),
      (.down, point.y), (.up, bounds.height - point.y),
    ]
    guard let nearest = distances.min(by: { $0.1 < $1.1 }) else { return [] }
    let dimension = nearest.0.isHorizontal ? bounds.width : bounds.height
    guard nearest.1 <= dimension * 0.30 else { return [] }
    externalDropZone = ExternalPaneDropZone(
      direction: nearest.0,
      opensTerminal: nearest.1 > dimension * 0.15
    )
    layer?.borderWidth = 2
    layer?.borderColor =
      (externalDropZone?.opensTerminal == true
      ? NSColor.systemGreen : AsterTheme.accent).cgColor
    return .copy
  }

  /// 顶边感应带：指针靠近 Pane 顶部时淡入拖动把手。用 `NSTrackingArea` 而不是叠一层
  /// 视图——终端要占满整个 Pane，任何实体覆盖层都会吃掉那一条上的点击与拖选。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let handleTrackingArea { removeTrackingArea(handleTrackingArea) }
    guard dragHandle != nil || closeButton != nil else { return }
    let strip = NSRect(
      x: 0, y: max(0, bounds.height - Self.handleRevealHeight),
      width: bounds.width, height: min(bounds.height, Self.handleRevealHeight))
    let area = NSTrackingArea(
      rect: strip,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self
    )
    addTrackingArea(area)
    handleTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    dragHandle?.isRevealed = true
    closeButton?.isRevealed = true
  }
  override func mouseExited(with event: NSEvent) {
    dragHandle?.isRevealed = false
    closeButton?.isRevealed = false
  }

  /// 顶条控件安装后把内容整体下移,让胶囊/按钮与内容之间留出固定间距,
  /// 不再压在终端首行文本上。重复调用幂等。
  private func applyChromeContentInset() {
    contentTopConstraint?.constant = Self.chromeContentInset
  }

  /// 安装顶边拖动把手；只有存在多个 Pane 时才有意义（单 Pane 无处可拖）。
  func installDragHandle(onDragStart: @escaping (UUID, NSEvent) -> Void) {
    guard dragHandle == nil else { return }
    let paneID = paneID
    let handle = PaneDragHandleView { event in onDragStart(paneID, event) }
    handle.translatesAutoresizingMaskIntoConstraints = false
    addSubview(handle)
    NSLayoutConstraint.activate([
      handle.centerXAnchor.constraint(equalTo: centerXAnchor),
      handle.topAnchor.constraint(equalTo: topAnchor),
      handle.widthAnchor.constraint(equalToConstant: 96),
      handle.heightAnchor.constraint(equalToConstant: Self.handleRevealHeight),
    ])
    dragHandle = handle
    applyChromeContentInset()
  }

  /// 安装顶条最右侧的关闭按钮;与把手一样只在多 Pane 时有意义(最后一个 Pane 无处可关)。
  func installCloseButton(onClose: @escaping (UUID) -> Void) {
    guard closeButton == nil else { return }
    let paneID = paneID
    let button = PaneCloseButton { onClose(paneID) }
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(button)
    NSLayoutConstraint.activate([
      button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      button.centerYAnchor.constraint(
        equalTo: topAnchor, constant: Self.handleRevealHeight / 2),
      button.widthAnchor.constraint(equalToConstant: Self.handleRevealHeight),
      button.heightAnchor.constraint(equalToConstant: Self.handleRevealHeight),
    ])
    closeButton = button
    applyChromeContentInset()
  }

}

@MainActor
final class DocumentTextDelegate: NSObject, NSTextViewDelegate {
  weak var runtime: WorkspacePaneRuntime?
  private let onChange: (() -> Void)?

  init(runtime: WorkspacePaneRuntime, onChange: (() -> Void)? = nil) {
    self.runtime = runtime
    self.onChange = onChange
  }

  func textDidChange(_ notification: Notification) {
    guard let text = notification.object as? NSTextView else { return }
    runtime?.updateDocument(text.string)
    onChange?()
  }
}
