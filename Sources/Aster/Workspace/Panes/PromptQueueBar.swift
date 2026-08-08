import AppKit
import AsterCore

/// 活动 Pane 底部的 Prompt Queue。设计稿把每条待发送命令和输入框绘制为相互独立的
/// 圆角卡片：Return 只入队，列表行左侧图标才会立即写入 Agent 并提交。
@MainActor
final class PromptQueueBarView: NSView, NSTextViewDelegate {
  private let textView = PlaceholderTextView()
  private var heightConstraint: NSLayoutConstraint!
  /// 展开按钮要在 `self` 可用后才能绑定 toggle 闭包，因此延后到 `makeInputCard` 创建。
  private var expandButton: IconHoverButton!
  private var inputCardHeightConstraint: NSLayoutConstraint!
  private weak var textScroll: NSScrollView?
  private let onDraftChanged: (String) -> Bool
  private let onEnqueue: () -> Bool
  private let onSend: (UUID) -> Bool
  private let onRemove: (UUID) -> Void
  private let onClose: () -> Void
  private let queueItemsHeight: CGFloat
  private var isExpanded = false

  /// 尺寸取自设计稿：两类卡片同高、8pt 间距、10pt 圆角，视觉重量低于终端网格。
  private enum Metrics {
    static let inputHeight: CGFloat = 44
    static let expandedInputHeight: CGFloat = 142
    static let cardSpacing: CGFloat = 8
    static let visibleItemLimit = 3
    static let controlSpacing: CGFloat = 10
  }

