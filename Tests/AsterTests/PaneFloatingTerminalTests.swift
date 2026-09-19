import AppKit
import AsterCore
import Testing

@testable import Aster

/// 两个真实终端的分屏工作区：验证可交互画中画只借走一个 Pane 的终端 Host。
@MainActor
private func makeFloatingTerminalFixture(
  first: PaneDescriptor,
  second: PaneDescriptor
) throws -> (
  model: AppModel,
  preferences: AppPreferences,
  workspace: WorkspaceViewController,
  window: NSWindow
) {
  let suite = "AsterFloatingTerminalTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let layout = PaneLayout.split(
    axis: .horizontal, first: .leaf(first), second: .leaf(second), ratio: 0.5)
  let tab = WorkspaceTabSnapshot(id: UUID(), title: "Floating", layout: layout)
  defaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
    forKey: "aster.workspace.snapshot.v1")

  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.contentViewController = workspace
  window.contentView?.layoutSubtreeIfNeeded()
  return (model, preferences, workspace, window)
}

/// 沿父链判断归属，避免测试依赖私有 Pane 容器类型。
@MainActor
private func isInside(_ candidate: NSView, _ ancestor: NSView?) -> Bool {
  guard let ancestor else { return false }
  var current: NSView? = candidate
  while let view = current {
    if view === ancestor { return true }
    current = view.superview
  }
  return false
}

/// 按 identifier 在视图树里找占位视图。
@MainActor
private func findView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for child in root.subviews {
    if let match = findView(identifier, in: child) { return match }
  }
  return nil
}

/// 模型变更 → 工作区安排 refresh → 重建视图树，各占一轮主队列。
@MainActor
private func settleFloatingTerminalUpdates() async throws {
  try await Task.sleep(for: .milliseconds(60))
}

@Test("可交互画中画把终端搬进小窗，工作区只画占位且刷新不抢回，关闭后挂回原 Pane")
@MainActor
func floatingTerminalBorrowsHostAndReturnsIt() async throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let first = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let second = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let fixture = try makeFloatingTerminalFixture(first: first, second: second)
  let tab = try #require(fixture.model.selectedTab)
  let firstSession = try #require(tab.runtime(for: first.id)?.terminalSession)
  let secondSession = try #require(tab.runtime(for: second.id)?.terminalSession)
  defer { firstSession.stop(immediately: true); secondSession.stop(immediately: true) }
  let firstHost = firstSession.makeTerminalHost(preferences: fixture.preferences)
  let secondHost = secondSession.makeTerminalHost(preferences: fixture.preferences)
  tab.setActivePane(first.id)

  let floating = PaneFloatingTerminalController(
    model: fixture.model, preferences: fixture.preferences)
  var closeCount = 0
  floating.onClose = { closeCount += 1 }
  floating.show()
  defer { floating.close() }

  let panel = try #require(floating.window)
  #expect(panel.level == .floating)
  #expect(panel.canBecomeKey, "小窗必须能接收键盘输入，否则和镜像没有区别")
  #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
  #expect(fixture.model.floatingPaneID == first.id)
  #expect(isInside(firstHost, panel.contentView))
  #expect(floating.matches(model: fixture.model, mode: .currentPane))
  #expect(!floating.matches(model: fixture.model, mode: .followActivePane))

  // 工作区重建多次也不能把 Host 抢回去；另一个 Pane 不受影响。
  try await settleFloatingTerminalUpdates()
  tab.setActivePane(second.id)
  fixture.model.objectWillChange.send()
  try await settleFloatingTerminalUpdates()
  #expect(isInside(firstHost, panel.contentView))
  #expect(isInside(secondHost, fixture.workspace.view))
  #expect(findView("floating-pane-placeholder", in: fixture.workspace.view) != nil)

  floating.close()
  #expect(floating.isClosed)
  #expect(closeCount == 1)
  #expect(fixture.model.floatingPaneID == nil)
  #expect(!panel.isVisible)
  try await settleFloatingTerminalUpdates()
  #expect(isInside(firstHost, fixture.workspace.view))
  #expect(findView("floating-pane-placeholder", in: fixture.workspace.view) == nil)
  floating.close()
  #expect(closeCount == 1, "重复关闭不能再次回调")
}

@Test("源 Pane 被关闭时小窗自动收起，不把别的 Pane 搬进来")
@MainActor
func floatingTerminalClosesWithSourcePane() async throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let first = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let second = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let fixture = try makeFloatingTerminalFixture(first: first, second: second)
  let tab = try #require(fixture.model.selectedTab)
  let secondSession = try #require(tab.runtime(for: second.id)?.terminalSession)
  defer { secondSession.stop(immediately: true) }
  let secondHost = secondSession.makeTerminalHost(preferences: fixture.preferences)
  tab.setActivePane(first.id)

  let floating = PaneFloatingTerminalController(
    model: fixture.model, preferences: fixture.preferences)
  var failure: String?
  floating.onFailure = { failure = $0 }
  floating.show()
  defer { floating.close() }
  let panel = try #require(floating.window)

  #expect(tab.closePane(id: first.id))
  try await settleFloatingTerminalUpdates()
  #expect(floating.isClosed)
  #expect(failure == nil, "关闭源 Pane 是正常生命周期，不弹错误")
  #expect(fixture.model.floatingPaneID == nil)
  #expect(panel.contentView?.subviews.isEmpty == true, "已结束的终端不能留在小窗容器里")
  #expect(isInside(secondHost, fixture.workspace.view))
}

@Test("画中画方式默认镜像，未知值回退镜像；小窗位置落盘并夹回屏幕")
@MainActor
func pictureInPictureStylePreferenceAndFrameClamp() throws {
  let suite = "AsterFloatingTerminalPreferenceTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let preferences = AppPreferences(defaults: defaults)
  #expect(preferences.pictureInPictureStyle == .mirror)
  preferences.setCompatibilityValue(.string("interactive"), forKey: "pictureInPicture.style")
  #expect(preferences.pictureInPictureStyle == .interactive)
  preferences.setCompatibilityValue(.string("hologram"), forKey: "pictureInPicture.style")
  #expect(preferences.pictureInPictureStyle == .mirror)

  #expect(preferences.pictureInPictureFloatingFrame == nil)
  let frame = NSRect(x: 40, y: 60, width: 600, height: 380)
  preferences.pictureInPictureFloatingFrame = frame
  #expect(AppPreferences(defaults: defaults).pictureInPictureFloatingFrame == frame)
  preferences.pictureInPictureFloatingFrame = nil
  #expect(preferences.pictureInPictureFloatingFrame == nil)

  let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
  let offscreen = PaneFloatingTerminalController.clamp(
    NSRect(x: 5_000, y: -300, width: 600, height: 380), to: visible)
  #expect(visible.contains(offscreen))
  #expect(offscreen.size == NSSize(width: 600, height: 380))
  let tiny = PaneFloatingTerminalController.clamp(
    NSRect(x: 10, y: 10, width: 20, height: 20), to: visible)
  #expect(tiny.size == PaneFloatingTerminalController.minimumSize)
  let huge = PaneFloatingTerminalController.clamp(
    NSRect(x: 10, y: 10, width: 9_000, height: 9_000), to: visible)
  #expect(huge == visible)
}
