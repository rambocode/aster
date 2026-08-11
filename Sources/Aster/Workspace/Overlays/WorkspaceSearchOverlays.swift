import AppKit
import AsterCore
import Combine

/// 全局查找、Agent 历史与命令面板等工作区级浮层。

@MainActor
final class GlobalFindOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let stack = NSStackView()
  private let search = OverlaySearchField()
  private let caseSensitive = NSButton(title: "Aa", target: nil, action: nil)
  private let regularExpression = NSButton(title: ".*", target: nil, action: nil)
  private let documents: [WorkspaceSearchDocument]
  private var results: [WorkspaceSearchResult] = []
  private var buttons: [NSButton] = []
  private var selectedIndex = 0

  init(model: AppModel) {
    self.model = model
    documents = model.workspaceSearchDocuments()
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.98).cgColor
    host.layer?.cornerRadius = 12
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.cgColor
    host.shadow = NSShadow()
    host.shadow?.shadowBlurRadius = 24
    host.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)
    stack.orientation = .vertical
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    search.placeholderString = "在全部终端和已打开文件中查找…"
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] _ in self?.activateSelection() }
    search.onCancel = { [weak model] in model?.isGlobalFindPresented = false }
    for button in [caseSensitive, regularExpression] {
      button.setButtonType(.toggle)
      button.bezelStyle = .inline
      button.target = self
      button.action = #selector(optionsChanged(_:))
    }
    caseSensitive.toolTip = "区分大小写"
    regularExpression.toolTip = "正则表达式"
    let header = NSStackView(views: [search, caseSensitive, regularExpression])
    header.orientation = .horizontal
    header.spacing = 8
    stack.addArrangedSubview(header)
    host.addSubview(stack)
    stack.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) {
    selectedIndex = 0
    reload()
  }

  @objc private func optionsChanged(_ sender: Any?) {
    selectedIndex = 0
    reload()
  }

  private func reload() {
    while stack.arrangedSubviews.count > 1 {
      stack.arrangedSubviews.last?.removeFromSuperview()
    }
    results = GlobalWorkspaceSearch.search(
      documents: documents,
      query: search.stringValue,
      options: .init(
        caseSensitive: caseSensitive.state == .on,
        regularExpression: regularExpression.state == .on
      ),
      maximumResults: 500
    )
    buttons.removeAll()
    if search.stringValue.isEmpty {
      stack.addArrangedSubview(
        makeLabel("输入内容以搜索当前窗口的全部 Pane。", size: 11, color: AsterTheme.secondaryInk))
      return
    }
    if results.isEmpty {
      stack.addArrangedSubview(makeLabel("没有匹配项", size: 11, color: AsterTheme.secondaryInk))
      return
    }
    for result in results.prefix(12) {
      let button = ActionButton(
        title: "\(result.title):\(result.line)    \(result.preview)", bezelStyle: .inline
      ) { [weak model] in
        model?.revealWorkspaceLocation(
          tabID: result.tabID,
          paneID: result.paneID,
          absoluteRow: result.absoluteRow
        )
      }
      button.alignment = .left
      button.isBordered = false
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      stack.addArrangedSubview(button)
      buttons.append(button)
    }
    selectedIndex = min(selectedIndex, buttons.count - 1)
    updateSelectionAppearance()
  }

  private func moveSelection(_ delta: Int) {
    guard !buttons.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + buttons.count) % buttons.count
    updateSelectionAppearance()
  }

  private func activateSelection() {
    guard results.indices.contains(selectedIndex) else { return }
    let result = results[selectedIndex]
    model.revealWorkspaceLocation(
      tabID: result.tabID,
      paneID: result.paneID,
      absoluteRow: result.absoluteRow
    )
  }

  private func updateSelectionAppearance() {
    for (index, button) in buttons.enumerated() {
      button.wantsLayer = true
      button.layer?.cornerRadius = 6
      button.layer?.backgroundColor =
        index == selectedIndex
        ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }
  }
}

