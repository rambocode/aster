import AppKit
import AsterCore
import Testing

@testable import Aster

/// PiP 所有权测试使用独立偏好域和真实 AppKit 视图树，但不展示窗口、不发送输入事件，
/// 因而只验证容器挂载契约，不依赖 UI 自动化或真实用户交互。
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

/// 构造包含两个真实终端的工作区，专门覆盖 PiP 跟随焦点时的所有权转移。
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

@Test("固定 PiP 在工作区刷新期间独占终端容器，关闭后由工作区恢复")
@MainActor
func fixedPictureInPictureRetainsTerminalOwnershipAcrossWorkspaceRefresh() async throws {
  let fixture = try makePictureInPictureFixture()
  let session = try #require(fixture.model.selectedTab?.activeSession)
  let terminalHost = session.makeTerminalHost(preferences: fixture.preferences)
  #expect(isDescendant(terminalHost, of: fixture.workspace.view))

  let pictureInPicture = PanePictureInPictureController(
    model: fixture.model,
    preferences: fixture.preferences,
    mode: .currentPane
  )
  // 复现长期容器被夺回的关键条件：PiP 已挂载后，工作区因任意模型变化整树刷新。
  fixture.model.objectWillChange.send()
  try await settlePictureInPictureViewUpdates()

  #expect(!isDescendant(terminalHost, of: fixture.workspace.view))
  #expect(
    fixture.workspace.view.descendantLabels.contains("正在 Picture in Picture 中显示")
  )

  pictureInPicture.close()
  try await settlePictureInPictureViewUpdates()

  #expect(isDescendant(terminalHost, of: fixture.workspace.view))
  #expect(
    !fixture.workspace.view.descendantLabels.contains("正在 Picture in Picture 中显示")
  )
}

@Test("固定 PiP 切换工作区活动 Pane 后仍持有最初终端")
@MainActor
func fixedPictureInPictureDoesNotFollowActivePane() async throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let first = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let second = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let fixture = try makeSplitPictureInPictureFixture(first: first, second: second)
  let tab = try #require(fixture.model.selectedTab)
  let firstSession = try #require(tab.runtime(for: first.id)?.terminalSession)
  let secondSession = try #require(tab.runtime(for: second.id)?.terminalSession)
  let firstHost = firstSession.makeTerminalHost(preferences: fixture.preferences)
  let secondHost = secondSession.makeTerminalHost(preferences: fixture.preferences)

  let pictureInPicture = PanePictureInPictureController(
    model: fixture.model,
    preferences: fixture.preferences,
    mode: .currentPane
  )
  try await settlePictureInPictureViewUpdates()

  // 固定模式只改变工作区焦点，不转移 PiP Claim；随后再触发整树刷新，确保结果不依赖
  // 当前视图恰好尚未重建的时序。
  tab.setActivePane(second.id)
  fixture.model.objectWillChange.send()
  try await settlePictureInPictureViewUpdates()

  #expect(!isDescendant(firstHost, of: fixture.workspace.view))
  #expect(isDescendant(secondHost, of: fixture.workspace.view))

  pictureInPicture.close()
  try await settlePictureInPictureViewUpdates()
  #expect(isDescendant(firstHost, of: fixture.workspace.view))
  #expect(isDescendant(secondHost, of: fixture.workspace.view))
}

@Test("跟随 PiP 切换活动 Pane 时把旧终端归还工作区并独占新终端")
@MainActor
func followingPictureInPictureTransfersTerminalOwnership() async throws {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let first = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let second = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let fixture = try makeSplitPictureInPictureFixture(first: first, second: second)
  let tab = try #require(fixture.model.selectedTab)
  let firstSession = try #require(tab.runtime(for: first.id)?.terminalSession)
  let secondSession = try #require(tab.runtime(for: second.id)?.terminalSession)
  let firstHost = firstSession.makeTerminalHost(preferences: fixture.preferences)
  let secondHost = secondSession.makeTerminalHost(preferences: fixture.preferences)

  let pictureInPicture = PanePictureInPictureController(
    model: fixture.model,
    preferences: fixture.preferences,
    mode: .followActivePane
  )
  try await settlePictureInPictureViewUpdates()
  #expect(!isDescendant(firstHost, of: fixture.workspace.view))
  #expect(isDescendant(secondHost, of: fixture.workspace.view))

  tab.setActivePane(second.id)
  try await settlePictureInPictureViewUpdates()

  #expect(isDescendant(firstHost, of: fixture.workspace.view))
  #expect(!isDescendant(secondHost, of: fixture.workspace.view))
  #expect(
    fixture.workspace.view.descendantLabels.filter {
      $0 == "正在 Picture in Picture 中显示"
    }.count == 1
  )

  pictureInPicture.close()
  try await settlePictureInPictureViewUpdates()
  #expect(isDescendant(firstHost, of: fixture.workspace.view))
  #expect(isDescendant(secondHost, of: fixture.workspace.view))
}

private extension NSView {
  /// 只读取可见文案作为行为断言，不暴露或探测工作区内部私有视图类型。
  var descendantLabels: [String] {
    let ownText = (self as? NSTextField).map { [$0.stringValue] } ?? []
    return ownText + subviews.flatMap(\.descendantLabels)
  }
}
