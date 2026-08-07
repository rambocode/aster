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
  // 滚动位置保持：全量重建会丢掉 NSScrollView 状态，这里按分类分桶记录偏移。
  private weak var contentScrollView: NSScrollView?
  private var scrollOffsets: [Section: CGPoint] = [:]
  private var renderedSection: Section?

  init(preferences: AppPreferences) {
    self.preferences = preferences
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 460))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferences.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    refresh()
  }

  /// 切换到指定分类并立即重建内容区；供布局测试与未来的深链入口使用。
  func showSection(_ section: Section) {
    selection = section
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

  /// 全量重建整个设置页视图树；重建前后按分类保存/恢复滚动位置，避免开关一次就跳回顶部。
  private func refresh() {
    // 记录的是「当前树实际渲染的分类」而不是 selection：侧栏切换时 selection 已指向
    // 新分类，用它做 key 会把旧页的偏移写错桶。
    if let scroll = contentScrollView, let rendered = renderedSection {
      scrollOffsets[rendered] = scroll.contentView.bounds.origin
    }
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
    root.addArrangedSubview(makeContentScroll())
    view.addSubview(root)
    root.pinEdges(to: view)
    renderedSection = selection

    // 必须先布局再恢复偏移：此时文档高度还是 0，直接 scroll(to:) 会被钳回顶部。
    if let scroll = contentScrollView {
      view.layoutSubtreeIfNeeded()
      let offset = scrollOffsets[selection] ?? .zero
      scroll.contentView.scroll(to: offset)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
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
    // 顶部内边距为透明标题栏下的红绿灯让位（全高侧栏窗口）；左右为 0，
    // 让导航行的选中高亮整宽贴到窗口边缘（Otty 风格），搜索框单独留边。
    column.edgeInsets = NSEdgeInsets(top: SettingsMetrics.sidebarTopInset, left: 0, bottom: 12, right: 0)

    let search = NSSearchField()
    search.placeholderString = "搜索"
    search.stringValue = searchText
    search.delegate = self
    search.controlSize = .large
    sidebarSearchField = search
    search.translatesAutoresizingMaskIntoConstraints = false
    search.heightAnchor.constraint(equalToConstant: 30).isActive = true
    column.addArrangedSubview(search)
    search.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
    column.setCustomSpacing(14, after: search)

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
      button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
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
    let items = sectionViews()
    for item in items {
      content.addArrangedSubview(item)
      // 标题与卡片必须满宽（扣除栈边距）。NSStackView 的 .width 对齐 + edgeInsets
      // 对「固有宽度超过可用宽度」的 arranged subview 不可靠：系统集成卡片（长说明
      // 文字单行固有宽度约 650pt）曾被布局引擎丢到 x=0、宽 474，丢失左侧 inset。
      // 这里对满宽项加显式 required 边距约束，宽度不再依赖栈的内部分配算法；
      // 超宽压力由行内文字列（压缩阻力已压低的 labels 栈）换行吸收。
      if item.identifier == Self.groupTitleIdentifier || item.identifier == Self.cardIdentifier {
        item.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: content.edgeInsets.left).isActive = true
        item.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -content.edgeInsets.right).isActive = true
      }
    }
    // 分组节奏：标题紧贴自己的卡片（8pt），上一块内容与下一个标题拉开（28pt），
    // 形成截图里「小标题 + 大卡片」的分组观感。
    for (index, item) in items.enumerated() {
      if item.identifier == Self.groupTitleIdentifier {
        content.setCustomSpacing(8, after: item)
        if index > 0 {
          content.setCustomSpacing(28, after: items[index - 1])
        }
      }
    }
    if let message {
      content.addArrangedSubview(makeLabel("✓  \(message)", size: 10.5, color: AsterTheme.accent))
    }
    document.addSubview(content)
    scroll.documentView = document
    contentScrollView = scroll
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
    [
      sectionTitle("通用"),
      card([
        popupRow(
          "语言", "界面显示语言",
          items: Self.languageOptions.map(\.label),
          selected: Self.languageOptions.firstIndex {
            $0.value == preferences.configuration.general.language
          } ?? 0
        ) { [weak self] index in
          self?.preferences.configuration.general.language = Self.languageOptions[index].value
        },
        enumPopupRow(
          "启动时", "打开 Aster 时的初始窗口行为",
          value: preferences.configuration.launchBehavior
        ) { [weak self] value in
          self?.preferences.configuration.launchBehavior = value
        },
        toggleRow(
          "最后一个窗口关闭后退出", "关闭全部窗口时同时退出应用",
          value: preferences.configuration.general.quitAfterLastWindowClosed
        ) { [weak self] value in
          self?.preferences.configuration.general.quitAfterLastWindowClosed = value
        },
        toggleRow(
          "全部关闭后新建窗口", "点按 Dock 图标时，若没有窗口则自动新建",
          value: preferences.configuration.general.newWindowWhenAllClosed
        ) { [weak self] value in
          self?.preferences.configuration.general.newWindowWhenAllClosed = value
        },
      ]),
      sectionTitle("关闭确认"),
      card([
        enumPopupRow(
          "关闭标签页", "何时在关闭标签页前询问",
          value: preferences.configuration.general.closeTabConfirmation
        ) { [weak self] value in
          self?.preferences.configuration.general.closeTabConfirmation = value
        },
        enumPopupRow(
          "关闭窗口", "何时在关闭窗口前询问",
          value: preferences.configuration.general.closeWindowConfirmation
        ) { [weak self] value in
          self?.preferences.configuration.general.closeWindowConfirmation = value
        },
        enumPopupRow(
          "关闭面板", "何时在关闭分屏面板前询问",
          value: preferences.configuration.general.closePaneConfirmation
        ) { [weak self] value in
          self?.preferences.configuration.general.closePaneConfirmation = value
        },
      ]),
      sectionTitle("系统集成"),
      card([
        actionRow(
          "默认终端", "将 Aster 注册为 ssh:// 链接的默认打开方式（macOS 以链接处理器代替全局默认终端）",
          title: "设为默认终端"
        ) { [weak self] in self?.registerAsDefaultTerminal() },
        actionRow(
          "安装 CLI", "把 `aster` 命令安装到 PATH，可在终端里用它打开目录或 Recipe",
          title: "安装 CLI"
        ) { [weak self] in self?.installCLI() },
        actionRow(
          "Finder 集成", "Finder 右键菜单「服务」中的「在 Aster 中打开」；可在「系统设置 → 键盘快捷键 → 服务」中重新绑定",
          title: "打开系统设置"
        ) { [weak self] in
          self?.openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")
        },
        actionRow(
          "完全磁盘访问权限", "当终端中的命令需要读写受保护目录时才需要；没有它 Aster 也能工作",
          title: "打开系统设置"
        ) { [weak self] in
          self?.openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        },
      ]),
    ]
  }

  // MARK: - System integration actions

  /// macOS 没有全局「默认终端」概念，可注册的是 ssh:// 链接处理器；需以 .app 打包运行。
  private func registerAsDefaultTerminal() {
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else {
      message = "需要以 Aster.app 方式运行才能设为默认终端"
      refresh()
      return
    }
    NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: "ssh") { error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.message = error == nil
          ? "已将 Aster 设为 ssh:// 链接的默认终端"
          : "设置失败：\(error!.localizedDescription)"
        self.refresh()
      }
    }
  }

  /// 安装 `aster` 命令行启动器脚本：优先 /usr/local/bin，不可写时退回 ~/.local/bin。
  /// 脚本只是 `open -a` 包装，不需要提权或后台守护进程。
  private func installCLI() {
    let script = """
      #!/bin/sh
      # Aster CLI 启动器：把目录、文件或 .asterrecipe 交给 Aster.app 打开。
      exec open -a "Aster" "$@"

      """
    let fileManager = FileManager.default
    let localBin = "/usr/local/bin"
    let fallback = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
    let targetDir = fileManager.isWritableFile(atPath: localBin) ? localBin : fallback
    let target = (targetDir as NSString).appendingPathComponent("aster")
    do {
      try fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
      try script.write(toFile: target, atomically: true, encoding: .utf8)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
      let pathHint = targetDir == fallback ? "；如 PATH 未包含该目录请自行加入" : ""
      message = "已安装 aster 命令到 \(target)\(pathHint)"
    } catch {
      message = "CLI 安装失败：\(error.localizedDescription)"
    }
    refresh()
  }

  /// 打开系统设置的指定面板（服务快捷键 / 完全磁盘访问）。
  private func openSystemSettingsPane(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  private func shellViews() -> [NSView] {
    [
      sectionTitle("通用"),
      card([
        infoRow("登录 Shell", ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "系统默认"),
        textRow("终端类型", "传递给 TUI 程序的 TERM", value: preferences.configuration.appearance.terminalIdentity) { [weak self] value in
          self?.preferences.configuration.appearance.terminalIdentity = value
        },
      ]),
      sectionTitle("Shell 集成"),
      card([
        toggleRow(
          "Shell 集成", "通过终端 OSC 标记跟踪当前目录、标题与命令状态",
          value: preferences.configuration.shell.shellIntegration
        ) { [weak self] value in
          self?.preferences.configuration.shell.shellIntegration = value
        },
        toggleRow(
          "SSH 集成", "在 SSH 会话中保持目录与标题跟踪",
          value: preferences.configuration.shell.sshIntegration
        ) { [weak self] value in
          self?.preferences.configuration.shell.sshIntegration = value
        },
      ]),
      sectionTitle("会话恢复"),
      card([
        toggleRow(
          "恢复 tmux / screen 会话", "恢复工作区时重新附着多路复用器会话",
          value: preferences.configuration.shell.restoreMultiplexerSessions
        ) { [weak self] value in
          self?.preferences.configuration.shell.restoreMultiplexerSessions = value
        },
        toggleRow(
          "恢复智能体会话", "恢复工作区时继续之前的智能体 CLI 会话",
          value: preferences.configuration.shell.restoreAgentSessions
        ) { [weak self] value in
          self?.preferences.configuration.shell.restoreAgentSessions = value
        },
        toggleRow(
          "恢复运行中的进程", "恢复工作区时重新启动之前运行的命令",
          value: preferences.configuration.shell.restoreProcesses
        ) { [weak self] value in
          self?.preferences.configuration.shell.restoreProcesses = value
        },
      ]),
      sectionTitle("通知"),
      card([
        toggleRow(
          "命令完成时通知", "长时间命令结束后发送系统通知",
          value: preferences.configuration.shell.notifyOnFinish
        ) { [weak self] value in
          self?.preferences.configuration.shell.notifyOnFinish = value
        },
        toggleRow(
          "命令出错时通知", "命令以非零状态退出时发送系统通知",
          value: preferences.configuration.shell.notifyOnError
        ) { [weak self] value in
          self?.preferences.configuration.shell.notifyOnError = value
        },
        toggleRow(
          "终端铃声", "响应终端 BEL 字符",
          value: preferences.configuration.shell.terminalBell
        ) { [weak self] value in
          self?.preferences.configuration.shell.terminalBell = value
        },
      ]),
      sectionTitle("标签徽章"),
      card([
        toggleRow(
          "退出状态徽章", "命令失败时在标签上显示标记",
          value: preferences.configuration.shell.badgeExitStatus
        ) { [weak self] value in
          self?.preferences.configuration.shell.badgeExitStatus = value
        },
        toggleRow(
          "等待输入徽章", "命令等待输入时在标签上显示标记",
          value: preferences.configuration.shell.badgeAwaitingInput
        ) { [weak self] value in
          self?.preferences.configuration.shell.badgeAwaitingInput = value
        },
      ]),
    ]
  }

  private func controlViews() -> [NSView] {
    [
      sectionTitle("键盘"),
      card([
        toggleRow("Option 作为 Meta", "发送 Esc 前缀，兼容 Emacs 和 Shell 快捷键", value: preferences.configuration.controls.optionAsMeta) { [weak self] value in
          self?.preferences.configuration.controls.optionAsMeta = value
        },
      ]),
      sectionTitle("鼠标"),
      card([
        toggleRow("允许鼠标报告", "供 vim、tmux、htop 等 TUI 使用", value: preferences.configuration.controls.allowMouseReporting) { [weak self] value in
          self?.preferences.configuration.controls.allowMouseReporting = value
        },
        toggleRow(
          "焦点跟随鼠标", "指针悬停的分屏面板自动获得键盘焦点",
          value: preferences.configuration.controls.focusFollowsMouse
        ) { [weak self] value in
          self?.preferences.configuration.controls.focusFollowsMouse = value
        },
      ]),
      sectionTitle("复制与粘贴"),
      card([
        toggleRow(
          "选中即复制", "选中文本后自动写入剪贴板",
          value: preferences.configuration.controls.copyOnSelect
        ) { [weak self] value in
          self?.preferences.configuration.controls.copyOnSelect = value
        },
        toggleRow(
          "复制时去除行尾空格", "复制的每行去掉末尾的空白字符",
          value: preferences.configuration.controls.trimTrailingSpaces
        ) { [weak self] value in
          self?.preferences.configuration.controls.trimTrailingSpaces = value
        },
        toggleRow(
          "粘贴保护", "粘贴多行或含控制字符的内容前先确认",
          value: preferences.configuration.controls.pasteProtection
        ) { [weak self] value in
          self?.preferences.configuration.controls.pasteProtection = value
        },
      ]),
      sectionTitle("显示"),
      card([
        toggleRow(
          "平滑滚动", "终端内容滚动时使用平滑动画",
          value: preferences.configuration.controls.smoothScrolling
        ) { [weak self] value in
          self?.preferences.configuration.controls.smoothScrolling = value
        },
        toggleRow(
          "链接预览", "悬停链接时显示 URL 目标",
          value: preferences.configuration.controls.showLinkPreviews
        ) { [weak self] value in
          self?.preferences.configuration.controls.showLinkPreviews = value
        },
      ]),
      sectionTitle("安全"),
      card([
        toggleRow(
          "自动安全输入", "检测到密码输入时启用系统安全键盘",
          value: preferences.configuration.controls.secureInputAutomatically
        ) { [weak self] value in
          self?.preferences.configuration.controls.secureInputAutomatically = value
        },
      ]),
    ]
  }

  private func editorViews() -> [NSView] {
    [
      sectionTitle("编辑器"),
      card([
        toggleRow(
          "自动换行", "对长行进行软换行，而不是水平滚动",
          value: preferences.configuration.editor.lineWrap
        ) { [weak self] value in
          self?.preferences.configuration.editor.lineWrap = value
        },
        toggleRow(
          "显示行号", "在文本面板左侧显示行号侧栏",
          value: preferences.configuration.editor.showLineNumbers
        ) { [weak self] value in
          self?.preferences.configuration.editor.showLineNumbers = value
        },
        toggleRow(
          "显示不可见字符", "把空格、Tab、换行渲染为可见符号",
          value: preferences.configuration.editor.showVisibleWhitespace
        ) { [weak self] value in
          self?.preferences.configuration.editor.showVisibleWhitespace = value
        },
        stepperRow(
          "Tab 宽度", "Tab 字符的视觉宽度（列数）",
          value: Double(preferences.configuration.editor.tabSize), range: 2...8
        ) { [weak self] value in
          self?.preferences.configuration.editor.tabSize = Int(value)
        },
        toggleRow(
          "滚动越过末尾", "允许继续向下滚动，使最后一行可位于视口顶部",
          value: preferences.configuration.editor.scrollPastEnd
        ) { [weak self] value in
          self?.preferences.configuration.editor.scrollPastEnd = value
        },
        toggleRow(
          "Vim 按键", "在文件 / 编辑器面板中启用模态编辑",
          value: preferences.configuration.editor.vimKeyBindings
        ) { [weak self] value in
          self?.preferences.configuration.editor.vimKeyBindings = value
        },
      ]),
      sectionTitle("打开文件"),
      card([
        toggleRow(
          "预览富文档", "双击 Markdown 等文件时在相邻面板渲染预览",
          value: preferences.configuration.editor.previewRichDocuments
        ) { [weak self] value in
          self?.preferences.configuration.editor.previewRichDocuments = value
        },
      ]),
    ]
  }

  private func agentViews() -> [NSView] {
    let commands = [("Claude Code", "claude"), ("Codex", "codex"), ("Kimi", "kimi")]
    // enabledAgents 是命令名数组：开关按「包含与否」读写，保持数组内不重复。
    let agentRows = commands.map { name, command in
      toggleRow(
        name,
        "\(command) · \(executableExists(command) ? "已安装" : "未检测到")",
        value: preferences.configuration.agents.enabledAgents.contains(command)
      ) { [weak self] enabled in
        guard let self else { return }
        var agents = self.preferences.configuration.agents.enabledAgents
        agents.removeAll { $0 == command }
        if enabled { agents.append(command) }
        self.preferences.configuration.agents.enabledAgents = agents
      }
    }
    return [
      sectionTitle("已启用的智能体"),
      card(agentRows),
      sectionTitle("标签徽章"),
      card([
        toggleRow(
          "处理中徽章", "智能体处理任务时在标签上显示标记",
          value: preferences.configuration.agents.badgeProcessing
        ) { [weak self] value in
          self?.preferences.configuration.agents.badgeProcessing = value
        },
        toggleRow(
          "任务完成徽章", "智能体完成任务时在标签上显示标记",
          value: preferences.configuration.agents.badgeTaskComplete
        ) { [weak self] value in
          self?.preferences.configuration.agents.badgeTaskComplete = value
        },
        toggleRow(
          "等待输入徽章", "智能体等待确认时在标签上显示标记",
          value: preferences.configuration.agents.badgeAwaitingInput
        ) { [weak self] value in
          self?.preferences.configuration.agents.badgeAwaitingInput = value
        },
      ]),
      sectionTitle("通知"),
      card([
        toggleRow(
          "任务完成时通知", "智能体完成任务后发送系统通知",
          value: preferences.configuration.agents.notifyTaskComplete
        ) { [weak self] value in
          self?.preferences.configuration.agents.notifyTaskComplete = value
        },
        toggleRow(
          "等待输入时通知", "智能体等待确认时发送系统通知",
          value: preferences.configuration.agents.notifyAwaitingInput
        ) { [weak self] value in
          self?.preferences.configuration.agents.notifyAwaitingInput = value
        },
      ]),
      sectionTitle("运行"),
      card([
        toggleRow(
          "处理期间阻止睡眠", "智能体处理任务时阻止系统进入睡眠",
          value: preferences.configuration.agents.preventSleepWhileProcessing
        ) { [weak self] value in
          self?.preferences.configuration.agents.preventSleepWhileProcessing = value
        },
        toggleRow(
          "恢复智能体会话", "恢复工作区时继续之前的智能体会话",
          value: preferences.configuration.agents.resumeSessions
        ) { [weak self] value in
          self?.preferences.configuration.agents.resumeSessions = value
        },
      ]),
    ]
  }

  private func recipeViews() -> [NSView] {
    [
      sectionTitle("命令重放"),
      card([
        enumPopupRow(
          "重放模式", "打开 Recipe 时如何处理其中保存的命令",
          value: preferences.configuration.recipeReplayMode
        ) { [weak self] value in
          self?.preferences.configuration.recipeReplayMode = value
        },
      ]),
      sectionTitle("格式"),
      card([
        infoRow("Recipe 包含", "标签页、分屏方向、目录、文件和可选命令", ".asterrecipe"),
        infoRow("安全边界", "不会保存 PID、文件描述符、令牌或临时焦点", "可移植"),
      ]),
    ]
  }

  private func shortcutViews() -> [NSView] {
    [
      sectionTitle("快捷键"),
      card([
        infoRow("新建标签页", "", "⌘ T"),
        infoRow("打开文件", "", "⌘ O"),
        infoRow("关闭标签页", "", "⌘ W"),
        infoRow("向右分屏", "", "⌘ D"),
        infoRow("向下分屏", "", "⇧ ⌘ D"),
        infoRow("关闭面板", "", "⌥ ⌘ W"),
        infoRow("命令面板", "", "⌘ K"),
        infoRow("设置", "", "⌘ ,"),
      ]),
    ]
  }

  private func advancedViews() -> [NSView] {
    [
      sectionTitle("运行时"),
      card([
        infoRow("终端内核", "VT100 / xterm、真彩色、鼠标、超链接与本地 PTY", "SwiftTerm"),
        infoRow("会话恢复", "保存可重建的标签与分屏结构", "已启用"),
        infoRow("界面框架", "主窗口、设置和所有控件均为原生视图", "AppKit"),
      ]),
      sectionTitle("配置"),
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
      toggleRow(
        "显示标签栏", "关闭后隐藏标签面板，仅保留终端内容",
        value: preferences.configuration.appearance.showTabBar
      ) { [weak self] value in
        self?.preferences.configuration.appearance.showTabBar = value
      },
      enumPopupRow(
        "新标签页位置", "空标签进入当前分组末尾；带内容标签可紧跟当前标签",
        value: preferences.configuration.appearance.resolvedNewTabPosition
      ) { [weak self] value in
        self?.preferences.configuration.appearance.newTabPosition = value
      },
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
      sliderRow(
        "行高", "行间距倍数",
        value: preferences.configuration.appearance.lineHeight,
        range: 0.8...2, suffix: "×", fractionDigits: 2
      ) { [weak self] value in
        self?.preferences.configuration.appearance.lineHeight = value
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
      enumPopupRow(
        "光标样式", "终端程序仍可通过 DECSCUSR 临时覆盖",
        value: preferences.configuration.appearance.cursorStyle
      ) { [weak self] value in
        self?.preferences.configuration.appearance.cursorStyle = value
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
    row.spacing = 14
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
    // 700pt 窗口下内容区约 448pt 宽：3 列 130pt 卡片刚好放下，4 列会横向裁切。
    let rows = stride(from: 0, to: themes.count, by: 3).map { start -> [NSView] in
      var cells: [NSView] = themes[start..<min(start + 3, themes.count)].map { theme in
        ThemeCardButton(theme: theme, selected: theme.name == selectedName) { [weak self] in
          self?.focusedThemeID = theme.id
          self?.preferences.selectTheme(theme)
        }
      }
      while cells.count < 3 { cells.append(NSView()) }
      return cells
    }
    let grid = NSGridView(views: rows)
    grid.columnSpacing = 12
    grid.rowSpacing = 14
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

  /// 大圆角设置卡片；行间不画分隔线，靠每行自身的内边距形成留白节奏（Otty 风格）。
  /// 分组卡片：surface 与窗口背景在多数主题下几乎相同，改用 `settingsCard`
  /// （窗口底色向文字色轻混）让每组功能在白色画布上有可见的浅色底块。
  private func card(_ rows: [NSView]) -> NSView {
    let card = NSStackView()
    card.orientation = .vertical
    card.spacing = 0
    card.wantsLayer = true
    card.layer?.backgroundColor = AsterTheme.settingsCard.cgColor
    card.layer?.cornerRadius = SettingsMetrics.cardCornerRadius
    card.identifier = Self.cardIdentifier
    // 显式压低卡片自身的水平压缩阻力。行内长说明文字的固有宽度（单行不换行）
    // 可能超过内容栈可用宽度（系统集成卡片达 650pt），而栈的压缩阻力取子视图
    // 最大值（750），外层内容栈的 .width 对齐压不动它，只能 break 左侧 inset
    // 约束——卡片曾因此贴到内容区左边缘。压低后由行内文字列吸收压缩并换行。
    card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for row in rows {
      card.addArrangedSubview(row)
    }
    return card
  }

  /// 所有设置行的统一底座：左侧「标题 + 可换行灰色说明」，右侧 accessory 控件。
  private func rowShell(_ title: String, _ detail: String, accessory: NSView) -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    let detailLabel = makeLabel(detail, size: SettingsMetrics.rowDetailSize, color: AsterTheme.secondaryInk)
    // 说明文字允许折行撑高整行；水平抗压缩降为最低，长说明被压缩换行而不是
    // 把右侧 accessory（已 required hugging）挤出卡片。
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.maximumNumberOfLines = 0
    detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let labels = NSStackView(views: [
      makeLabel(title, size: SettingsMetrics.rowTitleSize, weight: .medium),
      detailLabel,
    ])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 4
    // 关键点：显式压低文字列整体（而非单个 label）的水平压缩阻力。NSStackView 的
    // 压缩阻力取子视图最大值，只降详情 label 时标题的 750 会「代理」整列，而列宽
    // 又由长说明文字的单行固有宽度决定（可达 650pt）——外层内容栈的 .width 对齐
    // 约束压不动它，只能 break 边距约束，系统集成卡片曾因此丢失左侧 inset。
    labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    // 文字列必须比弹簧视图更愿意拉伸（hugging 低于 spacer 的 250）：否则 labels
    // 停在说明文字的单行固有宽度，行宽超出卡片可用宽度后整卡布局变成多解，
    // 系统集成卡片曾因此丢失左侧 inset 或出现顶部幽灵空白。
    labels.setContentHuggingPriority(.init(240), for: .horizontal)
    accessory.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [labels, NSView(), accessory])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.edgeInsets = NSEdgeInsets(
      top: SettingsMetrics.rowVerticalInset,
      left: SettingsMetrics.rowHorizontalInset,
      bottom: SettingsMetrics.rowVerticalInset,
      right: SettingsMetrics.rowHorizontalInset
    )
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

  /// 枚举下拉行：菜单项与选中索引都由 `allCases` 单一来源生成，杜绝文案数组与
  /// case 顺序两处维护导致的索引错位。
  private func enumPopupRow<T: SettingsEnumOption>(_ title: String, _ detail: String, value: T, action: @escaping (T) -> Void) -> NSView {
    let cases = Array(T.allCases)
    return popupRow(
      title, detail,
      items: cases.map(\.settingsLabel),
      selected: cases.firstIndex(of: value) ?? 0
    ) { index in
      action(cases[index])
    }
  }

  /// 语言下拉的取值表：value 写入配置持久化，label 只用于显示。
  private static let languageOptions: [(label: String, value: String)] = [
    ("跟随系统", "system"),
    ("简体中文", "zh-Hans"),
    ("English", "en"),
  ]

  /// 滑杆行；`fractionDigits` 控制数值标签的小数位（行高倍数等非整数设置需要）。
  private func sliderRow(_ title: String, _ detail: String, value: Double, range: ClosedRange<Double>, suffix: String, fractionDigits: Int = 0, action: @escaping (Double) -> Void) -> NSView {
    let slider = ClosureSlider(value: value, range: range, action: action)
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
    let text = fractionDigits == 0
      ? "\(Int(value)) \(suffix)"
      : String(format: "%.\(fractionDigits)f \(suffix)", value)
    let valueLabel = makeLabel(text, size: 10.5, color: AsterTheme.secondaryInk)
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

  /// 分组小标题：灰色小号加字距，identifier 供内容栈识别并收紧「标题 → 卡片」间距。
  private func sectionTitle(_ title: String) -> NSView {
    let label = makeLabel(title, size: SettingsMetrics.groupTitleSize, weight: .medium, color: AsterTheme.tertiaryInk)
    label.attributedStringValue = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: SettingsMetrics.groupTitleSize, weight: .medium),
        .foregroundColor: AsterTheme.tertiaryInk,
        .kern: 0.8,
      ]
    )
    label.identifier = Self.groupTitleIdentifier
    // 压低 hugging 让标题在内容栈里撑满整行：否则栈的对齐约束会把固有宽度的
    // 标签靠边放置，导致小标题跑到卡片右上角。
    label.setContentHuggingPriority(.init(100), for: .horizontal)
    return label
  }

  /// 标记分组标题视图，`makeContentScroll` 据此调整标题前后的自定义间距。
  private static let groupTitleIdentifier = NSUserInterfaceItemIdentifier("settings.group-title")
  /// 标记分组卡片视图，`makeContentScroll` 据此对卡片施加显式左右边距约束。
  private static let cardIdentifier = NSUserInterfaceItemIdentifier("settings.card")

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

/// 设置侧栏导航行：整宽方角高亮（Otty 风格），图标与文字通过内部子视图留出
/// 左侧间隙——NSButton 自身的 imageLeading 布局无法控制内容内边距。
@MainActor
private final class SettingsSidebarButton: NSButton {
  private let handler: () -> Void

  init(section: SettingsViewController.Section, selected: Bool, action: @escaping () -> Void) {
    handler = action
    super.init(frame: .zero)
    title = ""
    setAccessibilityLabel(section.rawValue)
    isBordered = false
    wantsLayer = true
    layer?.backgroundColor = selected ? AsterTheme.ink.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor

    let tint = selected ? AsterTheme.ink : AsterTheme.secondaryInk
    let icon = NSImageView(
      image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.rawValue) ?? NSImage()
    )
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    icon.contentTintColor = tint
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
    let label = makeLabel(section.rawValue, size: 13, color: tint)
    let row = NSStackView(views: [icon, label])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    addSubview(row)
    row.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 12))

    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 32).isActive = true
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
    // 选中框走主题强调色而不是系统 accent，遵守「主题色只经由 ThemeRuntime」规则。
    layer?.borderColor = (selected ? AsterTheme.accent : AsterTheme.hairline).cgColor
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
      widthAnchor.constraint(equalToConstant: 132),
      heightAnchor.constraint(equalToConstant: 100),
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
    // 同上：主题卡选中描边使用主题强调色。
    layer?.borderColor = AsterTheme.accent.cgColor
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
    preview.heightAnchor.constraint(equalToConstant: 68).isActive = true
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 130),
      heightAnchor.constraint(equalToConstant: 110),
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

/// UI 层为 AsterCore 配置枚举补充的下拉文案协议；领域层不感知任何显示字符串。
private protocol SettingsEnumOption: CaseIterable, Equatable {
  var settingsLabel: String { get }
}

extension CloseConfirmation: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .always: "总是询问"
    case .runningProcess: "有运行中的进程时"
    case .multipleTabs: "有多个标签页时"
    case .never: "从不"
    }
  }
}

extension LaunchBehavior: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .newWindow: "打开新窗口"
    case .restoreLastSession: "恢复上次会话"
    }
  }
}

extension NewTabPosition: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .automatic: "自动"
    case .end: "始终位于末尾"
    case .afterCurrent: "始终紧跟当前标签"
    }
  }
}

extension RecipeReplayMode: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .automatic: "自动执行"
    case .confirmOnce: "执行前确认一次"
    case .oneByOne: "逐条确认"
    case .skip: "跳过命令"
    }
  }
}

extension CursorStyle: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .block: "方块"
    case .bar: "竖线"
    case .underline: "下划线"
    case .hollowBlock: "空心方块"
    }
  }
}