  init(
    draft: String,
    items: [AgentQueuedPrompt],
    onDraftChanged: @escaping (String) -> Bool,
    onEnqueue: @escaping () -> Bool,
    onSend: @escaping (UUID) -> Bool,
    onRemove: @escaping (UUID) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.onDraftChanged = onDraftChanged
    self.onEnqueue = onEnqueue
    self.onSend = onSend
    self.onRemove = onRemove
    self.onClose = onClose
    queueItemsHeight = PromptQueueItemView.listHeight(
      itemCount: items.count,
      visibleItemLimit: Metrics.visibleItemLimit,
      spacing: Metrics.cardSpacing
    )
    super.init(frame: .zero)

    // 容器保持透明；背景、边框与圆角只属于设计稿中的两类独立卡片。
    translatesAutoresizingMaskIntoConstraints = false
    heightConstraint = heightAnchor.constraint(
      equalToConstant: Metrics.inputHeight + queueItemsHeight
        + (items.isEmpty ? 0 : Metrics.cardSpacing)
    )
    heightConstraint.isActive = true

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .width
    content.spacing = Metrics.cardSpacing
    addSubview(content)
    content.pinEdges(to: self)

    if !items.isEmpty {
      let list = makeQueueList(items: items)
      content.addArrangedSubview(list)
      // NSStackView 的 `.width` 对齐拗不过 NSScrollView 的固有宽度，缺这条约束时队列
      // 列表会塌成内容宽度，比下方输入框窄一大截。
      list.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    content.addArrangedSubview(makeInputCard(draft: draft))
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.textView) }
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    textView.needsDisplay = true
    _ = onDraftChanged(textView.string)
  }

  /// Shift-Return 保留为多行编辑；普通 Return 与右下角按钮遵循设计稿，只加入上方列表。
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard commandSelector == #selector(NSResponder.insertNewline(_:)),
      !NSEvent.modifierFlags.contains(.shift)
    else { return false }
    enqueue()
    return true
  }

  private func makeQueueList(items: [AgentQueuedPrompt]) -> NSView {
    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .width
    rows.spacing = Metrics.cardSpacing
    for item in items {
      let row = PromptQueueItemView(
        item: item,
        onSend: { [weak self] in _ = self?.onSend(item.id) },
        onRemove: { [weak self] in self?.onRemove(item.id) }
      )
      rows.addArrangedSubview(row)
      // `.width` 对齐只保证各行彼此等宽（取最宽的一行），不会撑到 stack 宽度。队列行
      // 要与下方输入行左右对齐，必须逐行绑定容器宽度。
      row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = items.count > Metrics.visibleItemLimit
    scroll.autohidesScrollers = true
    // legacy 滚动条会占走文档宽度，让队列卡比下方输入框窄一截；overlay 样式保证两者
    // 始终同宽（设计稿要求队列行与输入行左右对齐）。
    scroll.scrollerStyle = .overlay
    scroll.documentView = rows
    rows.translatesAutoresizingMaskIntoConstraints = false
    // 绑 scroll 而不是 contentView：clipView 的宽度由 NSScrollView 在内部按 frame 摆放，
    // 约束链在这里接不上，documentView 会停在自身的固有宽度上。
    rows.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: queueItemsHeight).isActive = true
    return scroll
  }

  private func makeInputCard(draft: String) -> NSView {
    let card = PromptQueueCardView()
    // 卡片自身的高度必须可变：只改外层容器高度的话，卡片仍锁在单行尺寸上，
    // 点展开按钮不会有任何视觉变化。
    inputCardHeightConstraint = card.heightAnchor.constraint(
      equalToConstant: Metrics.inputHeight)
    inputCardHeightConstraint.isActive = true

    textView.string = draft
    textView.delegate = self
    textView.font = NSFont.systemFont(ofSize: 14, weight: .regular)
    textView.textColor = AsterTheme.ink
    textView.backgroundColor = .clear
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    // 输入行只有 24pt 高，行高之外的余量按上下各 3pt 分配才能与右侧按钮对齐。
    textView.textContainerInset = NSSize(width: 0, height: 3)
    textView.textContainer?.lineFragmentPadding = 0
    textView.drawsBackground = false
    textView.placeholder = "加入 Prompt 队列…"
    // NSTextView 放进 NSScrollView 需要这组配置才能真正随内容增高并跟随宽度换行；
    // 缺少它们时展开后的多行输入会被裁在第一行。
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    let textScroll = NSScrollView()
    textScroll.drawsBackground = false
    textScroll.borderType = .noBorder
    textScroll.hasVerticalScroller = false
    textScroll.documentView = textView
    self.textScroll = textScroll

    let close = TextHoverButton(title: "关闭") { [weak self] in self?.onClose() }
    close.toolTip = "关闭 Prompt 队列输入条"
    expandButton = IconHoverButton(
      symbol: Symbols.expand, accessibilityDescription: "展开输入"
    ) { [weak self] in self?.toggleExpanded() }
    expandButton.toolTip = "展开/收起多行输入"
    applySymbolScale(to: expandButton)
    let enqueue = FilledCircleButton(symbol: "arrow.up", accessibilityDescription: "加入队列") {
      [weak self] in self?.enqueue()
    }
    enqueue.toolTip = "加入队列（Return）"
    constrainIconButton(expandButton)
    constrainIconButton(enqueue, side: 24)

    let row = NSStackView(views: [textScroll, close, expandButton, enqueue])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Metrics.controlSpacing
    row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 9)
    card.addSubview(row)
    row.pinEdges(to: card)
    return card
  }

  private func toggleExpanded() {
    isExpanded.toggle()
    let inputHeight = isExpanded ? Metrics.expandedInputHeight : Metrics.inputHeight
    inputCardHeightConstraint.constant = inputHeight
    heightConstraint.constant = inputHeight + queueItemsHeight
      + (queueItemsHeight == 0 ? 0 : Metrics.cardSpacing)
    textScroll?.hasVerticalScroller = isExpanded
    // 展开后是多行编辑区，文本要从顶部起排；单行态则靠内边距与右侧按钮对齐。
    textView.textContainerInset = NSSize(width: 0, height: isExpanded ? 8 : 3)
    // 图标要跟随状态翻转，否则展开后仍显示“展开”语义，用户无从判断再点会发生什么。
    expandButton.setSymbol(
      isExpanded ? Symbols.collapse : Symbols.expand,
      accessibilityDescription: isExpanded ? "收起输入" : "展开输入"
    )
    window?.makeFirstResponder(textView)
    superview?.layoutSubtreeIfNeeded()
  }

  private func enqueue() {
    guard onDraftChanged(textView.string) else { return }
    // 只有领域层已接受该项才清空文本；超限、空文本和队列满都保留用户输入。
    if onEnqueue() { textView.string = "" }
  }

  private enum Symbols {
    static let expand = "arrow.down.left.and.arrow.up.right"
    static let collapse = "arrow.up.right.and.arrow.down.left"
  }
}

/// 队列中的一张命令卡。左侧 ↳ 是立即发送，右侧垃圾桶是移除；两者都用悬停按钮，
/// 静止状态与设计稿一致地保持无底色。
@MainActor
private final class PromptQueueItemView: PromptQueueCardView {
  static let height: CGFloat = 44

