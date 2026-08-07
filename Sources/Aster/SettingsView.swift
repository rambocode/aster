import AppKit
import AsterCore
import Combine
import UniformTypeIdentifiers

/// 与 Otty 信息架构一致的九类纯 AppKit 设置页。控件直接写入 `AppPreferences`，
/// 当前终端会话通过其 Combine 订阅即时获得字体、配色、Meta 键和鼠标设置变化。
@MainActor
final class SettingsViewController: NSViewController, NSSearchFieldDelegate {
  enum Section: String, CaseIterable {
    case general = "通用"
    case shell = "Shell"
    case controls = "控制"
    case editor = "编辑器"
    case agents = "智能体"
    case appearance = "外观"
    case recipes = "Recipes"
    case shortcuts = "快捷键"
    case advanced = "高级"

    var symbol: String {
      switch self {
      case .general: "exclamationmark.circle"
      case .shell: "terminal"
      case .controls: "cursorarrow.motionlines"
      case .editor: "doc.text"
      case .agents: "sparkles"
      case .appearance: "paintpalette"
      case .recipes: "square.grid.2x2"
      case .shortcuts: "bolt"
      case .advanced: "wrench.and.screwdriver"
      }
    }
  }

  let sections = Section.allCases
  private let preferences: AppPreferences
  private var selection: Section = .general
  private var searchText = ""
  private var focusedThemeID: String?
  private var themeDraft: TerminalTheme?
  private var message: String?
  private var cancellables: Set<AnyCancellable> = []
  private var refreshScheduled = false
  private var retainedObjects: [AnyObject] = []
  private weak var sidebarSearchField: NSSearchField?

