import AppKit
import AsterCore
import AsterMemory
import Foundation

/// Inspector 会话时间线（Outline 页内嵌区域）与 History（Memory）页的视图构造与可复用行。
///
/// 控制器（`DetailsPanelViewController`）只保留生命周期、身份校验与数据装配；
/// 这里放大块 AppKit 组装代码，避免把组合根继续堆大（CLAUDE.md 分层约束）。
/// 所有行模型都来自 `SessionTimelineProjection` 的纯函数投影，本文件不解析事件语义。

/// 会话时间线区域的两种浏览态。详情态只由用户显式点击 session 进入。
enum SessionHistoryMode: Equatable {
  case sessionList
  case sessionDetail(UUID)
}

/// 数据可用性。三态分开是为了让空状态说清楚原因：数据库不存在（用户从未开启记录）、
/// 查询已完成但没有数据、以及仍在读取，用户的下一步动作完全不同。
enum SessionHistoryStatus: Equatable {
  case loading
  /// 数据库不存在、打不开或 schema 版本不匹配。
  case unavailable
  case ready
}

/// session 列表查询的结果。跨 concurrency domain 传回主线程，必须是 Sendable 值。
enum SessionHistoryFetch: Sendable {
  case unavailable
  case sessions([SessionSummaryRow])
}

/// session 详情查询的结果：事件时间线 + 仍存在的 artifact + Memory 来源回链。
enum SessionHistoryDetailFetch: Sendable {
  case unavailable
  case detail(SessionDetail, artifactPaths: Set<String>, sources: [MemorySourceRef])
}

/// History（Memory）页项目记忆列表查询的结果。跨 concurrency domain 传回主线程。
enum ProjectMemoryFetch: Sendable {
  case unavailable
  case memories([MemoryRecord])
}

/// History 表格的一行。session 列表与事件时间线共用同一张表，
/// 因此模式切换只是替换行数组 + reloadData，不重建视图层级。
enum SessionHistoryRow {
  /// 分组标题（「会话」「Memory」「时间线」）。
  case sectionHeader(String)
  case session(SessionSummaryRow, durationText: String?)
  /// 该 session 已提炼的 Memory：标题 + 正文摘要 + 来源回链说明。
  case memory(title: String, body: String, sources: String)
  case timeline(SessionTimelineRow, isExpanded: Bool)
  /// 展开后的正文块。`isFullText` 表示当前显示的是 artifact 全文而非事件摘录。
  case expandedText(id: String, text: String, isFullText: Bool, canLoadFullText: Bool)
}

/// History 页各类行的固定高度。可变高度只出现在 memory 与展开正文块上。
enum SessionHistoryMetrics {
  static let sectionHeaderHeight: CGFloat = 26
  static let sessionRowHeight: CGFloat = 48
  static let timelineRowHeight: CGFloat = 40
  static let horizontalInset: CGFloat = 12
  /// 展开正文块的最大高度。超出部分靠「复制全文」而不是在表格行里再套一层滚动视图
  ///（嵌套滚动会抢走表格的滚轮事件）。
  static let expandedTextMaximumHeight: CGFloat = 260
  /// 展开正文块单次渲染的字符上限。artifact 可能有 1MiB，直接塞进 NSTextField
  /// 会让整张表的布局卡住。
  static let expandedTextDisplayLimit = 4_000

  /// 展开正文块的实际高度：按可用宽度实测文本，再夹到上限。
  static func expandedTextHeight(for text: String, width: CGFloat) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    let available = max(60, width - horizontalInset * 2 - 20)
    let bounding = (text as NSString).boundingRect(
      with: NSSize(width: available, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font]
    )
    // +34 给顶部间距与底部动作行留位置。
    return min(expandedTextMaximumHeight, max(48, ceil(bounding.height) + 34))
  }

  /// Memory 行高度：标题一行（截断，固定高）+ 正文按实测换行 + 可选的来源一行。
  static func memoryHeight(body: String, sources: String, width: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 11)
    let available = max(60, width - horizontalInset * 2)
    let bounding = (body as NSString).boundingRect(
      with: NSSize(width: available, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font]
    )
    let sourcesHeight: CGFloat = sources.isEmpty ? 0 : 16
    return max(56, ceil(bounding.height) + 40 + sourcesHeight)
  }
}

