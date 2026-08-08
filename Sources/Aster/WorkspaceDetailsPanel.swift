import AppKit
import AsterCore
import Combine

/// 右侧详情面板：Info / Outline / Git / Files 四页 chip 切换。进程、端口、Git、文件树
/// 数据全部来自 `WorkspaceInspectionService` 的只读快照；Commit、stage 等写操作不后台
/// 执行 git，而是把命令注入当前终端输入行，由用户审阅后自行回车（不触发隐藏 hook）。
@MainActor
final class DetailsPanelViewController: NSViewController {
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
  private let contentHost = NSView()
  private var chips: [Section: PanelTabChip] = [:]
  private var selection: Section
  private var inspection: WorkspaceInspectionSnapshot?
  private var inspectionDirectory: String?
  private var requestedInspectionDirectory: String?
  private var inspectedAt: Date?
  private var inspectionTask: Task<Void, Never>?
  private var filesTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []
  private var outlineCancellables: Set<AnyCancellable> = []
  /// 每个顶部页签只在数据失效时重建；普通切换直接复用已经完成布局的视图，尤其避免
  /// Files 页重复创建数百个按钮和 Auto Layout 约束。
  private var cachedContent: [Section: NSView] = [:]
  /// Files 页的折叠/搜索状态留在面板实例内；工作区刷新和面板收起/重开都会保留，
  /// 只有切换标签创建新详情控制器时才重置。
  private var collapsedPaths: Set<String> = []
  private var filesQuery = ""
  private var filesDirectoriesFirst = true
  private var fileNodes: [WorkspaceFileNode]?
  private var filesDirectory: String?
  private var requestedFilesDirectory: String?
  private weak var filesSearchField: NSSearchField?
  private var didRequestAgentHistory = false
  private var renderedTheme: TerminalTheme?

