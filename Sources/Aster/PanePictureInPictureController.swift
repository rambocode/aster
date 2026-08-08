import AppKit
import Combine

extension Notification.Name {
  /// PiP 终端容器所有权变化只属于视图层，不应伪装成工作区领域模型变化。
  /// 通知的 `object` 是对应 `AppModel`，多窗口只刷新自己的工作区。
  static let panePictureInPictureOwnershipDidChange = Notification.Name(
    "Aster.panePictureInPictureOwnershipDidChange"
  )
}

/// 长期终端容器在主工作区与 PiP 之间只能有一个所有者。注册表按 `TerminalSession`
/// 对象身份记录，而不是只按 Pane UUID 记录，避免不同工作区极小概率的 ID 碰撞。
/// owner 身份用于防止旧 PiP 延迟关闭时误释放新 PiP 已接管的同一终端。
@MainActor
enum PanePictureInPictureOwnership {
  private static var ownerBySession: [ObjectIdentifier: ObjectIdentifier] = [:]

  static func acquire(
    _ session: TerminalSession,
    owner: PanePictureInPictureController,
    model: AppModel
  ) {
    let sessionID = ObjectIdentifier(session)
    let ownerID = ObjectIdentifier(owner)
    guard ownerBySession[sessionID] != ownerID else { return }
    ownerBySession[sessionID] = ownerID
    NotificationCenter.default.post(
      name: .panePictureInPictureOwnershipDidChange,
      object: model
    )
  }

  static func release(
    _ session: TerminalSession,
    owner: PanePictureInPictureController,
    model: AppModel
  ) {
    let sessionID = ObjectIdentifier(session)
    guard ownerBySession[sessionID] == ObjectIdentifier(owner) else { return }
    ownerBySession.removeValue(forKey: sessionID)
    NotificationCenter.default.post(
      name: .panePictureInPictureOwnershipDidChange,
      object: model
    )
  }

  static func isOwnedByPictureInPicture(_ session: TerminalSession) -> Bool {
    ownerBySession[ObjectIdentifier(session)] != nil
  }
}

/// 把一个真实 Pane 容器临时移入系统浮动窗口。终端视图与 PTY 都不复制，因此图像、
/// TUI、选区和滚动状态连续；PiP 关闭后通知工作区重建，把同一容器接回原分屏。
@MainActor
final class PanePictureInPictureController: NSObject, NSWindowDelegate {
  enum Mode {
    case currentPane
    case followActivePane
  }

  private let model: AppModel
  private let preferences: AppPreferences
  private let mode: Mode
  private let windowController: NSWindowController
  private let content = NSView()
  private var modelCancellable: AnyCancellable?
  private var paneCancellable: AnyCancellable?
  private var displayedPaneID: UUID?
  /// 控制器关闭前强持有已接管的会话，确保即使 Pane 同时从模型移除，仍能用稳定对象
  /// 身份释放注册表条目；窗口关闭后立即清空，不延长终端的正常生命周期。
  private var displayedSession: TerminalSession?

  init(model: AppModel, preferences: AppPreferences, mode: Mode) {
    self.model = model
    self.preferences = preferences
    self.mode = mode
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.title = mode == .currentPane ? "Aster · 当前 Pane" : "Aster · 跟随活动 Pane"
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    window.contentView = content
    windowController = NSWindowController(window: window)
    super.init()
    window.delegate = self
    content.wantsLayer = true
    content.layer?.backgroundColor = preferences.terminalBackgroundColor.cgColor
    installObservers()
    refreshPane(force: true)
  }

  func show() {
    windowController.showWindow(nil)
    windowController.window?.orderFrontRegardless()
  }

  func close() {
    windowController.close()
  }

  func windowWillClose(_ notification: Notification) {
    modelCancellable?.cancel()
    paneCancellable?.cancel()
    releaseDisplayedSessionOwnership()
    detachDisplayedView()
  }

  private func installObservers() {
    guard mode == .followActivePane else { return }
    modelCancellable = model.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.refreshPane(force: false) }
      }
    observeFocusedPane()
  }

  private func observeFocusedPane() {
    guard mode == .followActivePane else { return }
    paneCancellable?.cancel()
    paneCancellable = model.selectedTab?.activePaneChanged
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refreshPane(force: false) }
  }

  private func refreshPane(force: Bool) {
    guard let tab = model.selectedTab, let runtime = tab.activeRuntime else {
      releaseDisplayedSessionOwnership()
      showMessage("没有活动 Pane")
      return
    }
    let nextSession = runtime.terminalSession
    let keepsCurrentOwnership = runtime.id == displayedPaneID && nextSession === displayedSession
    guard force || !keepsCurrentOwnership else { return }
    // 固定模式不能订阅活动 Pane；否则第一次初始化后会悄悄退化成跟随模式。
    if mode == .followActivePane { observeFocusedPane() }
    // 跟随模式切换 Pane 时，必须先归还旧终端再接管新终端。两个通知会被工作区的
    // refreshScheduled 合并为一轮刷新，因此不会暴露中间态，也不会重复重建视图树。
    releaseDisplayedSessionOwnership()
    detachDisplayedView()
    displayedPaneID = runtime.id
    let paneView: NSView
    if let session = nextSession {
      // 先登记所有权再移动长期容器；工作区收到通知后的下一轮刷新只能创建占位，
      // 不会再次对同一个 NSView 调用 removeFromSuperview()。
      PanePictureInPictureOwnership.acquire(session, owner: self, model: model)
      displayedSession = session
      paneView = session.makeTerminalHost(preferences: preferences)
    } else {
      paneView = makeMessage("PiP 当前支持实时终端 Pane")
    }
    paneView.removeFromSuperview()
    content.addSubview(paneView)
    paneView.pinEdges(to: content)
  }

  private func detachDisplayedView() {
    for view in content.subviews { view.removeFromSuperview() }
    displayedPaneID = nil
  }

  private func releaseDisplayedSessionOwnership() {
    guard let displayedSession else { return }
    PanePictureInPictureOwnership.release(displayedSession, owner: self, model: model)
    self.displayedSession = nil
  }

  private func showMessage(_ message: String) {
    detachDisplayedView()
    let view = makeMessage(message)
    content.addSubview(view)
    view.pinEdges(to: content)
  }

  private func makeMessage(_ text: String) -> NSView {
    let label = NSTextField(labelWithString: text)
    label.alignment = .center
    label.textColor = AsterTheme.secondaryInk
    let host = NSView()
    label.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])
    return host
  }
}
