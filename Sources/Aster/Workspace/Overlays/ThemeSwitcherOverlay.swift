import AppKit
import AsterCore

/// `显示 → 主题` 使用独立可聚焦 Panel：列表接收键盘输入时，主工作区仍保持主题预览
/// 的完整活动样式。Panel 不嵌进工作区视图树，连续切换触发的重建也不会把选择器销毁。
@MainActor
final class ThemeSwitcherPanelController: NSWindowController, NSWindowDelegate {
  private weak var anchorWindow: NSWindow?
  private let content: ThemeSwitcherViewController
  private let onDismiss: () -> Void
  private var isDismissing = false

  init(preferences: AppPreferences, onDismiss: @escaping () -> Void) {
    self.onDismiss = onDismiss
    content = ThemeSwitcherViewController(preferences: preferences)
    let panel = ThemeSwitcherPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 366),
      // 不使用 `.nonactivatingPanel`：选择器必须真正成为 key window，搜索、方向键和
      // `Esc` 才会稳定到达输入控件；后方工作区由显式 presentation 状态保持激活样式。
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    panel.contentViewController = content
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.transient, .moveToActiveSpace]
    panel.hidesOnDeactivate = true
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    panel.delegate = self
    content.onCommit = { [weak self] in self?.dismiss(commit: true) }
    content.onCancel = { [weak self] in self?.dismiss(commit: false) }
  }

  required init?(coder: NSCoder) { nil }

  func present(relativeTo anchorWindow: NSWindow) {
    self.anchorWindow = anchorWindow
    guard let panel = window else { return }
    let frame = panel.frame
    let anchorFrame = anchorWindow.frame
    let origin = NSPoint(
      x: anchorFrame.midX - frame.width / 2,
      y: anchorFrame.maxY - frame.height - 62
    )
    panel.setFrameOrigin(origin)
    anchorWindow.addChildWindow(panel, ordered: .above)
    panel.makeKeyAndOrderFront(nil)
    content.focusSearch()
  }

  func dismiss(commit: Bool) {
    guard !isDismissing else { return }
    isDismissing = true
    if commit {
      content.commitSelection()
    } else {
      content.cancelPresentation()
    }
    if let panel = window {
      anchorWindow?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    anchorWindow?.makeKeyAndOrderFront(nil)
    onDismiss()
  }

  func windowDidResignKey(_ notification: Notification) {
    // 点击主窗口或切到其它应用等同于取消；只有明确点击主题或按回车才持久化。
    dismiss(commit: false)
  }
}

/// Borderless `NSPanel` 默认不一定接收键盘焦点；主题搜索和方向键导航要求它成为 key，
/// 但它不成为 main window，菜单命令仍归属后方工作区。
private final class ThemeSwitcherPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Otty 风格的主题搜索列表。方向键和鼠标悬停只做临时预览，点击/回车提交，`Esc`
/// 撤销；这组语义同时供 AppKit 自动化测试直接验证，不依赖屏幕坐标。
@MainActor
final class ThemeSwitcherViewController: NSViewController, NSSearchFieldDelegate {
  private let preferences: AppPreferences
  private let allThemes: [TerminalTheme]
  private let search = OverlaySearchField()
  private let rowsStack = NSStackView()
  private var visibleThemes: [TerminalTheme] = []
  private var selectedIndex = 0
  private var didFinish = false
  /// `NSSearchField` 编辑时按键先到共享 field editor，不能只依赖控件的 `keyDown`。
  /// 展示期间用局部 monitor 接住列表导航键；关闭后立即移除，不影响终端输入。
  private nonisolated(unsafe) var keyEventMonitor: Any?

  var onCommit: (() -> Void)?
  var onCancel: (() -> Void)?

  var visibleThemeNames: [String] { visibleThemes.map(\.name) }
  var selectedThemeName: String? {
    visibleThemes.indices.contains(selectedIndex) ? visibleThemes[selectedIndex].name : nil
  }

