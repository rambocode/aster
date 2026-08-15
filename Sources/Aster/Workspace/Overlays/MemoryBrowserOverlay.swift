import AppKit
import AsterCore
import AsterMemory
import Foundation

/// Session Memory 的浏览与管理界面（PRD §89：用户必须能看到 Agent 拿到了哪些上下文）。
///
/// 三个分段共用同一套「左列表 + 右正文 + 底部操作」骨架：
/// - **Memory**：查看、禁用/启用、删除。禁用后 MCP 检索完全不可见。
/// - **Task**：查看 Task 关联的会话与 Memory，把当前会话归入 Task，或标记完成。
/// - **Context 记录**：每一次 Agent 取走上下文的留痕。
///
/// 全部数据库读取都在后台执行；主线程只做列表与文本的装配。

// MARK: - 数据装载

/// 一次装载得到的全部列表数据。跨隔离边界传递，因此只含值类型。
private struct MemoryBrowserPayload: Sendable {
  var isStoreAvailable = false
  var memories: [MemoryRecord] = []
  var tasks: [TaskDescriptor] = []
  var receipts: [ContextReceipt] = []
  /// task id → 关联会话数与 Memory 数，用于列表副标题。
  var taskCounts: [UUID: (sessions: Int, memories: Int)] = [:]
}

/// 选中项的明细。与列表分开装载：列表一次拿全，明细只在选中时查。
private struct MemoryBrowserDetail: Sendable {
  var text = ""
  var sources: [MemorySourceRef] = []
}

// MARK: - 列表行

/// 列表行按钮：悬停有底色、光标变手型、选中有强调底色。
/// 无边框 `NSButton` 默认对指针毫无反馈，看上去和静态文本一样（CLAUDE.md 交互设计）。
@MainActor
final class MemoryBrowserRowButton: NSButton {
  private let handler: () -> Void
  private var hoverArea: NSTrackingArea?
  private var isHovering = false
  var isSelectedRow = false {
    didSet { applyBackground() }
  }

  init(item: MemoryListItem, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .inline
    wantsLayer = true
    layer?.cornerRadius = 6
    imagePosition = .noImage
    alignment = .left
    attributedTitle = Self.makeTitle(item: item)
    target = self
    action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 46).isActive = true
    applyBackground()
  }

  required init?(coder: NSCoder) { nil }

  /// 两行富文本：标题一行、元信息一行。已禁用的条目整体降透明度，
  /// 让「这条不会再进入 Agent 上下文」在列表里一眼可见。
  private static func makeTitle(item: MemoryListItem) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.lineSpacing = 1
    let titleColor = item.isDisabled ? AsterTheme.tertiaryInk : AsterTheme.ink
    let result = NSMutableAttributedString(
      string: item.title + "\n",
      attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: titleColor,
        .paragraphStyle: paragraph,
      ])
    result.append(
      NSAttributedString(
        string: item.subtitle,
        attributes: [
          .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
          .foregroundColor: AsterTheme.secondaryInk,
          .paragraphStyle: paragraph,
        ]))
    return result
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverArea = area
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    applyBackground()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    applyBackground()
  }

  private func applyBackground() {
    let color: NSColor
    if isSelectedRow {
      color = AsterTheme.accent.withAlphaComponent(0.18)
    } else if isHovering {
      color = AsterTheme.accent.withAlphaComponent(0.08)
    } else {
      color = .clear
    }
    layer?.backgroundColor = color.cgColor
  }

  @objc private func invoke() { handler() }
}

// MARK: - 主控制器

