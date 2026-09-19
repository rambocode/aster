// AI 用量浮动窗「配额」页：每个账号一张卡，逐窗口两行显示百分比与重置倒计时。
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
  /// 卡片排两列所需的最小内容宽度。
  static let twoColumnMinimumWidth: CGFloat = 620
  /// 掉回一列的宽度。比进两列的阈值低一档形成滞回，宽度正好卡在阈值上时不会来回跳。
  static let singleColumnMaximumWidth: CGFloat = 600
  private static let contentInset: CGFloat = 12
  private static let cardSpacing: CGFloat = 10

  private let store: UsageQuotaStore
  private let contentStack = NSStackView()
  private var subscription: AnyCancellable?
  private var tickTask: Task<Void, Never>?
  private var isActive = false
  /// 已渲染的卡片结构；只有它变化才重建视图。
  private var renderedSignatures: [CardSignature]?
  /// 当前卡片，与最近一次渲染的账号同序。
  private var cards: [UsageQuotaCardView] = []
  /// 当前展示口径。新建卡片要带上它，否则切过口径后新到的账号会显示成另一套数字。
  private var displayMode: UsageDisplayMode = .used
  /// `addFullWidth` 装上的宽度约束。重排容器前必须先拆掉，否则同一个视图会攒下多条。
  private var fullWidthConstraints: [NSLayoutConstraint] = []

  private lazy var emptyLabel: NSTextField = makeWrappingLabel(
    L("还没有配额数据。启动一次 Claude Code 或 Codex 后这里会显示。"),
    size: 11, color: AsterTheme.secondaryInk)
  private lazy var footnoteLabel: NSTextField = makeWrappingLabel(
    L("其它 Agent 没有本地配额数据，只统计 token。"),
    size: 10, color: AsterTheme.tertiaryInk)

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

  /// 当前列数。宽度跨过 `twoColumnMinimumWidth` 时在 1 和 2 之间切换。
  private(set) var columnCount = 1

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

  /// 「已用 / 剩余」口径切换。
  ///
  /// 走原地更新那条路：卡片实例、滚动位置与 tooltip 都保留，只改数字、条宽。
  /// 颜色不动——严重度永远按已用百分比算，见 `UsageQuotaWindowRow.severity`。
  func apply(displayMode: UsageDisplayMode) {
    guard displayMode != self.displayMode else { return }
    self.displayMode = displayMode
    for card in cards { card.apply(displayMode: displayMode) }
  }

  // MARK: - 视图

  private func makeView() -> NSView {
    contentStack.orientation = .vertical
    contentStack.alignment = .leading
    contentStack.spacing = Self.cardSpacing
    contentStack.edgeInsets = NSEdgeInsets(
      top: Self.contentInset, left: Self.contentInset, bottom: Self.contentInset,
      right: Self.contentInset)

    let document = UsageQuotaDocumentView()
    document.onWidthChange = { [weak self] width in self?.applyWidth(width) }
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

  /// 按可用宽度决定列数。只有跨过阈值才重排，所以每帧 layout 调用它是廉价的。
  ///
  /// 两个阈值之间是滞回区：滚动条出现/消失会让内容宽度抖动十几点，单阈值会在边界上反复重排。
  func applyWidth(_ width: CGFloat) {
    var target = columnCount
    if width >= Self.twoColumnMinimumWidth {
      target = 2
    } else if width <= Self.singleColumnMaximumWidth {
      target = 1
    }
    guard target != columnCount else { return }
    columnCount = target
    layoutCards()
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
    cards = accounts.map { UsageQuotaCardView(account: $0, displayMode: displayMode) }
    layoutCards()
  }

  /// 把当前卡片按 `columnCount` 摆进内容栈。
  ///
  /// 只换容器、不重建 `UsageQuotaCardView` 实例：切列数时卡片上的数字、tooltip 和
  /// 正在显示的倒计时都要原样留着，重建会让整页闪一下。
  private func layoutCards() {
    NSLayoutConstraint.deactivate(fullWidthConstraints)
    fullWidthConstraints = []
    for arranged in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(arranged)
      arranged.removeFromSuperview()
    }
    // 两列模式下卡片挂在临时的行 stack 上，那些 stack 刚被丢掉；先把卡片摘干净，
    // 免得它们还带着 `fillEqually` 生成的等宽约束进入下一种布局。
    for card in cards { card.removeFromSuperview() }

    if cards.isEmpty {
      addFullWidth(emptyLabel)
    } else if columnCount <= 1 {
      for card in cards { addFullWidth(card) }
    } else {
      for start in stride(from: 0, to: cards.count, by: columnCount) {
        let slice = cards[start..<min(start + columnCount, cards.count)]
        let row = NSStackView(views: Array(slice))
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = Self.cardSpacing
        // 末行不满时补占位视图，`fillEqually` 才不会把最后一张卡拉成整行宽。
        for _ in slice.count..<columnCount { row.addArrangedSubview(NSView()) }
        addFullWidth(row)
      }
    }

    addFullWidth(footnoteLabel)
  }

  /// 卡片与说明文字都要撑满内容宽度；stack 的 `.leading` 对齐只保证左边对齐。
  private func addFullWidth(_ view: NSView) {
    contentStack.addArrangedSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    let constraint = view.widthAnchor.constraint(
      equalTo: contentStack.widthAnchor, constant: -Self.contentInset * 2)
    constraint.isActive = true
    fullWidthConstraints.append(constraint)
  }

  private func makeWrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
    let label = makeLabel(text, size: size, color: color)
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
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

/// 配额页滚动区的文档视图：翻转坐标系，并在宽度变化时回调，让页面决定排几列。
@MainActor
private final class UsageQuotaDocumentView: NSView {
  var onWidthChange: ((CGFloat) -> Void)?

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    onWidthChange?(bounds.width)
  }
}
