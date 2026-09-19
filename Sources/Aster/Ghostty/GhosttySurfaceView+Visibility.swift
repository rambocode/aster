// 把宿主视图的真实可见性同步给 libghostty：看不见的 surface 不再编码 Metal 帧、
// 不再呈现 IOSurface，renderer 线程同时降到 utility QoS。
import AppKit
@preconcurrency import GhosttyKit

extension GhosttySurfaceView {
  /// 是否有人能看到这块 surface 的像素。
  ///
  /// 后台标签的终端视图会被拆出窗口（`window == nil`），窗口也可能最小化、被完全遮住、
  /// 位于其他 Space 或屏幕已关闭（`occlusionState` 不含 `.visible`）。系统画中画镜像直接
  /// 消费 renderer 的帧，镜像期间即使源视图不可见也必须继续绘制。
  var isSurfaceVisibleToUser: Bool {
    if pictureInPictureFrames.isCapturing { return true }
    guard let window, !isHiddenOrHasHiddenAncestor else { return false }
    return window.occlusionState.contains(.visible)
  }

  /// 把当前可见性报告给 libghostty；只在状态变化时调用 C API。
  ///
  /// 变为可见立即生效，renderer 会马上补画最新一帧。变为不可见延后一轮主队列再确认：
  /// 工作区整树刷新会在同一轮里把视图拆下再装回，立即上报会白白触发一次降级和一次补画。
  func synchronizeSurfaceVisibility() {
    guard surface != nil else { return }
    let visible = isSurfaceVisibleToUser
    guard reportedSurfaceVisible != visible else { return }
    if visible {
      applySurfaceVisibility(true)
      return
    }
    guard !surfaceInvisibilityCheckScheduled else { return }
    surfaceInvisibilityCheckScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.surfaceInvisibilityCheckScheduled = false
      guard !self.isSurfaceVisibleToUser else { return }
      self.applySurfaceVisibility(false)
    }
  }

  /// surface 刚创建时 libghostty 默认按可见处理；这里强制上报一次真实状态。
  func reportInitialSurfaceVisibility() {
    reportedSurfaceVisible = nil
    applySurfaceVisibility(isSurfaceVisibleToUser)
  }

  /// 唯一调用 `ghostty_surface_set_occlusion` 的入口（参数语义是「可见」）。
  private func applySurfaceVisibility(_ visible: Bool) {
    guard let surface, reportedSurfaceVisible != visible else { return }
    reportedSurfaceVisible = visible
    ghostty_surface_set_occlusion(surface, visible)
  }

  /// 跟随当前窗口的遮挡通知；视图换窗口（小窗借走、标签拖放）时重新订阅。
  func observeWindowOcclusion() {
    let center = NotificationCenter.default
    center.removeObserver(
      self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    guard let window else { return }
    center.addObserver(
      self, selector: #selector(windowOcclusionStateDidChange(_:)),
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
  }

  @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
    synchronizeSurfaceVisibility()
  }
}
