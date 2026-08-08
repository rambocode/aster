import AppKit
import AsterCore
import Combine

/// 右侧详情面板：Info / Outline / Git / Files 四页 chip 切换。进程、端口、Git、文件树
/// 数据全部来自 `WorkspaceInspectionService` 的只读快照；Commit、stage 等写操作不后台
/// 执行 git，而是把命令注入当前终端输入行，由用户审阅后自行回车（不触发隐藏 hook）。
@MainActor
final class DetailsPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  private enum Section: Int, CaseIterable {
    case info, outline, git, files

    var title: String {
      switch self {
      case .info: "Info"
      case .outline: "Outline"
      case .git: "Git"
      case .files: "Files"
      }
    }

    var symbol: String {
      switch self {
      case .info: "info.circle"
      case .outline: "list.bullet"
      case .git: "arrow.triangle.branch"
      case .files: "folder"
      }
    }

    var chipIdentifier: String {
      switch self {
      case .info: "details-chip-info"
      case .outline: "details-chip-outline"
      case .git: "details-chip-git"
      case .files: "details-chip-files"
      }
    }
  }

  private let model: AppModel
  private let preferences: AppPreferences
  private let inspectionClient: WorkspaceInspectionClient
  private let now: @MainActor () -> Date
  private let contentHost = NSView()
  private var chips: [Section: PanelTabChip] = [:]
  private var selection: Section
  private var information: WorkspaceInformationSnapshot?
  private var informationPaneID: UUID?
  private var requestedInformationPaneID: UUID?
  private var informationTask: Task<Void, Never>?
  private weak var informationStack: NSStackView?
  private var gitStatus: GitStatusSummary?
  private var gitDirectory: String?
  private var requestedGitDirectory: String?
  private var gitInspectedAt: Date?
  private var gitTask: Task<Void, Never>?
  private var filesTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []
  private var outlineCancellables: Set<AnyCancellable> = []
  private let outlineTable = NSTableView()
  private weak var outlinePathLabel: NSTextField?
  private weak var outlineTimeLabel: NSTextField?
  private weak var outlineEmptyLabel: NSTextField?
  private var outlineRows: [OutlineRow] = []
  private var outlineTask: Task<Void, Never>?
  private var outlineRevision = 0
  private var outlineNeedsRefresh = true
  private let gitTable = NSTableView()
  private weak var gitBranchLabel: NSTextField?
  private weak var gitInsertionsLabel: NSTextField?
  private weak var gitDeletionsLabel: NSTextField?
  private weak var gitCommitButton: SplitActionButton?
  private weak var gitEditorButton: SplitActionButton?
  /// diff 预览浮层同时只允许一个；控制器持有它以便切页、切 Pane 或收起面板时统一关闭。
  private var gitDiffPreview: GitDiffPreviewOverlay?
  private var gitDiffTask: Task<Void, Never>?
  private weak var gitEmptyLabel: NSTextField?
  private var gitRows: [GitRow] = []
  /// 每个顶部页签只在数据失效时重建；普通切换直接复用已经完成布局的视图，尤其避免
  /// Files 页重复创建数百个按钮和 Auto Layout 约束。
  private var cachedContent: [Section: NSView] = [:]
  /// Files 目录默认收起，因此只记录用户明确展开的路径。工作区刷新和面板收起/重开
  /// 都会保留；新出现的目录天然保持收起，不需要为整棵树预建折叠集合。
  private var expandedPaths: Set<String> = []
  private var filesQuery = ""
  private var filesDirectoriesFirst = true
  private var fileNodes: [WorkspaceFileNode]?
  private var filesDirectory: String?
  private var requestedFilesDirectory: String?
  private weak var filesSearchField: NSSearchField?
  private weak var filesSortButton: NSButton?
  private weak var filesEmptyLabel: NSTextField?
  private let filesTable = NSTableView()
  private var fileTree: [FileTreeItem] = []
  private var visibleFileRows: [FileRow] = []
  private var didRequestAgentHistory = false
  private var renderedTheme: TerminalTheme?
  /// 控制器在面板收起后继续缓存，但隐藏期间不得因 CWD、Pane 或文档事件重新启动工作。
  private var isPresentationActive = true
  private let editorLocator: @MainActor () -> [DetectedEditor]

  init(
    model: AppModel,
    preferences: AppPreferences,
    inspectionClient: WorkspaceInspectionClient = .live,
    now: @escaping @MainActor () -> Date = Date.init,
    // 编辑器探测走 NSWorkspace，结果取决于本机安装了什么；注入后测试才能稳定断言
    // 「在编辑器中打开」入口的存在与标题。
    editorLocator: @escaping @MainActor () -> [DetectedEditor] = { WorkspaceEditorLocator.detect() }
  ) {
    self.model = model
    self.preferences = preferences
    self.inspectionClient = inspectionClient
    self.now = now
    self.editorLocator = editorLocator
    self.selection = Section(rawValue: preferences.inspectorSection) ?? .info
    super.init(nibName: nil, bundle: nil)
    model.agentHistoriesChanged
      .sink { [weak self] _ in
        guard let self else { return }
        self.updateInformationContent()
      }
      .store(in: &cancellables)
    observeActivePane()
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let theme = preferences.activeTheme
    renderedTheme = theme
    let background = ThemeVisualEffectView()
    background.apply(
      material: theme.palette.material,
      tint: theme.palette.panelBackground
    )
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    column.addArrangedSubview(makeHeader())
    column.addArrangedSubview(makeSeparator())
    column.addArrangedSubview(contentHost)
    background.addSubview(column)
    column.pinEdges(to: background)
    view = background
    showSelectedContent()
    prepareSelectedSection()
  }

  deinit {
    informationTask?.cancel()
    gitTask?.cancel()
    filesTask?.cancel()
    outlineTask?.cancel()
    gitDiffTask?.cancel()
  }

  /// 工作区会在主题变化时复用详情控制器；只有主题真实变化才清理页缓存，普通模型
  /// 刷新仍保持快速切换。背景材质和页内静态颜色在同一次同步中更新。
  func synchronizeAppearanceIfNeeded() {
    guard isViewLoaded else { return }
    let theme = preferences.activeTheme
    guard renderedTheme != theme else { return }
    renderedTheme = theme
    if let background = view as? ThemeVisualEffectView {
      background.apply(material: theme.palette.material, tint: theme.palette.panelBackground)
    }
    cachedContent.removeAll()
    contentHost.removeAllSubviews()
    showSelectedContent()
  }

  /// 收起面板后停止尚未完成的 I/O 与解析，但保留已经完成的快照和所有交互状态；重开
  /// 时只为缺失或过期的当前页重新发起请求。
  func setPresentationActive(_ active: Bool) {
    isPresentationActive = active
    if active {
      prepareSelectedSection()
    } else {
      for section in Section.allCases { cancelInspection(for: section) }
    }
  }

  // MARK: - Header

  /// 页签 chip 行：未选中仅显示图标并保持统一收起宽度，选中项灰底并展开文字，最右侧
  /// 是收起面板按钮。间距固定，因此展开只挤占右侧 spacer，不会改变已收起页签的排布节奏。
  private func makeHeader() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 6
    row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    for section in Section.allCases {
      let chip = PanelTabChip(title: section.title, symbol: section.symbol) { [weak self] in
        self?.selectSection(section)
      }
      chip.identifier = NSUserInterfaceItemIdentifier(section.chipIdentifier)
      chip.setSelected(section == selection, animated: false)
      chips[section] = chip
      row.addArrangedSubview(chip)
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(spacer)
    let close = ActionButton(symbol: "sidebar.right", bezelStyle: .accessoryBarAction) {
      [weak self] in self?.model.toggleInspector()
    }
    close.isBordered = false
    close.toolTip = "收起详情面板"
    close.identifier = NSUserInterfaceItemIdentifier("details-panel-close")
    row.addArrangedSubview(close)
    return row
  }

  private func makeSeparator() -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = AsterTheme.hairline.cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }

  /// chip 切换只更新面板本地内容并持久化选中页；不经过 preferences 广播，避免
  /// 整棵工作区视图树跟着重建。
  private func selectSection(_ section: Section) {
    guard section != selection else { return }
    cancelInspection(for: selection)
    selection = section
    preferences.inspectorSection = section.rawValue
    for (key, chip) in chips { chip.setSelected(key == section, animated: true) }
    showSelectedContent()
    prepareSelectedSection()
  }

  /// 页签离开后立即终止该页仍未完成的昂贵工作，避免隐藏页继续占用子进程或解析 CPU。
  /// 已完成快照不会清理，因此回切时仍可直接显示；Outline 的未完成解析则标记为待刷新。
  private func cancelInspection(for section: Section) {
    switch section {
    case .info:
      informationTask?.cancel()
    case .git:
      gitTask?.cancel()
      // 切走 Git 页或收起面板时，diff 浮层不能继续悬在窗口上。
      dismissGitDiffPreview()
    case .files:
      filesTask?.cancel()
    case .outline:
      if outlineTask != nil { outlineNeedsRefresh = true }
      outlineTask?.cancel()
    }
  }

  private func observeActivePane() {
    guard let tab = model.selectedTab else { return }
    tab.activePaneChanged
      .sink { [weak self] _ in
        guard let self else { return }
        self.informationTask?.cancel()
        self.gitTask?.cancel()
        self.information = nil
        self.informationPaneID = nil
        self.requestedInformationPaneID = nil
        self.gitStatus = nil
        self.gitDirectory = nil
        self.requestedGitDirectory = nil
        self.gitInspectedAt = nil
        self.filesTask?.cancel()
        self.fileNodes = nil
        self.filesDirectory = nil
        self.requestedFilesDirectory = nil
        self.outlineTask?.cancel()
        self.outlineNeedsRefresh = true
        self.updateInformationContent()
        self.updateGitContent()
        self.rebuildFileTreeProjection()
        self.observeOutlineChanges()
        guard self.isPresentationActive else { return }
        self.prepareSelectedSection()
      }
      .store(in: &cancellables)
    tab.workingDirectoryChanged
      .sink { [weak self, weak tab] change in
        guard let self, let tab, change.paneID == tab.activePaneID else { return }
        // 保留当前快照直到新目录读取完成。清空并先绘制“正在读取目录…”会造成 Files
        // 页闪烁；异步任务自身带 Tab/Pane 校验，连续 cd 时旧结果不会覆盖新目录。
        self.updateInformationContent()
        // Terminal Outline 顶部也显示当前目录；命令条目可复用，但 header 必须同步。
        self.outlineNeedsRefresh = true
        guard self.isPresentationActive else { return }
        if self.selection == .info { self.showSelectedContent() }
        if self.selection == .outline { self.refreshOutline(debounced: false) }
        switch self.selection {
        case .info:
          self.refreshInformation()
        case .git:
          self.refreshGit(directory: change.directory)
        case .files:
          self.refreshFiles(directory: change.directory)
        case .outline:
          break
        }
      }
      .store(in: &cancellables)
    observeOutlineChanges()
  }

  /// Outline 的数据源是活动终端的 OSC 133 时间线，或编辑器当前内存文本。两者都
  /// 必须局部失效缓存；依赖工作区整树刷新会让页面看似永远没有更新。
  private func observeOutlineChanges() {
    outlineCancellables.removeAll()
    guard let runtime = model.selectedTab?.activeRuntime else { return }
    if let session = runtime.terminalSession {
      session.outlineChanged
        .sink { [weak self] in self?.invalidateOutline(debounced: false) }
        .store(in: &outlineCancellables)
    } else {
      runtime.$documentText
        .removeDuplicates()
        .dropFirst()
        .sink { [weak self] _ in
          // `@Published` 在 willSet 阶段发值；延后一轮才能让解析器读取已经提交的新文本，
          // 否则每次编辑都会用旧内容重建，看起来 Outline 完全没有更新。
          DispatchQueue.main.async { [weak self] in self?.invalidateOutline(debounced: true) }
        }
        .store(in: &outlineCancellables)
    }
  }

  private func invalidateOutline(debounced: Bool) {
    outlineNeedsRefresh = true
    if isPresentationActive, selection == .outline { refreshOutline(debounced: debounced) }
  }

  /// Info 只读取当前终端进程树与监听端口，不再等待无关的 Git 状态。Pane 切换或面板
  /// 收起后会取消任务，并用 Tab/Pane ID 防止旧结果覆盖新焦点。
  private func refreshInformation() {
    informationTask?.cancel()
    guard let tab = model.selectedTab else { return }
    let tabID = tab.id
    let paneID = tab.activePaneID
    let processIdentifier = tab.activeSession?.processIdentifier
    requestedInformationPaneID = paneID
    informationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let value = await self.inspectionClient.information(processIdentifier)
      guard !Task.isCancelled, self.model.selectedTab?.id == tabID,
        self.model.selectedTab?.activePaneID == paneID,
        self.requestedInformationPaneID == paneID
      else { return }
      self.information = value
      self.informationPaneID = paneID
      self.updateInformationContent()
    }
  }

  /// Git 只读取当前目录的只读状态与 diff 统计，不启动 ps/lsof。目录参数由 OSC 7
  /// willSet 事件直接传入，连续 cd 时取消旧命令并按目录身份丢弃迟到结果。
  /// 「已有快照且超过 30 秒」。从未成功检查过（`nil`）不算过期：那种情况由目录比较或
  /// 首次挂载负责发起请求，这里返回 true 会让首帧多发一次重复请求。
  private var isGitSnapshotExpired: Bool {
    guard let gitInspectedAt else { return false }
    return now().timeIntervalSince(gitInspectedAt) > 30
  }

  private func refreshGit(directory requestedDirectory: String? = nil) {
    gitTask?.cancel()
    guard let tab = model.selectedTab else { return }
    let tabID = tab.id
    let paneID = tab.activePaneID
    let directory = requestedDirectory ?? tab.workingDirectory
    requestedGitDirectory = directory
    gitTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let value = await self.inspectionClient.git(directory)
      guard !Task.isCancelled, self.model.selectedTab?.id == tabID,
        self.model.selectedTab?.activePaneID == paneID,
        self.requestedGitDirectory == directory
      else { return }
      self.gitStatus = value
      self.gitDirectory = directory
      self.gitInspectedAt = self.now()
      if self.cachedContent[.git] != nil { self.updateGitContent() }
      if self.selection == .git && self.cachedContent[.git] == nil { self.showSelectedContent() }
    }
  }

  /// Files 页使用独立任务，不等待进程、端口或 Git 检查。连续切换目录时以目录和
  /// Tab/Pane 身份丢弃旧结果，当前树保留到新树完整就绪。
  private func refreshFiles(directory requestedDirectory: String? = nil) {
    filesTask?.cancel()
    guard let tab = model.selectedTab else { return }
    let tabID = tab.id
    let paneID = tab.activePaneID
    let directory = requestedDirectory ?? tab.workingDirectory
    requestedFilesDirectory = directory
    filesTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let value = await self.inspectionClient.files(directory)
      guard !Task.isCancelled, self.model.selectedTab?.id == tabID,
        self.model.selectedTab?.activePaneID == paneID,
        self.requestedFilesDirectory == directory
      else { return }
      self.fileNodes = value
      self.filesDirectory = directory
      self.rebuildFileTreeProjection()
    }
  }

  private func prepareSelectedSection() {
    guard isPresentationActive, let directory = model.selectedTab?.workingDirectory else { return }
    switch selection {
    case .info:
      if informationPaneID != model.selectedTab?.activePaneID { refreshInformation() }
    case .git:
      // 目录没变也可能过期：分支切换、外部 commit 都不会通知面板，重开时必须按时间重取。
      if gitDirectory != directory || isGitSnapshotExpired { refreshGit() }
    case .files:
      if filesDirectory != directory { refreshFiles() }
    case .outline:
      if outlineNeedsRefresh { refreshOutline(debounced: false) }
    }
  }

  /// 每个页根视图首次展示时只挂载并约束一次。后续页签切换只改变 `isHidden`，滚动容器、
  /// 搜索框、表格行池和约束都留在原层级，避免反复 remove/add 触发完整布局。
  private func showSelectedContent() {
    // Git 页展示时若快照超过 30 秒则后台重取，避免分支切换后统计长期过期。
    if selection == .git, isGitSnapshotExpired { refreshGit() }
    if cachedContent[selection] == nil {
      let content: NSView
      switch selection {
      case .outline: content = makeOutlineContent()
      case .git: content = makeGitContent()
      case .files: content = makeFilesContent()
      case .info: content = makeInformationContent()
      }
      cachedContent[selection] = content
      contentHost.addSubview(content)
      content.pinEdges(to: contentHost)
    }
    for (section, content) in cachedContent {
      content.isHidden = section != selection
    }
  }

  // MARK: - Info

  private func makeInformationContent() -> NSView {
    let info = NSStackView()
    info.orientation = .vertical
    info.alignment = .leading
    info.spacing = 12
    informationStack = info
    populateInformationStack(info)
    return makeScrollableContent(info)
  }

  /// Info 页保留既有 scroll/document 根视图，只替换少量 stack 内容。进程检查完成、
  /// CWD 或 Pane 变化不会再销毁四个已加载页及其它表格的滚动/复用状态。
  private func updateInformationContent() {
    guard let info = informationStack else { return }
    info.arrangedSubviews.forEach { $0.removeFromSuperview() }
    populateInformationStack(info)
  }

  private func populateInformationStack(_ info: NSStackView) {
    let tab = model.selectedTab

    info.addArrangedSubview(makeGroupHeader("Working Directory"))
    let path = makeLabel(
      tab?.workingDirectory ?? "—", size: 11.5, monospaced: true)
    path.lineBreakMode = .byTruncatingMiddle
    path.maximumNumberOfLines = 2
    info.addArrangedSubview(path)

    if let directory = tab?.workingDirectory {
      info.addArrangedSubview(makeLinkRow(symbol: "doc.on.doc", title: "Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(directory, forType: .string)
      })
      info.addArrangedSubview(makeLinkRow(symbol: "folder", title: "Reveal in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
      })
      for editor in WorkspaceEditorLocator.detect() {
        info.addArrangedSubview(
          makeLinkRow(symbol: "arrow.up.right.square", title: "Open in \(editor.name)") {
            WorkspaceEditorLocator.open(directory: URL(fileURLWithPath: directory), in: editor)
          })
      }
    }

    if let claudeSection = makeClaudeCodeSection(tab: tab) {
      info.addArrangedSubview(claudeSection)
    }

    info.addArrangedSubview(makeGroupHeader("Process"))
    if let information {
      if information.processes.isEmpty {
        info.addArrangedSubview(makeLabel("没有活动子进程", size: 11, color: AsterTheme.secondaryInk))
      } else {
        for process in information.processes.prefix(50) {
          addFullWidthRow(makeProcessRow(process), to: info)
        }
      }
      info.addArrangedSubview(makeGroupHeader("Ports"))
      if information.listeningPorts.isEmpty {
        info.addArrangedSubview(makeLabel("No listening ports", size: 11, color: AsterTheme.secondaryInk))
      } else {
        for port in information.listeningPorts.prefix(50) {
          info.addArrangedSubview(
            makeLabel("\(port.processIdentifier)  \(port.endpoint)", size: 10.5, monospaced: true))
        }
      }
    } else {
      info.addArrangedSubview(makeLabel("正在检查…", size: 11, color: AsterTheme.secondaryInk))
    }
  }

  /// 仅当活动 Pane 的进程树里检测到 claude 时显示；会话记录按当前目录匹配最新一条。
  private func makeClaudeCodeSection(tab: TerminalTabItem?) -> NSView? {
    let claudeRunning = information?.processes.contains {
      $0.command.split(separator: "/").last == "claude"
    } ?? false
    guard claudeRunning else { return nil }
    // 首次需要时触发一次磁盘扫描；结果经 agentHistoriesChanged 局部更新 Info 内容。
    if model.agentHistories.isEmpty, !didRequestAgentHistory {
      didRequestAgentHistory = true
      model.reloadAgentHistory()
    }
    let session = latestClaudeSession(for: tab?.workingDirectory)
    let section = NSStackView()
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 8
    section.addArrangedSubview(makeGroupHeader("Claude Code"))
    if let session {
      section.addArrangedSubview(makeLinkRow(symbol: "doc.on.doc", title: "Copy Session ID") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
      })
      section.addArrangedSubview(
        makeLinkRow(symbol: "arrow.triangle.branch", title: "Branch in…") { [weak self] in
          self?.model.continueAgentSession(session, kind: .fork)
        })
    }
    section.addArrangedSubview(
      makeLinkRow(symbol: "clock.arrow.circlepath", title: "View Session History") { [weak self] in
        guard let self else { return }
        self.model.isAgentHistoryPresented = true
        self.model.reloadAgentHistory()
      })
    return section
  }

  private func latestClaudeSession(for directory: String?) -> AgentSessionMetadata? {
    guard let directory else { return nil }
    return model.agentHistories
      .map(\.metadata)
      .filter { $0.configuration.provider == .claudeCode && $0.projectDirectory == directory }
      .max(by: { $0.updatedAt < $1.updatedAt })
  }

  /// 进程行：状态圆点 + 命令名 + 右侧「PID · 运行时长」。圆点用主题 accent 而不是
  /// 固定绿色，保持在主题角色约束内。
  private func makeProcessRow(_ process: WorkspaceProcess) -> NSView {
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 3
    dot.layer?.backgroundColor = AsterTheme.accent.cgColor
    dot.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),
    ])
    let name = makeLabel(
      URL(fileURLWithPath: process.command).lastPathComponent, size: 11)
    var detail = "\(process.processIdentifier)"
    if let elapsed = process.elapsedTime { detail += " · \(elapsed)" }
    let meta = makeLabel(detail, size: 10, color: AsterTheme.secondaryInk, monospaced: true)
    meta.alignment = .right
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [dot, name, spacer, meta])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  // MARK: - Outline

  private func makeOutlineContent() -> NSView {
    let root = NSView()
    let path = makeLabel("—", size: 10.5, color: AsterTheme.secondaryInk, monospaced: true)
    path.lineBreakMode = .byTruncatingMiddle
    let time = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
    let header = NSStackView(views: [path, NSView(), time])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    outlinePathLabel = path
    outlineTimeLabel = time
    root.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false

    outlineTable.identifier = NSUserInterfaceItemIdentifier("details-outline-table")
    outlineTable.headerView = nil
    outlineTable.backgroundColor = .clear
    outlineTable.rowHeight = 26
    outlineTable.intercellSpacing = .zero
    outlineTable.selectionHighlightStyle = .none
    outlineTable.dataSource = self
    outlineTable.delegate = self
    if outlineTable.tableColumns.isEmpty {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details-outline-entry"))
      column.resizingMask = .autoresizingMask
      outlineTable.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = outlineTable
    root.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let empty = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
    empty.alignment = .center
    root.addSubview(empty)
    empty.translatesAutoresizingMaskIntoConstraints = false
    outlineEmptyLabel = empty
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      empty.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 14),
      empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
      empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
    ])
    refreshOutline(debounced: false)
    return root
  }

  private struct OutlineRow {
    let title: String
    let metadata: String
    let indentation: Int
    let toolTip: String?
    let action: () -> Void
  }

  /// 编辑器可能在每个按键后发布完整文本。120ms trailing debounce 合并输入突发，解析
  /// 在后台执行；`outlineRevision` 保证较慢的旧文本结果永远不能覆盖最新文档。
  private func refreshOutline(debounced: Bool) {
    outlineNeedsRefresh = false
    outlineRevision += 1
    let revision = outlineRevision
    outlineTask?.cancel()
    outlineTask = nil
    guard let tab = model.selectedTab, let runtime = tab.activeRuntime else {
      applyOutlineRows([], path: "—", latest: nil, emptyMessage: "没有活动 Pane")
      return
    }
    if let session = runtime.terminalSession {
      let entries = session.commandOutlineEntries()
      let rows = entries.map { entry in
        let status = entry.exitStatus.map { $0 == 0 ? "✓" : "× \($0)" } ?? "·"
        return OutlineRow(
          title: "\(status)  \(entry.title)",
          metadata: entry.finishedAt.map { RelativeTime.string(since: $0) } ?? "",
          indentation: 0,
          toolTip: nil,
          action: { [weak session] in _ = session?.revealAbsoluteRow(entry.absoluteRow) }
        )
      }
      applyOutlineRows(
        rows,
        path: tab.workingDirectory,
        latest: entries.compactMap(\.finishedAt).max(),
        emptyMessage: "运行命令后会在这里显示 Shell Integration 锚点。"
      )
      return
    }
    let displayedResourcePath = runtime.descriptor.resourcePath ?? "—"
    guard let resourcePath = runtime.descriptor.resourcePath,
      let kind = outlineKind(for: URL(fileURLWithPath: resourcePath))
    else {
      applyOutlineRows([], path: displayedResourcePath, latest: nil, emptyMessage: "此 Pane 没有 Outline。")
      return
    }
    let text = runtime.documentText
    let tabID = tab.id
    let paneID = runtime.id
    outlineTask = Task { @MainActor [weak self, weak tab] in
      if debounced {
        do { try await Task.sleep(for: .milliseconds(120)) }
        catch { return }
      }
      guard !Task.isCancelled else { return }
      let parseTask = Task.detached(priority: .userInitiated) {
        WorkspaceOutlineParser.parse(text, kind: kind)
      }
      let entries = await withTaskCancellationHandler {
        await parseTask.value
      } onCancel: {
        parseTask.cancel()
      }
      guard !Task.isCancelled, let self, let tab,
        self.outlineRevision == revision,
        self.model.selectedTab?.id == tabID,
        self.model.selectedTab?.activePaneID == paneID
      else { return }
      let rows = entries.map { entry in
        OutlineRow(
          title: entry.title,
          metadata: "",
          indentation: max(0, entry.level - 1),
          toolTip: "第 \(entry.line) 行",
          action: { [weak tab] in tab?.revealDocumentLine(entry.line, paneID: paneID) }
        )
      }
      self.applyOutlineRows(rows, path: resourcePath, latest: nil, emptyMessage: "此文件没有可索引的结构。")
      self.outlineTask = nil
    }
  }

  private func applyOutlineRows(
    _ rows: [OutlineRow], path: String, latest: Date?, emptyMessage: String
  ) {
    outlineRows = rows
    outlinePathLabel?.stringValue = path
    outlineTimeLabel?.stringValue = latest.map { RelativeTime.string(since: $0) } ?? ""
    outlineEmptyLabel?.stringValue = emptyMessage
    outlineEmptyLabel?.isHidden = !rows.isEmpty
    outlineTable.reloadData()
  }

  // MARK: - Git

  private func makeGitContent() -> NSView {
    let root = NSView()
    let branch = makeLabel("—", size: 13, weight: .bold)
    let insertions = makeLabel("", size: 11, weight: .semibold, color: AsterTheme.accent, monospaced: true)
    let deletions = makeLabel("", size: 11, weight: .semibold, color: AsterTheme.warning, monospaced: true)
    let header = NSStackView(views: [branch, NSView(), insertions, deletions])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 4
    gitBranchLabel = branch
    gitInsertionsLabel = insertions
    gitDeletionsLabel = deletions

    // Commit/stage/push 等写操作永远只把命令预填到终端输入行，不在检查服务里执行仓库
    // 写操作：面板没有终端的凭据、hook 与交互能力，静默执行会绕过用户审阅。
    let commit = SplitActionButton(
      title: "Commit",
      symbol: "checkmark.circle",
      primary: { [weak self] in self?.injectGitCommand(.commit) },
      menu: { [weak self] in self?.makeGitOperationsMenu() ?? NSMenu() }
    )
    commit.identifier = NSUserInterfaceItemIdentifier("details-git-commit")
    commit.toolTip = "把 git commit 放入终端输入行，确认后回车执行"
    gitCommitButton = commit
    let editor = SplitActionButton(
      title: "",
      symbol: nil,
      primary: { [weak self] in self?.openWorkingDirectoryInPreferredEditor() },
      menu: { [weak self] in self?.makeEditorMenu() ?? NSMenu() }
    )
    editor.identifier = NSUserInterfaceItemIdentifier("details-git-editor")
    gitEditorButton = editor
    let actionSpacer = NSView()
    actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let actions = NSStackView(views: [commit, actionSpacer, editor])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 6

    let top = NSStackView(views: [header, actions])
    top.orientation = .vertical
    top.alignment = .leading
    top.spacing = 9
    // 两行都必须撑满面板宽度，否则 stack 会按内容收缩，右侧编辑器按钮不再贴齐右边。
    header.translatesAutoresizingMaskIntoConstraints = false
    actions.translatesAutoresizingMaskIntoConstraints = false
    header.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
    actions.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
    root.addSubview(top)
    top.translatesAutoresizingMaskIntoConstraints = false

    gitTable.identifier = NSUserInterfaceItemIdentifier("details-git-table")
    gitTable.headerView = nil
    gitTable.backgroundColor = .clear
    gitTable.rowHeight = 26
    gitTable.intercellSpacing = .zero
    gitTable.selectionHighlightStyle = .none
    gitTable.dataSource = self
    gitTable.delegate = self
    if gitTable.tableColumns.isEmpty {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details-git-change"))
      column.resizingMask = .autoresizingMask
      gitTable.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = gitTable
    root.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let empty = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
    empty.alignment = .center
    root.addSubview(empty)
    empty.translatesAutoresizingMaskIntoConstraints = false
    gitEmptyLabel = empty
    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      top.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      empty.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 14),
      empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
      empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
    ])
    updateGitContent()
    return root
  }

  private enum GitRow {
    case group(title: String, count: Int, stageAll: (() -> Void)?)
    case change(GitChange, badgeColor: NSColor, actions: GitChangeRowActions)
  }

  private func updateGitContent() {
    guard let git = gitStatus else {
      gitRows = []
      gitBranchLabel?.stringValue = "—"
      gitInsertionsLabel?.stringValue = ""
      gitDeletionsLabel?.stringValue = ""
      gitCommitButton?.isHidden = true
      gitEditorButton?.isHidden = true
      gitEmptyLabel?.stringValue = "正在读取 Git 状态…"
      gitEmptyLabel?.isHidden = false
      gitTable.reloadData()
      return
    }
    guard git.branch != nil || git.objectID != nil else {
      gitRows = []
      gitBranchLabel?.stringValue = "—"
      gitInsertionsLabel?.stringValue = ""
      gitDeletionsLabel?.stringValue = ""
      gitCommitButton?.isHidden = true
      gitEditorButton?.isHidden = true
      gitEmptyLabel?.stringValue = "当前目录不在 Git 仓库中。"
      gitEmptyLabel?.isHidden = false
      gitTable.reloadData()
      return
    }
    gitBranchLabel?.stringValue = git.branch ?? "detached"
    gitInsertionsLabel?.stringValue = git.diffStat.map { "+\($0.insertions)" } ?? ""
    gitDeletionsLabel?.stringValue = git.diffStat.map { "−\($0.deletions)" } ?? ""
    gitCommitButton?.isHidden = false
    updateGitEditorButton()

    var rows: [GitRow] = []
    let stagedCount = git.stagedChanges.count
    let staged = Array(git.stagedChanges.prefix(200))
    if !staged.isEmpty {
      rows.append(.group(title: "Staged", count: stagedCount, stageAll: nil))
      rows.append(contentsOf: staged.map { change in
        .change(
          change, badgeColor: AsterTheme.accent,
          actions: gitRowActions(for: change, staged: true))
      })
    }
    let unstagedCount = git.unstagedChanges.count
    let unstaged = Array(git.unstagedChanges.prefix(200))
    if !unstaged.isEmpty {
      rows.append(.group(
        title: "Unstaged",
        count: unstagedCount,
        stageAll: { [weak self] in
          self?.injectGitCommand(.stageAll)
        }))
      rows.append(contentsOf: unstaged.map { change in
        .change(
          change, badgeColor: AsterTheme.warning,
          actions: gitRowActions(for: change, staged: false))
      })
    }
    gitRows = rows
    gitEmptyLabel?.stringValue = "工作区干净"
    gitEmptyLabel?.isHidden = !rows.isEmpty
    gitTable.reloadData()
  }

  /// 组装单个变更行的动作。已暂存行的第一个图标是取消暂存，未暂存行是暂存；编辑器图标
  /// 只在本机确实探测到编辑器时出现，避免给出点了没反应的入口。
  private func gitRowActions(for change: GitChange, staged: Bool) -> GitChangeRowActions {
    let editorName = preferredEditor()?.name
    return GitChangeRowActions(
      open: gitOpenAction(for: change),
      stageSymbol: staged ? "minus.circle" : "plus.circle",
      stageTooltip: staged
        ? "把 git restore --staged 放入终端输入行" : "把 git add 放入终端输入行",
      stage: { [weak self] in
        self?.injectGitCommand(staged ? .unstage(path: change.path) : .stage(path: change.path))
      },
      editorTooltip: editorName.map { "在 \($0) 中打开" },
      openInEditor: editorName == nil
        ? nil
        : { [weak self] in self?.openChangeInPreferredEditor(change) },
      preview: { [weak self] anchor in
        self?.presentGitDiffPreview(for: change, staged: staged, anchor: anchor)
      }
    )
  }

  private func gitOpenAction(for change: GitChange) -> () -> Void {
    { [weak self] in
      guard let self, let directory = self.model.selectedTab?.workingDirectory else { return }
      self.model.selectedTab?.openFile(
        URL(fileURLWithPath: directory).appendingPathComponent(change.path))
      self.model.persistWorkspace()
    }
  }

  // MARK: - Git 写操作与编辑器

  /// 所有仓库写操作的唯一出口：只把命令预填到当前 Pane 的终端输入行，由用户回车执行。
  /// 命令文本非法（分支名为空、路径含控制字符）时直接放弃，不注入半条命令。
  private func injectGitCommand(_ command: GitCommand) {
    guard let commandLine = command.commandLine else { return }
    model.selectedTab?.activeSession?.typeText(commandLine)
  }

  /// Commit 按钮右侧的下拉：同步类操作直接注入，Merge/Rebase 先要一个分支名。
  /// 非 private 是为了让测试直接检查菜单结构，不必真的弹出模态菜单。
  func makeGitOperationsMenu() -> NSMenu {
    let menu = NSMenu()
    for (title, command) in [("Push", GitCommand.push), ("Pull", .pull), ("Fetch", .fetch)] {
      menu.addItem(ActionMenuItem(title: title) { [weak self] in self?.injectGitCommand(command) })
    }
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: "Merge…") { [weak self] in
      self?.promptBranch(title: "Merge 分支", action: "Merge") { branch in
        self?.injectGitCommand(.merge(branch: branch))
      }
    })
    menu.addItem(ActionMenuItem(title: "Rebase…") { [weak self] in
      self?.promptBranch(title: "Rebase 到分支", action: "Rebase") { branch in
        self?.injectGitCommand(.rebase(branch: branch))
      }
    })
    return menu
  }

  /// Merge/Rebase 的分支输入。校验在 `GitCommand.sanitizedBranch` 中完成，这里只负责
  /// 收集文本并在非法时不做任何事——命令必须由用户在终端里最终确认。
  private func promptBranch(title: String, action: String, completion: @escaping (String) -> Void) {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.placeholderString = "分支名"
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "命令会预填到终端输入行，确认后回车执行。"
    alert.accessoryView = field
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let branch = GitCommand.sanitizedBranch(field.stringValue) else { return }
    completion(branch)
  }

  private func preferredEditor() -> DetectedEditor? {
    WorkspaceEditorLocator.preferred(
      from: editorLocator(),
      bundleIdentifier: preferences.inspectorGitEditorBundleIdentifier)
  }

  private func openWorkingDirectoryInPreferredEditor() {
    guard let editor = preferredEditor(),
      let directory = model.selectedTab?.workingDirectory
    else { return }
    WorkspaceEditorLocator.open(directory: URL(fileURLWithPath: directory), in: editor)
  }

  private func openChangeInPreferredEditor(_ change: GitChange) {
    guard let editor = preferredEditor(),
      let directory = model.selectedTab?.workingDirectory
    else { return }
    WorkspaceEditorLocator.open(
      [URL(fileURLWithPath: directory).appendingPathComponent(change.path)], in: editor)
  }

  /// 编辑器按钮的下拉：列出本机探测到的全部编辑器，选中项打勾并写回偏好。切换后同时
  /// 刷新行内图标的 tooltip，因此这里重建 Git 行而不是只改按钮标题。
  func makeEditorMenu() -> NSMenu {
    let menu = NSMenu()
    let editors = editorLocator()
    let current = WorkspaceEditorLocator.preferred(
      from: editors, bundleIdentifier: preferences.inspectorGitEditorBundleIdentifier)
    for editor in editors {
      let item = ActionMenuItem(title: editor.name) { [weak self] in
        guard let self else { return }
        self.preferences.inspectorGitEditorBundleIdentifier = editor.bundleIdentifier
        self.updateGitEditorButton()
        self.updateGitContent()
      }
      item.state = editor.bundleIdentifier == current?.bundleIdentifier ? .on : .off
      item.image = Self.applicationIcon(for: editor)
      menu.addItem(item)
    }
    if editors.isEmpty {
      let empty = NSMenuItem(title: "未检测到受支持的编辑器", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
    }
    return menu
  }

  /// 应用图标缩到菜单/按钮尺寸。`NSWorkspace.icon(forFile:)` 返回的是 512pt 大图，
  /// 直接放进按钮会撑高整行。
  private static func applicationIcon(for editor: DetectedEditor) -> NSImage {
    let icon = NSWorkspace.shared.icon(forFile: editor.appURL.path)
    let resized = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
      icon.draw(in: rect)
      return true
    }
    return resized
  }

  /// 内置 diff 预览。详情面板只有 278pt 宽，放不下有意义的 diff，因此浮层挂在窗口内容
  /// 视图上；数据仍走只读 `git diff`，与 Git 页其它检查共用同一个可注入 client。
  private func presentGitDiffPreview(for change: GitChange, staged: Bool, anchor: NSView) {
    guard let contentView = view.window?.contentView,
      let directory = model.selectedTab?.workingDirectory
    else { return }
    dismissGitDiffPreview()
    let overlay = GitDiffPreviewOverlay(path: change.path) { [weak self] in
      self?.dismissGitDiffPreview()
    }
    contentView.addSubview(overlay)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.pinEdges(to: contentView)
    // 气泡贴着详情面板左缘展开，箭头对准触发行；两者都用转换后的坐标，因此不依赖
    // 面板宽度常量，分隔线或未来的宽度调整都不会让气泡与面板之间出现缝隙。
    overlay.setAnchor(
      panelEdgeX: view.convert(view.bounds, to: contentView).minX,
      rowCenterY: anchor.convert(anchor.bounds, to: contentView).midY
    )
    gitDiffPreview = overlay
    let client = inspectionClient
    gitDiffTask = Task { @MainActor [weak self] in
      let text = await client.diff(directory, change.path, staged)
      // 请求返回时浮层可能已被替换或关闭；用身份比较而不是存在性判断，避免旧结果写进新浮层。
      guard !Task.isCancelled, let self, self.gitDiffPreview === overlay else { return }
      overlay.apply(lines: GitDiffParser.parse(text))
    }
  }

  private func dismissGitDiffPreview() {
    gitDiffTask?.cancel()
    gitDiffTask = nil
    gitDiffPreview?.dismiss()
    gitDiffPreview = nil
  }

  private func updateGitEditorButton() {
    guard let button = gitEditorButton else { return }
    guard let editor = preferredEditor() else {
      button.isHidden = true
      return
    }
    button.isHidden = false
    button.primaryButton.title = editor.name
    button.primaryButton.image = Self.applicationIcon(for: editor)
    button.primaryButton.imagePosition = .imageLeading
    button.toolTip = "在 \(editor.name) 中打开当前目录"
  }

  // MARK: - Files

  private func makeFilesContent() -> NSView {
    let root = NSView()
    let search = NSSearchField()
    search.placeholderString = "Find"
    search.stringValue = filesQuery
    search.delegate = self
    filesSearchField = search
    let sort = ActionButton(symbol: "arrow.up.arrow.down", bezelStyle: .accessoryBarAction) {
      [weak self] in
      guard let self else { return }
      self.filesDirectoriesFirst.toggle()
      self.rebuildFileTreeProjection()
    }
    sort.isBordered = false
    sort.toolTip = filesDirectoriesFirst ? "目录优先（点击切换为按名称）" : "按名称（点击切换为目录优先）"
    filesSortButton = sort
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [search, spacer, sort])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    search.translatesAutoresizingMaskIntoConstraints = false
    search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    root.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false

    filesTable.identifier = NSUserInterfaceItemIdentifier("details-files-table")
    filesTable.headerView = nil
    filesTable.backgroundColor = .clear
    filesTable.rowHeight = 24
    filesTable.intercellSpacing = .zero
    filesTable.selectionHighlightStyle = .none
    filesTable.dataSource = self
    filesTable.delegate = self
    if filesTable.tableColumns.isEmpty {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details-files-name"))
      column.resizingMask = .autoresizingMask
      filesTable.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = filesTable
    root.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let empty = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
    empty.alignment = .center
    root.addSubview(empty)
    empty.translatesAutoresizingMaskIntoConstraints = false
    filesEmptyLabel = empty
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      empty.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 14),
      empty.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -14),
      empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
    ])
    rebuildFileTreeProjection()
    return root
  }

  /// 扁平（depth 序列）→ 树。`WorkspaceFileTree.enumerate` 按遍历顺序输出，子节点
  /// 紧跟父节点且 depth 每次最多 +1，递归归入上一层末尾节点即可。
  private struct FileTreeItem {
    let node: WorkspaceFileNode
    var children: [FileTreeItem]
  }

  /// `NSTableView` 只实例化视口附近的 cell；树结构先压平成轻量行模型，搜索、排序和
  /// 折叠时只替换这个数组，不再创建数百个 AppKit 控件和约束。
  private struct FileRow {
    let item: FileTreeItem
    let depth: Int
  }

  private func buildFileTree(_ nodes: [WorkspaceFileNode]) -> [FileTreeItem] {
    func insert(_ node: WorkspaceFileNode, into items: inout [FileTreeItem], depth: Int) {
      if node.depth <= depth || items.isEmpty {
        items.append(FileTreeItem(node: node, children: []))
      } else {
        insert(node, into: &items[items.count - 1].children, depth: depth + 1)
      }
    }
    var roots: [FileTreeItem] = []
    for node in nodes.prefix(2_000) {
      insert(node, into: &roots, depth: 0)
    }
    return roots
  }

  private func sortFileTree(_ items: inout [FileTreeItem]) {
    for index in items.indices { sortFileTree(&items[index].children) }
    items.sort { lhs, rhs in
      if filesDirectoriesFirst, lhs.node.isDirectory != rhs.node.isDirectory {
        return lhs.node.isDirectory
      }
      return lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
    }
  }

  /// 搜索时保留匹配项及其祖先目录，展示为完全展开的树。
  private func filterFileTree(_ items: [FileTreeItem], query: String) -> [FileTreeItem] {
    items.compactMap { item in
      let children = filterFileTree(item.children, query: query)
      guard item.node.name.localizedCaseInsensitiveContains(query) || !children.isEmpty
      else { return nil }
      var copy = item
      copy.children = children
      return copy
    }
  }

  private func flattenFileTree(
    _ items: [FileTreeItem], honoringCollapse: Bool, depth: Int = 0
  ) -> [FileRow] {
    items.flatMap { item -> [FileRow] in
      let collapsed = honoringCollapse && item.node.isDirectory
        && !expandedPaths.contains(item.node.path)
      return [FileRow(item: item, depth: depth)]
        + (collapsed ? [] : flattenFileTree(
          item.children, honoringCollapse: honoringCollapse, depth: depth + 1))
    }
  }

  private func rebuildFileTreeProjection() {
    fileTree = buildFileTree(fileNodes ?? [])
    sortFileTree(&fileTree)
    rebuildVisibleFileRows()
  }

  private func rebuildVisibleFileRows() {
    var filtered = fileTree
    if !filesQuery.isEmpty { filtered = filterFileTree(filtered, query: filesQuery) }
    visibleFileRows = flattenFileTree(filtered, honoringCollapse: filesQuery.isEmpty)
    filesTable.reloadData()
    filesSortButton?.toolTip = filesDirectoriesFirst
      ? "目录优先（点击切换为按名称）" : "按名称（点击切换为目录优先）"
    guard let empty = filesEmptyLabel else { return }
    if fileNodes == nil {
      empty.stringValue = "正在读取目录…"
      empty.isHidden = false
    } else if visibleFileRows.isEmpty {
      empty.stringValue = filesQuery.isEmpty
        ? "目录为空或不可读取。" : "没有匹配 “\(filesQuery)” 的条目。"
      empty.isHidden = false
    } else {
      empty.isHidden = true
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView === filesTable { return visibleFileRows.count }
    if tableView === outlineTable { return outlineRows.count }
    if tableView === gitTable { return gitRows.count }
    return 0
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    if tableView === gitTable {
      guard gitRows.indices.contains(row) else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("details-git-row")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DetailsGitRowView
        ?? DetailsGitRowView(identifier: identifier)
      switch gitRows[row] {
      case .group(let title, let count, let stageAll):
        cell.configureGroup(title: title, count: count, stageAll: stageAll)
      case .change(let change, let badgeColor, let actions):
        cell.configureChange(change, badgeColor: badgeColor, actions: actions)
      }
      return cell
    }
    if tableView === outlineTable {
      guard outlineRows.indices.contains(row) else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("details-outline-row")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DetailsOutlineRowView
        ?? DetailsOutlineRowView(identifier: identifier)
      let outlineRow = outlineRows[row]
      cell.configure(
        title: outlineRow.title,
        metadata: outlineRow.metadata,
        indentation: outlineRow.indentation,
        toolTip: outlineRow.toolTip,
        action: outlineRow.action
      )
      return cell
    }
    guard tableView === filesTable, visibleFileRows.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("details-file-row")
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DetailsFileRowView
      ?? DetailsFileRowView(identifier: identifier)
    let fileRow = visibleFileRows[row]
    let node = fileRow.item.node
    cell.configure(
      node: node,
      depth: fileRow.depth,
      expanded: expandedPaths.contains(node.path),
      onToggle: { [weak self] in
        guard let self else { return }
        if self.expandedPaths.contains(node.path) {
          self.expandedPaths.remove(node.path)
        } else {
          self.expandedPaths.insert(node.path)
        }
        self.rebuildVisibleFileRows()
      },
      onOpen: { [weak self] in self?.openFileNode(node) }
    )
    return cell
  }

  private func openFileNode(_ node: WorkspaceFileNode) {
    let url = URL(fileURLWithPath: node.path)
    if node.isDirectory, !node.isSymbolicLink {
      model.selectedTab?.split(direction: .left, kind: .fileBrowser, resourcePath: node.path)
    } else if node.isSymbolicLink {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      model.selectedTab?.openFile(url)
    }
    model.persistWorkspace()
  }

  // MARK: - 共享构建辅助

  private func outlineKind(for url: URL) -> WorkspaceOutlineKind? {
    switch url.pathExtension.lowercased() {
    case "md", "markdown": .markdown
    case "html", "htm": .html
    case "json": .json
    case "yaml", "yml": .yaml
    case "toml": .toml
    case "diff", "patch": .diff
    case "jsonl": .jsonLinesTranscript
    default: nil
    }
  }

  /// 滚动文档用 `FlippedDocumentView`（左上原点）从顶部锚定：非翻转文档在内容
  /// 短于视口时会沉到底部。文档高度至少等于可视高度，内容始终贴顶排列。
  private func makeScrollableContent(_ stack: NSStackView) -> NSView {
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let document = FlippedDocumentView()
    document.addSubview(stack)
    scroll.documentView = document
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor),
    ])
    return scroll
  }

  private func makeGroupHeader(_ title: String) -> NSTextField {
    makeLabel(title, size: 10, weight: .semibold, color: AsterTheme.tertiaryInk)
  }

  private func rebuildFilesContent() {
    rebuildVisibleFileRows()
  }

  /// 让行占满内容区可用宽度（滚动文档宽 − 两侧 14pt 内边距），配合行内 spacer
  /// 把右侧元信息（PID、相对时间、diff 统计）推到行尾。
  private func addFullWidthRow(_ row: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
  }

  /// 图标 + accent 色文字的动作链接行（Copy Path / Open in … 一类）。
  private func makeLinkRow(symbol: String, title: String, handler: @escaping () -> Void) -> NSView {
    let button = ActionButton(title: title, symbol: symbol, bezelStyle: .inline, handler: handler)
    button.isBordered = false
    button.alignment = .left
    button.contentTintColor = AsterTheme.accent
    button.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .foregroundColor: AsterTheme.accent,
        .font: NSFont.systemFont(ofSize: 12),
      ])
    return button
  }
}