extension DetailsPanelViewController {
  /// 会话时间线区域根视图，嵌入 Outline 页下半部。只在 Outline 页首次展示时构建一次。
  /// 会话浏览本质上是「过去的时间线」，与 Outline 的现场命令时间线同页，History 页
  /// 留给项目记忆（Memory）。
  func makeSessionHistoryArea() -> NSView {
    let root = NSView()

    let back = IconHoverButton(symbol: "chevron.left") { [weak self] in
      self?.showHistorySessionList()
    }
    back.restingTint = AsterTheme.secondaryInk
    back.identifier = NSUserInterfaceItemIdentifier("details-history-back")
    back.toolTip = "返回会话列表"
    back.setAccessibilityLabel("返回会话列表")
    back.isHidden = true
    historyBackButton = back

    let title = makeLabel("会话", size: 11, weight: .semibold, color: AsterTheme.secondaryInk)
    title.lineBreakMode = .byTruncatingMiddle
    historyTitleLabel = title

    // 会话记录没有推送通道（session 可能在别的 Pane 或别的窗口里结束），除了展示时
    // 的过期重取，用户还需要一个确定性的手动刷新入口。
    let refresh = IconHoverButton(symbol: "arrow.clockwise") { [weak self] in
      self?.refreshHistoryFromUser()
    }
    refresh.identifier = NSUserInterfaceItemIdentifier("details-history-refresh")
    refresh.toolTip = "重新读取会话记录"
    refresh.setAccessibilityLabel("重新读取会话记录")
    refresh.restingTint = AsterTheme.tertiaryInk
    historyRefreshButton = refresh

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [back, title, spacer, refresh])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 4
    root.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false

