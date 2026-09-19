// 浮动窗「Token」页：区间切换、按项目 / 按 Agent 排行、活动热力图。
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
  private var rangeBar: UsageTokenRangeBar?

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
    rangeBar?.select(range)
    refreshSummary()
    rebuild()
  }

  /// 展开或收起某个项目的热力图。再点同一行收起。
  func toggleProject(_ key: String) {
    expandedProject = expandedProject == key ? nil : key
    rebuild()
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
    contentStack.spacing = 8
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

  /// 重建整页内容。区间、样本、展开行任一变化都走这里；进度刷新不走。
  private func rebuild() {
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
    if !summary.providers.isEmpty {
      addFullWidth(makeUsageTokenSectionTitle(L("按 Agent")))
      for row in summary.providers { addFullWidth(makeProviderRow(row, total: summary.totals.total))
      }
    }
    if !summary.projects.isEmpty {
      addFullWidth(makeUsageTokenSectionTitle(L("按项目")))
      for row in summary.projects {
        addFullWidth(makeProjectRow(row))
        guard expandedProject == row.key else { continue }
        addFullWidth(makeProjectHeatmap(for: row.key))
      }
    }
    addFullWidth(makeYearHeatmap())
  }

  /// 顶部：左边区间 chip，右边不打扰的「更新中」字样。
  private func makeHeaderRow() -> NSView {
    let bar = UsageTokenRangeBar(selection: range) { [weak self] range in
      self?.selectRange(range)
    }
    rangeBar = bar
    updatingLabel.isHidden = !hasInFlightLoad || samples.isEmpty
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [bar, spacer, updatingLabel])
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

  private func makeProviderRow(_ row: TokenStatsSummary.ProviderRow, total: Int64) -> NSView {
    let view = UsageTokenShareRow(
      name: row.provider.displayName, value: row.totals.total,
      share: total > 0 ? Double(row.totals.total) / Double(total) : 0,
      tooltip: TokenNumberText.breakdown(row.totals))
    view.identifier = NSUserInterfaceItemIdentifier(
      "usage-token-agent-\(row.provider.rawValue)")
    return view
  }

  /// 项目行。tooltip 给出完整路径与四列明细——行里只放得下最后一段目录名。
  private func makeProjectRow(_ row: TokenStatsSummary.ProjectRow) -> NSView {
    let path = row.key.isEmpty ? row.name : row.key
    let view = UsageTokenShareRow(
      name: row.name, value: row.totals.total, share: row.share,
      tooltip: "\(path)\n\(TokenNumberText.breakdown(row.totals))",
      highlighted: expandedProject == row.key
    ) { [weak self] in
      self?.toggleProject(row.key)
    }
    view.identifier = NSUserInterfaceItemIdentifier("usage-token-project-\(row.key)")
    return view
  }

  /// 展开在项目行下方的小热力图。不画月份刻度，免得把行距撑开。
  private func makeProjectHeatmap(for key: String) -> NSView {
    let view = TokenHeatmapView()
    view.identifier = NSUserInterfaceItemIdentifier("usage-token-project-heatmap")
    view.showsMonthScale = false
    view.apply(
      cells: TokenActivityHeatmap.cells(
        dailyTotals: TokenStatsSummary.dailyTotals(samples: samples, project: key), today: today))
    return view
  }

  /// 底部：全部项目合计的一年热力图。
  ///
  /// 它始终是「过去一年」，和上面按区间汇总的数字不是同一个量，所以说明文字里把窗口写明，
  /// 避免两个对不上的数字被当成统计错误。
  private func makeYearHeatmap() -> NSView {
    let daily = TokenStatsSummary.dailyTotals(samples: samples, project: nil)
    let today = self.today
    heatmap.apply(cells: TokenActivityHeatmap.cells(dailyTotals: daily, today: today))
    let windowTotal = TokenActivityHeatmap.windowTotal(dailyTotals: daily, today: today)
    heatmapCaption.stringValue = L("过去一年共 \(TokenNumberText.compact(windowTotal)) token")

    let card = UsageTokenCardView()
    let rows = NSStackView(views: [heatmap, heatmapCaption])
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 6
    card.addSubview(rows)
    rows.pinEdges(to: card, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    heatmap.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
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