@MainActor
final class AgentHistoryOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let search = OverlaySearchField()
  private let resultsStack = NSStackView()
  private let transcript = NSTextView()
  private var histories: [AgentSessionHistory] = []
  private var selectedIndex = 0
  private var historyCancellable: AnyCancellable?

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
    historyCancellable = model.agentHistoriesChanged.sink { [weak self] _ in
      guard let self, self.isViewLoaded else { return }
      self.reload()
    }
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.99).cgColor
    host.layer?.cornerRadius = 12
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.cgColor
    host.shadow = NSShadow()
    host.shadow?.shadowBlurRadius = 24
    host.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)

    search.placeholderString = "搜索 Agent 标题、项目、模型或 transcript…"
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] _ in self?.resumeSelection() }
    search.onCancel = { [weak model] in model?.isAgentHistoryPresented = false }
    let refresh = ActionButton(symbol: "arrow.clockwise") { [weak model] in
      model?.reloadAgentHistory()
    }
    let close = ActionButton(symbol: "xmark") { [weak model] in
      model?.isAgentHistoryPresented = false
    }
    let header = NSStackView(views: [search, refresh, close])
    header.orientation = .horizontal
    header.spacing = 8

    resultsStack.orientation = .vertical
    resultsStack.spacing = 4
    let resultsScroll = NSScrollView()
    resultsScroll.hasVerticalScroller = true
    resultsScroll.drawsBackground = false
    resultsScroll.documentView = resultsStack
    resultsStack.translatesAutoresizingMaskIntoConstraints = false
    resultsStack.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor).isActive =
      true
    resultsScroll.translatesAutoresizingMaskIntoConstraints = false
    resultsScroll.widthAnchor.constraint(equalToConstant: 270).isActive = true

    transcript.isEditable = false
    transcript.isSelectable = true
    transcript.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    transcript.textColor = AsterTheme.ink
    transcript.backgroundColor = AsterTheme.paper
    transcript.textContainerInset = NSSize(width: 12, height: 12)
    let transcriptScroll = NSScrollView()
    transcriptScroll.hasVerticalScroller = true
    transcriptScroll.documentView = transcript
    let body = NSStackView(views: [resultsScroll, transcriptScroll])
    body.orientation = .horizontal
    body.spacing = 8
    body.distribution = .fill

    let resume = ActionButton(title: "Resume", bezelStyle: .rounded) { [weak self] in
      self?.continueSelection(.resume)
    }
    let fork = ActionButton(title: "Fork / Branch", bezelStyle: .rounded) { [weak self] in
      self?.continueSelection(.fork)
    }
    let footer = NSStackView(views: [NSView(), fork, resume])
    footer.orientation = .horizontal
    footer.spacing = 8
    let column = NSStackView(views: [header, body, footer])
    column.orientation = .vertical
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    host.addSubview(column)
    column.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) {
    selectedIndex = 0
    reload()
  }

  private func reload() {
    for view in resultsStack.arrangedSubviews { view.removeFromSuperview() }
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      histories = Array(model.agentHistories.prefix(100))
    } else if let matches = try? AgentHistorySearch.search(
      query: query, histories: model.agentHistories, limit: 100
    ) {
      histories = matches.compactMap { match in
        model.agentHistories.first { $0.metadata == match.metadata }
      }
    } else {
      histories = []
    }
    selectedIndex = min(selectedIndex, max(0, histories.count - 1))
    if histories.isEmpty {
      resultsStack.addArrangedSubview(
        makeLabel("没有 Agent 历史", size: 11, color: AsterTheme.secondaryInk))
      transcript.string = ""
      return
    }
    for (index, history) in histories.enumerated() {
      let metadata = history.metadata
      let button = ActionButton(
        title: "\(metadata.title)\n\(metadata.configuration.provider.commandName)",
        bezelStyle: .inline
      ) { [weak self] in
        self?.selectedIndex = index
        self?.updateSelection()
      }
      button.alignment = .left
      button.isBordered = false
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 46).isActive = true
      resultsStack.addArrangedSubview(button)
    }
    updateSelection()
  }

  private func moveSelection(_ delta: Int) {
    guard !histories.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + histories.count) % histories.count
    updateSelection()
  }

  private func updateSelection() {
    for (index, view) in resultsStack.arrangedSubviews.enumerated() {
      view.wantsLayer = true
      view.layer?.cornerRadius = 6
      view.layer?.backgroundColor =
        index == selectedIndex
        ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }
    guard histories.indices.contains(selectedIndex) else {
      transcript.string = ""
      return
    }
    let history = histories[selectedIndex]
    transcript.string = history.transcript.entries.map { entry in
      let label: String =
        switch entry.kind {
        case .message(let role): role.rawValue.uppercased()
        case .reasoning: "REASONING"
        case .toolCall(let name): "TOOL · \(name)"
        case .attachment(let name): "ATTACHMENT · \(name ?? "file")"
        }
      return "[\(label)]\n\(entry.text)"
    }.joined(separator: "\n\n")
    transcript.scrollToBeginningOfDocument(nil)
  }

  private func resumeSelection() { continueSelection(.resume) }

  private func continueSelection(_ kind: AgentContinuationKind) {
    guard histories.indices.contains(selectedIndex) else { return }
    model.continueAgentSession(histories[selectedIndex].metadata, kind: kind)
  }
}

