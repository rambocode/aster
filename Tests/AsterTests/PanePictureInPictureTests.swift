import AppKit
import CoreVideo
import AVKit
import AsterCore
import Testing

@testable import Aster

/// PiP 使用独立偏好域和真实 AppKit 视图树，验证镜像不抢占终端容器。
@MainActor
private func makePictureInPictureFixture() throws -> (
  model: AppModel,
  preferences: AppPreferences,
  workspace: WorkspaceViewController,
  window: NSWindow
) {
  let suite = "AsterPictureInPictureOwnershipTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)

  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = workspace
  window.contentView?.layoutSubtreeIfNeeded()
  return (model, preferences, workspace, window)
}

/// 两个真实终端用于验证固定与跟随模式的帧源身份。
@MainActor
private func makeSplitPictureInPictureFixture(
  first: PaneDescriptor,
  second: PaneDescriptor
) throws -> (
  model: AppModel,
  preferences: AppPreferences,
  workspace: WorkspaceViewController,
  window: NSWindow
) {
  let suite = "AsterPictureInPictureFollowTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(first),
    second: .leaf(second),
    ratio: 0.5
  )
  let tab = WorkspaceTabSnapshot(id: UUID(), title: "PiP", layout: layout)
  defaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
    forKey: "aster.workspace.snapshot.v1"
  )

  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = workspace
  window.contentView?.layoutSubtreeIfNeeded()
  return (model, preferences, workspace, window)
}

/// 判断长期终端容器是否仍属于指定工作区；沿父链判断可避免测试依赖私有 Pane 容器类型。
@MainActor
private func isDescendant(_ candidate: NSView, of ancestor: NSView) -> Bool {
  var current: NSView? = candidate
  while let view = current {
    if view === ancestor { return true }
    current = view.superview
  }
  return false
}

/// Combine 与工作区刷新都会把视图更新排到下一轮主队列，等待两轮可覆盖“收到变更 →
/// 安排 refresh → 重建视图树”的完整链路，同时不启动或操控任何真实窗口。
@MainActor
private func settlePictureInPictureViewUpdates() async throws {
  try await Task.sleep(for: .milliseconds(40))
}

@Test("固定 PiP 镜像不移动终端容器，工作区刷新后仍可输入")
@MainActor
func fixedPictureInPictureKeepsTerminalInWorkspace() async throws {
  let fixture = try makePictureInPictureFixture()
  let session = try #require(fixture.model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }
  let terminalHost = session.makeTerminalHost(preferences: fixture.preferences)
  let pictureInPicture = PanePictureInPictureController(
    model: fixture.model, preferences: fixture.preferences, mode: .currentPane)
  defer { pictureInPicture.close() }
  #expect(pictureInPicture.sourceSurface === session.pictureInPictureSurface)
  #expect(isDescendant(terminalHost, of: fixture.workspace.view))
  fixture.model.objectWillChange.send()
  try await settlePictureInPictureViewUpdates()
  #expect(isDescendant(terminalHost, of: fixture.workspace.view))
  #expect(!fixture.workspace.view.descendantLabels.contains("正在 Picture in Picture 中显示"))
  pictureInPicture.close()
  #expect(pictureInPicture.isClosed)
  #expect(isDescendant(terminalHost, of: fixture.workspace.view))
}

@Test("固定 PiP 不随工作区焦点改变，跟随 PiP 切换帧源且保留两个终端")
@MainActor
func pictureInPictureSourceModesPreserveBothTerminals() async throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let first = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let second = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let fixture = try makeSplitPictureInPictureFixture(first: first, second: second)
  let tab = try #require(fixture.model.selectedTab)
  let firstSession = try #require(tab.runtime(for: first.id)?.terminalSession)
  let secondSession = try #require(tab.runtime(for: second.id)?.terminalSession)
  defer { firstSession.stop(immediately: true); secondSession.stop(immediately: true) }
  let firstHost = firstSession.makeTerminalHost(preferences: fixture.preferences)
  let secondHost = secondSession.makeTerminalHost(preferences: fixture.preferences)
  let fixed = PanePictureInPictureController(
    model: fixture.model, preferences: fixture.preferences, mode: .currentPane)
  #expect(fixed.displayedPaneID == first.id)
  tab.setActivePane(second.id)
  try await settlePictureInPictureViewUpdates()
  #expect(fixed.displayedPaneID == first.id)
  #expect(fixed.sourceSurface === firstSession.pictureInPictureSurface)
  fixed.close()
  let playback = PictureInPicturePlayback()
  let system = AVPictureInPictureController(contentSource: .init(
    sampleBufferDisplayLayer: playback.displayLayer, playbackDelegate: playback))
  var restored: Bool?
  fixed.pictureInPictureController(system,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 })
  #expect(restored == false)
  #expect(tab.activePaneID == second.id, "程序切换模式不能把焦点拉回旧的固定 Pane")

  let following = PanePictureInPictureController(
    model: fixture.model, preferences: fixture.preferences, mode: .followActivePane)
  defer { following.close() }
  #expect(following.displayedPaneID == second.id)
  tab.setActivePane(first.id)
  try await settlePictureInPictureViewUpdates()
  #expect(following.displayedPaneID == first.id)
  #expect(following.sourceSurface === firstSession.pictureInPictureSurface)
  #expect(isDescendant(firstHost, of: fixture.workspace.view))
  #expect(isDescendant(secondHost, of: fixture.workspace.view))
  following.close()
  tab.setActivePane(second.id)
  try await settlePictureInPictureViewUpdates()
  #expect(following.displayedPaneID == nil)
  #expect(following.sourceSurface == nil)
}

