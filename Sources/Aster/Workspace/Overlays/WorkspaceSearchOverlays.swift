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
  private let stack = NSStackView()
  private let search = OverlaySearchField()
  private var commands: [PaletteCommand] = []
  private var buttons: [NSButton] = []
  private var selectedIndex = 0

  init(model: AppModel) {
    self.model = model
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
    search.placeholderString = "输入命令或操作…"
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] keepsOpen in self?.activateSelection(keepsOpen: keepsOpen) }
    search.onCancel = { [weak model] in model?.isPalettePresented = false }
    stack.addArrangedSubview(search)
    host.addSubview(stack)
    stack.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) { reload() }

  private func reload() {
    while stack.arrangedSubviews.count > 1 {
      stack.arrangedSubviews.last?.removeFromSuperview()
    }
    commands = CommandPalette.filter(model.paletteCommands, query: search.stringValue)
    selectedIndex = min(selectedIndex, max(0, commands.count - 1))
    buttons.removeAll()
    for command in commands.prefix(9) {
      let scope =
        switch command.scope {
        case .pane: "Pane"
        case .window: "Window"
        case .application: "App"
        }
      let button = ActionButton(title: "\(command.title)    [\(scope)]", bezelStyle: .inline) {
        [weak self] in
        self?.model.performPaletteCommand(command)
      }
      button.alignment = .left
      button.isBordered = false
      button.contentTintColor = AsterTheme.ink
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      stack.addArrangedSubview(button)
      buttons.append(button)
    }
    updateSelectionAppearance()
  }

  private func moveSelection(_ delta: Int) {
    guard !buttons.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + buttons.count) % buttons.count
    updateSelectionAppearance()
  }

  private func activateSelection(keepsOpen: Bool) {
    guard commands.indices.contains(selectedIndex) else { return }
    model.performPaletteCommand(commands[selectedIndex], dismissesPalette: !keepsOpen)
    if keepsOpen { reload() }
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