@MainActor
final class PaletteOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let search = OverlaySearchField()
  private let resultsStack = NSStackView()
  /// 与 Open Quickly 同一套解法：`NSScrollView` 不会把 documentView 的固有高度传给
  /// 外层 NSStackView，必须由结果内容显式驱动高度，否则滚动区会被压缩成 0。
  private var resultsHeightConstraint: NSLayoutConstraint?
  private var commands: [PaletteCommand] = []
  private var rows: [PaletteCommandRowView] = []
  private var selectedIndex = 0

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    // 复用 Open Quickly 的面板：同一套圆角/描边/投影，以及只在搜索框范围保留
    // I-beam 光标的 cursor rect 处理——borderless 搜索框在 AppKit 里偶尔会留下
    // 过大的 cursor rect，这个宿主视图已经解决过一次，不需要重新踩坑。
    let host = OpenQuicklyPanelView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.99).cgColor
    host.layer?.cornerRadius = 16
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.90).cgColor
    host.layer?.shadowColor = NSColor.black.cgColor
    host.layer?.shadowOpacity = 0.22
    host.layer?.shadowRadius = 24
    host.layer?.shadowOffset = CGSize(width: 0, height: -10)
    host.layer?.masksToBounds = false
    host.identifier = NSUserInterfaceItemIdentifier("command-palette-overlay")

    search.placeholderString = "搜索命令…"
    search.identifier = NSUserInterfaceItemIdentifier("command-palette-search")
    // 保留 NSSearchField 的搜索图标位、IME 和文本编辑能力，只去掉会形成蓝色长条
    // 的系统 bezel/focus ring；插入光标仍清晰表示输入焦点。
    search.isBezeled = false
    search.drawsBackground = false
    search.focusRingType = .none
    search.cell?.focusRingType = .none
    (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
    search.font = NSFont.systemFont(ofSize: 15)
    search.translatesAutoresizingMaskIntoConstraints = false
    search.heightAnchor.constraint(equalToConstant: 36).isActive = true
    search.setContentHuggingPriority(.required, for: .vertical)
    search.setContentCompressionResistancePriority(.required, for: .vertical)
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] keepsOpen in self?.activateSelection(keepsOpen: keepsOpen) }
    search.onCancel = { [weak model] in model?.isPalettePresented = false }
    let searchRow = NSView()
    searchRow.identifier = NSUserInterfaceItemIdentifier("command-palette-search-row")
    let searchIcon = NSImageView()
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
    searchIcon.imageAlignment = .alignCenter
    searchIcon.imageScaling = .scaleProportionallyDown
    searchIcon.contentTintColor = AsterTheme.secondaryInk
    searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    searchIcon.translatesAutoresizingMaskIntoConstraints = false
    searchRow.addSubview(searchIcon)
    searchRow.addSubview(search)
    NSLayoutConstraint.activate([
      searchIcon.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 8),
      // NSSearchFieldCell 在比文字行高高得多的 frame 里，文字实际渲染位置比几何中心
      // 略低（字体度量的固有偏差），图标居中对齐 row 的几何中点会显得比文字高；
      // 往下挪 1.5pt 让图标光学中心贴合文字光学中心，而不是数学上的行几何中心。
      searchIcon.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor, constant: -1.5),
      searchIcon.widthAnchor.constraint(equalToConstant: 16),
      searchIcon.heightAnchor.constraint(equalToConstant: 16),
      search.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 32),
      search.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
      search.topAnchor.constraint(equalTo: searchRow.topAnchor),
      search.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
    ])
    host.searchInputView = searchRow

    resultsStack.orientation = .vertical
    resultsStack.alignment = .width
    resultsStack.spacing = 2
    let resultsScroll = NSScrollView()
    resultsScroll.drawsBackground = false
    resultsScroll.hasVerticalScroller = true
    resultsScroll.autohidesScrollers = true
    let document = FlippedDocumentView()
    document.addSubview(resultsStack)
    resultsScroll.documentView = document
    resultsStack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    resultsScroll.translatesAutoresizingMaskIntoConstraints = false
    let heightConstraint = resultsScroll.heightAnchor.constraint(equalToConstant: 1)
    resultsHeightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: resultsScroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: resultsScroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: resultsScroll.contentView.heightAnchor),
      resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: resultsStack.bottomAnchor),
      heightConstraint,
    ])

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
    for arrangedView in [searchRow, resultsScroll] {
      column.addArrangedSubview(arrangedView)
      arrangedView.translatesAutoresizingMaskIntoConstraints = false
      arrangedView.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true
    }
    host.addSubview(column)
    column.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) { reload() }

  private func reload() {
    for view in resultsStack.arrangedSubviews { view.removeFromSuperview() }
    commands = Self.groupedByScope(
      CommandPalette.filter(model.paletteCommands, query: search.stringValue))
    selectedIndex = min(selectedIndex, max(0, commands.count - 1))
    rows.removeAll()
    guard !commands.isEmpty else {
      resultsStack.addArrangedSubview(makeLabel("没有匹配项", size: 11, color: AsterTheme.secondaryInk))
      updateResultsHeight()
      return
    }
    // 按作用域分组展示（Pane → Window → Application），组内维持过滤后的相关性顺序；
    // 分组标题只在作用域切换时插入一次，与 Open Quickly 的小节标题同一套样式。
    var lastScope: PaletteCommandScope?
    for (index, command) in commands.enumerated() {
      if command.scope != lastScope {
        let header = Self.makeSectionHeader(command.scope)
        resultsStack.addArrangedSubview(header)
        // `alignment = .width` 不足以让每个 arranged subview 真的撑满宽度（Open
        // Quickly 的行也要显式加这条约束才行，否则命令/标题会整体缩到内容宽度贴右）。
        header.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        lastScope = command.scope
      }
      let row = PaletteCommandRowView(
        title: command.title,
        shortcut: PaletteShortcuts.glyphs(for: command.id)
      ) { [weak self] in
        guard let self else { return }
        self.selectedIndex = index
        self.activateSelection(keepsOpen: false)
      }
      resultsStack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
      rows.append(row)
    }
    updateResultsHeight()
    updateSelectionAppearance()
  }

  /// 按当前 arrangedSubviews 的真实 fitting height 更新滚动区，最多展示 400pt；
  /// 超出部分继续由 NSScrollView 滚动，与 Open Quickly 结果区完全同一套算法。
  private func updateResultsHeight() {
    resultsStack.needsLayout = true
    resultsStack.layoutSubtreeIfNeeded()
    let contentHeight = ceil(resultsStack.fittingSize.height)
    resultsHeightConstraint?.constant = min(400, max(1, contentHeight))
  }

  private func moveSelection(_ delta: Int) {
    guard !rows.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    updateSelectionAppearance()
    rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
  }

  private func activateSelection(keepsOpen: Bool) {
    guard commands.indices.contains(selectedIndex) else { return }
    model.performPaletteCommand(commands[selectedIndex], dismissesPalette: !keepsOpen)
    if keepsOpen { reload() }
  }

  private func updateSelectionAppearance() {
    for (index, row) in rows.enumerated() {
      row.isSelected = index == selectedIndex
    }
  }

  /// 按 Pane → Window → Application 稳定排序，让同一作用域的命令连续出现以配合
  /// 分组标题；不改变组内的过滤相关性顺序。
  private static func groupedByScope(_ commands: [PaletteCommand]) -> [PaletteCommand] {
    let rank: [PaletteCommandScope: Int] = [.pane: 0, .window: 1, .application: 2]
    return commands.enumerated().sorted { lhs, rhs in
      let lhsRank = rank[lhs.element.scope] ?? 0
      let rhsRank = rank[rhs.element.scope] ?? 0
      return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
    }.map(\.element)
  }

  /// 与 Open Quickly 的小节标题同一套字号/字重/颜色与内边距（10pt semibold
  /// tertiaryInk，上 6 左 4 下 2 右 4）。
  private static func makeSectionHeader(_ scope: PaletteCommandScope) -> NSView {
    let text: String =
      switch scope {
      case .pane: "PANE"
      case .window: "WINDOW"
      case .application: "APPLICATION"
      }
    let label = makeLabel(text, size: 10, weight: .semibold, color: AsterTheme.tertiaryInk)
    label.alignment = .left
    label.translatesAutoresizingMaskIntoConstraints = false
    let wrapper = NSView()
    wrapper.addSubview(label)
    label.pinEdges(to: wrapper, insets: NSEdgeInsets(top: 6, left: 4, bottom: 2, right: 4))
    return wrapper
  }
}

