// 浮动窗「Token」页：区间切换、总量卡、按 Agent / 按项目排行、活动热力图。
import AppKit
import AsterCore
import Foundation
import os

/// Token 页。
///
/// 页面可见期间才扫描，从不定时。`activate()` 先用缓存把旧数据秒出来，再在后台增量刷新；
/// `suspend()` 取消在途扫描（服务会把半成品缓存落盘）并推进 generation，迟到的结果直接丢弃。
@MainActor
final class UsageTokenSectionController: UsageSectionController {
  /// 区间选择的持久化键。
  static let rangeDefaultsKey = "aster.usage.token-range.v1"
  private static let contentInset: CGFloat = 12

  private let service: TokenStatsService
  private let defaults: UserDefaults
  private let timeZone: TimeZone

  private let contentStack = NSStackView()
  private let updatingLabel = makeLabel(L("更新中"), size: 10, color: AsterTheme.tertiaryInk)
  private let progressLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
  private let progressBar = NSProgressIndicator()
  private let heatmap = TokenHeatmapView()
  private let heatmapCaption = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
  private var rangeBar: UsageSegmentedControl?

  /// 项目卡及其行。展开块要原地插在某一行下方，所以这两个引用必须活过一次渲染。
  private var projectsCard: UsageTokenCardView?
  private var projectRows: [String: UsageTokenProjectRow] = [:]
  private var expansionView: NSView?

  private var samples: [TokenSample] = []
  /// 是否已经拿到过一次结果。决定空数据时显示进度还是「还没有数据」。
  private var didReceiveSamples = false
  private var isActive = false
  private var loadTask: Task<Void, Never>?
  /// 每次 activate / suspend 都自增，迟到的异步结果靠它识别并丢弃。
  private var generation: UInt64 = 0

  private(set) var summary: TokenStatsSummary?
  /// 当前展开了热力图的项目键；同一时刻只展开一行。
  private(set) var expandedProject: String?
  private(set) var range: TokenStatsRange

  /// 是否还有扫描在途。页面挂起后必须为 false。
  var hasInFlightLoad: Bool { loadTask != nil }

  init(
    service: TokenStatsService, defaults: UserDefaults = .standard, timeZone: TimeZone = .current
  ) {
    self.service = service
    self.defaults = defaults
    self.timeZone = timeZone
    let stored = defaults.string(forKey: Self.rangeDefaultsKey) ?? ""
    range = TokenStatsRange(rawValue: stored) ?? .sevenDays
  }

  deinit {
    loadTask?.cancel()
  }

  // MARK: - UsageSectionController

  private(set) lazy var view: NSView = makeView()

  func activate() {
    guard !isActive else { return }
    isActive = true
    _ = view
    startLoad()
  }

  func suspend() {
    isActive = false
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  /// 表头刷新按钮。页面已经是激活态时 `activate()` 会被 `isActive` 挡掉，所以直接再扫一次；
  /// 引擎是增量的，重扫只付新增文件的代价。
  func refreshRequested() {
    guard isActive else {
      activate()
      return
    }
    startLoad()
  }

  // MARK: - 取数

  /// 先用缓存秒出旧数据，再跑一次增量扫描。
  private func startLoad() {
    generation &+= 1
    let token = generation
    loadTask?.cancel()
    // 引擎每处理完一个文件回调一次进度，冷扫有几千次；节流器保证最多每 100ms 回一次主线程。
    let throttle = TokenScanProgressThrottle { [weak self] progress in
      self?.updateProgress(progress, generation: token)
    }
    loadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if let cached = await self.service.cachedSamples() {
        guard self.generation == token else { return }
        self.apply(samples: cached)
      }
      let scanned = await self.service.load(progress: { throttle.report($0) })
      guard self.generation == token else { return }
      self.loadTask = nil
      self.apply(samples: scanned)
    }
  }