  init(preferences: AppPreferences) {
    self.preferences = preferences
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 760))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferences.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    refresh()
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.refreshScheduled = false
      self?.refresh()
    }
  }

  private func refresh() {
    retainedObjects.removeAll()
    view.removeAllSubviews()
    view.appearance = preferences.preferredAppearance
    view.wantsLayer = true
    view.layer?.backgroundColor = AsterTheme.paper.cgColor

    let root = NSStackView()
    root.orientation = .horizontal
    root.alignment = .height
    root.distribution = .fill
    root.spacing = 0
    let sidebar = makeSidebar()
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    sidebar.widthAnchor.constraint(equalToConstant: 200).isActive = true
    root.addArrangedSubview(sidebar)
    root.addArrangedSubview(makeDivider())
    root.addArrangedSubview(makeContentScroll())
    view.addSubview(root)
    root.pinEdges(to: view)
  }

  // MARK: - Shell

  private func makeSidebar() -> NSView {
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.sidebar.cgColor
    let column = NSStackView()
    column.orientation = .vertical
    // 默认 alignment 会按按钮固有宽度居中；侧栏导航必须整行拉伸，才能维持
    // Otty 的左对齐导航和完整选中背景。
    column.alignment = .width
    column.spacing = 1
    column.edgeInsets = NSEdgeInsets(top: 12, left: 7, bottom: 12, right: 7)

    let search = NSSearchField()
    search.placeholderString = "搜索"
    search.stringValue = searchText
    search.delegate = self
    sidebarSearchField = search
    search.translatesAutoresizingMaskIntoConstraints = false
    search.heightAnchor.constraint(equalToConstant: 34).isActive = true
    column.addArrangedSubview(search)
    column.setCustomSpacing(12, after: search)

    for section in filteredSections {
      let button = SettingsSidebarButton(
        section: section,
        selected: section == selection,
        action: { [weak self] in
          self?.selection = section
          self?.refresh()
        }
      )
      column.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -14).isActive = true
    }
    let spacer = NSView()
    column.addArrangedSubview(spacer)
    let version = makeLabel("Aster 0.4.1", size: 9, color: AsterTheme.tertiaryInk, monospaced: true)
    version.alignment = .center
    column.addArrangedSubview(version)

    host.addSubview(column)
    column.pinEdges(to: host)
    return host
  }

  private var filteredSections: [Section] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? sections : sections.filter {
      $0.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    guard let field = obj.object as? NSSearchField else { return }
    searchText = field.stringValue
    refresh()
    DispatchQueue.main.async { [weak self] in
      guard let search = self?.sidebarSearchField else { return }
      search.window?.makeFirstResponder(search)
      search.currentEditor()?.selectedRange = NSRange(location: search.stringValue.utf16.count, length: 0)
    }
  }

  private func makeContentScroll() -> NSView {
    let scroll = NSScrollView()
    scroll.drawsBackground = true
    scroll.backgroundColor = AsterTheme.paper
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    // 右侧滚动区承担窗口横向伸缩；降低固有宽度优先级，避免根 Stack 仅按
    // 文档内容的最小宽度布局，从而在右侧留下大块空白。
    scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // 只翻转滚动文档，不翻转 StackView 本身。直接翻转 StackView 会把第一项排到
    // 文档底部，短页面仍会出现顶部大空白。
    let document = FlippedDocumentView()
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .width
    content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 30, right: 26)
    content.addArrangedSubview(makeLabel(selection.rawValue, size: 13, weight: .semibold, color: AsterTheme.secondaryInk))
    for item in sectionViews() {
      content.addArrangedSubview(item)
    }
    if let message {
      content.addArrangedSubview(makeLabel("✓  \(message)", size: 10.5, color: AsterTheme.accent))
    }
    document.addSubview(content)
    scroll.documentView = document
    content.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      content.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor),
    ])
    return scroll
  }

  private func sectionViews() -> [NSView] {
    switch selection {
    case .general: generalViews()
    case .shell: shellViews()
    case .controls: controlViews()
    case .editor: editorViews()
    case .agents: agentViews()
    case .appearance: appearanceViews()
    case .recipes: recipeViews()
    case .shortcuts: shortcutViews()
    case .advanced: advancedViews()
    }
  }

  // MARK: - Basic sections

  private func generalViews() -> [NSView] {
    [card([
      infoRow("语言", "界面显示语言", "简体中文"),
      infoRow("窗口行为", "关闭窗口后保留应用进程", "标准 macOS"),
      infoRow("关闭确认", "未保存内容会询问保存、放弃或取消", "已启用"),
    ])]
  }

  private func shellViews() -> [NSView] {
    [
      card([
        infoRow("登录 Shell", ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "系统默认"),
        textRow("终端类型", "传递给 TUI 程序的 TERM", value: preferences.configuration.appearance.terminalIdentity) { [weak self] value in
          self?.preferences.configuration.appearance.terminalIdentity = value
        },
      ]),
      card([
        infoRow("目录与标题", "通过终端 OSC 标记跟踪当前目录和标题", "已启用"),
        infoRow("SSH", "可直接在终端运行系统 ssh，尚无独立远程配置界面", "终端内"),
        infoRow("工作区恢复", "恢复标签、目录和 Pane，并启动新的 Shell", "已启用"),
      ]),
    ]
  }

  private func controlViews() -> [NSView] {
    [card([
      toggleRow("Option 作为 Meta", "发送 Esc 前缀，兼容 Emacs 和 Shell 快捷键", value: preferences.configuration.controls.optionAsMeta) { [weak self] value in
        self?.preferences.configuration.controls.optionAsMeta = value
      },
      toggleRow("允许鼠标报告", "供 vim、tmux、htop 等 TUI 使用", value: preferences.configuration.controls.allowMouseReporting) { [weak self] value in
        self?.preferences.configuration.controls.allowMouseReporting = value
      },
      infoRow("复制与粘贴", "使用系统 ⌘C / ⌘V，多行输入由目标 Shell 处理", "系统行为"),
      infoRow("链接", "识别 OSC 8 与文本 URL，按修饰键打开", "已启用"),
    ])]
  }

  private func editorViews() -> [NSView] {
    [card([
      infoRow("文本编辑", "UTF-8、自动换行、未保存标记与原子保存", "已启用"),
      infoRow("文档预览", "从文件浏览器双击在相邻 Pane 打开", "已启用"),
      infoRow("高级编辑选项", "行号、Vim 键位和可见空白尚未开放", "0.3 未开放"),
    ])]
  }

  private func agentViews() -> [NSView] {
    let commands = [("Codex", "codex"), ("Claude Code", "claude"), ("Kimi", "kimi")]
    let rows = commands.map { name, command in
      infoRow(
        name,
        command,
        executableExists(command) ? "已安装" : "未检测到"
      )
    }
    return [card(rows), card([infoRow("运行方式", "在终端中启动已检测到的 CLI", "终端内")])]
  }

  private func recipeViews() -> [NSView] {
    [
      card([infoRow("命令重放", "当前只恢复布局，不自动执行外部 Recipe 命令", "安全关闭")]),
      card([
        infoRow("Recipe 包含", "标签页、分屏方向、目录、文件和可选命令", ".asterrecipe"),
        infoRow("安全边界", "不会保存 PID、文件描述符、令牌或临时焦点", "可移植"),
      ]),
    ]
  }

  private func shortcutViews() -> [NSView] {
    [card([
      infoRow("新建标签页", "", "⌘ T"),
      infoRow("打开文件", "", "⌘ O"),
      infoRow("关闭标签页", "", "⌘ W"),
      infoRow("向右分屏", "", "⌘ D"),
      infoRow("向下分屏", "", "⇧ ⌘ D"),
      infoRow("关闭面板", "", "⌥ ⌘ W"),
      infoRow("命令面板", "", "⌘ K"),
      infoRow("设置", "", "⌘ ,"),
    ])]
  }

  private func advancedViews() -> [NSView] {
    [
      card([
        infoRow("终端内核", "VT100 / xterm、真彩色、鼠标、超链接与本地 PTY", "SwiftTerm"),
        infoRow("会话恢复", "保存可重建的标签与分屏结构", "已启用"),
        infoRow("界面框架", "主窗口、设置和所有控件均为原生视图", "AppKit"),
      ]),
      card([
        actionRow("导出配置", "保存为可备份的 JSON 文件", title: "导出") { [weak self] in self?.exportConfiguration() },
        actionRow("导入配置", "从 JSON 文件替换当前设置", title: "导入") { [weak self] in self?.importConfiguration() },
        actionRow("恢复默认设置", "不会删除 Recipe 和工作区文件", title: "重置") { [weak self] in self?.preferences.reset() },
      ]),
    ]
  }

  // MARK: - Appearance

  private func appearanceViews() -> [NSView] {
    var views: [NSView] = []
    views.append(sectionTitle("布局"))
    views.append(makeLayoutChoices())
    views.append(sectionTitle("标签栏"))
    views.append(card([
      popupRow(
        "新标签页位置", "新标签自动追加到当前标签之后",
        items: ["自动"], selected: 0
      ) { _ in },
      popupRow(
        "自动隐藏标签面板", "控制侧边栏布局下，标签面板的显示方式",
        items: ["默认", "仅单标签时隐藏"],
        selected: preferences.configuration.appearance.autoHideTabs ? 1 : 0
      ) { [weak self] index in
        self?.preferences.configuration.appearance.autoHideTabs = index == 1
      },
    ]))
    views.append(sectionTitle("窗口"))
    views.append(card([
      popupRow(
        "窗口大小", "新窗口如何决定初始尺寸",
        items: ["记住上次尺寸", "恢复默认尺寸"], selected: 0
      ) { [weak self] index in
        guard index == 1, let self else { return }
        self.preferences.configuration.appearance.windowWidth = 1180
        self.preferences.configuration.appearance.windowHeight = 760
        (NSApp.delegate as? AsterAppDelegate)?.applyDefaultMainWindowSize()
      },
      popupRow(
        "窗口主题", "跟随系统、始终浅色或始终深色",
        items: AppPreferences.Appearance.allCases.map(\.label),
        selected: AppPreferences.Appearance.allCases.firstIndex(of: preferences.appearance) ?? 0
      ) { [weak self] index in
        self?.preferences.appearance = AppPreferences.Appearance.allCases[index]
      },
      sliderRow("垂直侧栏宽度", "", value: preferences.sidebarWidth, range: 180...360, suffix: "pt") { [weak self] value in
        self?.preferences.sidebarWidth = value
      },
      toggleRow("显示状态栏", "显示目录、编码和 Pane 数量", value: preferences.showStatusBar) { [weak self] value in
        self?.preferences.showStatusBar = value
      },
    ]))

    views.append(sectionTitle("主题"))
    views.append(makeThemeGrid(mode: .light))
    views.append(toggleRow(
      "深色模式使用独立主题",
      "跟随系统配色时，浅色与深色模式分别使用两套主题",
      value: preferences.configuration.appearance.useSeparateDarkTheme
    ) { [weak self] value in
      self?.preferences.configuration.appearance.useSeparateDarkTheme = value
    })
    if preferences.configuration.appearance.useSeparateDarkTheme {
      views.append(makeThemeGrid(mode: .dark))
    }

    views.append(sectionTitle("详情"))
    views.append(ThemeDetailView(theme: focusedTheme))
    let actions = NSStackView(views: [
      ActionButton(title: "复制") { [weak self] in self?.duplicateTheme() },
      ActionButton(title: "编辑当前主题") { [weak self] in self?.beginEditingTheme() },
      ActionButton(title: "打开主题文件夹") { [weak self] in self?.openThemesFolder() },
      ActionButton(title: "导入主题…") { [weak self] in self?.importTheme() },
    ])
    actions.orientation = .horizontal
    actions.spacing = 10
    views.append(actions)
    if let themeDraft { views.append(makeThemeEditor(themeDraft)) }

    views.append(sectionTitle("文本"))
    views.append(card([
      stepperRow("字号", "终端字号", value: preferences.fontSize, range: 9...32) { [weak self] value in
        self?.preferences.fontSize = value
      },
      textRow("字体", "终端的基础等宽字体", value: preferences.configuration.appearance.fontFamily) { [weak self] value in
        self?.preferences.configuration.appearance.fontFamily = value
      },
      infoRow("粗体与斜体", "由基础字体自动匹配可用字重和斜体字形", "自动匹配"),
      actionRow("字体管理", "使用系统字体面板或打开用户字体目录", title: "安装字体") {
        NSFontManager.shared.orderFrontFontPanel(nil)
      },
    ]))

    views.append(sectionTitle("光标"))
    views.append(card([
      ThemeCursorPreviewView(theme: focusedTheme),
      popupRow(
        "光标样式", "终端程序仍可通过 DECSCUSR 临时覆盖",
        items: ["方块", "竖线", "下划线", "空心方块"],
        selected: CursorStyle.allCasesIndex(of: preferences.configuration.appearance.cursorStyle)
      ) { [weak self] index in
        let values: [CursorStyle] = [.block, .bar, .underline, .hollowBlock]
        self?.preferences.configuration.appearance.cursorStyle = values[index]
      },
      toggleRow("光标闪烁", "实时同步到已打开的终端", value: preferences.configuration.appearance.cursorBlink) { [weak self] value in
        self?.preferences.configuration.appearance.cursorBlink = value
      },
    ]))
    return views
  }

  private func makeLayoutChoices() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 18
    for layout in TabBarLayout.allCases {
      let card = LayoutChoiceButton(layout: layout, selected: preferences.tabBarLayout == layout) { [weak self] in
        self?.preferences.tabBarLayout = layout
      }
      row.addArrangedSubview(card)
    }
    return row
  }

  private func makeThemeGrid(mode: TerminalThemeMode) -> NSView {
    let themes = preferences.themes(for: mode)
    let selectedName = mode == .light
      ? preferences.configuration.appearance.themeName
      : preferences.configuration.appearance.darkThemeName
    let rows = stride(from: 0, to: themes.count, by: 4).map { start -> [NSView] in
      var cells: [NSView] = themes[start..<min(start + 4, themes.count)].map { theme in
        ThemeCardButton(theme: theme, selected: theme.name == selectedName) { [weak self] in
          self?.focusedThemeID = theme.id
          self?.preferences.selectTheme(theme)
        }
      }
      while cells.count < 4 { cells.append(NSView()) }
      return cells
    }
    let grid = NSGridView(views: rows)
    grid.columnSpacing = 14
    grid.rowSpacing = 16
    grid.xPlacement = .fill
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.sidebar.withAlphaComponent(0.52).cgColor
    host.layer?.cornerRadius = 12
    host.addSubview(grid)
    grid.pinEdges(to: host, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
    return host
  }

  private var allThemes: [TerminalTheme] {
    TerminalThemeCatalog.builtIns + preferences.themeLibrary.customThemes
  }

  private var focusedTheme: TerminalTheme {
    allThemes.first(where: { $0.id == focusedThemeID }) ?? preferences.activeTheme
  }

  private func duplicateTheme() {
    let copy = preferences.duplicateTheme(focusedTheme)
    focusedThemeID = copy.id
    do {
      _ = try preferences.saveThemeToLibraryFolder(copy)
      message = "已复制并保存主题“\(copy.name)”"
    } catch { message = "主题已复制，但文件保存失败：\(error.localizedDescription)" }
    refresh()
  }

  private func beginEditingTheme() {
    let editable = focusedTheme.isBuiltIn ? preferences.duplicateTheme(focusedTheme) : focusedTheme
    focusedThemeID = editable.id
    themeDraft = editable
    refresh()
  }

  private func makeThemeEditor(_ draft: TerminalTheme) -> NSView {
    let name = ClosureTextField(value: draft.name) { [weak self] value in
      self?.themeDraft?.name = value
    }
    let nameRow = rowShell("主题名称", "自定义主题的显示名称", accessory: name)
    let modeRow = popupRow(
      "配色模式",
      "决定主题出现在浅色或深色主题列表",
      items: ["浅色", "深色"],
      selected: draft.mode == .light ? 0 : 1
    ) { [weak self] index in
      self?.themeDraft?.mode = index == 0 ? .light : .dark
    }
    let colors: [(String, WritableKeyPath<TerminalThemePalette, HexColor>)] = [
      ("终端背景", \.windowBackground),
      ("容器背景", \.containerBackground),
      ("面板背景", \.panelBackground),
      ("终端文字", \.foreground),
      ("次要文字", \.secondaryForeground),
      ("强调色", \.accent),
      ("光标", \.cursor),
      ("选区", \.selection),
    ]
    var rows: [NSView] = [nameRow, modeRow]
    let windowColor = draft.palette.interfaceWindowBackground ?? draft.palette.panelBackground
    let windowWell = ClosureColorWell(color: NSColor(windowColor)) { [weak self] color in
      guard var current = self?.themeDraft else { return }
      current.palette.interfaceWindowBackground = HexColor(nsColor: color)
      self?.themeDraft = current
    }
    rows.append(rowShell("界面窗口", "终端网格之外的窗口底色", accessory: windowWell))
    for (title, keyPath) in colors {
      let well = ClosureColorWell(color: NSColor(draft.palette[keyPath: keyPath])) { [weak self] color in
        guard var current = self?.themeDraft else { return }
        current.palette[keyPath: keyPath] = HexColor(nsColor: color)
        self?.themeDraft = current
      }
      rows.append(rowShell(title, "", accessory: well))
    }
    rows.append(rowShell(
      "ANSI 16 色",
      "上排标准色，下排高亮色",
      accessory: makeANSIColorEditor(draft.palette.ansiColors)
    ))
    let buttons = NSStackView(views: [
      ActionButton(title: "保存") { [weak self] in self?.saveThemeDraft() },
      ActionButton(title: "取消") { [weak self] in self?.themeDraft = nil; self?.refresh() },
    ])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    rows.append(buttons)
    return card(rows)
  }

  /// ANSI 色表按 0…7 与 8…15 两排显示；每个色块原位写回草稿，保存前仍由领域层校验完整性。
  private func makeANSIColorEditor(_ colors: [HexColor]) -> NSView {
    let gridColors = Array(colors.prefix(16))
    let rows = stride(from: 0, to: gridColors.count, by: 8).map { start in
      gridColors[start..<min(start + 8, gridColors.count)].enumerated().map { offset, color -> NSView in
        let index = start + offset
        return ClosureColorWell(color: NSColor(color), size: NSSize(width: 30, height: 24)) { [weak self] value in
          guard var current = self?.themeDraft,
                current.palette.ansiColors.indices.contains(index) else { return }
          current.palette.ansiColors[index] = HexColor(nsColor: value)
          self?.themeDraft = current
        }
      }
    }
    let grid = NSGridView(views: rows)
    grid.columnSpacing = 5
    grid.rowSpacing = 5
    return grid
  }

  private func saveThemeDraft() {
    guard let draft = themeDraft else { return }
    do {
      try TerminalThemeStore.validate(draft)
      guard preferences.updateTheme(draft) else {
        message = "主题名称与现有主题重复，请换一个名称"
        refresh()
        return
      }
      _ = try preferences.saveThemeToLibraryFolder(draft)
      focusedThemeID = draft.id
      themeDraft = nil
      message = "主题“\(draft.name)”已保存"
    } catch { message = "主题保存失败：\(error.localizedDescription)" }
    refresh()
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if let type = UTType(filenameExtension: "astertheme") { panel.allowedContentTypes = [type] }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let theme = try preferences.importTheme(from: url)
      focusedThemeID = theme.id
      _ = try preferences.saveThemeToLibraryFolder(theme)
      message = "已导入主题“\(theme.name)”"
    } catch { message = "主题导入失败：\(error.localizedDescription)" }
    refresh()
  }

  private func openThemesFolder() {
    do { NSWorkspace.shared.open(try preferences.themesDirectory()) }
    catch { message = "无法打开主题文件夹：\(error.localizedDescription)"; refresh() }
  }

  // MARK: - Rows and cards

  private func card(_ rows: [NSView]) -> NSView {
    let card = NSStackView()
    card.orientation = .vertical
    card.spacing = 0
    card.wantsLayer = true
    card.layer?.backgroundColor = AsterTheme.panel.cgColor
    card.layer?.cornerRadius = 10
    for (index, row) in rows.enumerated() {
      if index > 0 { card.addArrangedSubview(makeHorizontalDivider()) }
      card.addArrangedSubview(row)
    }
    return card
  }

  private func rowShell(_ title: String, _ detail: String, accessory: NSView) -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(greaterThanOrEqualToConstant: detail.isEmpty ? 54 : 72).isActive = true
    let labels = NSStackView(views: [
      makeLabel(title, size: 12.5, weight: .medium),
      makeLabel(detail, size: 10.5, color: AsterTheme.secondaryInk),
    ])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 4
    accessory.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [labels, NSView(), accessory])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.edgeInsets = NSEdgeInsets(top: 12, left: 15, bottom: 12, right: 15)
    host.addSubview(row)
    row.pinEdges(to: host)
    return host
  }

  private func infoRow(_ title: String, _ detail: String, _ value: String) -> NSView {
    rowShell(title, detail, accessory: makeLabel(value, size: 11, color: AsterTheme.secondaryInk))
  }

  private func toggleRow(_ title: String, _ detail: String, value: Bool, action: @escaping (Bool) -> Void) -> NSView {
    rowShell(title, detail, accessory: ClosureSwitch(value: value, action: action))
  }

  private func textRow(_ title: String, _ detail: String, value: String, action: @escaping (String) -> Void) -> NSView {
    let field = ClosureTextField(value: value, action: action)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 210).isActive = true
    return rowShell(title, detail, accessory: field)
  }

  private func popupRow(_ title: String, _ detail: String, items: [String], selected: Int, action: @escaping (Int) -> Void) -> NSView {
    rowShell(title, detail, accessory: ClosurePopUpButton(items: items, selected: selected, action: action))
  }

  private func sliderRow(_ title: String, _ detail: String, value: Double, range: ClosedRange<Double>, suffix: String, action: @escaping (Double) -> Void) -> NSView {
    let slider = ClosureSlider(value: value, range: range, action: action)
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
    let valueLabel = makeLabel("\(Int(value)) \(suffix)", size: 10.5, color: AsterTheme.secondaryInk)
    let stack = NSStackView(views: [slider, valueLabel])
    stack.orientation = .horizontal
    stack.spacing = 8
    return rowShell(title, detail, accessory: stack)
  }

  private func stepperRow(_ title: String, _ detail: String, value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) -> NSView {
    rowShell(title, detail, accessory: ClosureStepper(value: value, range: range, action: action))
  }

  private func actionRow(_ title: String, _ detail: String, title buttonTitle: String, action: @escaping () -> Void) -> NSView {
    rowShell(title, detail, accessory: ActionButton(title: buttonTitle, handler: action))
  }

  private func sectionTitle(_ title: String) -> NSView {
    makeLabel(title, size: 12.5, weight: .semibold, color: AsterTheme.tertiaryInk)
  }

  private func makeDivider() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = AsterTheme.hairline.cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 1).isActive = true
    return view
  }

  private func makeHorizontalDivider() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = AsterTheme.hairline.cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return view
  }

  private func executableExists(_ command: String) -> Bool {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    return paths.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(command)") }
  }

  private func exportConfiguration() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Aster Settings.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(preferences.configuration).write(to: url, options: .atomic)
      message = "配置已导出"
    } catch { message = "导出失败：\(error.localizedDescription)" }
    refresh()
  }

  private func importConfiguration() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let decoded = try JSONDecoder().decode(AsterConfiguration.self, from: Data(contentsOf: url))
      preferences.importConfiguration(decoded)
      message = "配置已导入"
    } catch { message = "导入失败：\(error.localizedDescription)" }
    refresh()
  }
}