/// 命令面板里已知固定绑定的少量常用快捷键，仅用于展示提示胶囊；与 `AsterApp.swift`
/// 「显示」菜单等处的真实 `keyEquivalent` 保持同步，本身不驱动任何按键处理。
/// 未收录的命令（多数没有固定快捷键，或快捷键会随上下文变化）不显示提示。
private enum PaletteShortcuts {
  static let byCommandID: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [
    "new-window": ("N", .command),
    "new-tab": ("T", .command),
    "reopen-tab": ("T", [.command, .shift]),
    "open-file": ("O", .command),
    "split-right": ("D", .command),
    "split-left": ("D", [.command, .option]),
    "split-down": ("D", [.command, .shift]),
    "split-up": ("D", [.command, .option, .shift]),
    "zoom-pane": ("↩", [.command, .shift]),
    "equalize-splits": ("=", [.command, .control]),
    "focus-next-pane": ("]", .command),
    "find": ("F", .command),
    "global-find": ("F", [.command, .shift]),
    "open-quickly": ("O", [.command, .shift]),
    "close-pane": ("W", [.command, .option]),
  ]

  static func glyphs(for id: String) -> String? {
    guard let entry = byCommandID[id] else { return nil }
    var symbol = ""
    if entry.modifiers.contains(.control) { symbol += "⌃" }
    if entry.modifiers.contains(.option) { symbol += "⌥" }
    if entry.modifiers.contains(.shift) { symbol += "⇧" }
    if entry.modifiers.contains(.command) { symbol += "⌘" }
    return symbol + entry.key
  }
}