  init(model: AppModel, preferences: AppPreferences) {
    self.model = model
    self.preferences = preferences
    self.selection = Section(rawValue: preferences.inspectorSection) ?? .info
    super.init(nibName: nil, bundle: nil)
    model.agentHistoriesChanged
      .sink { [weak self] _ in
        guard let self else { return }
        self.cachedContent.removeValue(forKey: .info)
        if self.selection == .info { self.showSelectedContent() }
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
    inspectionTask?.cancel()
    filesTask?.cancel()
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
    showSelectedContent()
  }

  // MARK: - Header

  /// 页签 chip 行：未选中仅显示图标，选中项灰底并展开文字，最右侧是收起面板按钮。
  private func makeHeader() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 4
    row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    for section in Section.allCases {
      let chip = PanelTabChip(title: section.title, symbol: section.symbol) { [weak self] in
        self?.selectSection(section)
      }
      chip.identifier = NSUserInterfaceItemIdentifier(section.chipIdentifier)
      chip.isChipSelected = section == selection
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
    selection = section
    preferences.inspectorSection = section.rawValue
    for (key, chip) in chips { chip.isChipSelected = key == section }
    showSelectedContent()
    prepareSelectedSection()
  }

  private func observeActivePane() {
    guard let tab = model.selectedTab else { return }
    tab.activePaneChanged
      .sink { [weak self] _ in
        guard let self else { return }
        self.inspection = nil
        self.inspectionDirectory = nil
        self.requestedInspectionDirectory = nil
        self.inspectedAt = nil
        self.fileNodes = nil
        self.filesDirectory = nil
        self.requestedFilesDirectory = nil
        self.cachedContent.removeAll()
        self.showSelectedContent()
        self.observeOutlineChanges()
        self.prepareSelectedSection()
      }
      .store(in: &cancellables)
    tab.workingDirectoryChanged
      .sink { [weak self, weak tab] change in
        guard let self, let tab, change.paneID == tab.activePaneID else { return }
        // 保留当前快照直到新目录读取完成。清空并先绘制“正在读取目录…”会造成 Files
        // 页闪烁；异步任务自身带 Tab/Pane 校验，连续 cd 时旧结果不会覆盖新目录。
        self.cachedContent.removeValue(forKey: .info)
        // Terminal Outline 顶部也显示当前目录；命令条目可复用，但 header 必须同步。
        self.cachedContent.removeValue(forKey: .outline)
        if self.selection == .info || self.selection == .outline { self.showSelectedContent() }
        switch self.selection {
        case .info, .git:
          self.refreshInspection(directory: change.directory)
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
        .sink { [weak self] in self?.invalidateOutline() }
        .store(in: &outlineCancellables)
    } else {
      runtime.$documentText
        .removeDuplicates()
        .dropFirst()
        .sink { [weak self] _ in
          // `@Published` 在 willSet 阶段发值；延后一轮才能让解析器读取已经提交的新文本，
          // 否则每次编辑都会用旧内容重建，看起来 Outline 完全没有更新。
          DispatchQueue.main.async { [weak self] in self?.invalidateOutline() }
        }
        .store(in: &outlineCancellables)
    }
  }

  private func invalidateOutline() {
    cachedContent.removeValue(forKey: .outline)
    if selection == .outline { showSelectedContent() }
  }

  /// 只检查当前聚焦 Pane；结果回来前再次切换焦点时用 Tab/Pane ID 丢弃旧结果，避免
  /// 慢 Git 仓库把前一个目录的信息覆盖到新 Pane。
  private func refreshInspection(directory requestedDirectory: String? = nil) {
    inspectionTask?.cancel()
    guard let tab = model.selectedTab else { return }
    let tabID = tab.id
    let paneID = tab.activePaneID
    // `@Published currentWorkingDirectory` 在 willSet 阶段发出新值；目录专用事件必须把
    // 新路径直接传进来，不能此刻回读仍是旧值的 Session 属性。
    let directory = requestedDirectory ?? tab.workingDirectory
    let processIdentifier = tab.activeSession?.processIdentifier
    requestedInspectionDirectory = directory
    inspectionTask = Task { @MainActor [weak self] in
      let value = await WorkspaceInspectionService.inspect(
        directory: directory,
        shellProcessIdentifier: processIdentifier
      )
      guard !Task.isCancelled, let self, self.model.selectedTab?.id == tabID,
        self.model.selectedTab?.activePaneID == paneID,
        self.requestedInspectionDirectory == directory
      else { return }
      self.inspection = value
      self.inspectionDirectory = directory
      self.inspectedAt = Date()
      self.cachedContent.removeValue(forKey: .info)
      self.cachedContent.removeValue(forKey: .git)
      if self.selection == .info || self.selection == .git { self.showSelectedContent() }
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
      let value = await WorkspaceInspectionService.inspectFiles(directory: directory)
      guard !Task.isCancelled, let self, self.model.selectedTab?.id == tabID,
        self.model.selectedTab?.activePaneID == paneID,
        self.requestedFilesDirectory == directory
      else { return }
      self.fileNodes = value
      self.filesDirectory = directory
      self.cachedContent.removeValue(forKey: .files)
      if self.selection == .files { self.showSelectedContent() }
    }
  }

  private func prepareSelectedSection() {
    guard let directory = model.selectedTab?.workingDirectory else { return }
    switch selection {
    case .info, .git:
      if inspectionDirectory != directory { refreshInspection() }
    case .files:
      if filesDirectory != directory { refreshFiles() }
    case .outline:
      break
    }
  }

  /// 顶部页签切换只替换已缓存的根视图；数据变化时调用方先移除对应缓存，再重建一次。
  private func showSelectedContent() {
    // Git 页展示时若快照超过 30 秒则后台重取，避免分支切换后统计长期过期。
    if selection == .git, let inspectedAt, Date().timeIntervalSince(inspectedAt) > 30 {
      refreshInspection()
    }
    contentHost.removeAllSubviews()
    let content: NSView
    if let cached = cachedContent[selection] {
      content = cached
    } else {
      switch selection {
      case .outline: content = makeOutlineContent()
      case .git: content = makeGitContent()
      case .files: content = makeFilesContent()
      case .info: content = makeInformationContent()
      }
      cachedContent[selection] = content
    }
    contentHost.addSubview(content)
    content.pinEdges(to: contentHost)
  }

  // MARK: - Info

  private func makeInformationContent() -> NSView {
    let info = NSStackView()
    info.orientation = .vertical
    info.alignment = .leading
    info.spacing = 12
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
    if let inspection {
      if inspection.processes.isEmpty {
        info.addArrangedSubview(makeLabel("没有活动子进程", size: 11, color: AsterTheme.secondaryInk))
      } else {
        for process in inspection.processes.prefix(50) {
          addFullWidthRow(makeProcessRow(process), to: info)
        }
      }
      info.addArrangedSubview(makeGroupHeader("Ports"))
      if inspection.listeningPorts.isEmpty {
        info.addArrangedSubview(makeLabel("No listening ports", size: 11, color: AsterTheme.secondaryInk))
      } else {
        for port in inspection.listeningPorts.prefix(50) {
          info.addArrangedSubview(
            makeLabel("\(port.processIdentifier)  \(port.endpoint)", size: 10.5, monospaced: true))
        }
      }
    } else {
      info.addArrangedSubview(makeLabel("正在检查…", size: 11, color: AsterTheme.secondaryInk))
    }
    return makeScrollableContent(info)
  }

  /// 仅当活动 Pane 的进程树里检测到 claude 时显示；会话记录按当前目录匹配最新一条。
  private func makeClaudeCodeSection(tab: TerminalTabItem?) -> NSView? {
    let claudeRunning = inspection?.processes.contains {
      $0.command.split(separator: "/").last == "claude"
    } ?? false
    guard claudeRunning else { return nil }
    // 首次需要时触发一次磁盘扫描；结果经 model.objectWillChange 驱动整树刷新后到达。
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
    let outline = NSStackView()
    outline.orientation = .vertical
    outline.alignment = .leading
    outline.spacing = 10
    guard let tab = model.selectedTab, let runtime = tab.activeRuntime else {
      outline.addArrangedSubview(makeLabel("没有活动 Pane", size: 11, color: AsterTheme.secondaryInk))
      return makeScrollableContent(outline)
    }
    if let session = runtime.terminalSession {
      let entries = session.commandOutlineEntries()
      addFullWidthRow(
        makeOutlineHeader(directory: tab.workingDirectory, entries: entries), to: outline)
      if entries.isEmpty {
        outline.addArrangedSubview(
          makeLabel("运行命令后会在这里显示 Shell Integration 锚点。", size: 11, color: AsterTheme.secondaryInk))
      }
      for entry in entries {
        addFullWidthRow(makeOutlineEntryRow(entry, session: session), to: outline)
      }
    } else if let path = runtime.descriptor.resourcePath {
      let kind = outlineKind(for: URL(fileURLWithPath: path))
      let entries = kind.map { WorkspaceOutlineParser.parse(runtime.documentText, kind: $0) } ?? []
      outline.addArrangedSubview(makeGroupHeader("跳转到"))
      if entries.isEmpty {
        outline.addArrangedSubview(
          makeLabel("此文件没有可索引的结构。", size: 11, color: AsterTheme.secondaryInk))
      }
      for entry in entries {
        let button = ActionButton(
          title: "\(String(repeating: "  ", count: max(0, entry.level - 1)))\(entry.title)",
          bezelStyle: .inline
        ) { [weak tab] in
          tab?.revealDocumentLine(entry.line, paneID: runtime.id)
        }
        button.alignment = .left
        button.isBordered = false
        button.toolTip = "第 \(entry.line) 行"
        outline.addArrangedSubview(button)
      }
    } else {
      outline.addArrangedSubview(makeLabel("此 Pane 没有 Outline。", size: 11, color: AsterTheme.secondaryInk))
    }
    return makeScrollableContent(outline)
  }

  /// 顶部行：左侧当前目录，右侧最后一条命令的相对结束时间（照参考样式）。
  private func makeOutlineHeader(
    directory: String?, entries: [TerminalCommandOutlineEntry]
  ) -> NSView {
    let path = makeLabel(directory ?? "—", size: 10.5, color: AsterTheme.secondaryInk, monospaced: true)
    path.lineBreakMode = .byTruncatingMiddle
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let latest = entries.compactMap(\.finishedAt).max()
    let time = makeLabel(
      latest.map { RelativeTime.string(since: $0) } ?? "",
      size: 10, color: AsterTheme.tertiaryInk)
    let row = NSStackView(views: [path, spacer, time])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  private func makeOutlineEntryRow(
    _ entry: TerminalCommandOutlineEntry, session: TerminalSession
  ) -> NSView {
    let status = entry.exitStatus.map { $0 == 0 ? "✓" : "× \($0)" } ?? "·"
    let button = ActionButton(title: "\(status)  \(entry.title)", bezelStyle: .inline) {
      [weak session] in
      _ = session?.revealAbsoluteRow(entry.absoluteRow)
    }
    button.alignment = .left
    button.isBordered = false
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let time = makeLabel(
      entry.finishedAt.map { RelativeTime.string(since: $0) }
        ?? "",
      size: 10, color: AsterTheme.tertiaryInk)
    let row = NSStackView(views: [button, spacer, time])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  // MARK: - Git

  private func makeGitContent() -> NSView {
    let git = NSStackView()
    git.orientation = .vertical
    git.alignment = .leading
    git.spacing = 9
    guard let inspection else {
      git.addArrangedSubview(makeLabel("正在读取 Git 状态…", size: 11, color: AsterTheme.secondaryInk))
      return makeScrollableContent(git)
    }
    guard inspection.git.branch != nil || inspection.git.objectID != nil else {
      git.addArrangedSubview(makeLabel("当前目录不在 Git 仓库中。", size: 11, color: AsterTheme.secondaryInk))
      return makeScrollableContent(git)
    }

    addFullWidthRow(makeGitHeader(inspection.git), to: git)

    // Commit/stage 不后台执行 git（避免触发仓库 hook），只把命令预填到终端输入行，
    // 用户在 Shell 里可见地审阅并回车（typeText 不带回车）。
    let commit = ActionButton(title: "Commit", symbol: "checkmark.circle", bezelStyle: .rounded) {
      [weak self] in
      self?.model.selectedTab?.activeSession?.typeText("git commit ")
    }
    commit.toolTip = "把 git commit 放入终端输入行，确认后回车执行"
    git.addArrangedSubview(commit)

    appendGitGroup(
      to: git, title: "Staged", changes: inspection.git.stagedChanges, badgeColor: AsterTheme.accent,
      stageAll: nil)
    appendGitGroup(
      to: git, title: "Unstaged", changes: inspection.git.unstagedChanges,
      badgeColor: AsterTheme.warning,
      stageAll: { [weak self] in
        self?.model.selectedTab?.activeSession?.typeText("git add -A")
      })
    if inspection.git.changes.isEmpty {
      git.addArrangedSubview(makeLabel("工作区干净", size: 11, color: AsterTheme.secondaryInk))
    }
    return makeScrollableContent(git)
  }

  /// 顶行：粗体分支名 + 右侧 +insertions/−deletions（复用主题 accent/warning 色）。
  private func makeGitHeader(_ git: GitStatusSummary) -> NSView {
    let branch = makeLabel(git.branch ?? "detached", size: 13, weight: .bold)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [branch, spacer])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 4
    if let stat = git.diffStat {
      row.addArrangedSubview(
        makeLabel("+\(stat.insertions)", size: 11, weight: .semibold, color: AsterTheme.accent,
          monospaced: true))
      row.addArrangedSubview(
        makeLabel("−\(stat.deletions)", size: 11, weight: .semibold, color: AsterTheme.warning,
          monospaced: true))
    }
    return row
  }

  private func appendGitGroup(
    to stack: NSStackView,
    title: String,
    changes: [GitChange],
    badgeColor: NSColor,
    stageAll: (() -> Void)?
  ) {
    guard !changes.isEmpty else { return }
    let headerLabel = makeLabel(
      "\(title) (\(changes.count))", size: 10, weight: .semibold, color: AsterTheme.tertiaryInk)
    if let stageAll {
      let spacer = NSView()
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let stage = ActionButton(symbol: "plus.circle", bezelStyle: .accessoryBarAction, handler: stageAll)
      stage.isBordered = false
      stage.toolTip = "把 git add -A 放入终端输入行"
      let header = NSStackView(views: [headerLabel, spacer, stage])
      header.orientation = .horizontal
      header.alignment = .centerY
      header.spacing = 4
      addFullWidthRow(header, to: stack)
    } else {
      stack.addArrangedSubview(headerLabel)
    }
    for change in changes.prefix(200) {
      addFullWidthRow(makeGitChangeRow(change, badgeColor: badgeColor), to: stack)
    }
  }

  private func makeGitChangeRow(_ change: GitChange, badgeColor: NSColor) -> NSView {
    let badge = makeLabel(
      change.status.replacingOccurrences(of: ".", with: ""),
      size: 10, weight: .semibold, color: badgeColor, monospaced: true)
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
    let button = ActionButton(title: change.path, bezelStyle: .inline) { [weak self] in
      guard let directory = self?.model.selectedTab?.workingDirectory else { return }
      self?.model.selectedTab?.openFile(
        URL(fileURLWithPath: directory).appendingPathComponent(change.path))
      self?.model.persistWorkspace()
    }
    button.alignment = .left
    button.isBordered = false
    button.lineBreakMode = .byTruncatingMiddle
    let row = NSStackView(views: [badge, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  // MARK: - Files

  private func makeFilesContent() -> NSView {
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8

    let search = NSSearchField()
    search.placeholderString = "Find"
    search.stringValue = filesQuery
    search.delegate = self
    filesSearchField = search
    let sort = ActionButton(symbol: "arrow.up.arrow.down", bezelStyle: .accessoryBarAction) {
      [weak self] in
      guard let self else { return }
      self.filesDirectoriesFirst.toggle()
      self.rebuildFilesContent()
    }
    sort.isBordered = false
    sort.toolTip = filesDirectoriesFirst ? "目录优先（点击切换为按名称）" : "按名称（点击切换为目录优先）"
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [search, spacer, sort])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    search.translatesAutoresizingMaskIntoConstraints = false
    search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    addFullWidthRow(header, to: column)

    guard let fileNodes else {
      column.addArrangedSubview(makeLabel("正在读取目录…", size: 11, color: AsterTheme.secondaryInk))
      return makeScrollableContent(column)
    }
    if fileNodes.isEmpty {
      column.addArrangedSubview(makeLabel("目录为空或不可读取。", size: 11, color: AsterTheme.secondaryInk))
      return makeScrollableContent(column)
    }
    var tree = buildFileTree(fileNodes)
    sortFileTree(&tree)
    if !filesQuery.isEmpty { tree = filterFileTree(tree, query: filesQuery) }
    let rows = flattenFileTree(tree, honoringCollapse: filesQuery.isEmpty)
    if rows.isEmpty {
      column.addArrangedSubview(
        makeLabel("没有匹配 “\(filesQuery)” 的条目。", size: 11, color: AsterTheme.secondaryInk))
    }
    for (item, depth) in rows {
      addFullWidthRow(makeFileRow(item, depth: depth), to: column)
    }
    return makeScrollableContent(column)
  }

  /// 扁平（depth 序列）→ 树。`WorkspaceFileTree.enumerate` 按遍历顺序输出，子节点
  /// 紧跟父节点且 depth 每次最多 +1，递归归入上一层末尾节点即可。
  private struct FileTreeItem {
    let node: WorkspaceFileNode
    var children: [FileTreeItem]
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
  ) -> [(FileTreeItem, Int)] {
    items.flatMap { item -> [(FileTreeItem, Int)] in
      let collapsed = honoringCollapse && collapsedPaths.contains(item.node.path)
      return [(item, depth)] + (collapsed ? [] : flattenFileTree(item.children, honoringCollapse: honoringCollapse, depth: depth + 1))
    }
  }

  private func makeFileRow(_ item: FileTreeItem, depth: Int) -> NSView {
    let node = item.node
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(depth) * 14, bottom: 0, right: 0)
    if node.isDirectory, !node.isSymbolicLink {
      let expanded = !collapsedPaths.contains(node.path)
      let disclosure = ActionButton(
        symbol: expanded ? "chevron.down" : "chevron.right", bezelStyle: .accessoryBarAction
      ) { [weak self] in
        guard let self else { return }
        if expanded { self.collapsedPaths.insert(node.path) } else { self.collapsedPaths.remove(node.path) }
        self.rebuildFilesContent()
      }
      disclosure.isBordered = false
      disclosure.contentTintColor = AsterTheme.secondaryInk
      disclosure.translatesAutoresizingMaskIntoConstraints = false
      disclosure.widthAnchor.constraint(equalToConstant: 18).isActive = true
      row.addArrangedSubview(disclosure)
    } else {
      let indentation = NSView()
      indentation.translatesAutoresizingMaskIntoConstraints = false
      indentation.widthAnchor.constraint(equalToConstant: 18).isActive = true
      row.addArrangedSubview(indentation)
    }
    // 点击目录仍走既有的「左分屏打开文件浏览器」；折叠/展开只由 chevron 负责。
    let button = ActionButton(
      title: node.name,
      symbol: node.isSymbolicLink ? "arrow.up.forward.square" : (node.isDirectory ? "folder" : "doc"),
      bezelStyle: .inline
    ) { [weak self] in
      guard let self else { return }
      let url = URL(fileURLWithPath: node.path)
      if node.isDirectory, !node.isSymbolicLink {
        self.model.selectedTab?.split(
          direction: .left, kind: .fileBrowser, resourcePath: node.path)
      } else if node.isSymbolicLink {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } else {
        self.model.selectedTab?.openFile(url)
      }
      self.model.persistWorkspace()
    }
    button.alignment = .left
    button.isBordered = false
    button.toolTip = node.path
    button.lineBreakMode = .byTruncatingTail
    row.addArrangedSubview(button)
    return row
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
    cachedContent.removeValue(forKey: .files)
    if selection == .files { showSelectedContent() }
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

/// 面板页签 chip：未选中只显示图标，选中时灰底圆角并展开标题文字。背景色来自
/// dynamic NSColor，需要在 appearance 变化时重填 cgColor。
private final class PanelTabChip: NSButton {
  var isChipSelected = false {
    didSet { applyAppearance() }
  }

  private let fullTitle: String

  init(title: String, symbol: String, handler: @escaping () -> Void) {
    fullTitle = title
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    imagePosition = .imageLeading
    bezelStyle = .accessoryBarAction
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 6
    target = self
    action = #selector(invoke)
    self.handler = handler
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 24).isActive = true
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  private var handler: (() -> Void)?

  @objc private func invoke() { handler?() }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    title = isChipSelected ? " \(fullTitle)" : ""
    font = NSFont.systemFont(ofSize: 11, weight: isChipSelected ? .semibold : .regular)
    layer?.backgroundColor = isChipSelected
      ? AsterTheme.ink.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
  }
}

extension DetailsPanelViewController: NSSearchFieldDelegate {
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField, field === filesSearchField else { return }
    filesQuery = field.stringValue
    rebuildFilesContent()
    // Files 页重建了搜索框，把焦点与文字还原，避免每敲一个字符就丢失输入。
    if let search = filesSearchField {
      search.stringValue = filesQuery
      view.window?.makeFirstResponder(search)
    }
  }
}