    historyTable.identifier = NSUserInterfaceItemIdentifier("details-history-table")
    historyTable.headerView = nil
    historyTable.backgroundColor = .clear
    historyTable.style = .plain
    historyTable.rowHeight = SessionHistoryMetrics.timelineRowHeight
    historyTable.intercellSpacing = .zero
    historyTable.selectionHighlightStyle = .none
    historyTable.usesAutomaticRowHeights = false
    historyTable.dataSource = self
    historyTable.delegate = self
    if historyTable.tableColumns.isEmpty {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details-history-entry"))
      column.resizingMask = .autoresizingMask
      historyTable.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = historyTable
    root.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let empty = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
    empty.alignment = .center
    empty.maximumNumberOfLines = 3
    empty.lineBreakMode = .byWordWrapping
    root.addSubview(empty)
    empty.translatesAutoresizingMaskIntoConstraints = false
    historyEmptyLabel = empty

    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(
        equalTo: root.leadingAnchor, constant: SessionHistoryMetrics.horizontalInset),
      header.trailingAnchor.constraint(
        equalTo: root.trailingAnchor, constant: -SessionHistoryMetrics.horizontalInset),
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      empty.leadingAnchor.constraint(
        greaterThanOrEqualTo: root.leadingAnchor, constant: SessionHistoryMetrics.horizontalInset),
      empty.trailingAnchor.constraint(
        lessThanOrEqualTo: root.trailingAnchor, constant: -SessionHistoryMetrics.horizontalInset),
      empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20),
    ])
    applyHistoryRows()
    return root
  }

  /// History（Memory）页根视图：当前项目的记忆列表。只在首次展示时构建一次。
  /// 完整管理（搜索、筛选、固定、禁用、删除）由 Memory 浏览器承担，此页提供只读
  /// 概览与浏览器入口。
  func makeMemoryContent() -> NSView {
    let root = NSView()

    let title = makeLabel("Memory", size: 11, weight: .semibold, color: AsterTheme.secondaryInk)
    title.lineBreakMode = .byTruncatingMiddle
    memoryTitleLabel = title

    // 管理动作（固定/禁用/删除）在 Memory 浏览器里；面板只留一个显眼的入口。
    let manage = IconHoverButton(symbol: "arrow.up.forward.app") { [weak self] in
      self?.presentMemoryBrowserFromPanel()
    }
    manage.identifier = NSUserInterfaceItemIdentifier("details-memory-manage")
    manage.toolTip = "在 Memory 浏览器中管理"
    manage.setAccessibilityLabel("在 Memory 浏览器中管理")
    manage.restingTint = AsterTheme.tertiaryInk

    // Memory 没有推送通道（提炼在 session 结束后异步落库），除了进入本页时的过期重取，
    // 用户还需要一个确定性的手动刷新入口。
    let refresh = IconHoverButton(symbol: "arrow.clockwise") { [weak self] in
      self?.refreshMemoryFromUser()
    }
    refresh.identifier = NSUserInterfaceItemIdentifier("details-memory-refresh")
    refresh.toolTip = "重新读取项目记忆"
    refresh.setAccessibilityLabel("重新读取项目记忆")
    refresh.restingTint = AsterTheme.tertiaryInk
    memoryRefreshButton = refresh

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let header = NSStackView(views: [title, spacer, manage, refresh])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 4
    root.addSubview(header)
    header.translatesAutoresizingMaskIntoConstraints = false

    memoryTable.identifier = NSUserInterfaceItemIdentifier("details-memory-table")
    memoryTable.headerView = nil
    memoryTable.backgroundColor = .clear
    memoryTable.style = .plain
    memoryTable.rowHeight = SessionHistoryMetrics.timelineRowHeight
    memoryTable.intercellSpacing = .zero
    memoryTable.selectionHighlightStyle = .none
    memoryTable.usesAutomaticRowHeights = false
    memoryTable.dataSource = self
    memoryTable.delegate = self
    if memoryTable.tableColumns.isEmpty {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("details-memory-entry"))
      column.resizingMask = .autoresizingMask
      memoryTable.addTableColumn(column)
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = memoryTable
    root.addSubview(scroll)
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let empty = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
    empty.alignment = .center
    empty.maximumNumberOfLines = 3
    empty.lineBreakMode = .byWordWrapping
    root.addSubview(empty)
    empty.translatesAutoresizingMaskIntoConstraints = false
    memoryEmptyLabel = empty

    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(
        equalTo: root.leadingAnchor, constant: SessionHistoryMetrics.horizontalInset),
      header.trailingAnchor.constraint(
        equalTo: root.trailingAnchor, constant: -SessionHistoryMetrics.horizontalInset),
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      empty.leadingAnchor.constraint(
        greaterThanOrEqualTo: root.leadingAnchor, constant: SessionHistoryMetrics.horizontalInset),
      empty.trailingAnchor.constraint(
        lessThanOrEqualTo: root.trailingAnchor, constant: -SessionHistoryMetrics.horizontalInset),
      empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 20),
    ])
    applyMemoryRows()
    return root
  }

  /// 构造某一行的 cell。与 Outline/Files 一致走 `makeView(withIdentifier:)` 复用池，
  /// 数百条事件不会转成等量常驻控件。
  func makeHistoryRowView(_ row: SessionHistoryRow, in tableView: NSTableView) -> NSView? {
    switch row {
    case .sectionHeader(let title):
      let identifier = NSUserInterfaceItemIdentifier("details-history-section")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self)
        as? SessionHistorySectionHeaderView ?? SessionHistorySectionHeaderView(identifier: identifier)
      cell.configure(title: title)
      return cell
    case .session(let summary, let durationText):
      let identifier = NSUserInterfaceItemIdentifier("details-history-session-row")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self)
        as? SessionHistorySessionRowView ?? SessionHistorySessionRowView(identifier: identifier)
      cell.configure(summary: summary, durationText: durationText) { [weak self] in
        self?.showHistorySessionDetail(summary.descriptor.id)
      }
      return cell
    case .memory(let title, let body, let sources):
      let identifier = NSUserInterfaceItemIdentifier("details-history-memory")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self)
        as? SessionHistoryMemoryRowView ?? SessionHistoryMemoryRowView(identifier: identifier)
      cell.configure(title: title, body: body, sources: sources)
      return cell
    case .timeline(let timelineRow, let isExpanded):
      let identifier = NSUserInterfaceItemIdentifier("details-history-row")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self)
        as? SessionHistoryTimelineRowView ?? SessionHistoryTimelineRowView(identifier: identifier)
      cell.configure(row: timelineRow, isExpanded: isExpanded) { [weak self] in
        self?.toggleHistoryRowExpansion(timelineRow)
      }
      return cell
    case .expandedText(let id, let text, let isFullText, let canLoadFullText):
      let identifier = NSUserInterfaceItemIdentifier("details-history-output")
      let cell = tableView.makeView(withIdentifier: identifier, owner: self)
        as? SessionHistoryOutputRowView ?? SessionHistoryOutputRowView(identifier: identifier)
      cell.configure(
        text: text,
        isFullText: isFullText,
        canLoadFullText: canLoadFullText,
        loadFullText: { [weak self] in self?.loadHistoryArtifact(rowID: id) },
        copy: { [weak self] in self?.copyHistoryOutput(text) }
      )
      return cell
    }
  }

  /// 行高。History 的 memory 与展开正文块必须按实际文本测量，其余为固定值。
  func historyRowHeight(_ row: SessionHistoryRow, width: CGFloat) -> CGFloat {
    switch row {
    case .sectionHeader: SessionHistoryMetrics.sectionHeaderHeight
    case .session: SessionHistoryMetrics.sessionRowHeight
    case .timeline: SessionHistoryMetrics.timelineRowHeight
    case .memory(_, let body, let sources):
      SessionHistoryMetrics.memoryHeight(body: body, sources: sources, width: width)
    case .expandedText(_, let text, _, _):
      SessionHistoryMetrics.expandedTextHeight(for: text, width: width)
    }
  }
}