// MARK: - Native setting controls

@MainActor
private final class SettingsSidebarButton: NSButton {
  private let handler: () -> Void

  init(section: SettingsViewController.Section, selected: Bool, action: @escaping () -> Void) {
    handler = action
    super.init(frame: .zero)
    title = section.rawValue
    image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.rawValue)
    imagePosition = .imageLeading
    alignment = .left
    isBordered = false
    font = NSFont.systemFont(ofSize: 12.5)
    contentTintColor = selected ? AsterTheme.ink : AsterTheme.secondaryInk
    wantsLayer = true
    layer?.backgroundColor = selected ? AsterTheme.ink.withAlphaComponent(0.065).cgColor : NSColor.clear.cgColor
    layer?.cornerRadius = 6
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 35).isActive = true
  }

  required init?(coder: NSCoder) { nil }
  @objc private func invoke() { handler() }
}

@MainActor
private final class ClosureSwitch: NSSwitch {
  private let handler: (Bool) -> Void
  init(value: Bool, action: @escaping (Bool) -> Void) {
    handler = action
    super.init(frame: .zero)
    state = value ? .on : .off
    target = self
    self.action = #selector(changed)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(state == .on) }
}

@MainActor
private final class ClosurePopUpButton: NSPopUpButton {
  private let handler: (Int) -> Void
  init(items: [String], selected: Int, action: @escaping (Int) -> Void) {
    handler = action
    super.init(frame: .zero, pullsDown: false)
    addItems(withTitles: items)
    selectItem(at: min(max(selected, 0), max(items.count - 1, 0)))
    target = self
    self.action = #selector(changed)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(indexOfSelectedItem) }
}

@MainActor
private final class ClosureSlider: NSSlider {
  private let handler: (Double) -> Void
  init(value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) {
    handler = action
    // Swift 6.2 release 优化器会把 NSSlider 的 Objective-C 便捷初始化器与子类闭包
    // 属性组合误判为 owned value 泄漏。使用指定 frame 初始化器后逐项赋值，运行语义
    // 相同，同时避开编译器 ownership 崩溃。
    super.init(frame: .zero)
    minValue = range.lowerBound
    maxValue = range.upperBound
    doubleValue = value
    target = self
    self.action = #selector(changed)
    isContinuous = false
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(doubleValue) }
}

@MainActor
private final class ClosureTextField: NSTextField, NSTextFieldDelegate {
  private let handler: (String) -> Void
  init(value: String, action: @escaping (String) -> Void) {
    handler = action
    super.init(frame: .zero)
    stringValue = value
    delegate = self
  }
  required init?(coder: NSCoder) { nil }
  func controlTextDidEndEditing(_ obj: Notification) { handler(stringValue) }
}

@MainActor
private final class ClosureStepper: NSView {
  private let label = NSTextField(labelWithString: "")
  private var value: Double
  private let handler: (Double) -> Void