/// 面板页签 chip：未选中收起成固定宽度的图标按钮，选中时灰底圆角并向右展开标题文字。
/// 宽度由显式约束驱动并做一次短过渡，相邻 chip 平滑让位而不是瞬间跳到新位置；收起态
/// 宽度固定，四个页签在默认状态下保持一致的间距，不随各自标题长度变化。背景色来自
/// dynamic NSColor，需要在 appearance 变化时重填 cgColor。
private final class PanelTabChip: NSButton {
  /// 收起态正方形宽度。展开宽度取「该值 + 标题实际宽度」，因为按钮内容居中，两种状态
  /// 下图标左右留白都是 `(collapsedWidth - 图标宽) / 2`，图标停在原处、只有文字从右侧
  /// 长出来；若改成按固有尺寸展开，bezel 内边距会让图标在动画里横向漂移。
  private static let collapsedWidth: CGFloat = 26
  private static let titleFontSize: CGFloat = 11
  private static let expansionDuration: TimeInterval = 0.18
  private static let backgroundDuration: TimeInterval = 0.12

  private static var prefersReducedMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private(set) var isChipSelected = false

  private let fullTitle: String
  private var widthConstraint: NSLayoutConstraint?
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false

  init(title: String, symbol: String, handler: @escaping () -> Void) {
    fullTitle = title
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    imagePosition = .imageLeading
    bezelStyle = .accessoryBarAction
    isBordered = false
    // 展开过程中的中间宽度只能显示部分文字，按宽度直接裁剪比省略号更接近「拉开」的观感。
    lineBreakMode = .byClipping
    wantsLayer = true
    layer?.cornerRadius = 6
    target = self
    action = #selector(invoke)
    self.handler = handler
    translatesAutoresizingMaskIntoConstraints = false
    let width = widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
    width.isActive = true
    widthConstraint = width
    heightAnchor.constraint(equalToConstant: 24).isActive = true
    applyTitle()
    applyAppearance(animated: false)
  }

