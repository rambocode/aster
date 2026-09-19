// AI 用量浮动窗「配额」页：每个账号一张卡，逐窗口显示已用百分比与重置倒计时。
import AppKit
import AsterCore
import Combine
import Foundation

/// 配额页。
///
/// 页面可见期间才订阅账号快照，并靠「单次延迟任务自续」每分钟刷新一次倒计时文字；
/// `suspend()` 同时取消订阅与延迟任务，隐藏的页面不留任何在途工作。
@MainActor
final class UsageQuotaSectionController: UsageSectionController {
  /// 倒计时文字的刷新间隔。分钟级精度不需要更密的 tick。
  static let tickInterval = Duration.seconds(60)
  private static let contentInset: CGFloat = 12

  private let store: UsageQuotaStore
  private let contentStack = NSStackView()
  private var subscription: AnyCancellable?
  private var tickTask: Task<Void, Never>?
  private var isActive = false
  /// 已渲染的卡片结构；只有它变化才重建视图。
  private var renderedSignatures: [CardSignature]?
  /// 当前卡片，与最近一次渲染的账号同序。
  private var cards: [UsageQuotaCardView] = []

  /// 卡片结构签名。
  ///
  /// 刻意不含 `plan` 与 `fetchedAt`：订阅档位变化和每轮取数都只是几个字的差别，
  /// 跟着重建整张卡会丢掉已有实例、滚动位置和正在显示的 tooltip。
  private struct CardSignature: Equatable {
    let id: String
    let label: String
    let windows: [AgentUsageWindow]
  }

  /// 是否还排着下一次倒计时刷新。页面挂起后必须为 false。
  var hasScheduledTick: Bool { tickTask != nil }

  init(store: UsageQuotaStore) {
    self.store = store
  }

  deinit {
    tickTask?.cancel()
  }

  // MARK: - UsageSectionController

  private(set) lazy var view: NSView = makeView()

  func activate() {
    guard !isActive else { return }
    isActive = true
    _ = view
    // 订阅时 `@Published` 会立刻带回当前值，首帧不必额外渲染一次。
    subscription = store.$accounts.sink { [weak self] accounts in
      self?.render(accounts)
    }
    // 页面挂起期间倒计时是停的，重新可见时先把文字补到当前时刻，再排下一次刷新。
    refreshCards()
    scheduleTick()
    // 浮动窗刚打开：本地来源（Codex rollout）立即重读一次，不等下一轮轮询。
    store.refreshLocalSources()
  }

  func suspend() {
    isActive = false
    subscription?.cancel()
    subscription = nil
    tickTask?.cancel()
    tickTask = nil
  }

  // MARK: - 视图

  private func makeView() -> NSView {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = 10
    contentStack.edgeInsets = NSEdgeInsets(
      top: Self.contentInset, left: Self.contentInset, bottom: Self.contentInset,
      right: Self.contentInset)

    let document = FlippedDocumentView()
    document.addSubview(contentStack)
    let scroll = NSScrollView()
    scroll.identifier = NSUserInterfaceItemIdentifier("usage-quota-section")
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
    render(store.accounts, force: true)
    return scroll
  }

  // MARK: - 渲染

  /// 用一份快照更新页面。内部可见而非 private：`UsageQuotaStore` 目前没有注入数据的入口，
  /// 测试只能从这里喂快照来验证徽标与倒计时任务。
  ///
  /// 分两步：结构变了才重建卡片，订阅档位与数据时刻一律原地改文字。
  func render(_ accounts: [UsageAccountSnapshot], force: Bool = false) {
    let signatures = Self.signatures(of: accounts)
    if force || signatures != renderedSignatures {
      renderedSignatures = signatures
      rebuild(accounts)
    }
    for (account, card) in zip(accounts, cards) { card.apply(account) }
    refreshCards()
    scheduleTick()
  }

  private static func signatures(of accounts: [UsageAccountSnapshot]) -> [CardSignature] {
    accounts.map { CardSignature(id: $0.id, label: $0.label, windows: $0.windows) }
  }

  private func rebuild(_ accounts: [UsageAccountSnapshot]) {
    for arranged in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }
    cards = accounts.map { UsageQuotaCardView(account: $0) }

    if cards.isEmpty {
      let empty = makeLabel(
        L("还没有配额数据。启动一次 Claude Code 或 Codex 后这里会显示。"),
        size: 11, color: AsterTheme.secondaryInk)
      empty.lineBreakMode = .byWordWrapping
      empty.maximumNumberOfLines = 0
      addFullWidth(empty)
    } else {
      for card in cards { addFullWidth(card) }
    }