  init(value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) {
    self.value = value
    handler = action
    super.init(frame: .zero)
    let stepper = NSStepper()
    stepper.minValue = range.lowerBound
    stepper.maxValue = range.upperBound
    stepper.doubleValue = value
    stepper.target = self
    stepper.action = #selector(changed(_:))
    label.stringValue = "\(Int(value))"
    label.font = NSFont.systemFont(ofSize: 14)
    let stack = NSStackView(views: [label, stepper])
    stack.orientation = .horizontal
    stack.spacing = 8
    addSubview(stack)
    stack.pinEdges(to: self)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed(_ sender: NSStepper) {
    value = sender.doubleValue
    label.stringValue = "\(Int(value))"
    handler(value)
  }
}

@MainActor
private final class ClosureColorWell: NSColorWell {
  private let handler: (NSColor) -> Void
  init(color: NSColor, size: NSSize = NSSize(width: 52, height: 28), action: @escaping (NSColor) -> Void) {
    handler = action
    super.init(frame: NSRect(origin: .zero, size: size))
    self.color = color
    target = self
    self.action = #selector(changed)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size.width),
      heightAnchor.constraint(equalToConstant: size.height),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(color) }
}

@MainActor
private final class LayoutChoiceButton: NSButton {
  private let handler: () -> Void
  init(layout: TabBarLayout, selected: Bool, action: @escaping () -> Void) {
    handler = action
    super.init(frame: .zero)
    let data: (String, String) = switch layout {
    case .vertical: ("sidebar.left", "垂直标签栏")
    case .top: ("rectangle.topthird.inset.filled", "顶部标签栏")
    case .bottom: ("rectangle.bottomthird.inset.filled", "底部标签栏")
    }
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.panel.cgColor
    layer?.cornerRadius = 12
    layer?.borderWidth = selected ? 2 : 1
    layer?.borderColor = (selected ? NSColor.controlAccentColor : AsterTheme.hairline).cgColor
    let image = NSImageView(
      image: NSImage(systemSymbolName: data.0, accessibilityDescription: data.1) ?? NSImage()
    )
    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)
    image.contentTintColor = AsterTheme.secondaryInk
    let label = makeLabel(data.1, size: 12, color: AsterTheme.secondaryInk)
    label.alignment = .center
    let stack = NSStackView(views: [image, label])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .centerX
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 148),
      heightAnchor.constraint(equalToConstant: 112),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func invoke() { handler() }
}

@MainActor
private final class ThemeCardButton: NSButton {
  private let handler: () -> Void
  init(theme: TerminalTheme, selected: Bool, action: @escaping () -> Void) {
    handler = action
    super.init(frame: .zero)
    title = ""
    setAccessibilityLabel(theme.name)
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderWidth = selected ? 2 : 0
    layer?.borderColor = NSColor.controlAccentColor.cgColor
    let preview = ThemeMiniPreviewView(theme: theme)
    let label = makeLabel(theme.name, size: 11.5, color: AsterTheme.secondaryInk)
    label.alignment = .center
    let stack = NSStackView(views: [preview, label])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    addSubview(stack)
    stack.pinEdges(to: self)
    preview.translatesAutoresizingMaskIntoConstraints = false
    preview.heightAnchor.constraint(equalToConstant: 76).isActive = true
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 150),
      heightAnchor.constraint(equalToConstant: 118),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func invoke() { handler() }
}

/// 主题卡片直接按 Otty 的 sidebar/tab/container token 绘制，不使用统一模板近似。
@MainActor
private final class ThemeMiniPreviewView: NSView {
  private let theme: TerminalTheme
  init(theme: TerminalTheme) { self.theme = theme; super.init(frame: .zero); wantsLayer = true }
  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
    let clip = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
    clip.addClip()
    NSColor(theme.palette.interfaceWindowBackground ?? theme.palette.panelBackground).setFill()
    bounds.fill()

