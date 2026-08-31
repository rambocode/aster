import AppKit
import AsterCore

/// 内容区顶条（`makeWorkspaceHeader` 的 `background`）：承载路径胶囊与安全输入指示器。
/// 隐藏原生标题栏后（`titleVisibility = .hidden`）这条 28pt 区域失去了系统自带的
/// 「双击标题栏放大/还原窗口」手势，这里在空白处（路径胶囊、指示器等子视图仍优先
/// 吃掉命中）手动补回，双击调用 `NSWindow.performZoom` 与「显示」菜单的「缩放」项等效。
@MainActor
final class WorkspaceTitleBarBackgroundView: NSView {
  override func mouseDown(with event: NSEvent) {
    guard event.clickCount == 2 else {
      super.mouseDown(with: event)
      return
    }
    window?.performZoom(nil)
  }
}

/// 工作区标题按钮。Otty 在左侧标签布局中常驻显示当前目录胶囊；程序标题仍保存在
/// `programTitle` 中供窗口标题和辅助语义使用，但不会替换用户定位工作区所需的路径。
@MainActor
final class WorkspaceTitleButton: NSButton {
  var programTitle: String {
    didSet { updatePresentation() }
  }
  var workingDirectory: String {
    didSet { updatePresentation() }
  }
  /// 活动 Pane 的 Agent 会话标题。有值时胶囊显示它（工作目录退到 toolTip），
  /// 没有 Agent 或标题尚未产生时保持原有的缩写目录胶囊。
  var agentSessionTitle: String? {
    didSet {
      guard agentSessionTitle != oldValue else { return }
      updatePresentation()
    }
  }
  /// 活动 Pane 正在运行的 Agent；对齐 Otty，会话标题前缀该 Agent 的图标。
  var agentProvider: AgentProvider? {
    didSet {
      guard agentProvider != oldValue else { return }
      updatePresentation()
    }
  }

  private let foregroundColor: NSColor
  /// Otty 的 `[titlebar].background` 只涂目录胶囊，胶囊外的整条标题区继承 Window。
  /// 未显式声明该 token 的主题保持透明，不能拿派生终端色造出一块白色药丸。
  private let backgroundColor: NSColor?
  private let handler: (WorkspaceTitleButton) -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false
  private var isPopoverPresented = false

  init(
    programTitle: String,
    workingDirectory: String,
    foregroundColor: NSColor,
    backgroundColor: NSColor?,
    handler: @escaping (WorkspaceTitleButton) -> Void
  ) {
    self.programTitle = programTitle
    self.workingDirectory = workingDirectory
    self.foregroundColor = foregroundColor
    self.backgroundColor = backgroundColor
    self.handler = handler
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .accessoryBarAction
    alignment = .center
    font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    lineBreakMode = .byTruncatingMiddle
    contentTintColor = foregroundColor
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = NSColor.clear.cgColor
    target = self
    action = #selector(invoke)
    updatePresentation()
  }

  required init?(coder: NSCoder) { nil }

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
    isHovered = true
    updatePresentation()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    updatePresentation()
  }

  func setPopoverPresented(_ presented: Bool) {
    isPopoverPresented = presented
    updatePresentation()
  }

  private func updatePresentation() {
    if let agentSessionTitle {
      title = "\(agentSessionTitle) ⋯"
      // 会话标题占据胶囊时，目录定位信息仍要可达：toolTip 保留完整路径。
      toolTip = workingDirectory
      // 会话标题前放 Agent 图标（与侧栏行同一套图标集），图标集缺图时不放；
      // 标题本身已带 ✳/◐ 等 spinner 前缀时也不放，避免并排两个图标。
      image = AsterControlTitleNormalizer.hasSpinnerPrefix(agentSessionTitle)
        ? nil
        : agentProvider.flatMap { TabIconArtwork.image(named: TabRowButton.agentIconName($0)) }
      imagePosition = image == nil ? .noImage : .imageLeading
    } else {
      title = "\((workingDirectory as NSString).abbreviatingWithTildeInPath) ⋯"
      toolTip = workingDirectory
      image = nil
      imagePosition = .noImage
    }
    // 路径始终使用 titlebar.foreground；悬停只能为未显式设置胶囊背景的主题补充
    // 轻量反馈，不能覆盖 April / Ayu / Pink 等主题声明的 titlebar.background。
    contentTintColor = foregroundColor
    if let backgroundColor {
      layer?.backgroundColor = backgroundColor.cgColor
    } else if isHovered || isPopoverPresented {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.075).cgColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  @objc private func invoke() { handler(self) }
}