  init(item: AgentQueuedPrompt, onSend: @escaping () -> Void, onRemove: @escaping () -> Void) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: Self.height).isActive = true

    let send = IconHoverButton(
      symbol: "arrow.turn.down.right", accessibilityDescription: "立即发送", handler: onSend)
    send.toolTip = "立即发送此命令"
    applySymbolScale(to: send)
    constrainIconButton(send)
    let text = NSTextField(labelWithString: item.text)
    text.font = NSFont.systemFont(ofSize: 14, weight: .regular)
    text.textColor = AsterTheme.ink
    text.lineBreakMode = .byTruncatingTail
    text.maximumNumberOfLines = 1
    let remove = IconHoverButton(
      symbol: "trash", accessibilityDescription: "从队列移除", handler: onRemove)
    remove.toolTip = "从队列移除"
    remove.restingTint = AsterTheme.tertiaryInk
    applySymbolScale(to: remove)
    constrainIconButton(remove)

    let row = NSStackView(views: [send, text, remove])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 8)
    addSubview(row)
    row.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }

  static func listHeight(itemCount: Int, visibleItemLimit: Int, spacing: CGFloat) -> CGFloat {
    let visibleCount = min(itemCount, visibleItemLimit)
    guard visibleCount > 0 else { return 0 }
    return CGFloat(visibleCount) * height + CGFloat(visibleCount - 1) * spacing
  }
}

/// 两类卡片共享设计稿的低对比度圆角面板外观，避免容器再套一层边框。
@MainActor
private class PromptQueueCardView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.98).cgColor
    layer?.borderWidth = 1
    layer?.borderColor = AsterTheme.hairline.cgColor
    layer?.cornerRadius = 10
    layer?.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { nil }
}

/// 设计稿的图标比 SF Symbol 默认字号更舒展；按钮尺寸只决定命中面积，符号尺寸要
/// 单独指定，否则图标会缩在 24pt 命中框中间显得偏小。
@MainActor
private func applySymbolScale(to button: NSButton, pointSize: CGFloat = 15) {
  button.image = button.image?.withSymbolConfiguration(
    .init(pointSize: pointSize, weight: .regular))
}

/// 统一设计稿里 24pt 的图标命中面积，避免各按钮尺寸漂移导致基线不齐。
@MainActor
private func constrainIconButton(_ button: NSButton, side: CGFloat = 24) {
  button.widthAnchor.constraint(equalToConstant: side).isActive = true
  button.heightAnchor.constraint(equalToConstant: side).isActive = true
}

/// 设计稿右下角的主操作：实心圆底 + 反色箭头。`arrow.up.circle.fill` 的镂空箭头会
/// 透出卡片灰底，对比度不足，因此圆底由 layer 自己画，symbol 只画箭头。
@MainActor
private final class FilledCircleButton: NSButton {
  private let handler: () -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false

  init(symbol: String, accessibilityDescription: String?, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    imagePosition = .imageOnly
    bezelStyle = .accessoryBarAction
    isBordered = false
    wantsLayer = true
    layer?.cornerCurve = .continuous
    target = self
    action = #selector(invoke)
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovering = true
    applyAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovering = false
    applyAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .pointingHand)
  }

  private func applyAppearance() {
    contentTintColor = AsterTheme.paper
    layer?.backgroundColor =
      (isHovering ? AsterTheme.ink.withAlphaComponent(0.82) : AsterTheme.ink).cgColor
  }

  @objc private func invoke() { handler() }
}

/// 设计稿的“关闭”是纯文字按钮，没有 bezel；悬停时加深文字并补一层浅底，让用户
/// 能分辨这是可点区域而不是状态标签。
@MainActor
private final class TextHoverButton: NSButton {
  private let handler: () -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    font = NSFont.systemFont(ofSize: 14, weight: .regular)
    bezelStyle = .accessoryBarAction
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 5
    layer?.cornerCurve = .continuous
    target = self
    action = #selector(invoke)
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    var size = super.intrinsicContentSize
    size.width += 10
    return size
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovering = true
    applyAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovering = false
    applyAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .pointingHand)
  }

  private func applyAppearance() {
    let color = isHovering ? AsterTheme.ink : AsterTheme.secondaryInk
    attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 14),
        .foregroundColor: color,
      ]
    )
    layer?.backgroundColor = isHovering
      ? AsterTheme.ink.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
  }

  @objc private func invoke() { handler() }
}

/// AppKit 的 `NSTextView` 没有原生 placeholder；仅在文本为空时绘制提示，绘制层不参与
/// 命中测试，也不会把提示文字写入队列草稿。
@MainActor
private final class PlaceholderTextView: NSTextView {
  var placeholder = "" { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 14),
      .foregroundColor: AsterTheme.tertiaryInk,
    ]
    placeholder.draw(
      at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
      withAttributes: attributes
    )
  }
}