    let footnote = makeLabel(
      L("其它 Agent 没有本地配额数据，只统计 token。"),
      size: 10, color: AsterTheme.tertiaryInk)
    footnote.lineBreakMode = .byWordWrapping
    footnote.maximumNumberOfLines = 0
    addFullWidth(footnote)
  }

  /// 卡片与说明文字都要撑满内容宽度；stack 的 `.leading` 对齐只保证左边对齐。
  private func addFullWidth(_ view: NSView) {
    contentStack.addArrangedSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(
      equalTo: contentStack.widthAnchor, constant: -Self.contentInset * 2
    ).isActive = true
  }

  private func refreshCards() {
    let now = Date()
    for card in cards { card.refresh(now: now) }
  }

  /// 单次延迟任务自续，不用常驻 Timer：切页、收窗、关功能都靠同一次 `cancel` 收尾。
  private func scheduleTick() {
    tickTask?.cancel()
    guard isActive, cards.contains(where: \.needsTick) else {
      tickTask = nil
      return
    }
    tickTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.tickInterval)
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.isActive else { return }
      self.refreshCards()
      self.scheduleTick()
    }
  }
}

/// 一个账号的配额卡片：标题行（账号名 + 订阅档位徽标）、逐窗口进度条、数据时刻。
///
/// 窗口结构由 `init` 固定；`plan` 与 `fetchedAt` 走 `apply` 原地更新，
/// 倒计时文字走 `refresh(now:)`，两者都不动视图结构。
@MainActor
final class UsageQuotaCardView: NSView {
  /// 数据比这更旧才值得标出来，与用量条 tooltip 的口径一致。
  private static let staleThreshold: TimeInterval = 120

  private let titleLabel: NSTextField
  private let planBadge: UsagePlanBadgeView
  private let meterRows: [UsageQuotaMeterRow]
  private let stampLabel = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
  private var fetchedAt: Date?

  /// 是否有随时间变化的内容。全是静态数据的卡片不需要页面排 tick。
  var needsTick: Bool { fetchedAt != nil || meterRows.contains(where: \.hasCountdown) }

  init(account: UsageAccountSnapshot) {
    titleLabel = makeLabel(account.label, size: 12, weight: .semibold)
    planBadge = UsagePlanBadgeView(accountID: account.id)
    meterRows = account.windows.map { UsageQuotaMeterRow(window: $0) }
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-quota-card-\(account.id)")
    wantsLayer = true
    layer?.cornerRadius = 8

    // 徽标紧跟账号名，右侧留一个会撑开的空视图，标题行才不会把徽标推到卡片中间。
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let titleRow = NSStackView(views: [titleLabel, planBadge, spacer])
    titleRow.orientation = .horizontal
    titleRow.alignment = .centerY
    titleRow.spacing = 6

    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 6
    rows.translatesAutoresizingMaskIntoConstraints = false
    rows.addArrangedSubview(titleRow)
    for row in meterRows { rows.addArrangedSubview(row) }
    rows.addArrangedSubview(stampLabel)
    addSubview(rows)
    rows.pinEdges(to: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    titleRow.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    for row in meterRows {
      row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    apply(account)
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 订阅档位与数据时刻的原地更新。
  func apply(_ account: UsageAccountSnapshot) {
    planBadge.apply(plan: account.plan)
    fetchedAt = account.fetchedAt
  }

  /// 刷新所有随时间变化的文字。
  func refresh(now: Date) {
    for row in meterRows { row.refresh(now: now) }
    guard let fetchedAt else {
      stampLabel.isHidden = true
      return
    }
    // 超过两分钟才提示：`/usage` 限流很紧，刚取回的数据标「0 分钟前」只是噪声。
    let age = now.timeIntervalSince(fetchedAt)
    stampLabel.isHidden = age <= Self.staleThreshold
    stampLabel.stringValue = L("\(UsageDurationText.make(age)) 前更新")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.05).cgColor
      layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.5).cgColor
      layer?.borderWidth = 1
    }
  }
}

/// 账号名右侧的订阅档位徽标（「Max 20x」「Pro」「Plus」……）。
///
/// 各家的档位叫法不统一，这里不做归一化映射，原样展示数据源给的字符串——
/// 把「5x」翻译成别的说法只会让用户对不上自己在官网看到的订阅名。
@MainActor
final class UsagePlanBadgeView: NSView {
  private static let horizontalInset: CGFloat = 5
  private let label = makeLabel("", size: 10, weight: .medium, color: AsterTheme.secondaryInk)