/// `NSSegmentedControl` 保留原生键盘/辅助功能和 target-action，但按参考界面重绘为
/// 灰色轨道 + 白色选中胶囊。系统 `.capsule` 的选中段仍是深灰，视觉层级正好相反。
@MainActor
private final class WorkspaceTitleModeControl: NSSegmentedControl {
  override func draw(_ dirtyRect: NSRect) {
    let track = bounds.insetBy(dx: 0, dy: 1)
    let radius = track.height / 2
    AsterTheme.ink.withAlphaComponent(0.065).setFill()
    NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

    let segmentWidth = track.width / CGFloat(max(1, segmentCount))
    if selectedSegment >= 0 {
      let selected = NSRect(
        x: track.minX + CGFloat(selectedSegment) * segmentWidth + 2,
        y: track.minY + 2,
        width: segmentWidth - 4,
        height: track.height - 4
      )
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowBlurRadius = 2
      shadow.shadowOffset = NSSize(width: 0, height: -1)
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
      shadow.set()
      NSColor.controlBackgroundColor.setFill()
      NSBezierPath(
        roundedRect: selected,
        xRadius: selected.height / 2,
        yRadius: selected.height / 2
      ).fill()
      NSGraphicsContext.restoreGraphicsState()
    }

    for index in 0..<segmentCount {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .center
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(
          ofSize: 11.5, weight: index == selectedSegment ? .semibold : .regular),
        .foregroundColor: index == selectedSegment ? AsterTheme.ink : AsterTheme.secondaryInk,
        .paragraphStyle: paragraph,
      ]
      let label = label(forSegment: index) ?? ""
      let textSize = label.size(withAttributes: attributes)
      let rect = NSRect(
        x: track.minX + CGFloat(index) * segmentWidth,
        y: track.midY - textSize.height / 2,
        width: segmentWidth,
        height: textSize.height
      )
      label.draw(in: rect, withAttributes: attributes)
    }
  }
}

/// 标题弹层里的整行动作。按钮本身覆盖整行，文字、快捷键和箭头仍保持原生可访问控件，
/// 悬停反馈使用产品现有中性色，不引入标题区域专属主题颜色。
@MainActor
private final class WorkspaceTitleRowButton: NSButton {
  private let handler: (WorkspaceTitleRowButton) -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false

  init(
    title: String,
    symbol: String? = nil,
    shortcut: String? = nil,
    trailingSymbols: [String] = [],
    showsSubmenu: Bool = false,
    handler: @escaping (WorkspaceTitleRowButton) -> Void
  ) {
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    alignment = .left
    font = NSFont.systemFont(ofSize: 13.5)
    contentTintColor = AsterTheme.ink
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    target = self
    action = #selector(invoke)

    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      imagePosition = .imageLeading
    }

    let trailingText = shortcut ?? (showsSubmenu ? "›" : nil)
    if let trailingText {
      let label = makeLabel(trailingText, size: 11.5, color: AsterTheme.tertiaryInk)
      label.alignment = .right
      addSubview(label)
      label.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        label.centerYAnchor.constraint(equalTo: centerYAnchor),
        label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      ])
    }
    if !trailingSymbols.isEmpty {
      let icons = trailingSymbols.map { name -> NSImageView in
        let image = NSImageView(image: NSImage(systemSymbolName: name,
          accessibilityDescription: title) ?? NSImage())
        image.contentTintColor = AsterTheme.tertiaryInk
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          image.widthAnchor.constraint(equalToConstant: 14),
          image.heightAnchor.constraint(equalToConstant: 14),
        ])
        return image
      }
      let stack = NSStackView(views: icons)
      stack.orientation = .horizontal
      stack.spacing = 8
      addSubview(stack)
      stack.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: showsSubmenu ? -24 : -8),
      ])
    }
  }

  required init?(coder: NSCoder) { nil }

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
    isHovered = true
    updateBackground()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    updateBackground()
  }

  private func updateBackground() {
    layer?.backgroundColor = isHovered
      ? AsterTheme.ink.withAlphaComponent(0.075).cgColor : NSColor.clear.cgColor
  }

  @objc private func invoke() { handler(self) }
}

/// Otty 式标题工作区弹层。所有会修改仓库的 Git 动作只预填到终端，仍由用户回车确认；
/// Finder、编辑器、分屏与搜索动作直接复用主工作区的正式入口。
@MainActor
final class WorkspaceTitlePopoverViewController: NSViewController {
  private let model: AppModel
  private let preferences: AppPreferences
  private weak var tab: TerminalTabItem?
  private weak var modeControl: NSSegmentedControl?
  private weak var titleField: NSTextField?

