// 「收起实时画面」后盖在终端宿主上的静态状态卡：说明这个 Pane 在做什么，并提供唯一的恢复入口。
import AppKit
import AsterCore
import Combine

/// 状态卡展示的纯数据。只由会话事件（Agent provider / 任务状态 / 标题）推导，
/// 不含任何时钟相关字段，因此相同输入永远得到相同结果，可用 `Equatable` 去重重绘。
struct TerminalPaneCollapsedCardPresentation: Equatable {
  /// 状态卡的强调级别；只有「等待你确认或输入」需要醒目。
  enum Emphasis: Equatable {
    case calm
    case attention
  }

  var title: String
  var status: String
  var symbol: String
  var emphasis: Emphasis

  /// 按会话当前状态生成展示。有 Agent 时显示 provider 与任务状态；否则显示 Pane 标题。
  ///
  /// Agent 运行期间刻意不使用终端标题：Claude Code 等会以 spinner 字符高频改写标题，
  /// 若把标题放进展示，去重失效，卡片就会随标题一起反复重绘。
  init(
    provider: AgentProvider?,
    taskState: AgentTaskState,
    completionUnread: Bool,
    terminalTitle: String
  ) {
    guard let provider else {
      let trimmed = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      title = trimmed.isEmpty ? L("终端") : trimmed
      status = L("实时画面已收起")
      symbol = "terminal"
      emphasis = .calm
      return
    }
    title = provider.displayName
    switch taskState {
    case .processing:
      status = L("处理中")
      symbol = "ellipsis.circle"
      emphasis = .calm
    case .awaitingInput:
      status = L("等待你确认或输入")
      symbol = "hand.raised"
      emphasis = .attention
    case .idle:
      status = completionUnread ? L("已完成") : L("空闲")
      symbol = completionUnread ? "checkmark.circle" : "pause.circle"
      emphasis = .calm
    }
  }
}

/// 覆盖整个终端宿主的静态状态卡。终端 surface 此时处于隐藏状态，libghostty 不再绘制；
/// 卡片本身没有定时器或动画，只在会话状态事件到达且展示真的变化时重绘。
///
/// 根视图可以成为 first responder：Pane 获得焦点时键盘落在这里而不是隐藏的终端，
/// Return / Space 恢复实时画面，其他按键一律吞掉，绝不盲目写进看不见的程序。
@MainActor
final class TerminalPaneCollapsedCardView: NSView {
  private let onRestore: () -> Void
  private let card = NSView()
  private let icon = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private var subscription: AnyCancellable?
  /// 当前已渲染的展示；测试据此断言事件驱动的更新。
  private(set) var presentation: TerminalPaneCollapsedCardPresentation?
  /// 恢复按钮；internal 供测试模拟点击。
  let restoreButton: ActionButton