  /// 刷新进度文字与进度条。只动这两个控件，不重建页面结构。
  private func updateProgress(_ progress: TokenScanProgress, generation token: UInt64) {
    guard generation == token else { return }
    progressLabel.stringValue = L(
      "正在统计本机用量… \(String(progress.completed)) / \(String(progress.total))")
    progressBar.doubleValue =
      progress.total > 0 ? Double(progress.completed) / Double(progress.total) * 100 : 0
  }

  /// 用一批样本刷新页面。内部可见：测试从这里直接喂样本，不必真的扫描磁盘。
  func apply(samples: [TokenSample]) {
    self.samples = samples
    didReceiveSamples = true
    refreshSummary()
    rebuild()
  }

  /// 切换区间。选择立即持久化，下次打开浮动窗还是这一档。
  func selectRange(_ range: TokenStatsRange) {
    guard range != self.range else { return }
    self.range = range
    defaults.set(range.rawValue, forKey: Self.rangeDefaultsKey)
    rangeBar?.select(range.rawValue)
    refreshSummary()
    rebuild()
  }

  /// 展开或收起某个项目的热力图。再点同一行收起。
  func toggleProject(_ key: String) {
    setExpandedProject(expandedProject == key ? nil : key)
  }

  private func refreshSummary() {
    summary = TokenStatsSummary.make(samples: samples, range: range, today: today)
  }

  /// 今天的本地日整数。与扫描引擎口径一致：两边都走 `LocalDayStamper`，同一个时区。
  private var today: Int { LocalDayStamper.today(zone: timeZone) }

  // MARK: - 视图