  required init?(coder: NSCoder) { nil }

  private var handler: (() -> Void)?

  @objc private func invoke() { handler?() }

  /// 用户点击切页时传 `animated: true`；构建 header 或恢复持久化选中页时传 false，
  /// 避免面板刚出现就播放一次没有来由的展开动画。
  func setSelected(_ selected: Bool, animated: Bool) {
    guard selected != isChipSelected else { return }
    isChipSelected = selected
    applyAppearance(animated: animated)
    // 展开时先把文字放上去，再让宽度动画把它揭示出来。
    if selected { applyTitle() }
    // 约束常量立即写入最终值，动画只负责把这一轮布局变化演出来；用 animator() 代理改
    // constant 会让模型值滞后于动画，收起/展开状态就无法被同步读取或测试。
    widthConstraint?.constant = selected ? expandedWidth : Self.collapsedWidth
    guard animated, !Self.prefersReducedMotion, let superview else {
      applyTitle()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.expansionDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      superview.layoutSubtreeIfNeeded()
    }
    // 收起态的文字保留到宽度收完再清空，否则会先看到文字消失、再看到宽度回缩的两段跳变。
    if !selected {
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(Self.expansionDuration))
        guard let self, !self.isChipSelected else { return }
        self.applyTitle()
      }
    }
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
    guard !isHovering else { return }
    isHovering = true
    applyAppearance(animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard isHovering else { return }
    isHovering = false
    applyAppearance(animated: true)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance(animated: false)
  }

  private var selectedTitle: String { " \(fullTitle)" }

  private var expandedWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: Self.titleFontSize, weight: .semibold)
    let width = (selectedTitle as NSString).size(withAttributes: [.font: font]).width
    // +2 吸收字距测量与实际绘制的舍入差，避免最后一个字符被宽度约束切掉。
    return Self.collapsedWidth + ceil(width) + 2
  }

  private func applyTitle() {
    title = isChipSelected ? selectedTitle : ""
  }

  private func applyAppearance(animated: Bool) {
    font = NSFont.systemFont(ofSize: Self.titleFontSize, weight: isChipSelected ? .semibold : .regular)
    contentTintColor = isChipSelected ? AsterTheme.ink : AsterTheme.secondaryInk
    let alpha: CGFloat = isChipSelected ? 0.08 : (isHovering ? 0.05 : 0)
    let background =
      alpha > 0 ? AsterTheme.ink.withAlphaComponent(alpha).cgColor : NSColor.clear.cgColor
    guard animated, !Self.prefersReducedMotion, let layer else {
      layer?.backgroundColor = background
      return
    }
    let fade = CABasicAnimation(keyPath: "backgroundColor")
    fade.fromValue = layer.backgroundColor
    fade.toValue = background
    fade.duration = Self.backgroundDuration
    layer.backgroundColor = background
    layer.add(fade, forKey: "chipBackground")
  }
}