// MARK: - 行视图

/// 分组标题行。不可点，因此关闭悬停高亮——高亮会提示一个并不存在的动作。
@MainActor
final class SessionHistorySectionHeaderView: HoverHighlightRowView {
  private let label = NSTextField(labelWithString: "")

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    isHoverHighlightEnabled = false
    label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    label.textColor = AsterTheme.tertiaryInk
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: SessionHistoryMetrics.horizontalInset),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(title: String) {
    label.stringValue = title
  }
}

/// Session 列表行：时间 + provider/Shell + 命令与失败计数 + Memory 标题。
/// 整行可点进入详情，因此保留悬停底色与手型指针。
@MainActor
final class SessionHistorySessionRowView: HoverHighlightRowView {
  private let openButton = PointingHandButton()
  private let titleLabel = NSTextField(labelWithString: "")
  private let metaLabel = NSTextField(labelWithString: "")
  private let timeLabel = NSTextField(labelWithString: "")
  private let chevron = NSImageView()
  private var openAction: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    titleLabel.textColor = AsterTheme.ink
    titleLabel.lineBreakMode = .byTruncatingTail
    metaLabel.font = NSFont.systemFont(ofSize: 10)
    metaLabel.textColor = AsterTheme.secondaryInk
    metaLabel.lineBreakMode = .byTruncatingTail
    timeLabel.font = NSFont.systemFont(ofSize: 10)
    timeLabel.textColor = AsterTheme.tertiaryInk
    timeLabel.alignment = .right
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)
    chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    chevron.contentTintColor = AsterTheme.tertiaryInk
    chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)

    // 透明按钮铺满整行承担点击与指针反馈；文字由独立 label 绘制，避免按钮标题
    // 在两行布局里无法分别控制字重与颜色。
    openButton.isBordered = false
    openButton.title = ""
    openButton.target = self
    openButton.action = #selector(open)
    openButton.translatesAutoresizingMaskIntoConstraints = false

    for view in [titleLabel, metaLabel, timeLabel, chevron, openButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      openButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      openButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      openButton.topAnchor.constraint(equalTo: topAnchor),
      openButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      titleLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: SessionHistoryMetrics.horizontalInset),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -6),
      timeLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -4),
      timeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      chevron.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -SessionHistoryMetrics.horizontalInset),
      chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
      metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      metaLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(
    summary: SessionSummaryRow, durationText: String?, open: @escaping () -> Void
  ) {
    let descriptor = summary.descriptor
    let agent = descriptor.agentProvider ?? descriptor.shell.map {
      ($0 as NSString).lastPathComponent
    } ?? "Shell"
    titleLabel.stringValue = summary.memoryTitle ?? agent
    var parts = ["\(summary.commandCount) 条命令"]
    if summary.failureCount > 0 { parts.append("\(summary.failureCount) 条失败") }
    if summary.memoryTitle != nil { parts.append(agent) }
    // 未结束的 session 明说「进行中」，不用一个编造的时长填空。
    parts.append(durationText ?? "进行中")
    metaLabel.stringValue = parts.joined(separator: " · ")
    metaLabel.textColor = summary.failureCount > 0 ? AsterTheme.warning : AsterTheme.secondaryInk
    timeLabel.stringValue = RelativeTime.string(since: summary.endedAt ?? descriptor.startedAt)
    toolTip = descriptor.projectPath
    openAction = open
  }

  @objc private func open() { openAction?() }
}