@MainActor
final class MemoryBrowserViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  /// nil 表示不按项目过滤（用户当前 Pane 无法解析出项目时）。
  private let projectPath: String?
  private let projectName: String

  private let segmented = NSSegmentedControl()
  private let search = OverlaySearchField()
  private let listStack = NSStackView()
  private let detailTitle = makeLabel("", size: 13, weight: .semibold)
  private let detailSubtitle = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
  private let detailText = NSTextView()
  private let statusLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
  private let primaryButton = NSButton(title: "", target: nil, action: nil)
  /// PINNED 固定席位的开关（zero-mem 教训：关键事实不该依赖检索排名）。
  private let pinButton = NSButton(title: "", target: nil, action: nil)
  private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
  /// Task 的状态流转。用下拉而不是「标记完成」单个按钮：状态是三态机，
  /// 用户既要能完成也要能放弃，还要能把关掉的 Task 重新打开。
  private let taskStatusPopUp = NSPopUpButton()

  private var tab: MemoryBrowserTab
  private var payload = MemoryBrowserPayload()
  /// 当前分段过滤后的列表条目，与 `listStack` 的行一一对应。
  private var items: [MemoryListItem] = []
  private var selectedID: UUID?
  private var loadGeneration = 0

  /// `onClose` 由宿主（浮层或面板窗口）接管关闭动作，控制器本身不假设自己怎么被展示。
  var onClose: (() -> Void)?

  init(
    model: AppModel,
    projectPath: String?,
    initialTab: MemoryBrowserTab = .memories,
    selectedTaskID: UUID? = nil
  ) {
    self.model = model
    self.projectPath = projectPath
    projectName = projectPath.map { ($0 as NSString).lastPathComponent } ?? "全部项目"
    tab = initialTab
    selectedID = selectedTaskID
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let host = NSView()
    host.wantsLayer = true
    // 浮层脱离工作区的 NSVisualEffectView 宿主，按主题 surface 取色（CLAUDE.md 主题规则）。
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.99).cgColor
    host.layer?.cornerRadius = 12
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.cgColor
    host.shadow = NSShadow()
    host.shadow?.shadowBlurRadius = 24
    host.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)

    segmented.segmentCount = MemoryBrowserTab.allCases.count
    segmented.segmentStyle = .rounded
    segmented.trackingMode = .selectOne
    for (index, value) in MemoryBrowserTab.allCases.enumerated() {
      segmented.setLabel(value.displayName, forSegment: index)
      segmented.setWidth(84, forSegment: index)
    }
    segmented.selectedSegment = MemoryBrowserTab.allCases.firstIndex(of: tab) ?? 0
    segmented.target = self
    segmented.action = #selector(segmentChanged(_:))

    search.placeholderString = "搜索标题、正文与摘要…"
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onCancel = { [weak self] in self?.onClose?() }
    // 回车把焦点交给正文：键盘用户由此可以滚动与选取正文。刻意不绑定到
    // 禁用/删除 —— 破坏性操作不该被一次误按回车触发。
    search.onActivate = { [weak self] _ in
      guard let self else { return }
      self.detailText.window?.makeFirstResponder(self.detailText)
    }

    let refresh = ActionButton(symbol: "arrow.clockwise") { [weak self] in self?.reload() }
    refresh.toolTip = "重新读取"
    let close = ActionButton(symbol: "xmark") { [weak self] in self?.onClose?() }
    close.toolTip = "关闭"
    let header = NSStackView(views: [segmented, search, refresh, close])
    header.orientation = .horizontal
    header.spacing = 8

    listStack.orientation = .vertical
    listStack.spacing = 2
    listStack.alignment = .leading
    let listScroll = NSScrollView()
    listScroll.hasVerticalScroller = true
    listScroll.drawsBackground = false
    listScroll.documentView = listStack
    listStack.translatesAutoresizingMaskIntoConstraints = false
    listStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor).isActive = true
    listScroll.translatesAutoresizingMaskIntoConstraints = false
    listScroll.widthAnchor.constraint(equalToConstant: 300).isActive = true

    detailTitle.lineBreakMode = .byTruncatingTail
    detailSubtitle.lineBreakMode = .byTruncatingTail
    // NSTextView 进 NSScrollView 必须自己接好可变高度与宽度跟随，
    // 否则 documentView 停在零尺寸，正文区看起来永远是空的。
    detailText.isEditable = false
    detailText.isSelectable = true
    detailText.drawsBackground = true
    detailText.backgroundColor = AsterTheme.paper
    detailText.textColor = AsterTheme.ink
    detailText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    detailText.textContainerInset = NSSize(width: 12, height: 12)
    detailText.isVerticallyResizable = true
    detailText.isHorizontallyResizable = false
    detailText.autoresizingMask = [.width]
    detailText.textContainer?.widthTracksTextView = true
    let detailScroll = NSScrollView()
    detailScroll.hasVerticalScroller = true
    detailScroll.drawsBackground = false
    detailScroll.documentView = detailText
    let detailColumn = NSStackView(views: [detailTitle, detailSubtitle, detailScroll])
    detailColumn.orientation = .vertical
    detailColumn.spacing = 4
    detailColumn.alignment = .leading
    detailTitle.translatesAutoresizingMaskIntoConstraints = false
    detailSubtitle.translatesAutoresizingMaskIntoConstraints = false
    detailTitle.widthAnchor.constraint(equalTo: detailColumn.widthAnchor).isActive = true
    detailSubtitle.widthAnchor.constraint(equalTo: detailColumn.widthAnchor).isActive = true

    let body = NSStackView(views: [listScroll, detailColumn])
    body.orientation = .horizontal
    body.spacing = 10
    body.distribution = .fill

    for button in [primaryButton, pinButton, deleteButton] {
      button.bezelStyle = .rounded
      button.target = self
    }
    primaryButton.action = #selector(primaryAction(_:))
    pinButton.action = #selector(pinAction(_:))
    deleteButton.action = #selector(deleteAction(_:))
    deleteButton.contentTintColor = AsterTheme.warning
    taskStatusPopUp.addItems(withTitles: TaskStatus.allCases.map(\.displayName))
    taskStatusPopUp.target = self
    taskStatusPopUp.action = #selector(taskStatusChanged(_:))
    taskStatusPopUp.toolTip = "改变这个 Task 的状态"
    let footer = NSStackView(
      views: [statusLabel, NSView(), taskStatusPopUp, deleteButton, pinButton, primaryButton])
    footer.orientation = .horizontal
    footer.spacing = 8

    let column = NSStackView(views: [header, body, footer])
    column.orientation = .vertical
    column.spacing = 10
    column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    host.addSubview(column)
    column.pinEdges(to: host)
    view = host

    renderList()
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  // MARK: - 事件

  func controlTextDidChange(_ obj: Notification) {
    renderList()
  }

  @objc private func segmentChanged(_ sender: NSSegmentedControl) {
    let index = sender.selectedSegment
    guard MemoryBrowserTab.allCases.indices.contains(index) else { return }
    tab = MemoryBrowserTab.allCases[index]
    selectedID = nil
    renderList()
  }

  private func moveSelection(_ delta: Int) {
    guard !items.isEmpty else { return }
    let current = items.firstIndex { $0.id == selectedID } ?? 0
    let next = (current + delta + items.count) % items.count
    selectedID = items[next].id
    updateSelection()
  }

  // MARK: - 装载

  /// 重新读取列表。数据库查询在后台执行；`loadGeneration` 让过期结果被丢弃，
  /// 避免连点刷新时旧结果覆盖新结果。
  private func reload() {
    loadGeneration += 1
    let generation = loadGeneration
    let path = projectPath
    statusLabel.stringValue = "读取中…"
    Task { [weak self] in
      let payload = await Self.loadPayload(projectPath: path)
      guard let self, generation == self.loadGeneration else { return }
      self.payload = payload
      self.renderList()
    }
  }

  private nonisolated static func loadPayload(projectPath: String?) async
    -> MemoryBrowserPayload
  {
    guard let reader = MemoryStoreAccess.makeReader() else { return MemoryBrowserPayload() }
    var payload = MemoryBrowserPayload()
    payload.isStoreAvailable = true
    // 管理界面必须显示 disabled 条目：看不到就无法重新启用。
    payload.memories =
      (try? reader.memories(projectPath: projectPath, includeDisabled: true, limit: 200)) ?? []
    payload.tasks = (try? reader.tasks(projectPath: projectPath, limit: 100)) ?? []
    payload.receipts = (try? reader.contextReceipts(projectPath: projectPath, limit: 200)) ?? []
    for task in payload.tasks {
      let sessions = (try? reader.taskDetail(id: task.id))?.sessions.count ?? 0
      let memories = (try? reader.memories(projectPath: nil, taskID: task.id, limit: 50))?.count ?? 0
      payload.taskCounts[task.id] = (sessions, memories)
    }
    return payload
  }

  // MARK: - 渲染

  private func renderList() {
    let now = Date()
    let query = search.stringValue
    switch tab {
    case .memories:
      let filtered = MemoryBrowsing.filter(payload.memories, query: query)
      items = filtered.map { MemoryBrowsing.listItem(for: $0, now: now) }
    case .tasks:
      let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let filtered = payload.tasks.filter {
        needle.isEmpty
          || $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
      items = filtered.map { task in
        let counts = payload.taskCounts[task.id] ?? (0, 0)
        return MemoryBrowsing.taskItem(
          for: task, sessionCount: counts.sessions, memoryCount: counts.memories, now: now)
      }
    case .receipts:
      let receipts = MemoryBrowsing.receiptItems(payload.receipts, now: now)
      let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let filtered =
        needle.isEmpty
        ? receipts
        : receipts.filter {
          $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
      items = filtered.map {
        MemoryListItem(
          id: $0.id,
          title: $0.title,
          subtitle: "\($0.subtitle) · \($0.timestampLabel)",
          typeLabel: "receipt",
          extractorLabel: "",
          timestampLabel: $0.timestampLabel,
          isDisabled: false
        )
      }
    }

    for view in listStack.arrangedSubviews { view.removeFromSuperview() }
    if items.isEmpty {
      listStack.addArrangedSubview(makeLabel(emptyMessage(), size: 11, color: AsterTheme.secondaryInk))
    } else {
      for item in items {
        let button = MemoryBrowserRowButton(item: item) { [weak self] in
          self?.selectedID = item.id
          self?.updateSelection()
        }
        listStack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
      }
    }
    if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
      selectedID = items.first?.id
    }
    updateSelection()
  }

  private func emptyMessage() -> String {
    guard payload.isStoreAvailable else {
      return "尚无记录。在设置 → 智能体 → Session Memory 中开启记录。"
    }
    switch tab {
    case .memories: return "该项目还没有 Memory。"
    case .tasks: return "该项目还没有 Task。用命令面板的“新建 Task”创建。"
    case .receipts: return "还没有 Agent 取用过上下文。"
    }
  }

  private func updateSelection() {
    for (index, view) in listStack.arrangedSubviews.enumerated() {
      guard let row = view as? MemoryBrowserRowButton, items.indices.contains(index) else {
        continue
      }
      row.isSelectedRow = items[index].id == selectedID
    }
    updateFooter()
    updateDetail()
  }

  private func updateFooter() {
    let scope = projectPath == nil ? "全部项目" : projectName
    statusLabel.stringValue = "\(scope) · \(items.count) 项"
    switch tab {
    case .memories:
      let record = selectedMemory
      primaryButton.isHidden = record == nil
      pinButton.isHidden = record == nil
      deleteButton.isHidden = record == nil
      taskStatusPopUp.isHidden = true
      primaryButton.isEnabled = true
      primaryButton.title = record?.status == .disabled ? "启用" : "禁用"
      primaryButton.toolTip =
        record?.status == .disabled
        ? "重新允许该 Memory 进入 Agent 检索" : "禁用后 MCP 检索完全看不到这条 Memory"
      // 固定与禁用互斥：禁用中的条目先启用才能固定，避免出现「固定但不可见」的矛盾态。
      pinButton.isEnabled = record?.status != .disabled
      pinButton.title = record?.status == .pinned ? "取消固定" : "固定"
      pinButton.toolTip =
        record?.status == .pinned
        ? "移出固定席位，回到普通检索"
        : "固定后无条件随项目上下文交给 Agent，不参与检索排名"
    case .tasks:
      let task = selectedTask
      primaryButton.isHidden = task == nil
      pinButton.isHidden = true
      deleteButton.isHidden = true
      taskStatusPopUp.isHidden = task == nil
      if let task, let index = TaskStatus.allCases.firstIndex(of: task.status) {
        taskStatusPopUp.selectItem(at: index)
      }
      // 已完成或已放弃的 Task 不再吸附新会话，按钮同步禁用，
      // 与「归入 Task」候选列表只列 open 的规则保持一致。
      primaryButton.isEnabled = task?.status == .open
      primaryButton.title = "归入当前会话"
      primaryButton.toolTip =
        task?.status == .open
        ? "把当前聚焦 Pane 的会话关联到这个 Task"
        : "只有进行中的 Task 可以关联新会话"
    case .receipts:
      primaryButton.isHidden = true
      pinButton.isHidden = true
      deleteButton.isHidden = true
      taskStatusPopUp.isHidden = true
    }
  }

  private var selectedMemory: MemoryRecord? {
    guard tab == .memories, let selectedID else { return nil }
    return payload.memories.first { $0.id == selectedID }
  }

  private var selectedTask: TaskDescriptor? {
    guard tab == .tasks, let selectedID else { return nil }
    return payload.tasks.first { $0.id == selectedID }
  }

  private func updateDetail() {
    guard let selectedID else {
      detailTitle.stringValue = ""
      detailSubtitle.stringValue = ""
      detailText.string = ""
      return
    }
    let item = items.first { $0.id == selectedID }
    detailTitle.stringValue = item?.title ?? ""
    detailSubtitle.stringValue = item?.subtitle ?? ""
    switch tab {
    case .memories:
      guard let record = selectedMemory else { return }
      // 先用已有正文立刻上屏，再补上需要额外查询的来源回链，避免选中后出现空白等待。
      detailText.string = MemoryBrowsing.detailText(for: record, sources: [])
      loadMemorySources(record)
    case .tasks:
      guard let task = selectedTask else { return }
      detailText.string = "读取中…"
      loadTaskDetail(task)
    case .receipts:
      guard let receipt = payload.receipts.first(where: { $0.id == selectedID }) else { return }
      detailText.string = receiptDetailText(receipt)
    }
  }

  private func loadMemorySources(_ record: MemoryRecord) {
    let identifier = record.id
    Task { [weak self] in
      let sources = await Self.fetchSources(memoryID: identifier)
      guard let self, self.selectedID == identifier, self.tab == .memories else { return }
      self.detailText.string = MemoryBrowsing.detailText(for: record, sources: sources)
    }
  }

  private nonisolated static func fetchSources(memoryID: UUID) async -> [MemorySourceRef] {
    guard let reader = MemoryStoreAccess.makeReader() else { return [] }
    return (try? reader.memorySources(memoryID: memoryID)) ?? []
  }

  private func loadTaskDetail(_ task: TaskDescriptor) {
    let identifier = task.id
    let now = Date()
    Task { [weak self] in
      let text = await Self.fetchTaskDetailText(task: task, now: now)
      guard let self, self.selectedID == identifier, self.tab == .tasks else { return }
      self.detailText.string = text
    }
  }

  private nonisolated static func fetchTaskDetailText(task: TaskDescriptor, now: Date) async
    -> String
  {
    guard let reader = MemoryStoreAccess.makeReader() else {
      return MemoryBrowsing.taskDetailText(
        task: task, sessions: [], memoryTitles: [], now: now)
    }
    let sessions = (try? reader.taskDetail(id: task.id))?.sessions ?? []
    let memories = (try? reader.memories(projectPath: nil, taskID: task.id, limit: 50)) ?? []
    let summaries = sessions.map { row in
      MemoryBrowsing.TaskSessionSummary(
        startedAt: row.descriptor.startedAt,
        agentProvider: row.descriptor.agentProvider,
        commandCount: row.commandCount,
        failureCount: row.failureCount,
        memoryTitle: row.memoryTitle
      )
    }
    return MemoryBrowsing.taskDetailText(
      task: task, sessions: summaries, memoryTitles: memories.map(\.title), now: now)
  }

  /// Receipt 正文把 memory id 还原成标题：只列 id 对用户没有意义，
  /// 「Agent 拿到了哪几条」才是这个页面存在的理由。
  private func receiptDetailText(_ receipt: ContextReceipt) -> String {
    var blocks: [String] = []
    blocks.append(
      "触发：\(receipt.trigger)　方式：\(receipt.deliveryMethod)　约 \(receipt.tokenEstimate) token")
    if let query = receipt.query, !query.isEmpty {
      blocks.append("查询：\(query)")
    }
    if receipt.memoryIDs.isEmpty {
      blocks.append("交付的 Memory\n· 无")
    } else {
      let lines = receipt.memoryIDs.map { identifier -> String in
        let title = UUID(uuidString: identifier)
          .flatMap { id in payload.memories.first { $0.id == id }?.title }
        return "· \(title ?? identifier)"
      }
      blocks.append((["交付的 Memory"] + lines).joined(separator: "\n"))
    }
    return blocks.joined(separator: "\n\n")
  }

  // MARK: - 操作

  @objc private func primaryAction(_ sender: NSButton) {
    switch tab {
    case .memories:
      guard let record = selectedMemory else { return }
      let next: MemoryStatus = record.status == .disabled ? .active : .disabled
      Task { [weak self] in
        await MemoryStoreAccess.writer.record(.updateMemoryStatus(id: record.id, status: next))
        await MemoryStoreAccess.writer.flush()
        self?.reload()
      }
    case .tasks:
      guard let task = selectedTask else { return }
      model.assignActiveSession(toTask: task)
      reload()
    case .receipts:
      break
    }
  }

  /// 固定 / 取消固定。pinned 是关键事实的固定席位：`get_project_context` 无条件带上，
  /// 不与检索排名竞争（zero-mem 五个身份类 live bug 的教训）。
  @objc private func pinAction(_ sender: NSButton) {
    guard tab == .memories, let record = selectedMemory, record.status != .disabled else { return }
    let next: MemoryStatus = record.status == .pinned ? .active : .pinned
    Task { [weak self] in
      await MemoryStoreAccess.writer.record(.updateMemoryStatus(id: record.id, status: next))
      await MemoryStoreAccess.writer.flush()
      self?.reload()
    }
  }

  /// Task 状态流转。只写状态与 `updatedAt`，不碰标题与摘要 —— 这里是状态机，
  /// 不是 Task 编辑器。
  @objc private func taskStatusChanged(_ sender: NSPopUpButton) {
    guard let task = selectedTask,
      TaskStatus.allCases.indices.contains(sender.indexOfSelectedItem)
    else { return }
    let next = TaskStatus.allCases[sender.indexOfSelectedItem]
    let updated = MemoryBrowsing.updating(task, status: next)
    guard updated != task else { return }
    Task { [weak self] in
      await MemoryStoreAccess.writer.record(.upsertTask(updated))
      await MemoryStoreAccess.writer.flush()
      self?.reload()
    }
  }

  @objc private func deleteAction(_ sender: NSButton) {
    guard tab == .memories, let record = selectedMemory, let window = view.window else { return }
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "删除这条 Memory？"
    alert.informativeText = """
      「\(record.title)」将被永久删除，连同它的来源回链一起消失，无法恢复。

      如果只是想让它不再进入 Agent 上下文，用“禁用”即可。
      """
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    alert.buttons.first?.hasDestructiveAction = true
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self, response == .alertFirstButtonReturn else { return }
      Task { [weak self] in
        await MemoryStoreAccess.writer.record(.deleteMemory(id: record.id))
        await MemoryStoreAccess.writer.flush()
        self?.selectedID = nil
        self?.reload()
      }
    }
  }
}