  private func makeView() -> NSView {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 10
    contentStack.edgeInsets = NSEdgeInsets(
      top: Self.contentInset, left: Self.contentInset, bottom: Self.contentInset,
      right: Self.contentInset)

    progressBar.style = .bar
    progressBar.isIndeterminate = false
    progressBar.controlSize = .small
    progressBar.minValue = 0
    progressBar.maxValue = 100
    progressBar.identifier = NSUserInterfaceItemIdentifier("usage-token-progress")
    updatingLabel.identifier = NSUserInterfaceItemIdentifier("usage-token-updating")
    heatmap.identifier = NSUserInterfaceItemIdentifier("usage-token-year-heatmap")
    heatmapCaption.lineBreakMode = .byWordWrapping
    heatmapCaption.maximumNumberOfLines = 0

    let document = FlippedDocumentView()
    document.addSubview(contentStack)
    let scroll = NSScrollView()
    scroll.identifier = NSUserInterfaceItemIdentifier("usage-token-section")
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.hasHorizontalScroller = false
    scroll.horizontalScrollElasticity = .none
    scroll.documentView = document
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: contentStack.bottomAnchor),
    ])
    rebuild()
    return scroll
  }

  // MARK: - 渲染

  /// 重建整页内容。区间与样本变化走这里；展开 / 收起项目不走，它只原地换一块。
  private func rebuild() {
    projectsCard = nil
    projectRows = [:]
    expansionView = nil
    for arranged in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }
    addFullWidth(makeHeaderRow())

    guard let summary, !samples.isEmpty else {
      addFullWidth(didReceiveSamples ? makeEmptyView() : makeProgressView())
      return
    }

    addFullWidth(makeUsageTokenTotalsCard(summary.totals))
    if !summary.providers.isEmpty { addFullWidth(makeAgentsCard(summary)) }
    if !summary.projects.isEmpty { addFullWidth(makeProjectsCard(summary)) }
    addFullWidth(makeYearHeatmapCard())
  }

  /// 顶部：左边不打扰的「更新中」字样，右上角区间分段控件。
  ///
  /// 分段控件与页签、配额页共用 `UsageSegmentedControl`，三处样式才不会各走各的。
  private func makeHeaderRow() -> NSView {
    let items = TokenStatsRange.allCases.map {
      UsageSegmentedControl.Item(id: $0.rawValue, title: usageTokenRangeTitle($0))
    }
    let bar = UsageSegmentedControl(
      items: items, selected: range.rawValue, identifierPrefix: "usage-token-range"
    ) { [weak self] id in
      guard let range = TokenStatsRange(rawValue: id) else { return }
      self?.selectRange(range)
    }
    bar.setContentHuggingPriority(.required, for: .horizontal)
    bar.setContentCompressionResistancePriority(.required, for: .horizontal)
    rangeBar = bar
    updatingLabel.isHidden = !hasInFlightLoad || samples.isEmpty
    // 「更新中」在窄面板里先让位：分段控件是可点的，截断了就没法用。
    updatingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [updatingLabel, spacer, bar])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    row.distribution = .fill
    return row
  }

  private func makeEmptyView() -> NSView {
    let label = makeLabel(L("还没有 token 用量数据。"), size: 11, color: AsterTheme.secondaryInk)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
  }

  /// 首次冷扫时的进度块。有缓存时永远不显示，改用右上角的「更新中」。
  private func makeProgressView() -> NSView {
    // 第一次进度回调之前没有分母可报，先只说在统计，不写「0 / 0」这种看着像卡住的数字。
    if progressLabel.stringValue.isEmpty {
      progressLabel.stringValue = L("正在统计本机用量…")
    }
    let stack = NSStackView(views: [progressLabel, progressBar])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    progressBar.translatesAutoresizingMaskIntoConstraints = false
    progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return stack
  }

  /// 按 Agent 卡。每个 provider 一行：图标 + 名称、占比、数值。
  private func makeAgentsCard(_ summary: TokenStatsSummary) -> NSView {
    let card = UsageTokenCardView()
    card.identifier = NSUserInterfaceItemIdentifier("usage-token-agents")
    card.addRow(makeUsageTokenSectionTitle(L("按 Agent")))
    let total = summary.totals.total
    for row in summary.providers {
      card.addRow(
        UsageTokenAgentRow(
          provider: row.provider, value: row.totals.total,
          share: total > 0 ? Double(row.totals.total) / Double(total) : 0,
          tooltip: TokenNumberText.breakdown(row.totals)))
    }
    return card
  }

  /// 按项目卡。tooltip 给出完整路径与四列明细——行里只放得下最后一段目录名。
  private func makeProjectsCard(_ summary: TokenStatsSummary) -> NSView {
    let card = UsageTokenCardView()
    card.identifier = NSUserInterfaceItemIdentifier("usage-token-projects")
    card.addRow(makeUsageTokenSectionTitle(L("按项目")))
    for row in summary.projects {
      let path = row.key.isEmpty ? row.name : row.key
      let view = UsageTokenProjectRow(
        key: row.key, name: row.name, value: row.totals.total, share: row.share,
        tooltip: "\(path)\n\(TokenNumberText.breakdown(row.totals))"
      ) { [weak self] in
        self?.toggleProject(row.key)
      }
      card.addRow(view)
      projectRows[row.key] = view
    }
    projectsCard = card

    // 切区间后重建这张卡，展开态要跟着回来；那个项目在新区间里没有行了就自动收起。
    if let key = expandedProject {
      if let row = projectRows[key] {
        row.setExpanded(true)
        insertExpansion(for: key)
      } else {
        expandedProject = nil
      }
    }
    return card
  }

  /// 原地插入 / 移除展开块，不重建整页：整页重建会把滚动位置顶回最上面。
  private func setExpandedProject(_ key: String?) {
    if let previous = expandedProject { projectRows[previous]?.setExpanded(false) }
    if let expansionView, let projectsCard { projectsCard.removeRow(expansionView) }
    expansionView = nil
    expandedProject = key
    guard let key, let row = projectRows[key] else { return }
    row.setExpanded(true)
    insertExpansion(for: key)
  }

  /// 把展开块插在对应项目行的正下方。
  private func insertExpansion(for key: String) {
    guard let projectsCard, let row = projectRows[key],
      let index = projectsCard.rows.arrangedSubviews.firstIndex(of: row)
    else { return }
    let view = makeProjectExpansion(for: key)
    projectsCard.insertRow(view, at: index + 1)
    expansionView = view
  }

  /// 展开块：该项目自己的一年热力图加一行说明。
  ///
  /// 分位数刻度按项目各算各的（`TokenActivityHeatmap.cells` 已经这么做），项目之间差
  /// 两三个数量级，共用一套刻度会让小项目常年平铺在 1 级。
  private func makeProjectExpansion(for key: String) -> NSView {
    let daily = TokenStatsSummary.dailyTotals(samples: samples, project: key)
    let today = self.today
    let view = TokenHeatmapView()
    view.identifier = NSUserInterfaceItemIdentifier("usage-token-project-heatmap")
    // 与底部那张走同一套布局：月份刻度照画，窄到摆不下锚点月份时热力图自己会把那行收掉。
    view.apply(cells: TokenActivityHeatmap.cells(dailyTotals: daily, today: today))

    let windowTotal = TokenActivityHeatmap.windowTotal(dailyTotals: daily, today: today)
    let caption = makeLabel(
      L("过去一年共 \(TokenNumberText.compact(windowTotal)) token"), size: 10,
      color: AsterTheme.tertiaryInk)

    let stack = NSStackView(views: [view, caption])
    stack.identifier = NSUserInterfaceItemIdentifier("usage-token-project-expansion")
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return stack
  }

  /// 底部：全部项目合计的一年热力图。
  ///
  /// 它始终是「过去一年」，和上面按区间汇总的数字不是同一个量，所以说明文字里把窗口写明，
  /// 避免两个对不上的数字被当成统计错误。
  private func makeYearHeatmapCard() -> NSView {
    let daily = TokenStatsSummary.dailyTotals(samples: samples, project: nil)
    let today = self.today
    heatmap.apply(cells: TokenActivityHeatmap.cells(dailyTotals: daily, today: today))
    let windowTotal = TokenActivityHeatmap.windowTotal(dailyTotals: daily, today: today)
    heatmapCaption.stringValue = L("过去一年共 \(TokenNumberText.compact(windowTotal)) token")

    let card = UsageTokenCardView()
    card.identifier = NSUserInterfaceItemIdentifier("usage-token-year")
    card.addRow(heatmap)
    card.addRow(heatmapCaption)
    return card
  }

  /// 每一行都要撑满内容宽度；stack 的 `.leading` 对齐只保证左边对齐。
  private func addFullWidth(_ view: NSView) {
    contentStack.addArrangedSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(
      equalTo: contentStack.widthAnchor, constant: -Self.contentInset * 2
    ).isActive = true
  }
}

/// 扫描进度节流器。
///
/// 引擎每处理完一个文件就回调一次，冷扫有几千次；逐次 hop 到主线程刷 UI 会把主线程淹掉，
/// 而进度条上一个文件的差别人眼根本看不出来。最后一次（完成）不节流，保证进度条能停在 100%。
final class TokenScanProgressThrottle: Sendable {
  /// 两次回主线程之间的最小间隔。
  static let interval: TimeInterval = 0.1

  private let sink: @Sendable @MainActor (TokenScanProgress) -> Void
  private let lastSentAt = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

  init(sink: @escaping @Sendable @MainActor (TokenScanProgress) -> Void) {
    self.sink = sink
  }

  /// 后台线程调用。
  func report(_ progress: TokenScanProgress) {
    let now = Date().timeIntervalSinceReferenceDate
    let shouldSend = lastSentAt.withLock { last -> Bool in
      let due = progress.completed >= progress.total || now - last >= Self.interval
      guard due else { return false }
      last = now
      return true
    }
    guard shouldSend else { return }
    let sink = self.sink
    Task { @MainActor in sink(progress) }
  }
}