@Test("真实 Ghostty GPU 帧进入 PiP 邮箱，不改变原终端网格或父视图")
@MainActor
func pictureInPictureCapturesRealGhosttyFrame() async throws {
  let fixture = try makePictureInPictureFixture()
  let session = try #require(fixture.model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }
  fixture.window.makeKeyAndOrderFront(nil)
  defer { fixture.window.orderOut(nil) }
  let surface = try #require(session.pictureInPictureSurface)
  for _ in 0..<100 where surface.surface == nil {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(surface.surface != nil)
  #expect(surface.typeText("printf '\\033[41;97m%s%s\\033[0m\\n' PIP_ PIXEL_PROBE\n"))
  for _ in 0..<100 where surface.readText(includeScrollback: false)?.contains("PIP_PIXEL_PROBE") != true {
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(surface.readText(includeScrollback: false)?.contains("PIP_PIXEL_PROBE") == true)
  try await Task.sleep(for: .milliseconds(100))
  let originalSize = surface.bounds.size
  let parent = surface.superview
  let pip = PanePictureInPictureController(
    model: fixture.model, preferences: fixture.preferences, mode: .currentPane)
  defer { pip.close() }
  surface.renderNow()
  var frame: CVPixelBuffer?
  for _ in 0..<100 {
    frame = surface.pictureInPictureFrames.takeLatest()
    if frame != nil { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let captured = try #require(frame, "GPU 完成回调没有交付帧")
  #expect(CVPixelBufferGetWidth(captured) > 0)
  #expect(CVPixelBufferGetHeight(captured) > 0)
  #expect(CVPixelBufferGetPixelFormatType(captured) == kCVPixelFormatType_32BGRA)
  CVPixelBufferLockBaseAddress(captured, .readOnly)
  let pixels = try #require(CVPixelBufferGetBaseAddress(captured))
    .assumingMemoryBound(to: UInt8.self)
  var hasRedPixels = false
  for row in 0..<CVPixelBufferGetHeight(captured) {
    for column in 0..<CVPixelBufferGetWidth(captured) {
      let offset = row * CVPixelBufferGetBytesPerRow(captured) + column * 4
      if Int(pixels[offset + 2]) > Int(pixels[offset + 1]) + 20,
        Int(pixels[offset + 2]) > Int(pixels[offset]) + 20 { hasRedPixels = true; break }
    }
    if hasRedPixels { break }
  }
  CVPixelBufferUnlockBaseAddress(captured, .readOnly)
  #expect(hasRedPixels, "PiP 帧必须包含终端真实的红色像素，不能只交付空白缓冲")
  #expect(surface.bounds.size == originalSize)
  #expect(surface.superview === parent)
  pip.close()
  #expect(!surface.pictureInPictureFrames.reserveFrame())
}

@Test("系统 AVKit 画中画真实启动和关闭", .enabled(if:
  ProcessInfo.processInfo.environment["ASTER_TEST_SYSTEM_PIP"] == "1"))
@MainActor
func pictureInPictureSystemWindowStartsAndStops() async throws {
  let fixture = try makePictureInPictureFixture()
  let previousPolicy = NSApp.activationPolicy()
  NSApp.setActivationPolicy(.regular)
  defer { NSApp.setActivationPolicy(previousPolicy) }
  fixture.window.title = "Aster · PiP QA"
  fixture.model.isInspectorPresented = true
  let session = try #require(fixture.model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }
  fixture.window.makeKeyAndOrderFront(nil)
  NSApp.activate(ignoringOtherApps: true)
  defer { fixture.window.orderOut(nil) }
  let surface = try #require(session.pictureInPictureSurface)
  for _ in 0..<100 where surface.surface == nil {
    try await Task.sleep(for: .milliseconds(20))
  }
  let pip = PanePictureInPictureController(
    model: fixture.model, preferences: fixture.preferences, mode: .currentPane)
  defer { pip.close() }
  var failure: String?
  pip.onFailure = { failure = $0 }
  pip.show()
  for _ in 0..<100 where !pip.isActive && failure == nil {
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(failure == nil, "\(failure ?? "")")
  #expect(pip.isActive, "系统 PiP 没有进入活动状态")
  #expect(surface.window === fixture.window, "原终端必须继续留在原窗口")
  let previousFrameCount = pip.presentedFrameCount
  fixture.window.orderOut(nil)
  #expect(surface.typeText("printf 'aster-pip-background-update\\n'\n"))
  for _ in 0..<50 where pip.presentedFrameCount <= previousFrameCount {
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(pip.isActive, "主窗口隐藏后系统 PiP 应继续显示")
  #expect(pip.presentedFrameCount > previousFrameCount, "主窗口隐藏后仍应接收新的终端帧")
  fixture.window.makeKeyAndOrderFront(nil)
  // 仅显式视觉验收时保留窗口，常规测试不等待人工观察。
  if let value = ProcessInfo.processInfo.environment["ASTER_PIP_VISUAL_QA_SECONDS"],
    let seconds = Double(value), seconds.isFinite, seconds > 0
  {
    try await Task.sleep(for: .seconds(min(seconds, 60)))
  }
  pip.close()
  for _ in 0..<50 where !pip.isClosed {
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(pip.isClosed)
  #expect(!pip.isActive)
}

private extension NSView {
  /// 只读取可见文案作为行为断言，不暴露或探测工作区内部私有视图类型。
  var descendantLabels: [String] {
    let ownText = (self as? NSTextField).map { [$0.stringValue] } ?? []
    return ownText + subviews.flatMap(\.descendantLabels)
  }
}