    let sidebarRect = NSRect(x: bounds.minX, y: bounds.minY, width: 29, height: bounds.height)
    NSColor(theme.style.sidebarBackground ?? theme.palette.panelBackground).setFill()
    sidebarRect.fill()
    let tabColor = NSColor(theme.style.tab.foreground ?? theme.palette.secondaryForeground)
    let active = NSColor(theme.style.tab.activeBackground ?? theme.palette.panelSurface ?? theme.palette.panelBackground)
    for index in 0..<3 {
      let y = bounds.maxY - 15 - CGFloat(index * 10)
      if index == 1 {
        active.setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: y - 3, width: 19, height: 9), xRadius: theme.style.tab.radius * 0.35, yRadius: theme.style.tab.radius * 0.35).fill()
      }
      tabColor.withAlphaComponent(index == 1 ? 0.82 : 0.48).setFill()
      NSBezierPath(roundedRect: NSRect(x: 7, y: y, width: index == 1 ? 13 : 10, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }

    let margin = theme.style.container.margin
    let containerRect = NSRect(
      x: 29 + margin.leading * 0.25,
      y: margin.bottom * 0.25,
      width: bounds.width - 29 - (margin.leading + margin.trailing) * 0.25,
      height: bounds.height - (margin.top + margin.bottom) * 0.25
    )
    NSColor(theme.style.container.background ?? theme.palette.renderedTerminalBackground).setFill()
    NSBezierPath(
      roundedRect: containerRect,
      xRadius: min(theme.style.container.radius * 0.45, 8),
      yRadius: min(theme.style.container.radius * 0.45, 8)
    ).fill()
    NSColor(theme.palette.accent).setFill()
    NSBezierPath(ovalIn: NSRect(x: containerRect.minX + 9, y: containerRect.midY - 3, width: 6, height: 6)).fill()
    let foreground = NSColor(theme.palette.foreground)
    let secondary = NSColor(theme.palette.secondaryForeground)
    drawLine(x: containerRect.minX + 22, y: containerRect.midY + 1, width: 30, color: foreground.withAlphaComponent(0.78))
    drawLine(x: containerRect.minX + 22, y: containerRect.midY - 5, width: 48, color: secondary.withAlphaComponent(0.58))
    drawLine(x: containerRect.minX + 22, y: containerRect.midY - 11, width: 34, color: secondary.withAlphaComponent(0.35))
  }

