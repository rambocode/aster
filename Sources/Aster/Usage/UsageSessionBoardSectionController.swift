// 浮动窗「会话」页：所有在跑 Agent 的状态卡，附 CPU / 内存占用。
import AppKit
import AsterCore
import Combine
import Foundation

/// 会话页。
///
/// 会话列表事件驱动（订阅数据源），只有进程占用需要按节拍采样；采样仅在页面可见且
/// 至少有一张卡时进行，`suspend()` 之后不留任何在途任务与订阅。
@MainActor
final class UsageSessionBoardSectionController: UsageSectionController {
  /// 进程占用的采样间隔。一拍是一次全机 libproc 扫描（约 2ms），3 秒足够跟手。
  static let sampleInterval = Duration.seconds(3)
  private static let contentInset: CGFloat = 12

  private let dataSource: UsageSessionBoardDataSource
  private let sampler: @Sendable () -> ProcessSample
  private let sampleInterval: Duration

  private let contentStack = NSStackView()
  private var subscription: AnyCancellable?
  private var sampleTask: Task<Void, Never>?
  private var isActive = false
  /// 上一拍还没回来就跳过这一拍，不排队堆积。
  private(set) var isSampling = false
  /// 挂起与重新激活都会自增，用来丢弃迟到的采样结果。
  private var generation: UInt64 = 0

  /// 座位顺序。页面打开期间冻结，详见 `UsageSessionBoardOrder.seats`。
  private(set) var seats: [UUID] = []
  private var entries: [UUID: UsageSessionEntry] = [:]
  private var footprints: [UUID: ProcessFootprint] = [:]
  private var cards: [UUID: UsageSessionCardView] = [:]
  /// 上一份全机采样，用来求 CPU 差值。挂起时丢弃，因此重新打开的第一拍没有 CPU。
  private var previousSample: ProcessSample?
  /// 列表是否已经渲染过。首帧即使是空列表也要落地一次，否则空态文字永远不出现。
  private var hasRendered = false

  /// 是否还排着下一拍采样。页面挂起或没有卡片时必须为 false。
  var hasScheduledPoll: Bool { sampleTask != nil }

  /// 按当前座位顺序返回卡片。顺序取自视图树，测试据此验证「不换位」。
  var cardsInOrder: [UsageSessionCardView] {
    contentStack.arrangedSubviews.compactMap { $0 as? UsageSessionCardView }
  }

  /// `sampler` 与 `sampleInterval` 可注入，测试用假采样器与短间隔。
  init(
    dataSource: UsageSessionBoardDataSource,
    sampler: @escaping @Sendable () -> ProcessSample = ProcessFootprintSampler.sample,
    sampleInterval: Duration = UsageSessionBoardSectionController.sampleInterval
  ) {
    self.dataSource = dataSource
    self.sampler = sampler
    self.sampleInterval = sampleInterval
  }

  deinit {
    sampleTask?.cancel()
  }

  // MARK: - UsageSectionController

  private(set) lazy var view: NSView = makeView()

  func activate() {
    guard !isActive else { return }
    isActive = true
    generation &+= 1
    _ = view
    subscription = dataSource.changes.sink { [weak self] in
      self?.reload(reseat: false)
    }
    // 重新打开：按优先级重排一次座位，并丢掉上一次的占用数据——隔了一段时间的
    // 内存数字已经不可信，CPU 更是要等到第二拍才有差值。
    previousSample = nil
    footprints.removeAll()
    reload(reseat: true)
  }

  func suspend() {
    isActive = false
    generation &+= 1
    subscription?.cancel()
    subscription = nil
    sampleTask?.cancel()
    sampleTask = nil
    isSampling = false
    previousSample = nil
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
    scroll.identifier = NSUserInterfaceItemIdentifier("usage-session-section")
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
    return scroll
  }

  // MARK: - 列表