  /// 创建状态卡并订阅会话的 Agent / 标题事件。`collapsedAt` 只在创建时格式化一次。
  init(session: TerminalSession, collapsedAt: Date, onRestore: @escaping () -> Void) {
    self.onRestore = onRestore
    restoreButton = ActionButton(title: L("恢复实时画面"), symbol: "play.rectangle") { onRestore() }
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("terminal-collapsed-card-\(session.id.uuidString)")
    focusRingType = .exterior
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    buildCard(collapsedAt: collapsedAt)

    // 四个来源合并成一份展示，再按值去重：标题或未读标记的无关变化不会触发重绘。
    subscription = Publishers.CombineLatest4(
      session.$activeAgentProvider,
      session.$agentTaskState,
      session.$agentTaskCompletionUnread,
      session.$terminalTitle
    )
    .map { provider, state, unread, title in
      TerminalPaneCollapsedCardPresentation(
        provider: provider, taskState: state, completionUnread: unread, terminalTitle: title)
    }
    .removeDuplicates()
    .sink { [weak self] presentation in self?.render(presentation) }
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - 布局

  /// 组装居中的小卡片：图标 + 标题、状态、收起时刻说明与恢复按钮。
  private func buildCard(collapsedAt: Date) {
    card.wantsLayer = true
    card.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.96).cgColor
    card.layer?.borderColor = AsterTheme.hairline.cgColor
    card.layer?.borderWidth = 1
    card.layer?.cornerRadius = 10

    icon.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: InterfaceScale.font(15), weight: .medium)
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: InterfaceScale.length(20)),
      icon.heightAnchor.constraint(equalToConstant: InterfaceScale.length(20)),
    ])
    titleLabel.font = .interface(ofSize: 12.5, weight: .semibold)
    titleLabel.textColor = AsterTheme.ink
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let heading = NSStackView(views: [icon, titleLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 6

    statusLabel.font = .interface(ofSize: 11.5, weight: .medium)
    statusLabel.alignment = .center

    // 收起时刻只格式化一次；卡片上没有任何随时间走动的计数，避免周期性唤醒。
    let time = DateFormatter.localizedString(from: collapsedAt, dateStyle: .none, timeStyle: .short)
    let detail = NSTextField(
      wrappingLabelWithString: L("收起于 \(time)。进程继续在后台运行，画面暂不绘制。"))
    detail.font = .interface(ofSize: 10.5)
    detail.textColor = AsterTheme.tertiaryInk
    detail.alignment = .center
    detail.maximumNumberOfLines = 2

    restoreButton.identifier = NSUserInterfaceItemIdentifier("terminal-restore-live-view")
    restoreButton.controlSize = .regular

    let column = NSStackView(views: [heading, statusLabel, detail, restoreButton])
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = 6
    column.setCustomSpacing(12, after: detail)
    column.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
    card.addSubview(column)
    column.pinEdges(to: card)

    addSubview(card)
    card.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: centerXAnchor),
      card.centerYAnchor.constraint(equalTo: centerYAnchor),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      card.widthAnchor.constraint(lessThanOrEqualToConstant: InterfaceScale.length(360)),
      detail.widthAnchor.constraint(lessThanOrEqualToConstant: InterfaceScale.length(300)),
    ])
  }

  /// 把展示写进控件；「等待输入」用主题的 warning 色强调标题图标、状态与边框。
  private func render(_ presentation: TerminalPaneCollapsedCardPresentation) {
    self.presentation = presentation
    let attention = presentation.emphasis == .attention
    icon.image = NSImage(
      systemSymbolName: presentation.symbol, accessibilityDescription: presentation.status)
    icon.contentTintColor = attention ? AsterTheme.warning : AsterTheme.secondaryInk
    titleLabel.stringValue = presentation.title
    statusLabel.stringValue = presentation.status
    statusLabel.textColor = attention ? AsterTheme.warning : AsterTheme.secondaryInk
    card.layer?.borderColor = (attention ? AsterTheme.warning : AsterTheme.hairline).cgColor
    card.layer?.borderWidth = attention ? 1.5 : 1
    setAccessibilityLabel("\(presentation.title), \(presentation.status)")
  }

  // MARK: - 键盘与焦点

  override var acceptsFirstResponder: Bool { true }

  /// Return / Space 恢复实时画面；其余按键全部吞掉，既不写入隐藏的终端，也不发出提示音。
  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection([.command, .control, .option])
    // 36 = Return，76 = 小键盘 Enter，49 = Space。
    if flags.isEmpty, [36, 76, 49].contains(event.keyCode) {
      onRestore()
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { noteFocusRingMaskChanged() }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { noteFocusRingMaskChanged() }
    return accepted
  }

  /// 焦点环只画在居中卡片上，而不是整个 Pane 外框。
  override var focusRingMaskBounds: NSRect { card.frame }

  /// 焦点环形状与卡片圆角一致。
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: card.frame, xRadius: 10, yRadius: 10).fill()
  }

  override func layout() {
    super.layout()
    noteFocusRingMaskChanged()
  }

  // MARK: - 右键菜单

  /// 收起状态下右键只提供恢复；终端菜单里的复制、粘贴对隐藏的画面没有意义。
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu(title: L("终端"))
    let onRestore = onRestore
    let item = ActionMenuItem(title: L("恢复实时画面")) { onRestore() }
    item.identifier = NSUserInterfaceItemIdentifier("terminal-live-view-toggle")
    menu.addItem(item)
    return menu
  }
}

/// 「收起 / 恢复实时画面」的菜单文案与终端右键菜单条目，菜单栏与右键菜单共用同一套标题。
@MainActor
enum TerminalLiveViewMenu {
  /// 按当前状态返回切换命令的标题。
  static func title(collapsed: Bool) -> String {
    collapsed ? L("恢复实时画面") : L("收起实时画面")
  }

  /// 终端右键菜单条目：按 Pane ID 作用于被右键的那个 Pane，而不是当前活动 Pane。
  /// 画中画占用等不可切换的情况返回置灰条目，让用户知道能力存在但此刻不可用。
  static func makeContextMenuItem(model: AppModel, paneID: UUID) -> NSMenuItem {
    let collapsed = model.tabs.lazy
      .compactMap { $0.runtime(for: paneID)?.terminalSession }.first?.isLiveViewCollapsed == true
    let title = title(collapsed: collapsed)
    let item: NSMenuItem
    if model.canToggleLiveView(paneID: paneID) {
      item = ActionMenuItem(title: title) { [weak model] in model?.toggleLiveView(paneID: paneID) }
    } else {
      // action 为 nil 的条目会被 NSMenu 自动置灰。
      item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
    item.identifier = NSUserInterfaceItemIdentifier("terminal-live-view-toggle")
    return item
  }
}