  private func drawLine(x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
  }
}

@MainActor
private final class ThemeDetailView: NSView {
  init(theme: TerminalTheme) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = AsterTheme.panel.cgColor
    layer?.cornerRadius = 12
    let title = makeLabel(theme.name, size: 14, weight: .semibold)
    let sample = TerminalSampleView(theme: theme)
    sample.translatesAutoresizingMaskIntoConstraints = false
    sample.heightAnchor.constraint(equalToConstant: 164).isActive = true
    let mode = makeLabel(theme.mode == .dark ? "深色" : "浅色", size: 10, color: AsterTheme.secondaryInk)
    let header = NSStackView(views: [title, NSView(), mode])
    header.orientation = .horizontal
    let roleSwatches = NSStackView(views: [
      ThemeRoleSwatch(title: "Window", color: theme.palette.interfaceWindowBackground ?? theme.palette.panelBackground),
      ThemeRoleSwatch(title: "Container", color: theme.palette.containerBackground),
      ThemeRoleSwatch(title: "Panel", color: theme.palette.panelBackground),
    ])
    roleSwatches.orientation = .horizontal
    roleSwatches.spacing = 12
    roleSwatches.distribution = .fillEqually
    let ansi = ANSIColorStrip(colors: theme.palette.ansiColors)
    let stack = NSStackView(views: [header, sample, roleSwatches, ansi])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    addSubview(stack)
    stack.pinEdges(to: self)
  }
  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class ThemeRoleSwatch: NSView {
  init(title: String, color: HexColor) {
    super.init(frame: .zero)
    let swatch = NSView()
    swatch.wantsLayer = true
    swatch.layer?.backgroundColor = NSColor(color).cgColor
    swatch.layer?.cornerRadius = 5
    swatch.layer?.borderWidth = 1
    swatch.layer?.borderColor = AsterTheme.hairline.cgColor
    swatch.translatesAutoresizingMaskIntoConstraints = false
    swatch.heightAnchor.constraint(equalToConstant: 28).isActive = true
    let label = makeLabel(title, size: 9.5, color: AsterTheme.secondaryInk)
    let stack = NSStackView(views: [swatch, label])
    stack.orientation = .vertical
    stack.spacing = 5
    addSubview(stack)
    stack.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }
}

/// 详情区只读展示完整 ANSI 色表，便于与 Otty 主题文件逐色核对。
@MainActor
private final class ANSIColorStrip: NSView {
  init(colors: [HexColor]) {
    super.init(frame: .zero)
    let cells = colors.prefix(16).map { color -> NSView in
      let cell = NSView()
      cell.wantsLayer = true
      cell.layer?.backgroundColor = NSColor(color).cgColor
      cell.layer?.cornerRadius = 9
      cell.layer?.borderWidth = 0.5
      cell.layer?.borderColor = AsterTheme.hairline.cgColor
      cell.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        cell.widthAnchor.constraint(equalToConstant: 18),
        cell.heightAnchor.constraint(equalToConstant: 18),
      ])
      return cell
    }
    let row = NSStackView(views: cells)
    row.orientation = .horizontal
    row.spacing = 7
    row.alignment = .centerY
    addSubview(row)
    row.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class TerminalSampleView: NSView {
  private let theme: TerminalTheme
  init(theme: TerminalTheme) { self.theme = theme; super.init(frame: .zero); wantsLayer = true }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor(theme.palette.renderedTerminalBackground).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let lines = [
      "otty@macbook:~  $ eza -la --icons --git",
      "Permissions   Size  User   Date Modified   Name",
      "drwxr-xr-x    12k  otty   22 Aug 13:42   build.sh",
      "-rw-r--r--   4.2k  otty   18 Jul 14:22   main.rs",
    ]
    for (index, line) in lines.enumerated() {
      line.draw(
        at: NSPoint(x: 13, y: bounds.maxY - 26 - CGFloat(index * 25)),
        withAttributes: [.font: font, .foregroundColor: NSColor(theme.palette.foreground)]
      )
    }
  }
}

@MainActor
private final class ThemeCursorPreviewView: NSView {
  init(theme: TerminalTheme) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor(theme.palette.renderedTerminalBackground).cgColor
    layer?.cornerRadius = 8
    let text = makeLabel("abner@makbook$ git commit -am \"▮", size: 12.5, color: NSColor(theme.palette.foreground), monospaced: true)
    addSubview(text)
    text.pinEdges(to: self, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 58).isActive = true
  }
  required init?(coder: NSCoder) { nil }
}

private extension HexColor {
  init(nsColor: NSColor) {
    let value = nsColor.usingColorSpace(.sRGB) ?? nsColor
    self.init(
      red: UInt8(min(max(value.redComponent, 0), 1) * 255),
      green: UInt8(min(max(value.greenComponent, 0), 1) * 255),
      blue: UInt8(min(max(value.blueComponent, 0), 1) * 255),
      alpha: UInt8(min(max(value.alphaComponent, 0), 1) * 255)
    )
  }
}

private extension CursorStyle {
  static func allCasesIndex(of value: CursorStyle) -> Int {
    let values: [CursorStyle] = [.block, .bar, .underline, .hollowBlock]
    return values.firstIndex(of: value) ?? 0
  }
}
