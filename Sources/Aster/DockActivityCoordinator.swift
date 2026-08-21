import AppKit
import AsterCore
import Combine

/// 把所有标签的任务状态投影到 Dock。聚合只读运行态，不进入工作区持久化；点击
/// Dock 后会选择一个失败标签并确认当前错误，后续新错误仍会再次标红。
@MainActor
final class DockActivityCoordinator {
  private var models: [ObjectIdentifier: AppModel] = [:]
  private let preferences: AppPreferences
  private var modelCancellables: [ObjectIdentifier: AnyCancellable] = [:]
  private var preferencesCancellable: AnyCancellable?
  private var isStarted = false
  private var refreshScheduled = false
  private var acknowledgedErrorTabIDs: Set<UUID> = []
  private var animationTimer: Timer?
  private var agentSleepActivity: NSObjectProtocol?
  private var animationPhase = 0
  /// Working 动画的离散帧数；同时决定每帧的旋转步进（360 / 帧数）。
  private static let animationFrameCount = 12
  private let imageView = NSImageView()
  /// Working 动画只有 12 个离散角度。按需缓存已经出现的帧，避免每 220ms 重复把同一
  /// NSImage 栅格化；短任务只生成实际展示过的帧，长任务完成一圈后完全复用缓存。
  private var cachedWorkingFrames: [Int: NSImage] = [:]
  private var cachedErrorIcon: NSImage?
  /// 上一次生成帧所用的 Dock tile 尺寸。用户改 Dock 大小后尺寸会变，旧帧必须作废，
  /// 否则会被拉伸成糊图。
  private var cachedTileSize: NSSize = .zero
  /// 最近一次已应用的聚合状态。它同时作为幂等诊断真值和自动化验收 seam；不包含
  /// 标签、命令或终端内容，也不参与持久化。
  private(set) var currentState = DockActivityState.idle
  /// 图标真正执行栅格化的累计次数。仅用于性能回归诊断，不参与 UI 或持久化。
  private(set) var renderedIconCount = 0

  init(model: AppModel, preferences: AppPreferences) {
    self.preferences = preferences
    models[ObjectIdentifier(model)] = model
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    for model in models.values { subscribe(to: model) }
    preferencesCancellable = preferences.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
    refresh()
  }

  func addModel(_ model: AppModel) {
    let identifier = ObjectIdentifier(model)
    guard models[identifier] == nil else { return }
    models[identifier] = model
    if isStarted { subscribe(to: model) }
    refresh()
  }

  func removeModel(_ model: AppModel) {
    let identifier = ObjectIdentifier(model)
    modelCancellables[identifier]?.cancel()
    modelCancellables[identifier] = nil
    models[identifier] = nil
    refresh()
  }

  func stop() {
    animationTimer?.invalidate()
    animationTimer = nil
    isStarted = false
    refreshScheduled = false
    modelCancellables.values.forEach { $0.cancel() }
    modelCancellables.removeAll()
    preferencesCancellable?.cancel()
    preferencesCancellable = nil
    if let activity = agentSleepActivity {
      ProcessInfo.processInfo.endActivity(activity)
      agentSleepActivity = nil
    }
  }

  @discardableResult
  func acknowledgeAndSelectNextError() -> Bool {
    let failing = models.values.flatMap { model in
      model.tabs.filter { $0.activityBadge == .error }.map { (model, $0) }
    }
    guard let target = failing.first(where: { !acknowledgedErrorTabIDs.contains($0.1.id) })
      ?? failing.first
    else { return false }
    target.0.select(target.1)
    acknowledgedErrorTabIDs.formUnion(failing.map { $0.1.id })
    refresh()
    return true
  }

  private func subscribe(to model: AppModel) {
    let identifier = ObjectIdentifier(model)
    // 布局变化仍来自 ObservableObject；Agent lifecycle/完成未读则走局部活动事件，
    // 否则 Dock 会停在首次 processing 状态，或为更新图标迫使工作区整树重建。
    modelCancellables[identifier] = Publishers.Merge(
      model.objectWillChange.map { _ in () },
      model.tabActivityChanged.map { _ in () }
    )
      .sink { [weak self] _ in self?.scheduleRefresh() }
  }