  /// 当前展示的档位文字；空串表示徽标隐藏。
  var text: String { label.stringValue }

  init(accountID: String) {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-quota-plan-\(accountID)")
    wantsLayer = true
    layer?.cornerRadius = 4
    addSubview(label)
    label.pinEdges(
      to: self,
      insets: NSEdgeInsets(
        top: 1, left: Self.horizontalInset, bottom: 1, right: Self.horizontalInset))
    setContentHuggingPriority(.required, for: .horizontal)
    apply(plan: nil)
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 档位为 nil、空串或纯空白时整块隐藏；有值只改文字。
  func apply(plan: String?) {
    let value = plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    label.stringValue = value
    isHidden = value.isEmpty
    toolTip = value.isEmpty ? nil : value
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.08).cgColor
    }
  }
}

/// 配额页里的一行：窗口名 + 可伸缩进度条 + 百分比 + 「X 后重置」。
///
/// 不复用 Pane 用量条的 `AgentUsageMeterView`：那里的轨道固定 56pt，
/// 在 380pt 宽的浮动窗里会留下大片空白。填充同样用 `CALayer` 直接设 frame，
/// 因为 Auto Layout 的 multiplier 不可变，改比例得重建约束。
@MainActor
final class UsageQuotaMeterRow: NSView {
  private static let trackHeight: CGFloat = 5

  private let usageWindow: AgentUsageWindow
  private let track = NSView()
  private let fill = CALayer()
  private let percentLabel: NSTextField
  private let resetLabel: NSTextField
  private let fraction: Double
  private let severity: UsageStatusSummary.Severity

  init(window: AgentUsageWindow) {
    usageWindow = window
    fraction = min(max(window.usedPercent / 100, 0), 1)
    severity =
      switch window.usedPercent {
      case UsageStatusSummary.criticalThreshold...: .critical
      case UsageStatusSummary.warningThreshold...: .warning
      default: .normal
      }
    percentLabel = makeLabel(
      "\(Int(window.usedPercent.rounded()))%", size: 10, weight: .medium,
      color: AsterTheme.secondaryInk, monospaced: true)
    resetLabel = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-quota-meter-\(window.kind.rawValue)")
    translatesAutoresizingMaskIntoConstraints = false
    toolTip = AgentUsageMeterView.tooltip(for: window)

    let name = makeLabel(window.displayLabel, size: 10, color: AsterTheme.tertiaryInk)
    name.setContentHuggingPriority(.required, for: .horizontal)
    percentLabel.alignment = .right
    resetLabel.alignment = .right
    resetLabel.setContentHuggingPriority(.required, for: .horizontal)

    track.wantsLayer = true
    track.layer?.cornerRadius = Self.trackHeight / 2
    track.layer?.masksToBounds = true
    fill.cornerRadius = Self.trackHeight / 2
    track.layer?.addSublayer(fill)
    track.translatesAutoresizingMaskIntoConstraints = false
    track.setContentHuggingPriority(.defaultLow, for: .horizontal)
    track.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stack = NSStackView(views: [name, track, percentLabel, resetLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.distribution = .fill
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
      name.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
      percentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    refresh(now: Date())
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 是否有重置倒计时。没有的话这一行的文字不随时间变化。
  var hasCountdown: Bool { usageWindow.resetsAt != nil }

  /// 刷新倒计时文字。没有重置时间的窗口这一列留空。
  func refresh(now: Date) {
    guard let resetsAt = usageWindow.resetsAt, resetsAt > now else {
      resetLabel.stringValue = ""
      return
    }
    resetLabel.stringValue = L("\(UsageDurationText.make(resetsAt.timeIntervalSince(now))) 后重置")
  }

  override func layout() {
    super.layout()
    let bounds = track.bounds
    fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.layer?.backgroundColor = AsterTheme.hairline.cgColor
      fill.backgroundColor =
        switch severity {
        case .normal: AsterTheme.accent.cgColor
        case .warning: AsterTheme.warning.cgColor
        case .critical: NSColor.systemRed.cgColor
        }
    }
  }
}

/// 时长短语（「2 小时 5 分」）。「X 后重置」与「X 前更新」共用同一套措辞。
@MainActor
enum UsageDurationText {
  private static let formatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    return formatter
  }()

  /// 不足一分钟的差值按一分钟显示：显示「0 分钟」既不准确也没有信息量。
  static func make(_ interval: TimeInterval) -> String {
    formatter.string(from: max(interval, 60)) ?? ""
  }
}
