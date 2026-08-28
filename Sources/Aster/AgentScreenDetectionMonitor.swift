import AsterCore
import Foundation

/// 单个 Pane 的 Agent 屏幕检测轮询器：按节奏读屏 → 清单求值 → 发布层仲裁 → 回调发布。
///
/// 数据全部通过 `Source` 闭包注入（读屏、OSC 标题/进度、PTY 内容序号、进程退出），
/// 本类不直接依赖 Ghostty，因此回归测试可以用假屏幕驱动完整链路。
/// 纯逻辑（节奏、pending idle、启动宽限、心跳）在 `AgentScreenDetectionPublisher` 里，
/// 这里只做定时循环与回调分发。
@MainActor
final class AgentScreenDetectionMonitor {
  /// 检测输入来源。`readScreen` 返回 nil 表示本轮读不到屏幕（surface 未就绪），跳过。
  struct Source {
    var readScreen: @MainActor () -> String?
    var oscTitle: @MainActor () -> String
    var oscProgress: @MainActor () -> String
    var contentSequence: @MainActor () -> UInt64
    var processExited: @MainActor () -> Bool
  }

  /// 轮询节奏。生产固定 300ms / 3s；测试用短值验证链路而不真等待。
  struct Timing: Sendable {
    var pollInterval: Duration = AgentScreenDetectionPublisher.pollInterval
    var pendingIdleRecheck: Duration = AgentScreenDetectionPublisher.pendingIdleRecheck
    var startupGrace: Duration = AgentScreenDetectionPublisher.startupGraceWindow

    static let production = Timing()
  }

  typealias PublishedState = AgentScreenDetectionPublisher.PublishedState

  let manifest: CompiledAgentManifest
  let timing: Timing
  /// 发布层判定需要发布时回调（状态或 visible 标志变化、blocked 心跳、进程退出）。
  var onPublish: (@MainActor (PublishedState) -> Void)?
  /// 启动宽限结束时回调一次，让状态机从「启动中视为 processing」切到真实检测结果。
  var onStartupGraceEnded: (@MainActor () -> Void)?

  private(set) var isRunning = false
  private(set) var isInStartupGrace = false
  /// 最近一次发布的状态；未发布前为 unknown。
  private(set) var published = PublishedState(state: .unknown)

  private let source: Source
  private var publisher = AgentScreenDetectionPublisher()
  private var task: Task<Void, Never>?

  init(manifest: CompiledAgentManifest, source: Source, timing: Timing = .production) {
    self.manifest = manifest
    self.source = source
    self.timing = timing
  }

  /// 开始轮询；重复调用先取消旧循环（保留调用方刚装好的回调）。每次启动都重新进入启动宽限。
  func start() {
    task?.cancel()
    task = nil
    publisher.reset()
    publisher.beginStartupGrace(now: .now, window: timing.startupGrace)
    isInStartupGrace = true
    isRunning = true
    published = PublishedState(state: .unknown)
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let interval = self.publisher.pendingIdle.isActive
          ? self.timing.pendingIdleRecheck : self.timing.pollInterval
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        self.tick(now: .now)
      }
    }
  }

  /// 停止轮询并清空发布层状态；同时解除回调，切断 Session ↔ monitor 之间的保留环。
  func stop() {
    task?.cancel()
    task = nil
    isRunning = false
    isInStartupGrace = false
    publisher.reset()
    onPublish = nil
    onStartupGraceEnded = nil
  }

  /// 立即对当前屏幕做一次完整解释（不经过发布层，不改变轮询状态），供调试菜单使用。
  func explainNow() -> AgentDetectionExplain? {
    guard let screen = source.readScreen() else { return nil }
    return manifest.explain(currentInput(screen: screen))
  }

  /// 单轮：先处理启动宽限，再决定是否读屏，最后交给发布层仲裁。
  func tick(now: AgentScreenDetectionPublisher.Instant) {
    let processExited = source.processExited()
    if publisher.consumeStartupGrace(processExited: processExited, now: now) {
      return
    }
    if isInStartupGrace, publisher.startupGraceUntil == nil {
      isInStartupGrace = false
      onStartupGraceEnded?()
    }
    let sequence = source.contentSequence()
    guard
      publisher.shouldReadScreen(
        state: published.state, contentSequence: sequence,
        agentChanged: false, processExited: processExited)
    else { return }
    // 进程已退出时不再依赖屏幕内容，发布层会直接给出 idle + visibleIdle。
    let screen = processExited ? "" : (source.readScreen() ?? "")
    let detection = manifest.detect(currentInput(screen: screen))
    guard
      let next = publisher.decide(
        detection: detection, previous: published,
        agentChanged: false, processExited: processExited, now: now)
    else { return }
    published = next
    onPublish?(next)
  }

  private func currentInput(screen: String) -> AgentDetectionInput {
    AgentDetectionInput(
      screen: screen, oscTitle: source.oscTitle(), oscProgress: source.oscProgress())
  }
}

extension AgentDetectionManifestStore {
  /// 进程级单例：内置清单 + `~/.config/aster/agent-detection` 覆盖目录。所有 Pane 共用
  /// 已编译的清单，设置页「重新加载清单」调用 `reload()` 后新会话即生效。
  static let shared = AgentDetectionManifestStore(
    overrideDirectory: AppPreferences.agentDetectionOverrideDirectoryURL)
}