extension DetailsPanelViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField, field === filesSearchField else { return }
    filesQuery = field.stringValue
    rebuildFilesContent()
  }
}

/// Git 变更行悬停后出现的动作集合。行视图只负责显示与转发，命令构造和安全校验都留在
/// 控制器与 `GitCommand` 里。
@MainActor
struct GitChangeRowActions {
  let open: () -> Void
  let stageSymbol: String
  let stageTooltip: String
  let stage: () -> Void
  let editorTooltip: String?
  let openInEditor: (() -> Void)?
  /// 参数是触发预览的行视图：气泡要贴着面板并把箭头对准这一行，因此必须知道它的位置。
  let preview: (NSView) -> Void
}

/// 分离式下拉按钮：左侧主动作 + 右侧箭头菜单。AppKit 没有对应控件（`NSPopUpButton`
/// 的 pull-down 会把标题和箭头合成一体、点标题也弹菜单），因此用两个原生按钮拼出
/// 参考实现的形态，主动作仍然一键可达。
@MainActor
final class SplitActionButton: NSStackView {
  let primaryButton: ActionButton
  private let arrowButton: ActionButton

  init(
    title: String,
    symbol: String?,
    primary: @escaping () -> Void,
    menu: @escaping () -> NSMenu
  ) {
    primaryButton = ActionButton(title: title, symbol: symbol, bezelStyle: .rounded, handler: primary)
    var arrow: ActionButton!
    arrow = ActionButton(symbol: "chevron.down", bezelStyle: .rounded) {
      let popup = menu()
      // 菜单从箭头按钮左下角展开，与参考实现一致；`nil` 定位项避免高亮首项。
      popup.popUp(
        positioning: nil,
        at: NSPoint(x: 0, y: arrow.bounds.height + 2),
        in: arrow)
    }
    arrowButton = arrow
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 1
    primaryButton.controlSize = .regular
    arrowButton.controlSize = .regular
    arrowButton.imagePosition = .imageOnly
    arrowButton.translatesAutoresizingMaskIntoConstraints = false
    arrowButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
    addArrangedSubview(primaryButton)
    addArrangedSubview(arrowButton)
  }

