import AppKit
import AVKit
import Combine

/// 系统画中画只消费终端渲染帧。原 Pane、PTY、输入焦点和网格尺寸始终留在工作区。
/// 固定模式绑定稳定 Pane ID；跟随模式按同一工作区的活动 Pane 切换帧源。
@MainActor
final class PanePictureInPictureController: NSObject,
  @preconcurrency AVPictureInPictureControllerDelegate
{
  enum Mode { case currentPane, followActivePane }

  private let model: AppModel
  private let mode: Mode
  private let pinnedPaneID: UUID?
  private let playback = PictureInPicturePlayback()
  private var controller: AVPictureInPictureController?
  private var sourceWindow: PictureInPictureSourceWindow?
  private var modelCancellable: AnyCancellable?
  private var paneCancellable: AnyCancellable?
  private weak var observedTab: TerminalTabItem?
  private weak var ownerWindow: NSWindow?
  private var timer: Timer?
  private var startupTimeout: Task<Void, Never>?
  private var requestedStart = false
  private var isClosing = false
  private(set) var isClosed = false
  private(set) var displayedPaneID: UUID?
  private(set) var sourceSurface: GhosttySurfaceView?
  var isActive: Bool { controller?.isPictureInPictureActive == true }
  var presentedFrameCount: Int { playback.presentedFrameCount }
  /// AVKit 的 delegate 是弱引用。开始到 didStop/failed 之间必须保活，防止关闭或切换
  /// 模式的异步回调尚未结束就销毁显示层。所有终止入口统一由 finishClose 解除保活。
  private var activeLifetime: PanePictureInPictureController?
  var onFailure: ((String) -> Void)?
  var onClose: (() -> Void)?

  init(model: AppModel, preferences: AppPreferences, mode: Mode) {
    self.model = model
    self.mode = mode
    pinnedPaneID = model.selectedTab?.activePaneID
    super.init()
    // 偏好只通过已有终端生效；镜像不能另建不同主题或不同字号的终端。
    _ = preferences
    playback.onPlayingChanged = { [weak self] playing in
      guard let self, !self.isClosing, !self.isClosed, let source = self.sourceSurface else { return }
      if playing {
        source.pictureInPictureFrames.start()
        source.renderNow()
      } else {
        source.pictureInPictureFrames.stop()
      }
    }
    playback.onRenderSizeChanged = { [weak self] size in
      guard let self, !self.isClosing, !self.isClosed else { return }
      self.sourceWindow?.updateFallbackRenderSize(size)
    }
    controller = AVPictureInPictureController(contentSource: .init(
      sampleBufferDisplayLayer: playback.displayLayer, playbackDelegate: playback))
    controller?.delegate = self
    controller?.requiresLinearPlayback = true
    modelCancellable = model.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.refreshSource() }
    }
    refreshSource()
  }

  func matches(model: AppModel, mode: Mode) -> Bool {
    self.model === model && self.mode == mode && !isClosed && !isClosing
  }

  func show() {
    guard !isClosed, !isClosing, activeLifetime == nil else { return }
    guard AVPictureInPictureController.isPictureInPictureSupported(), controller != nil else {
      fail("当前系统不支持画中画")
      return
    }
    guard sourceSurface != nil else {
      fail("当前 Pane 没有可镜像的终端画面")
      return
    }
    activeLifetime = self
    let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.presentLatestFrame() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    sourceSurface?.renderNow()
    presentLatestFrame()
    startupTimeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, !self.isClosed, self.controller?.isPictureInPictureActive != true else { return }
      self.fail("系统画中画未能启动，请确认终端画面已显示后重试")
    }
  }

  func close() {
    guard !isClosed, !isClosing else { return }
    isClosing = true
    startupTimeout?.cancel()
    timer?.invalidate()
    timer = nil
    sourceSurface?.pictureInPictureFrames.stop()
    if let controller, controller.isPictureInPictureActive || requestedStart {
      controller.stopPictureInPicture()
      // 尚在启动时停止可能不触发 didStop；failed/didStart 也都检查 isClosing。
      if !controller.isPictureInPictureActive && !controller.isPictureInPictureSuspended {
        finishClose()
      }
    } else {
      finishClose()
    }
  }

  private func refreshSource() {
    guard !isClosed, !isClosing else { return }
    let tab: TerminalTabItem?
    let paneID: UUID?
    switch mode {
    case .currentPane:
      paneID = pinnedPaneID
      tab = model.tabs.first { tab in pinnedPaneID.map { tab.runtime(for: $0) != nil } ?? false }
    case .followActivePane:
      tab = model.selectedTab
      paneID = tab?.activePaneID
    }
    if observedTab !== tab {
      observedTab = tab
      paneCancellable?.cancel()
      if let tab {
        paneCancellable = Publishers.Merge(
          tab.activePaneChanged.map { _ in () }, tab.$layout.dropFirst().map { _ in () }
        ).sink { [weak self] _ in
          DispatchQueue.main.async { self?.refreshSource() }
        }
      }
    }
    guard let tab, let paneID, let runtime = tab.runtime(for: paneID) else {
      // 用户关闭源 Pane 是正常生命周期，不弹出错误对话框，也不恢复到其他 Pane。
      if activeLifetime != nil { close() } else { detachSource() }
      return
    }
    guard let session = runtime.terminalSession,
      let surface = session.pictureInPictureSurface
    else {
      // Pane 已关闭或切换到不支持的内容时，不能继续展示前一个 Pane 的旧画面。
      if activeLifetime != nil { fail("活动 Pane 已关闭或没有可镜像的终端画面") }
      else { detachSource() }
      return
    }
    guard sourceSurface !== surface else { return }
    detachSource()
    sourceSurface = surface
    displayedPaneID = paneID
    if let window = surface.window { ownerWindow = window }
    if sourceWindow == nil {
      sourceWindow = PictureInPictureSourceWindow(layer: playback.displayLayer, size: surface.bounds.size)
    }
    if !playback.isPaused {
      surface.pictureInPictureFrames.start()
      surface.renderNow()
    }
  }

  private func presentLatestFrame() {
    guard !isClosing, !isClosed, let source = sourceSurface else { return }
    if let message = source.pictureInPictureFrames.takeFailure() { fail(message); return }
    sourceWindow?.synchronize(active: isActive)
    if let frame = source.pictureInPictureFrames.takeLatest(), let error = playback.enqueue(frame) {
      fail(error)
      return
    }
    guard !requestedStart, controller?.isPictureInPicturePossible == true else { return }
    requestedStart = true
    controller?.startPictureInPicture()
  }

  private func detachSource() {
    sourceSurface?.pictureInPictureFrames.stop()
    sourceSurface = nil
    displayedPaneID = nil
    playback.displayLayer.flushAndRemoveImage()
  }

  private func fail(_ message: String) {
    guard !isClosed else { return }
    let handler = onFailure
    close()
    handler?(message)
  }

  private func finishClose() {
    guard !isClosed else { return }
    isClosed = true
    startupTimeout?.cancel()
    startupTimeout = nil
    timer?.invalidate()
    timer = nil
    modelCancellable?.cancel()
    paneCancellable?.cancel()
    detachSource()
    sourceWindow?.close()
    sourceWindow = nil
    controller?.delegate = nil
    controller = nil
    activeLifetime = nil
    onClose?()
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    startupTimeout?.cancel()
    sourceWindow?.synchronize(active: true)
    if isClosing || isClosed { controller.stopPictureInPicture() }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    finishClose()
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error)
  {
    // 不回显系统错误里的文件路径或媒体元数据。
    let handler = isClosing ? nil : onFailure
    finishClose()
    handler?("系统无法启动画中画，请稍后重试")
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void)
  {
    // 程序关闭或切换模式时 AVKit 也可能请求恢复；此时不能把用户焦点拉回旧 Pane。
    guard !isClosing, !isClosed else { completionHandler(false); return }
    if let paneID = displayedPaneID,
      let tab = model.tabs.first(where: { $0.runtime(for: paneID) != nil })
    {
      model.selectedTabID = tab.id
      tab.setActivePane(paneID)
    }
    ownerWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    completionHandler(ownerWindow != nil)
  }
}