/// 命令面板单行：与 Open Quickly 结果行同一套 NSButton 结构、44pt 行高与
/// 10pt 内边距，只是没有图标/副标题——命令面板的条目只有标题和可选快捷键。
/// `isSelected` 驱动的选中高亮沿用同一套 accent 16% 透明度配色。
@MainActor
final class PaletteCommandRowView: NSButton {
  private var handler: (() -> Void)?
  var isSelected = false {
    didSet { if oldValue != isSelected { applySelection() } }
  }

  init(title: String, shortcut: String?, handler: @escaping () -> Void) {
    super.init(frame: .zero)
    self.title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 8
    target = self
    action = #selector(invoke)
    self.handler = handler

    let titleLabel = makeLabel(title, size: 13, color: AsterTheme.ink)
    titleLabel.lineBreakMode = .byTruncatingTail

    let row: NSStackView
    if let shortcut {
      let chip = Self.makeShortcutChip(shortcut)
      // 快捷键胶囊必须钉死在自身内容宽度：留白该由 spacer 一个人吃掉，否则
      // 两者同为默认低优先级会让胶囊也跟着被拉宽，看起来像贴着行尾的空框。
      chip.setContentHuggingPriority(.required, for: .horizontal)
      let spacer = NSView()
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      row = NSStackView(views: [titleLabel, spacer, chip])
    } else {
      row = NSStackView(views: [titleLabel])
    }
    row.orientation = .horizontal
    row.spacing = 10
    row.alignment = .centerY
    addSubview(row)
    row.pinEdges(to: self, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 44).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  @objc private func invoke() { handler?() }

  private func applySelection() {
    layer?.backgroundColor =
      isSelected ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
  }

  /// 与 Open Quickly 结果行的快捷键键帽同一套外观（4pt 圆角、panel 底色、
  /// 0.72 透明度描边）。
  private static func makeShortcutChip(_ text: String) -> NSView {
    let label = makeLabel(
      text, size: 10, weight: .medium, color: AsterTheme.secondaryInk, monospaced: true)
    let background = NSView()
    background.wantsLayer = true
    background.layer?.cornerRadius = 4
    background.layer?.backgroundColor = AsterTheme.panel.cgColor
    background.layer?.borderWidth = 1
    background.layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.72).cgColor
    background.addSubview(label)
    label.pinEdges(to: background, insets: NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5))
    return background
  }
}

