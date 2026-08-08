import AppKit
import AsterCore

/// 活动 Pane 底部的 Prompt Queue。设计上把每条待发送命令和输入框绘制为相互独立的
/// 圆角卡片：Return 只入队，列表行左侧图标才会立即写入 Agent 并提交。
@MainActor
final class PromptQueueBarView: NSView, NSTextViewDelegate {
  private let textView = PlaceholderTextView()
  private var heightConstraint: NSLayoutConstraint!
  private let onDraftChanged: (String) -> Bool
  private let onEnqueue: () -> Bool
  private let onSend: (UUID) -> Bool
  private let onRemove: (UUID) -> Void
  private let onClose: () -> Void
  private let queueItemsHeight: CGFloat
  private var isExpanded = false

  private enum Metrics {
    static let inputHeight: CGFloat = 70
    static let expandedInputHeight: CGFloat = 142
    static let cardSpacing: CGFloat = 16
    static let visibleItemLimit = 3
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

    if !items.isEmpty { content.addArrangedSubview(makeQueueList(items: items)) }
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
      rows.addArrangedSubview(
        PromptQueueItemView(
          item: item,
          onSend: { [weak self] in _ = self?.onSend(item.id) },
          onRemove: { [weak self] in self?.onRemove(item.id) }
        )
      )
    }

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = items.count > Metrics.visibleItemLimit
    scroll.autohidesScrollers = true
    scroll.documentView = rows
    rows.translatesAutoresizingMaskIntoConstraints = false
    rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: queueItemsHeight).isActive = true
    return scroll
  }

  private func makeInputCard(draft: String) -> NSView {
    let card = PromptQueueCardView()
    card.heightAnchor.constraint(equalToConstant: Metrics.inputHeight).isActive = true

    textView.string = draft
    textView.delegate = self
    textView.font = NSFont.systemFont(ofSize: 14, weight: .regular)
    textView.textColor = AsterTheme.ink
    textView.backgroundColor = .clear
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 0, height: 8)
    textView.textContainer?.lineFragmentPadding = 0
    textView.drawsBackground = false
    textView.placeholder = "加入 Prompt 队列…"
    let textScroll = NSScrollView()
    textScroll.drawsBackground = false
    textScroll.borderType = .noBorder
    textScroll.hasVerticalScroller = false
    textScroll.documentView = textView

    let close = ActionButton(title: "关闭", bezelStyle: .inline) { [weak self] in self?.onClose() }
    close.font = NSFont.systemFont(ofSize: 14, weight: .medium)
    close.contentTintColor = AsterTheme.secondaryInk
    let expand = ActionButton(symbol: "arrow.down.left.and.arrow.up.right", bezelStyle: .inline) {
      [weak self] in self?.toggleExpanded()
    }
    expand.toolTip = "展开/收起多行输入"
    expand.contentTintColor = AsterTheme.secondaryInk
    let enqueue = ActionButton(symbol: "arrow.up.circle.fill", bezelStyle: .inline) { [weak self] in
      self?.enqueue()
    }
    enqueue.toolTip = "加入队列（Return）"
    enqueue.contentTintColor = AsterTheme.secondaryInk
    constrainIconButton(expand)
    constrainIconButton(enqueue)

    let row = NSStackView(views: [textScroll, close, expand, enqueue])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 14
    row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
    card.addSubview(row)
    row.pinEdges(to: card)
    return card
  }

  private func toggleExpanded() {
    isExpanded.toggle()
    heightConstraint.constant = (isExpanded ? Metrics.expandedInputHeight : Metrics.inputHeight)
      + queueItemsHeight + (queueItemsHeight == 0 ? 0 : Metrics.cardSpacing)
    textView.isVerticallyResizable = isExpanded
    superview?.layoutSubtreeIfNeeded()
  }

  private func enqueue() {
    guard onDraftChanged(textView.string) else { return }
    // 只有领域层已接受该项才清空文本；超限、空文本和队列满都保留用户输入。
    if onEnqueue() { textView.string = "" }
  }
}

/// 队列中的一张命令卡。操作图标保持在卡片两侧，文本则使用设计稿的单行摘要样式。
@MainActor
private final class PromptQueueItemView: PromptQueueCardView {
  static let height: CGFloat = 80

  init(item: AgentQueuedPrompt, onSend: @escaping () -> Void, onRemove: @escaping () -> Void) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: Self.height).isActive = true

    let send = ActionButton(symbol: "arrow.turn.down.right", bezelStyle: .inline, handler: onSend)
    send.toolTip = "立即发送此命令"
    // 设计稿把唯一的立即发送动作置于浅色圆角底上，使其与右侧删除动作区分开。
    send.wantsLayer = true
    send.layer?.backgroundColor = AsterTheme.hairline.withAlphaComponent(0.72).cgColor
    send.layer?.cornerRadius = 8
    send.layer?.cornerCurve = .continuous
    send.contentTintColor = AsterTheme.ink
    constrainIconButton(send, side: 38)
    let text = NSTextField(labelWithString: item.text)
    text.font = NSFont.systemFont(ofSize: 14, weight: .medium)
    text.textColor = AsterTheme.ink
    text.lineBreakMode = .byTruncatingTail
    text.maximumNumberOfLines = 1
    let remove = ActionButton(symbol: "trash", bezelStyle: .inline, handler: onRemove)
    remove.toolTip = "从队列移除"
    remove.contentTintColor = AsterTheme.tertiaryInk
    constrainIconButton(remove)

    let row = NSStackView(views: [send, text, remove])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 14
    row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 14)
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

/// 两类卡片共享截图中的低对比度圆角面板外观，避免容器再套一层边框。
@MainActor
private class PromptQueueCardView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.98).cgColor
    layer?.borderWidth = 1
    layer?.borderColor = AsterTheme.hairline.cgColor
    layer?.cornerRadius = 20
    layer?.cornerCurve = .continuous
  }

  required init?(coder: NSCoder) { nil }
}

/// 图标仍使用标准 `ActionButton`，这里统一补足设计稿需要的 28–38pt 命中面积。
@MainActor
private func constrainIconButton(_ button: NSButton, side: CGFloat = 28) {
  button.widthAnchor.constraint(equalToConstant: side).isActive = true
  button.heightAnchor.constraint(equalToConstant: side).isActive = true
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
      at: NSPoint(x: textContainerInset.width, y: textContainerInset.height + 1),
      withAttributes: attributes
    )
  }
}
