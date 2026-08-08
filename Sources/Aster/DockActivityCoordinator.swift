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
  private var acknowledgedErrorTabIDs: Set<UUID> = []
  private var animationTimer: Timer?
  private var agentSleepActivity: NSObjectProtocol?
  private var animationPhase = 0
  private let imageView = NSImageView()

  init(model: AppModel, preferences: AppPreferences) {
    self.preferences = preferences
    models[ObjectIdentifier(model)] = model
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    for model in models.values { subscribe(to: model) }
    preferencesCancellable = preferences.objectWillChange
      .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
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
    modelCancellables[identifier] = model.objectWillChange
      .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
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
    animationTimer?.invalidate()
    animationTimer = nil
    switch state {
    case .idle:
      NSApp.dockTile.contentView = nil
      NSApp.dockTile.badgeLabel = nil
      NSApp.dockTile.display()
    case .error:
      imageView.image = renderedIcon(angle: 0, errorTint: true)
      NSApp.dockTile.contentView = imageView
      NSApp.dockTile.badgeLabel = "!"
      NSApp.dockTile.display()
    case .working:
      NSApp.dockTile.badgeLabel = nil
      NSApp.dockTile.contentView = imageView
      advanceAnimation()
      animationTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) {
        [weak self] _ in
        Task { @MainActor [weak self] in self?.advanceAnimation() }
      }
    }
  }

  private func advanceAnimation() {
    animationPhase = (animationPhase + 1) % 12
    imageView.image = renderedIcon(angle: CGFloat(animationPhase) * 2.5, errorTint: false)
    NSApp.dockTile.display()
  }

  private func renderedIcon(angle: CGFloat, errorTint: Bool) -> NSImage {
    let source = NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 128, height: 128))
    let size = source.size.width > 0 ? source.size : NSSize(width: 128, height: 128)
    let result = NSImage(size: size)
    result.lockFocus()
    let transform = NSAffineTransform()
    transform.translateX(by: size.width / 2, yBy: size.height / 2)
    transform.rotate(byDegrees: angle)
    transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
    transform.concat()
    source.draw(in: NSRect(origin: .zero, size: size))
    if errorTint {
      NSColor.systemRed.withAlphaComponent(0.48).setFill()
      NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    }
    result.unlockFocus()
    return result
  }
}