/// 命令面板、Open Quickly 与全局搜索共用的键盘导航搜索框。只截获列表导航键，
/// 其它组合键继续由 NSSearchField 处理，IME 与系统文本编辑行为不受影响。
@MainActor
final class OverlaySearchField: NSSearchField {
  var onMove: ((Int) -> Void)?
  var onActivate: ((Bool) -> Void)?
  var onCancel: (() -> Void)?
  /// ⌘1…9 快速选中第 N 行；仅 Open Quickly 接线。
  var onQuickSelect: ((Int) -> Void)?
  /// ⌘K 弹出选中行的操作菜单；仅 Open Quickly 接线。
  var onShowActions: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    // ⌘ 组合键优先于导航键判断:数字走 Quick Select,K 走操作菜单,其余放行。
    if event.modifierFlags.contains(.command),
      let character = event.charactersIgnoringModifiers?.first
    {
      if let digit = character.wholeNumberValue, (1...9).contains(digit) {
        onQuickSelect?(digit)
        return
      }
      if character == "k" {
        onShowActions?()
        return
      }
    }
    switch event.keyCode {
    case 125:
      onMove?(1)
    case 126:
      onMove?(-1)
    case 36, 76:
      onActivate?(event.modifierFlags.contains(.command))
    case 53:
      onCancel?()
    default:
      super.keyDown(with: event)
    }
  }
}

extension NSView {
  func addTopBorder(color: NSColor) {
    let border = NSView()
    border.wantsLayer = true
    border.layer?.backgroundColor = color.cgColor
    addSubview(border)
    border.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.topAnchor.constraint(equalTo: topAnchor),
      border.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  func addBottomBorder(color: NSColor) {
    let border = NSView()
    border.wantsLayer = true
    border.layer?.backgroundColor = color.cgColor
    addSubview(border)
    border.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.bottomAnchor.constraint(equalTo: bottomAnchor),
      border.heightAnchor.constraint(equalToConstant: 1),
    ])
  }
}