  required init?(coder: NSCoder) { nil }
}

/// 带右侧指向箭头的气泡背板。圆角矩形与箭头必须是同一条填充路径，分开画会在接缝处
/// 留下两层阴影的暗边；箭头基线刻意嵌入矩形 1pt，避免抗锯齿在交界露出发丝缝。
@MainActor
final class CalloutPanelView: NSView {
  static let arrowWidth: CGFloat = 9
  static let arrowHeight: CGFloat = 18
  static let cornerRadius: CGFloat = 12

  /// 箭头尖端在本视图坐标中的纵向位置。超出圆角区域会被夹紧，避免箭头长在圆角上。
  var arrowCenterY: CGFloat = 0 {
    didSet { needsLayout = true }
  }

  private var shapeLayer: CAShapeLayer? { layer as? CAShapeLayer }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    shapeLayer?.fillColor = AsterTheme.paper.cgColor
    shapeLayer?.shadowColor = NSColor.black.cgColor
    shapeLayer?.shadowOpacity = 0.26
    shapeLayer?.shadowRadius = 20
    shapeLayer?.shadowOffset = NSSize(width: -2, height: -4)
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer { CAShapeLayer() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    shapeLayer?.fillColor = AsterTheme.paper.cgColor
  }

  override func layout() {
    super.layout()
    let body = NSRect(
      x: 0, y: 0, width: max(0, bounds.width - Self.arrowWidth), height: bounds.height)
    let path = CGMutablePath()
    path.addRoundedRect(in: body, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius)
    let limit = Self.cornerRadius + Self.arrowHeight / 2
    let tipY = min(max(arrowCenterY, limit), max(limit, bounds.height - limit))
    path.move(to: CGPoint(x: body.maxX - 1, y: tipY - Self.arrowHeight / 2))
    path.addLine(to: CGPoint(x: bounds.maxX, y: tipY))
    path.addLine(to: CGPoint(x: body.maxX - 1, y: tipY + Self.arrowHeight / 2))
    path.closeSubpath()
    shapeLayer?.path = path
  }
}