  init(preferences: AppPreferences) {
    self.preferences = preferences
    // “显示 → 主题”是完整主题选择器，不是当前明暗模式的过滤器。保持明亮在前、
    // 黑暗在后，同时让搜索和键盘预览覆盖全部内置及自定义主题。
    allThemes = TerminalThemeMode.allCases.flatMap { preferences.themes(for: $0) }
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) }
  }

  override func loadView() {
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = SettingsTheme.card.cgColor
    host.layer?.cornerRadius = 16
    host.identifier = NSUserInterfaceItemIdentifier("theme-switcher-overlay")

    let searchRow = NSView()
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        ?? NSImage())
    icon.contentTintColor = SettingsTheme.tertiaryInk
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

    search.placeholderString = "搜索主题…"
    search.isBordered = false
    search.drawsBackground = false
    search.focusRingType = .none
    search.font = .systemFont(ofSize: 14)
    search.textColor = SettingsTheme.ink
    search.delegate = self
    search.identifier = NSUserInterfaceItemIdentifier("theme-switcher-search")
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] _ in self?.onCommit?() }
    search.onCancel = { [weak self] in self?.onCancel?() }

    let separator = NSView()
    separator.wantsLayer = true
    separator.layer?.backgroundColor = SettingsTheme.hairline.cgColor

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder

    let document = FlippedDocumentView()
    // `NSScrollView` 不会替 documentView 自动开启约束布局；缺少这一行时文档维持零
    // frame，搜索栏正常但主题行全部不可见。
    document.translatesAutoresizingMaskIntoConstraints = false
    rowsStack.orientation = .vertical
    rowsStack.alignment = .leading
    rowsStack.spacing = 0
    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(rowsStack)
    scroll.documentView = document

    for child in [searchRow, separator, scroll] {
      child.translatesAutoresizingMaskIntoConstraints = false
      host.addSubview(child)
    }
    for child in [icon, search] {
      child.translatesAutoresizingMaskIntoConstraints = false
      searchRow.addSubview(child)
    }

    NSLayoutConstraint.activate([
      host.widthAnchor.constraint(equalToConstant: 560),
      host.heightAnchor.constraint(equalToConstant: 366),
      searchRow.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      searchRow.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      searchRow.topAnchor.constraint(equalTo: host.topAnchor),
      searchRow.heightAnchor.constraint(equalToConstant: 56),
      icon.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 19),
      icon.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 16),
      icon.heightAnchor.constraint(equalToConstant: 16),
      search.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
      search.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -16),
      search.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
      separator.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      separator.topAnchor.constraint(equalTo: searchRow.bottomAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
      scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
      scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8),
      rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
      rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
      rowsStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
      rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -8),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
    ])
    view = host
    reload(previewSelection: false)
  }

  func focusSearch() {
    loadViewIfNeeded()
    view.window?.makeFirstResponder(search)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.view.window?.isVisible == true else { return }
      self.scrollSelectionToVisible()
    }
    guard keyEventMonitor == nil else { return }
    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, self.view.window?.isVisible == true else { return event }
      switch event.keyCode {
      case 125:
        self.moveSelection(1)
        return nil
      case 126:
        self.moveSelection(-1)
        return nil
      case 36, 76:
        self.onCommit?()
        return nil
      case 53:
        self.onCancel?()
        return nil
      default:
        return event
      }
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    selectedIndex = 0
    reload(previewSelection: true)
  }

  func moveSelection(_ delta: Int) {
    guard !visibleThemes.isEmpty else { return }
    selectedIndex = min(max(selectedIndex + delta, 0), visibleThemes.count - 1)
    previewSelectedTheme()
    updateRows()
    scrollSelectionToVisible()
  }

  func commitSelection() {
    guard !didFinish else { return }
    didFinish = true
    removeKeyEventMonitor()
    if visibleThemes.indices.contains(selectedIndex) {
      preferences.previewTheme(visibleThemes[selectedIndex])
    }
    preferences.commitThemePreview()
  }

  func cancelPresentation() {
    guard !didFinish else { return }
    didFinish = true
    removeKeyEventMonitor()
    preferences.cancelThemePreview()
  }

  private func removeKeyEventMonitor() {
    guard let keyEventMonitor else { return }
    NSEvent.removeMonitor(keyEventMonitor)
    self.keyEventMonitor = nil
  }

  private func reload(previewSelection: Bool) {
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    visibleThemes = query.isEmpty
      ? allThemes
      : allThemes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    let activeName = preferences.activeTheme.name
    selectedIndex = visibleThemes.firstIndex(where: { $0.name == activeName }) ?? 0
    rowsStack.arrangedSubviews.forEach {
      rowsStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    if visibleThemes.isEmpty {
      let empty = makeLabel("没有匹配的主题", size: 12, color: SettingsTheme.secondaryInk)
      empty.alignment = .center
      rowsStack.addArrangedSubview(empty)
      empty.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
      empty.heightAnchor.constraint(equalToConstant: 52).isActive = true
      return
    }
    for (index, theme) in visibleThemes.enumerated() {
      let row = ThemeSwitcherRowView(theme: theme)
      row.identifier = NSUserInterfaceItemIdentifier("theme-switcher-row-\(theme.id)")
      row.onHover = { [weak self] in self?.select(index: index, preview: true) }
      row.onActivate = { [weak self] in
        self?.select(index: index, preview: true)
        self?.onCommit?()
      }
      rowsStack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
      row.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    updateRows()
    if previewSelection { previewSelectedTheme() }
  }

  private func select(index: Int, preview: Bool) {
    guard visibleThemes.indices.contains(index) else { return }
    selectedIndex = index
    if preview { previewSelectedTheme() }
    updateRows()
  }

  private func previewSelectedTheme() {
    guard visibleThemes.indices.contains(selectedIndex) else { return }
    preferences.previewTheme(visibleThemes[selectedIndex])
  }

  private func updateRows() {
    for (index, row) in rowsStack.arrangedSubviews.enumerated() {
      (row as? ThemeSwitcherRowView)?.setSelected(index == selectedIndex)
    }
  }

  private func scrollSelectionToVisible() {
    guard rowsStack.arrangedSubviews.indices.contains(selectedIndex) else { return }
    rowsStack.arrangedSubviews[selectedIndex].scrollToVisible(
      rowsStack.arrangedSubviews[selectedIndex].bounds)
  }
}

/// 单行主题项目。右侧四个色点与 Otty 一样提供快速视觉识别，分别展示终端前景、
/// 终端背景、ANSI red 与 ANSI blue；完整主题仍由主工作区实时预览，而非依赖色点猜测。
@MainActor
private final class ThemeSwitcherRowView: NSButton {
  var onHover: (() -> Void)?
  var onActivate: (() -> Void)?
  private var trackingArea: NSTrackingArea?

  init(theme: TerminalTheme) {
    super.init(frame: .zero)
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 7
    target = self
    action = #selector(activate)
    setAccessibilityLabel(theme.name)

    let label = makeLabel(theme.name, size: 13.5, color: SettingsTheme.ink)
    let dots = NSStackView()
    dots.orientation = .horizontal
    dots.spacing = 6
    dots.alignment = .centerY
    let palette = theme.palette
    let colors = [
      palette.foreground,
      palette.renderedTerminalBackground,
      palette.ansiColors.indices.contains(1) ? palette.ansiColors[1] : palette.accent,
      palette.ansiColors.indices.contains(4) ? palette.ansiColors[4] : palette.accent,
    ]
    for color in colors {
      let dot = NSView()
      dot.wantsLayer = true
      dot.layer?.backgroundColor = NSColor(color).cgColor
      dot.layer?.cornerRadius = 4
      dot.layer?.borderWidth = 0.5
      dot.layer?.borderColor = SettingsTheme.hairline.cgColor
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
      dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
      dots.addArrangedSubview(dot)
    }
    label.translatesAutoresizingMaskIntoConstraints = false
    dots.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    addSubview(dots)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      dots.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
      dots.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: dots.leadingAnchor, constant: -12),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    if let trackingArea { removeTrackingArea(trackingArea) }
    let trackingArea = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
    addTrackingArea(trackingArea)
    self.trackingArea = trackingArea
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) { onHover?() }

  func setSelected(_ selected: Bool) {
    layer?.backgroundColor =
      selected ? SettingsTheme.ink.withAlphaComponent(0.075).cgColor : NSColor.clear.cgColor
  }

  @objc private func activate() { onActivate?() }
}