  /// 同一 lifecycle 指令可能同步改变 provider、task state 与未读状态；合并到下一轮
  /// 主队列只应用一次 Dock 状态，避免重复重建图标或重启动画 timer。
  private func scheduleRefresh() {
    guard isStarted, !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      guard self.isStarted else { return }
      self.refresh()
    }
  }

  private func refresh() {
    let tabs = models.values.flatMap(\.tabs)
    let failingIDs = Set(tabs.filter { $0.activityBadge == .error }.map(\.id))
    acknowledgedErrorTabIDs.formIntersection(failingIDs)
    let badges = tabs.map { tab -> TerminalBadgeState in
      if tab.activityBadge == .error, acknowledgedErrorTabIDs.contains(tab.id) { return .none }
      return tab.activityBadge
    }
    let appearance = preferences.configuration.appearance
    updateAgentSleepActivity()
    apply(
      DockActivityResolver.resolve(
        badges: badges,
        animateOnProgress: appearance.resolvedAnimateDockIconOnProgress,
        redOnError: appearance.resolvedRedDockIconOnError
      )
    )
  }

  private func updateAgentSleepActivity() {
    let shouldPreventSleep = preferences.configuration.agents.preventSleepWhileProcessing
      && models.values.flatMap(\.tabs).contains(where: \.hasProcessingAgent)
    if shouldPreventSleep, agentSleepActivity == nil {
      agentSleepActivity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated],
        reason: "Aster Agent 正在处理任务"
      )
    } else if !shouldPreventSleep, let activity = agentSleepActivity {
      ProcessInfo.processInfo.endActivity(activity)
      agentSleepActivity = nil
    }
  }

  private func apply(_ state: DockActivityState) {
    currentState = state
    animationTimer?.invalidate()
    animationTimer = nil
    switch state {
    case .idle:
      NSApp.dockTile.contentView = nil
      NSApp.dockTile.badgeLabel = nil
      NSApp.dockTile.display()
    case .error:
      imageView.image = errorIcon()
      prepareImageView()
      NSApp.dockTile.contentView = imageView
      NSApp.dockTile.badgeLabel = "!"
      NSApp.dockTile.display()
    case .working:
      NSApp.dockTile.badgeLabel = nil
      prepareImageView()
      NSApp.dockTile.contentView = imageView
      advanceAnimation()
      animationTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) {
        [weak self] _ in
        Task { @MainActor [weak self] in self?.advanceAnimation() }
      }
    }
  }

  private func advanceAnimation() {
    animationPhase = (animationPhase + 1) % Self.animationFrameCount
    imageView.image = workingIcon(for: animationPhase)
    NSApp.dockTile.display()
  }

  /// NSDockTile 不保证给 contentView 排版；frame 留在零尺寸时整块 tile 什么都画不出来。
  private func prepareImageView() {
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.frame = NSRect(origin: .zero, size: tileSize())
  }

  /// Dock 尺寸随用户设置变化；尺寸变了就作废所有派生帧，避免拉伸旧帧。
  private func tileSize() -> NSSize {
    let reported = NSApp.dockTile.size
    let size = reported.width > 0 && reported.height > 0
      ? reported
      : NSSize(width: 128, height: 128)
    if size != cachedTileSize {
      cachedTileSize = size
      cachedWorkingFrames.removeAll(keepingCapacity: true)
      cachedErrorIcon = nil
    }
    return size
  }

  /// 12 帧 × 30° 正好走满一圈，动画首尾无缝衔接；只有中央星芒在转。
  private func workingIcon(for phase: Int) -> NSImage {
    let size = tileSize()
    if let cached = cachedWorkingFrames[phase] { return cached }
    renderedIconCount += 1
    let image = DockIconArtwork.image(
      size: size,
      sparkleAngle: CGFloat(phase) * (360 / CGFloat(Self.animationFrameCount)),
      plate: DockIconArtwork.plateColor
    )
    cachedWorkingFrames[phase] = image
    return image
  }

  private func errorIcon() -> NSImage {
    let size = tileSize()
    if let cachedErrorIcon { return cachedErrorIcon }
    renderedIconCount += 1
    let image = DockIconArtwork.image(
      size: size,
      sparkleAngle: 0,
      plate: DockIconArtwork.errorPlateColor
    )
    cachedErrorIcon = image
    return image
  }
}