/// diff 气泡的标题条：固定 `#EFF4FF` 浅底 + 顶部圆角，与气泡背板的圆角半径一致（底边
/// 保持直角，紧接下面的 diff 文本）。
///
/// 这里刻意不走 `ThemeRuntime` 的动态色：底色由设计稿指定为固定值。既然底色不跟随
/// 明暗外观，条上的前景色也必须一起固定——深色主题的浅色文字落在这块浅蓝底上会不可读。
@MainActor
private final class DiffPreviewHeaderView: NSView {
  static let backgroundColor = NSColor(
    srgbRed: 0xEF / 255, green: 0xF4 / 255, blue: 0xFF / 255, alpha: 1)
  static let foregroundColor = NSColor(
    srgbRed: 0x1F / 255, green: 0x29 / 255, blue: 0x33 / 255, alpha: 1)

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = CalloutPanelView.cornerRadius
    // 非翻转坐标下 MaxY 一侧才是视觉上的顶部两角。
    layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    layer?.backgroundColor = Self.backgroundColor.cgColor
  }

  required init?(coder: NSCoder) { nil }
}

/// 内置 diff 预览气泡。覆盖整个窗口内容区并自带 scrim：点击气泡外、按 Esc 或切走 Git
/// 页都会关闭。气泡本体贴着详情面板左缘、箭头对准触发行，文本用等宽字体按行着色，
/// 只读展示，不提供任何写操作入口。
@MainActor
final class GitDiffPreviewOverlay: NSView {
  private static let maximumPanelSize = NSSize(width: 620, height: 520)
  private static let minimumPanelSize = NSSize(width: 260, height: 200)
  private static let screenInset: CGFloat = 16