// MARK: - 面板宿主

/// Memory 浏览器的窗口宿主。
///
/// 用独立面板而不是工作区内浮层：浏览历史时用户往往要一边看结论一边在终端里操作，
/// 面板可以一直开着；关闭时 key window 自然回到工作区，AppKit 恢复原 first responder，
/// 因此不会出现浮层关闭后吞掉第一个字符的问题。
@MainActor
final class MemoryBrowserWindowController: NSWindowController, NSWindowDelegate {
  private let browser: MemoryBrowserViewController
  /// 窗口关闭时通知 `AppModel` 释放引用，避免第二次打开命中已关闭的窗口。
  var onClose: (() -> Void)?

  init(
    model: AppModel,
    projectPath: String?,
    initialTab: MemoryBrowserTab,
    selectedTaskID: UUID? = nil
  ) {
    browser = MemoryBrowserViewController(
      model: model,
      projectPath: projectPath,
      initialTab: initialTab,
      selectedTaskID: selectedTaskID
    )
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
      styleMask: [.titled, .closable, .resizable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = "Session Memory"
    panel.isReleasedWhenClosed = false
    panel.contentViewController = browser
    panel.setContentSize(NSSize(width: 880, height: 560))
    panel.minSize = NSSize(width: 720, height: 420)
    super.init(window: panel)
    panel.delegate = self
    browser.onClose = { [weak self] in self?.close() }
  }

  required init?(coder: NSCoder) { nil }

  func present() {
    window?.center()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }
}