  init(model: AppModel, preferences: AppPreferences, tab: TerminalTabItem) {
    self.model = model
    self.preferences = preferences
    self.tab = tab
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = NSSize(width: 280, height: 462)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 462))
    root.identifier = NSUserInterfaceItemIdentifier("workspace-title-popover")
    root.wantsLayer = true
    view = root

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 1
    root.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
      content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
      content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
    ])

    content.addArrangedSubview(makeNamingHeader())
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeWorkingDirectoryBlock())
    content.addArrangedSubview(makeRow(
      "Copy Path", identifier: "workspace-title-copy-path"
    ) { [weak self] _ in self?.copyPath() })
    content.addArrangedSubview(makeRow(
      "Reveal in Finder", identifier: "workspace-title-reveal-finder"
    ) { [weak self] _ in self?.revealInFinder() })
    content.addArrangedSubview(makeRow(
      "Open in", identifier: "workspace-title-open-in", showsSubmenu: true
    ) { [weak self] sender in self?.showOpenInMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      "Git", identifier: "workspace-title-git", showsSubmenu: true
    ) { [weak self] sender in self?.showGitMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      "Notifications & Privileges", identifier: "workspace-title-notifications",
      trailingSymbols: ["speaker.wave.2", "bell"], showsSubmenu: true
    ) { [weak self] _ in self?.openNotificationSettings() })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      "Split View", identifier: "workspace-title-split", showsSubmenu: true
    ) { [weak self] sender in self?.showSplitMenu(from: sender) })
    content.addArrangedSubview(makeDivider())
    content.addArrangedSubview(makeRow(
      "Find", identifier: "workspace-title-find", shortcut: "⌘F"
    ) { [weak self] _ in self?.model.isFindPresented = true })
    content.addArrangedSubview(makeRow(
      "Find in All Tabs", identifier: "workspace-title-global-find", shortcut: "⌘⇧F"
    ) { [weak self] _ in self?.model.toggleGlobalFind() })
    content.addArrangedSubview(makeRow(
      "Jump to", identifier: "workspace-title-jump", shortcut: "⌘J"
    ) { [weak self] _ in self?.model.toggleOpenQuickly() })
    content.addArrangedSubview(makeRow(
      "Command Palette", identifier: "workspace-title-palette", shortcut: "⌘⇧P"
    ) { [weak self] _ in self?.model.togglePalette() })
  }

  private func makeNamingHeader() -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 76).isActive = true

    let segmented = WorkspaceTitleModeControl(
      labels: ["Name", "Prefix"], trackingMode: .selectOne,
      target: self, action: #selector(modeChanged(_:)))
    segmented.selectedSegment = selectedMode
    segmented.segmentStyle = .capsule
    segmented.translatesAutoresizingMaskIntoConstraints = false
    modeControl = segmented

    let reset = IconHoverButton(symbol: "arrow.uturn.backward", accessibilityDescription: "恢复自动标题") {
      [weak self] in self?.resetName()
    }
    reset.identifier = NSUserInterfaceItemIdentifier("workspace-title-reset-name")
    reset.translatesAutoresizingMaskIntoConstraints = false

    let field = NSTextField(string: currentOverrideText)
    field.identifier = NSUserInterfaceItemIdentifier("workspace-title-name-field")
    field.placeholderString = selectedMode == 0 ? "Tab name" : "Tab prefix"
    field.font = NSFont.systemFont(ofSize: 13)
    field.isBezeled = false
    field.drawsBackground = true
    field.backgroundColor = AsterTheme.ink.withAlphaComponent(0.08)
    field.wantsLayer = true
    field.layer?.cornerRadius = 6
    field.layer?.cornerCurve = .continuous
    field.target = self
    field.action = #selector(commitName(_:))
    field.translatesAutoresizingMaskIntoConstraints = false
    titleField = field

    host.addSubview(segmented)
    host.addSubview(reset)
    host.addSubview(field)
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      segmented.topAnchor.constraint(equalTo: host.topAnchor),
      segmented.widthAnchor.constraint(equalToConstant: 142),
      reset.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      reset.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
      reset.widthAnchor.constraint(equalToConstant: 28),
      reset.heightAnchor.constraint(equalToConstant: 28),
      field.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      field.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      field.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 9),
      field.heightAnchor.constraint(equalToConstant: 32),
      host.widthAnchor.constraint(equalToConstant: 252),
    ])
    return host
  }

  private func makeWorkingDirectoryBlock() -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 54).isActive = true
    let heading = makeLabel("WORKING DIRECTORY", size: 10.5, weight: .semibold,
      color: AsterTheme.tertiaryInk)
    let path = makeLabel(abbreviatedDirectory + "/", size: 12.5, color: AsterTheme.secondaryInk)
    path.toolTip = tab?.workingDirectory
    let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill",
      accessibilityDescription: "工作目录") ?? NSImage())
    icon.contentTintColor = AsterTheme.tertiaryInk
    for item in [heading, icon, path] {
      host.addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      heading.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
      heading.topAnchor.constraint(equalTo: host.topAnchor, constant: 5),
      icon.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 2),
      icon.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
      icon.widthAnchor.constraint(equalToConstant: 15),
      icon.heightAnchor.constraint(equalToConstant: 15),
      path.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      path.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      path.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor),
      host.widthAnchor.constraint(equalToConstant: 252),
    ])
    return host
  }

  private func makeRow(
    _ title: String,
    symbol: String? = nil,
    identifier: String,
    shortcut: String? = nil,
    trailingSymbols: [String] = [],
    showsSubmenu: Bool = false,
    handler: @escaping (WorkspaceTitleRowButton) -> Void
  ) -> NSView {
    let button = WorkspaceTitleRowButton(
      title: title, symbol: symbol, shortcut: shortcut, trailingSymbols: trailingSymbols,
      showsSubmenu: showsSubmenu,
      handler: handler)
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 252),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }

  private func makeDivider() -> NSView {
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = AsterTheme.hairline.cgColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      divider.widthAnchor.constraint(equalToConstant: 252),
      divider.heightAnchor.constraint(equalToConstant: 1),
    ])
    return divider
  }

  private var selectedMode: Int {
    if case .prefix = tab?.tabTitleOverride { return 1 }
    return 0
  }

  private var currentOverrideText: String {
    switch tab?.tabTitleOverride {
    case .name(let value), .prefix(let value): value
    case .automatic, .none: ""
    }
  }

  private var abbreviatedDirectory: String {
    ((tab?.workingDirectory ?? NSHomeDirectory()) as NSString).abbreviatingWithTildeInPath
  }

  @objc private func modeChanged(_ sender: NSSegmentedControl) {
    titleField?.placeholderString = sender.selectedSegment == 0 ? "Tab name" : "Tab prefix"
    titleField?.stringValue = ""
    view.window?.makeFirstResponder(titleField)
  }

  @objc private func commitName(_ sender: NSTextField) {
    let override: TerminalTitleOverride = modeControl?.selectedSegment == 1
      ? .prefix(sender.stringValue) : .name(sender.stringValue)
    tab?.setTabTitleOverride(override)
    model.persistWorkspace()
  }

  private func resetName() {
    tab?.setTabTitleOverride(.automatic)
    titleField?.stringValue = ""
    model.persistWorkspace()
  }

  private func copyPath() {
    guard let directory = tab?.workingDirectory else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(directory, forType: .string)
  }

  private func revealInFinder() {
    guard let directory = tab?.workingDirectory else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
  }

  /// 「打开方式」与菜单栏 Shell 菜单共用 `ShellDirectoryMenuBuilder`，保证条目一致。
  private func showOpenInMenu(from sender: NSView) {
    guard let directory = tab?.workingDirectory else { return }
    let menu = ShellDirectoryMenuBuilder.openInMenu(
      directory: directory, model: model, tab: tab, preferences: preferences)
    popUp(menu, from: sender)
  }

  /// 「Git」与菜单栏 Shell 菜单共用 `ShellDirectoryMenuBuilder`，保证条目与注入语义一致。
  private func showGitMenu(from sender: NSView) {
    popUp(ShellDirectoryMenuBuilder.gitMenu(tab: tab, preferences: preferences), from: sender)
  }

  private func showSplitMenu(from sender: NSView) {
    let menu = NSMenu()
    for (title, direction) in [
      ("Split Left", SplitDirection.left), ("Split Right", .right),
      ("Split Up", .up), ("Split Down", .down),
    ] {
      menu.addItem(ActionMenuItem(title: title) { [weak self] in
        self?.model.splitSelectedTab(direction)
      })
    }
    popUp(menu, from: sender)
  }

  private func openNotificationSettings() {
    (NSApp.delegate as? AsterAppDelegate)?.showSettings(section: .shell)
  }

  private func popUp(_ menu: NSMenu, from sender: NSView) {
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 2), in: sender)
  }
}