  private let dismissHandler: () -> Void
  private let textView = NSTextView()
  private let panel = CalloutPanelView()
  private var eventMonitor: Any?
  /// 详情面板左缘与触发行中心，均为本视图坐标。窗口尺寸变化后按同一组锚点重新定位。
  private var panelEdgeX: CGFloat?
  private var rowCenterY: CGFloat = 0

  init(path: String, dismiss: @escaping () -> Void) {
    dismissHandler = dismiss
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("details-git-diff-preview")
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.12).cgColor

    panel.identifier = NSUserInterfaceItemIdentifier("details-git-diff-panel")
    addSubview(panel)

    let header = DiffPreviewHeaderView()
    header.identifier = NSUserInterfaceItemIdentifier("details-git-diff-header")
    header.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(header)

    let title = makeLabel(
      path, size: 12.5, weight: .semibold, color: DiffPreviewHeaderView.foregroundColor,
      monospaced: true)
    title.lineBreakMode = .byTruncatingHead
    title.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(title)

    let close = IconHoverButton(symbol: "xmark", accessibilityDescription: "关闭预览") { dismiss() }
    // 标题条底色固定，因此按钮的静息色也固定；悬停态仍由 IconHoverButton 统一提供。
    close.restingTint = DiffPreviewHeaderView.foregroundColor.withAlphaComponent(0.65)
    close.toolTip = "关闭预览"
    close.identifier = NSUserInterfaceItemIdentifier("details-git-diff-close")
    close.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(close)

    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainerInset = NSSize(width: 10, height: 8)
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = textView
    scroll.translatesAutoresizingMaskIntoConstraints = false
    panel.addSubview(scroll)

    // 内容一律避开右侧箭头占用的宽度，否则标题条和关闭按钮会压在箭头根部。
    let bodyTrailing = -CalloutPanelView.arrowWidth
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: bodyTrailing),
      header.topAnchor.constraint(equalTo: panel.topAnchor),
      header.heightAnchor.constraint(equalToConstant: 34),
      close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
      close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      close.widthAnchor.constraint(equalToConstant: 20),
      close.heightAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
      title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
      scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
      scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: bodyTrailing - 6),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
      scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
    ])
    apply(lines: [GitDiffLine(kind: .notice, text: "正在读取 diff…")])
    installEventMonitor()
  }

  required init?(coder: NSCoder) { nil }

  /// 记录详情面板左缘与触发行位置。定位本身在 `layout()` 里做，窗口尺寸变化时会按同一
  /// 组锚点重算，气泡不会脱离面板。
  func setAnchor(panelEdgeX: CGFloat, rowCenterY: CGFloat) {
    self.panelEdgeX = panelEdgeX
    self.rowCenterY = rowCenterY
    needsLayout = true
  }

  /// 气泡用 frame 定位而不是约束：宽高要同时受可用空间、上限和最小可读尺寸约束，纵向
  /// 还要在贴近窗口边缘时把箭头留在原位——这些用一组会互相冲突的约束表达并不更清晰。
  override func layout() {
    super.layout()
    guard let panelEdgeX else { return }
    let available = bounds.insetBy(dx: Self.screenInset, dy: Self.screenInset)
    guard available.width > 0, available.height > 0 else { return }
    let right = min(panelEdgeX, bounds.maxX - Self.screenInset)
    let width = max(
      Self.minimumPanelSize.width,
      min(Self.maximumPanelSize.width, right - available.minX))
    let height = max(
      Self.minimumPanelSize.height,
      min(Self.maximumPanelSize.height, available.height))
    // 先按行中心居中，再夹回窗口内；夹紧后箭头仍指向原来的行，因此只移动本体。
    var originY = rowCenterY - height / 2
    originY = min(max(originY, available.minY), max(available.minY, available.maxY - height))
    panel.frame = NSRect(x: right - width, y: originY, width: width, height: height)
    panel.arrowCenterY = rowCenterY - originY
  }

  func apply(lines: [GitDiffLine]) {
    let text = NSMutableAttributedString()
    let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let display = lines.isEmpty
      ? [GitDiffLine(kind: .notice, text: "该文件没有可显示的差异。")] : lines
    for line in display {
      text.append(NSAttributedString(
        string: line.text + "\n",
        attributes: [.font: font, .foregroundColor: Self.color(for: line.kind)]))
    }
    textView.textStorage?.setAttributedString(text)
    textView.sizeToFit()
    textView.scroll(NSPoint(x: 0, y: 0))
  }

  private static func color(for kind: GitDiffLine.Kind) -> NSColor {
    switch kind {
    case .addition: AsterTheme.accent
    case .deletion: AsterTheme.warning
    case .hunkHeader: AsterTheme.secondaryInk
    case .fileHeader, .notice: AsterTheme.tertiaryInk
    case .context: AsterTheme.ink
    }
  }

  /// Esc 与浮层外点击都在 local monitor 里处理：浮层是普通子视图，没有独立窗口可以
  /// 依赖 `cancelOperation(_:)`，而终端仍然持有 first responder。
  private func installEventMonitor() {
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
      [weak self] event in
      guard let self, self.window != nil else { return event }
      if event.type == .keyDown {
        guard event.keyCode == 53 else { return event }
        self.dismissHandler()
        return nil
      }
      guard event.window === self.window else { return event }
      let point = self.convert(event.locationInWindow, from: nil)
      guard self.bounds.contains(point), !self.panel.frame.contains(point) else { return event }
      self.dismissHandler()
      return nil
    }
  }

  func dismiss() {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    removeFromSuperview()
  }
}

/// 详情面板所有列表行的基类：悬停时整行加底色。列表项是可点的，必须给出「这里能点」
/// 的指针反馈；底色用独立子视图而不是染 cell 自身的 layer，行才能保留左右留白与圆角。
@MainActor
class HoverHighlightRowView: NSTableCellView {
  private static var hoverColor: NSColor { AsterTheme.ink.withAlphaComponent(0.06) }

  private let hoverBackground = NSView()
  private var hoverTrackingArea: NSTrackingArea?
  private(set) var isHovering = false
  /// 分组标题这类不可点的行要关掉高亮，否则会提示一个并不存在的动作。
  var isHoverHighlightEnabled = true {
    didSet { updateHoverHighlight() }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    hoverBackground.wantsLayer = true
    hoverBackground.layer?.cornerRadius = 5
    hoverBackground.isHidden = true
    hoverBackground.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hoverBackground)
    NSLayoutConstraint.activate([
      hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 子类在悬停状态变化时露出行内动作等附加反馈。
  func hoverStateChanged() {}

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
    guard !isHovering else { return }
    isHovering = true
    updateHoverHighlight()
    hoverStateChanged()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard isHovering else { return }
    isHovering = false
    updateHoverHighlight()
    hoverStateChanged()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateHoverHighlight()
  }

  private func updateHoverHighlight() {
    let visible = isHovering && isHoverHighlightEnabled
    hoverBackground.isHidden = !visible
    // 动态色的 cgColor 必须在当前 appearance 下取值，因此每次显示时重新计算。
    if visible { hoverBackground.layer?.backgroundColor = Self.hoverColor.cgColor }
  }
}

/// 可点文本按钮：无边框标题在视觉上和普通文字没有区别，指针必须变成手型。
@MainActor
final class PointingHandButton: NSButton {
  /// 文件项用双击才触发：详情面板的列表是浏览用的，单击打开会在滚动、选中或想点行尾
  /// 图标时误开 Pane。双击的第一次点击 `clickCount` 是 1，直接拦掉即可。
  var activatesOnDoubleClickOnly = false

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
    if activatesOnDoubleClickOnly, (NSApp.currentEvent?.clickCount ?? 1) < 2 { return false }
    return super.sendAction(action, to: target)
  }
}