/// Memory 卡片行：标题 + 正文摘要 + 来源回链说明。
@MainActor
final class SessionHistoryMemoryRowView: HoverHighlightRowView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let bodyLabel = NSTextField(labelWithString: "")
  private let sourcesLabel = NSTextField(labelWithString: "")

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    isHoverHighlightEnabled = false

    titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    titleLabel.textColor = AsterTheme.ink
    titleLabel.lineBreakMode = .byTruncatingTail
    bodyLabel.font = NSFont.systemFont(ofSize: 11)
    bodyLabel.textColor = AsterTheme.secondaryInk
    bodyLabel.lineBreakMode = .byWordWrapping
    bodyLabel.maximumNumberOfLines = 0
    sourcesLabel.font = NSFont.systemFont(ofSize: 10)
    sourcesLabel.textColor = AsterTheme.tertiaryInk
    sourcesLabel.lineBreakMode = .byTruncatingTail

    for view in [titleLabel, bodyLabel, sourcesLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    let inset = SessionHistoryMetrics.horizontalInset
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      sourcesLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      sourcesLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      sourcesLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 4),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(title: String, body: String, sources: String) {
    titleLabel.stringValue = title
    bodyLabel.stringValue = body
    sourcesLabel.stringValue = sources
    sourcesLabel.isHidden = sources.isEmpty
    toolTip = sources.isEmpty ? nil : sources
  }
}

/// 时间线事件行：图标 + 标题 + 副标题 + 状态标记 + transcript 来源标注。
/// 有可展开正文时整行可点，展开态由 chevron 方向直接表达。
@MainActor
final class SessionHistoryTimelineRowView: HoverHighlightRowView {
  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let sourceBadge = NSTextField(labelWithString: "")
  private let disclosure = NSImageView()
  private let toggleButton = PointingHandButton()
  private var toggleAction: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    iconView.contentTintColor = AsterTheme.tertiaryInk
    titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    titleLabel.textColor = AsterTheme.ink
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = NSFont.systemFont(ofSize: 9.5)
    subtitleLabel.textColor = AsterTheme.tertiaryInk
    subtitleLabel.lineBreakMode = .byTruncatingMiddle
    statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    statusLabel.alignment = .right
    statusLabel.setContentHuggingPriority(.required, for: .horizontal)
    // transcript 来源必须肉眼可辨：这些事件来自 Agent 自己的记录，不是终端实测。
    sourceBadge.font = NSFont.systemFont(ofSize: 9, weight: .medium)
    sourceBadge.textColor = AsterTheme.accent
    sourceBadge.setContentHuggingPriority(.required, for: .horizontal)
    disclosure.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
    disclosure.contentTintColor = AsterTheme.tertiaryInk

    toggleButton.isBordered = false
    toggleButton.title = ""
    toggleButton.target = self
    toggleButton.action = #selector(toggle)

