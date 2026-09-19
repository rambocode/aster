import AppKit
import Testing
@testable import Aster

// 看不见的 Ghostty surface 不应继续绘制：可见性判定与向 renderer 的上报。

@MainActor
private func waitUntilTrue(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Test("未挂入窗口的 Ghostty 视图视为不可见，画中画采集期间保持可见")
@MainActor
func ghosttySurfaceVisibilityFollowsWindowAndPictureInPicture() {
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  #expect(!view.isSurfaceVisibleToUser)

  // 镜像直接消费 renderer 的帧：后台标签里的源 Pane 也必须继续绘制。
  view.pictureInPictureFrames.start()
  #expect(view.pictureInPictureFrames.isCapturing)
  #expect(view.isSurfaceVisibleToUser)
  view.pictureInPictureFrames.stop()
  #expect(!view.isSurfaceVisibleToUser)

  // 隐藏的祖先视图同样使 surface 不可见，即使它在窗口里。
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
    styleMask: [.titled], backing: .buffered, defer: true)
  let container = NSView(frame: window.contentLayoutRect)
  window.contentView = container
  view.surfaceCreationDisabled = true
  container.addSubview(view)
  container.isHidden = true
  #expect(!view.isSurfaceVisibleToUser)
  view.removeFromSuperview()
}

@Test("真实 Ghostty surface 随窗口显隐上报可见性，画中画采集期间不降级")
@MainActor
func ghosttySurfaceReportsOcclusionToRenderer() async throws {
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  defer { view.destroySurface() }
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  let container = NSView(frame: window.contentLayoutRect)
  window.contentView = container
  view.frame = container.bounds
  container.addSubview(view)
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }

  // 窗口上屏后 surface 已创建，并且上报过「可见」。
  #expect(await waitUntilTrue { view.surface != nil && view.reportedSurfaceVisible == true })

  // 拆出窗口（等同切到后台标签）：延后一轮确认后上报「不可见」。
  view.removeFromSuperview()
  #expect(view.reportedSurfaceVisible == true, "同一轮主队列内不应立即降级")
  #expect(await waitUntilTrue { view.reportedSurfaceVisible == false })

  // 同一轮里拆下再装回（工作区整树刷新）不产生任何状态翻转。
  container.addSubview(view)
  #expect(await waitUntilTrue { view.reportedSurfaceVisible == true })
  view.removeFromSuperview()
  container.addSubview(view)
  try await Task.sleep(for: .milliseconds(50))
  #expect(view.reportedSurfaceVisible == true)

  // 画中画镜像开着时，源视图离开窗口也保持可见；停止采集后才降级。
  view.pictureInPictureFrames.start()
  view.removeFromSuperview()
  try await Task.sleep(for: .milliseconds(50))
  #expect(view.reportedSurfaceVisible == true)
  view.pictureInPictureFrames.stop()
  #expect(await waitUntilTrue { view.reportedSurfaceVisible == false })
}