  /// 重新读取会话并刷新卡片。`reseat` 为真时按状态优先级整体重排座位。
  private func reload(reseat: Bool) {
    let sessions = dataSource.sessions()
    entries = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let inputs = sessions.map {
      UsageSessionOrderInput(
        id: $0.id, status: $0.status, title: UsageSessionCardView.displayTitle(for: $0))
    }
    let updated = UsageSessionBoardOrder.seats(
      previous: seats, current: inputs, reseat: reseat)
    // 座位没变就只改已有卡片的文字与颜色；重建整列会丢掉悬停状态，也会让列表闪一下。
    if updated != seats || !hasRendered {
      seats = updated
      hasRendered = true
      rebuildCards()
    }
    refreshCards()
    updateSampling()
  }

  /// 按座位顺序重排卡片：复用还在的卡片实例，只增删差集。
  private func rebuildCards() {
    for view in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    let alive = Set(seats)
    cards = cards.filter { alive.contains($0.key) }
    footprints = footprints.filter { alive.contains($0.key) }

    guard !seats.isEmpty else {
      let empty = makeLabel(
        L("现在没有正在运行的 Agent。"), size: 11, color: AsterTheme.secondaryInk)
      empty.identifier = NSUserInterfaceItemIdentifier("usage-session-empty")
      empty.lineBreakMode = .byWordWrapping
      empty.maximumNumberOfLines = 0
      addFullWidth(empty)
      return
    }
    for id in seats {
      let card = cards[id] ?? makeCard(id: id)
      cards[id] = card
      addFullWidth(card)
    }
  }

  private func makeCard(id: UUID) -> UsageSessionCardView {
    UsageSessionCardView(entryID: id) { [weak self] paneID in
      self?.dataSource.focus(paneID: paneID)
    }
  }

  /// 原地刷新每张卡的文字与颜色。
  private func refreshCards() {
    for id in seats {
      guard let card = cards[id], let entry = entries[id] else { continue }
      card.update(entry: entry, footprint: footprints[id])
    }
  }

  /// 卡片与空态文字都要撑满内容宽度；stack 的 `.leading` 对齐只保证左边对齐。
  private func addFullWidth(_ view: NSView) {
    contentStack.addArrangedSubview(view)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(
      equalTo: contentStack.widthAnchor, constant: -Self.contentInset * 2
    ).isActive = true
  }

  // MARK: - 进程占用采样

  /// 根据「页面是否可见 / 有没有卡片」开停采样。没有卡片时一拍也不采。
  private func updateSampling() {
    guard isActive, !seats.isEmpty else {
      sampleTask?.cancel()
      sampleTask = nil
      return
    }
    guard sampleTask == nil else { return }
    scheduleSample(immediate: true)
  }

  /// 单次延迟任务自续，不用常驻 Timer：切页、收窗、关功能都靠同一次 `cancel` 收尾。
  /// `immediate` 只在第一拍用——刚打开页面不该空着占用信息等满一个间隔。
  private func scheduleSample(immediate: Bool = false) {
    sampleTask?.cancel()
    guard isActive, !seats.isEmpty else {
      sampleTask = nil
      return
    }
    let generation = self.generation
    let interval = sampleInterval
    sampleTask = Task { @MainActor [weak self] in
      if !immediate {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
      }
      guard let self, !Task.isCancelled, self.isActive, self.generation == generation else {
        return
      }
      await self.sampleOnce()
      guard !Task.isCancelled, self.isActive, self.generation == generation else { return }
      self.scheduleSample()
    }
  }

  /// 采一拍并刷新占用文字。内部可见：测试要在不依赖真实计时的情况下推进节拍。
  ///
  /// 采样本身放到后台：全机扫描约 2ms，主线程要留给终端输入与渲染。
  func sampleOnce() async {
    guard isActive, !seats.isEmpty, !isSampling else { return }
    isSampling = true
    let generation = self.generation
    let sampler = self.sampler
    let sample = await Task.detached(priority: .utility) { sampler() }.value
    // 迟到的结果：页面早已挂起或重新激活过，这一份属于上一个世代，直接丢弃。
    guard self.generation == generation else { return }
    isSampling = false
    guard isActive else { return }
    apply(sample)
  }

  private func apply(_ sample: ProcessSample) {
    for id in seats {
      guard let root = entries[id]?.rootProcessIdentifier else {
        footprints[id] = nil
        continue
      }
      footprints[id] = ProcessFootprintCalculator.footprint(
        root: root, current: sample, previous: previousSample)
    }
    previousSample = sample
    refreshCards()
  }
}