    // 透明命中区必须最后添加：`NSTextField` 的 hitTest 会截住落在文字上的点击，
    // 放在下层的按钮就再也收不到事件。
    for view in [iconView, titleLabel, subtitleLabel, statusLabel, sourceBadge, disclosure, toggleButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    let inset = SessionHistoryMetrics.horizontalInset
    NSLayoutConstraint.activate([
      toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      toggleButton.topAnchor.constraint(equalTo: topAnchor),
      toggleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 14),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceBadge.leadingAnchor, constant: -4),
      sourceBadge.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -4),
      sourceBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -4),
      statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
      disclosure.widthAnchor.constraint(equalToConstant: 10),
      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
      subtitleLabel.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -6),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func configure(row: SessionTimelineRow, isExpanded: Bool, toggle: @escaping () -> Void) {
    iconView.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
    titleLabel.stringValue = row.title
    subtitleLabel.stringValue = row.subtitle
    subtitleLabel.isHidden = row.subtitle.isEmpty
    statusLabel.stringValue = row.status.displayText
    statusLabel.textColor = row.status.isFailure ? AsterTheme.warning : AsterTheme.tertiaryInk
    sourceBadge.stringValue = row.isTranscriptSourced ? "transcript" : ""
    sourceBadge.isHidden = !row.isTranscriptSourced
    let expandable = row.detail != nil
    disclosure.image = expandable
      ? NSImage(
        systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
        accessibilityDescription: isExpanded ? "收起输出" : "展开输出")
      : nil
    disclosure.isHidden = !expandable
    // 不可展开的行不接受点击，也不给悬停高亮与手型指针——否则是空承诺。
    toggleButton.isEnabled = expandable
    isHoverHighlightEnabled = expandable
    toolTip = row.isTranscriptSourced
      ? "来自 Agent transcript 的补录，非终端实测：\(row.subtitle.isEmpty ? row.title : row.subtitle)"
      : (row.subtitle.isEmpty ? row.title : row.subtitle)
    toggleAction = toggle
  }

  @objc private func toggle() { toggleAction?() }
}

/// 展开后的输出正文块：等宽正文 + 「查看全文 / 复制」动作。
@MainActor
final class SessionHistoryOutputRowView: HoverHighlightRowView {
  private let textLabel = NSTextField(labelWithString: "")
  private let background = NSView()
  /// 用 `PointingHandButton` 而不是普通按钮：动作链接必须给出手型指针反馈
  ///（CLAUDE.md「交互设计」）。
  private let fullTextButton = PointingHandButton()
  private let copyButton = PointingHandButton()
  private var loadFullTextAction: (() -> Void)?
  private var copyAction: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    isHoverHighlightEnabled = false

    background.wantsLayer = true
    background.layer?.cornerRadius = 6
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)

    textLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    textLabel.textColor = AsterTheme.secondaryInk
    textLabel.lineBreakMode = .byWordWrapping
    textLabel.maximumNumberOfLines = 0
    textLabel.isSelectable = true
    textLabel.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(textLabel)

    fullTextButton.identifier = NSUserInterfaceItemIdentifier("details-history-full-text")
    fullTextButton.target = self
    fullTextButton.action = #selector(loadFullText)
    copyButton.target = self
    copyButton.action = #selector(copyText)
    for (button, title) in [(fullTextButton, "查看全文"), (copyButton, "复制")] {
      button.isBordered = false
      button.alignment = .left
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [.foregroundColor: AsterTheme.accent, .font: NSFont.systemFont(ofSize: 10.5)]
      )
      button.translatesAutoresizingMaskIntoConstraints = false
      addSubview(button)
    }

    let inset = SessionHistoryMetrics.horizontalInset
    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 20),
      background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      background.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      textLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
      textLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
      textLabel.topAnchor.constraint(equalTo: background.topAnchor, constant: 5),
      background.bottomAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 5),
      fullTextButton.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      fullTextButton.topAnchor.constraint(equalTo: background.bottomAnchor, constant: 2),
      copyButton.leadingAnchor.constraint(equalTo: fullTextButton.trailingAnchor, constant: 8),
      copyButton.centerYAnchor.constraint(equalTo: fullTextButton.centerYAnchor),
    ])
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    background.layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.05).cgColor
  }

  func configure(
    text: String,
    isFullText: Bool,
    canLoadFullText: Bool,
    loadFullText: @escaping () -> Void,
    copy: @escaping () -> Void
  ) {
    let display = text.count > SessionHistoryMetrics.expandedTextDisplayLimit
      ? String(text.suffix(SessionHistoryMetrics.expandedTextDisplayLimit))
      : text
    textLabel.stringValue = display.isEmpty ? "（无输出内容）" : display
    // 已经是全文时不再提供入口：重复点击会反复读同一个文件。
    fullTextButton.isHidden = isFullText || !canLoadFullText
    copyButton.isHidden = display.isEmpty
    loadFullTextAction = loadFullText
    copyAction = copy
    applyAppearance()
  }

  @objc private func loadFullText() { loadFullTextAction?() }

  @objc private func copyText() { copyAction?() }
}