/// Git 页的复用行同时承载分组标题和文件变更。两种模式共享固定约束，只切换对应控件，
/// staged/unstaged 最多数百项时也只保留视口附近的 cell。
@MainActor
private final class DetailsGitRowView: HoverHighlightRowView {
  private let groupLabel = NSTextField(labelWithString: "")
  private lazy var stageButton = IconHoverButton(
    symbol: "plus.circle", accessibilityDescription: "暂存全部"
  ) { [weak self] in self?.stageAction?() }
  private let badgeLabel = NSTextField(labelWithString: "")
  private let fileButton = PointingHandButton()
  private lazy var rowStageButton = IconHoverButton(symbol: "plus.circle") { [weak self] in
    self?.rowStageAction?()
  }
  private lazy var rowEditorButton = IconHoverButton(symbol: "arrow.up.forward.app") {
    [weak self] in self?.editorAction?()
  }
  private lazy var rowPreviewButton = IconHoverButton(symbol: "eye") { [weak self] in
    guard let self else { return }
    self.previewAction?(self)
  }
  private var stageAction: (() -> Void)?
  private var fileAction: (() -> Void)?
  private var rowStageAction: (() -> Void)?
  private var editorAction: (() -> Void)?
  private var previewAction: ((NSView) -> Void)?
  private var changeActionsAvailable = false
  private var fileTrailingFull: NSLayoutConstraint!
  private var fileTrailingCompact: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    groupLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    groupLabel.textColor = AsterTheme.tertiaryInk
    groupLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(groupLabel)

    stageButton.toolTip = "把 git add -A 放入终端输入行"
    stageButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stageButton)

    badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(badgeLabel)

    fileButton.isBordered = false
    fileButton.alignment = .left
    fileButton.lineBreakMode = .byTruncatingMiddle
    fileButton.activatesOnDoubleClickOnly = true
    fileButton.target = self
    fileButton.action = #selector(openFile)
    fileButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(fileButton)

    let rowActions = NSStackView(views: [rowStageButton, rowEditorButton, rowPreviewButton])
    rowActions.orientation = .horizontal
    rowActions.spacing = 2
    rowActions.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rowActions)
    for button in [rowStageButton, rowEditorButton, rowPreviewButton] {
      button.isHidden = true
      button.translatesAutoresizingMaskIntoConstraints = false
      button.widthAnchor.constraint(equalToConstant: 20).isActive = true
      button.heightAnchor.constraint(equalToConstant: 20).isActive = true
    }
    rowEditorButton.identifier = NSUserInterfaceItemIdentifier("details-git-row-editor")
    rowPreviewButton.identifier = NSUserInterfaceItemIdentifier("details-git-row-preview")
    rowStageButton.identifier = NSUserInterfaceItemIdentifier("details-git-row-stage")

    fileTrailingFull = fileButton.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -14)
    fileTrailingCompact = fileButton.trailingAnchor.constraint(
      equalTo: rowActions.leadingAnchor, constant: -6)
    NSLayoutConstraint.activate([
      groupLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      groupLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      groupLabel.trailingAnchor.constraint(lessThanOrEqualTo: stageButton.leadingAnchor, constant: -6),
      stageButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      stageButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      stageButton.widthAnchor.constraint(equalToConstant: 20),
      stageButton.heightAnchor.constraint(equalToConstant: 20),
      badgeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
      rowActions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      rowActions.centerYAnchor.constraint(equalTo: centerYAnchor),
      fileButton.leadingAnchor.constraint(equalTo: badgeLabel.trailingAnchor, constant: 6),
      fileTrailingFull,
      fileButton.topAnchor.constraint(equalTo: topAnchor),
      fileButton.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configureGroup(title: String, count: Int, stageAll: (() -> Void)?) {
    groupLabel.stringValue = "\(title) (\(count))"
    groupLabel.isHidden = false
    stageButton.isHidden = stageAll == nil
    badgeLabel.isHidden = true
    fileButton.isHidden = true
    stageAction = stageAll
    fileAction = nil
    // 分组行没有行内动作，也不该有整行高亮（它不可点）；复用 cell 时必须显式关掉，
    // 否则会继承上一条变更行的图标与底色。
    changeActionsAvailable = false
    isHoverHighlightEnabled = false
    rowStageAction = nil
    editorAction = nil
    previewAction = nil
    updateHoverActions()
  }

  func configureChange(
    _ change: GitChange, badgeColor: NSColor, actions: GitChangeRowActions
  ) {
    groupLabel.isHidden = true
    stageButton.isHidden = true
    badgeLabel.stringValue = change.status.replacingOccurrences(of: ".", with: "")
    badgeLabel.textColor = badgeColor
    badgeLabel.isHidden = false
    fileButton.title = change.path
    fileButton.toolTip = change.path
    fileButton.isHidden = false
    stageAction = nil
    fileAction = actions.open
    rowStageButton.setSymbol(
      actions.stageSymbol, accessibilityDescription: actions.stageTooltip)
    rowStageButton.toolTip = actions.stageTooltip
    rowStageAction = actions.stage
    editorAction = actions.openInEditor
    rowEditorButton.toolTip = actions.editorTooltip
    previewAction = actions.preview
    changeActionsAvailable = true
    isHoverHighlightEnabled = true
    updateHoverActions()
  }

  override func hoverStateChanged() { updateHoverActions() }

  /// 悬停时露出行内动作（整行底色由基类负责）。图标区不常驻：三个图标占 68pt，一直显示
  /// 会让所有行的路径都被提前截断；只有指针所在行需要让位，因此在两条 trailing 约束
  /// 之间切换。
  private func updateHoverActions() {
    let visible = changeActionsAvailable && isHovering
    rowStageButton.isHidden = !visible
    rowEditorButton.isHidden = !visible || editorAction == nil
    rowPreviewButton.isHidden = !visible
    fileTrailingCompact.isActive = visible
    fileTrailingFull.isActive = !visible
  }

  @objc private func openFile() { fileAction?() }
}

/// Outline 页的可复用行。标题按钮继续承担跳转动作，右侧元信息和层级缩进仅在 cell
/// 重配时更新，因此 1,000 条大纲不会对应 1,000 组常驻控件与约束。
@MainActor
private final class DetailsOutlineRowView: HoverHighlightRowView {
  private let titleButton = PointingHandButton()
  private let metadataLabel = NSTextField(labelWithString: "")
  private var indentationConstraint: NSLayoutConstraint!
  private var actionHandler: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    titleButton.isBordered = false
    titleButton.alignment = .left
    titleButton.lineBreakMode = .byTruncatingTail
    titleButton.target = self
    titleButton.action = #selector(activate)
    titleButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleButton)

    metadataLabel.font = NSFont.systemFont(ofSize: 10)
    metadataLabel.textColor = AsterTheme.tertiaryInk
    metadataLabel.alignment = .right
    metadataLabel.setContentHuggingPriority(.required, for: .horizontal)
    metadataLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(metadataLabel)

    indentationConstraint = titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
    NSLayoutConstraint.activate([
      indentationConstraint,
      titleButton.topAnchor.constraint(equalTo: topAnchor),
      titleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      titleButton.trailingAnchor.constraint(lessThanOrEqualTo: metadataLabel.leadingAnchor, constant: -6),
      metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      metadataLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(
    title: String,
    metadata: String,
    indentation: Int,
    toolTip: String?,
    action: @escaping () -> Void
  ) {
    titleButton.title = title
    titleButton.toolTip = toolTip
    metadataLabel.stringValue = metadata
    indentationConstraint.constant = 14 + CGFloat(max(0, indentation)) * 12
    actionHandler = action
  }

  @objc private func activate() { actionHandler?() }
}

/// Files 页的可复用表格行。每个 cell 只在首次进入视口时建立约束，后续滚动、搜索和
/// 折叠仅更新图标、标题、缩进与动作闭包，避免把目录规模转换成等量 AppKit 视图。
@MainActor
private final class DetailsFileRowView: HoverHighlightRowView {
  private lazy var disclosure = IconHoverButton(symbol: "chevron.right") { [weak self] in
    self?.onToggle?()
  }
  private let fileButton = PointingHandButton()
  private var indentationConstraint: NSLayoutConstraint!
  private var onToggle: (() -> Void)?
  private var onOpen: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    disclosure.translatesAutoresizingMaskIntoConstraints = false
    addSubview(disclosure)

    fileButton.isBordered = false
    fileButton.alignment = .left
    fileButton.imagePosition = .imageLeading
    fileButton.lineBreakMode = .byTruncatingTail
    fileButton.activatesOnDoubleClickOnly = true
    fileButton.target = self
    fileButton.action = #selector(openItem)
    fileButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(fileButton)

    indentationConstraint = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
    NSLayoutConstraint.activate([
      indentationConstraint,
      disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
      disclosure.widthAnchor.constraint(equalToConstant: 18),
      disclosure.heightAnchor.constraint(equalToConstant: 18),
      fileButton.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 2),
      fileButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      fileButton.topAnchor.constraint(equalTo: topAnchor),
      fileButton.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(
    node: WorkspaceFileNode,
    depth: Int,
    expanded: Bool,
    onToggle: @escaping () -> Void,
    onOpen: @escaping () -> Void
  ) {
    indentationConstraint.constant = 8 + CGFloat(max(0, depth)) * 14
    let expandable = node.isDirectory && !node.isSymbolicLink
    disclosure.isHidden = !expandable
    if expandable {
      disclosure.setSymbol(
        expanded ? "chevron.down" : "chevron.right",
        accessibilityDescription: expanded ? "折叠目录" : "展开目录")
    }
    fileButton.title = node.name
    fileButton.image = NSImage(
      systemSymbolName: node.isSymbolicLink
        ? "arrow.up.forward.square" : (node.isDirectory ? "folder" : "doc"),
      accessibilityDescription: nil)
    fileButton.toolTip = node.path
    self.onToggle = onToggle
    self.onOpen = onOpen
  }

  @objc private func openItem() { onOpen?() }
}
