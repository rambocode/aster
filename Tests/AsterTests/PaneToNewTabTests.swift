// 把 Pane 拖成独立标签：运行态搬家、焦点归属、控制桥身份，以及拖到标签栏的 AppKit 接线。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

private extension NSView {
  var paneToTabDescendants: [NSView] { subviews.flatMap { [$0] + $0.paneToTabDescendants } }
}

@MainActor
private func paneToTabDefaults() -> UserDefaults {
  let suite = "AsterPaneToTabTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 一个左右两个终端 Pane 的标签；返回模型、标签和右侧（聚焦）Pane 的 ID。
@MainActor
private func makeSplitModel() -> (model: AppModel, tab: TerminalTabItem, rightPaneID: UUID) {
  let model = AppModel(defaults: paneToTabDefaults())
  model.ensureInitialTab()
  let tab = model.tabs[0]
  tab.split(direction: .right)
  return (model, tab, tab.activePaneID)
}

@Test("Pane 拖成独立标签时原样搬运运行态，当前标签保持选中")
@MainActor
func movePaneToNewTabKeepsTheRuntimeAndSelection() throws {
  let (model, tab, paneID) = makeSplitModel()
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let runtime = try #require(tab.runtime(for: paneID))
  let descriptor = try #require(tab.layout.descriptor(forPane: paneID))
  let remainingPaneID = try #require(tab.layout.firstPaneID)

  #expect(model.movePaneToNewTab(paneID))

  #expect(model.tabs.count == 2)
  #expect(model.tabs[0] === tab)
  #expect(model.selectedTab === tab)
  #expect(model.recentlyClosedSnapshots.isEmpty)
  // 原标签收拢成剩下的那个 Pane，焦点落到它身上。
  #expect(tab.layout.allPanes.map(\.id) == [remainingPaneID])
  #expect(tab.activePaneID == remainingPaneID)
  #expect(tab.runtime(for: paneID) == nil)
  // 新标签紧跟当前标签，持有同一个运行态对象。
  let created = model.tabs[1]
  #expect(created.layout == .leaf(descriptor))
  #expect(created.runtime(for: paneID) === runtime)
  #expect(created.activePaneID == paneID)
}

@Test("拖成独立标签后会话事件进入新标签")
@MainActor
func movePaneToNewTabRewiresSessionCallbacks() throws {
  let (model, tab, paneID) = makeSplitModel()
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  tab.setTabTitleOverride(.name("pinned"))
  let session = try #require(tab.runtime(for: paneID)?.terminalSession)

  #expect(model.movePaneToNewTab(paneID))
  let created = model.tabs[1]

  // 固定名是原标签的设置，不带到新标签；新标签跟随自己 Pane 的程序标题。
  session.onTitleUpdate?(2, "moved-title")
  #expect(created.title == "moved-title")
  #expect(tab.title == "pinned")
}

@Test("标签的最后一个 Pane 不能拖成独立标签")
@MainActor
func movePaneToNewTabRejectsTheLastPane() {
  let model = AppModel(defaults: paneToTabDefaults())
  model.ensureInitialTab()
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let tab = model.tabs[0]

  #expect(!model.canMovePaneToNewTab(tab.activePaneID))
  #expect(!model.movePaneToNewTab(tab.activePaneID))
  #expect(model.tabs.count == 1)
  #expect(tab.runtime(for: tab.activePaneID) != nil)
}

@Test("Pane 拖出再并回，始终是同一个运行态")
@MainActor
func paneSurvivesMoveOutAndMergeBack() throws {
  let (model, tab, paneID) = makeSplitModel()
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let runtime = try #require(tab.runtime(for: paneID))
  let remainingPaneID = try #require(tab.layout.firstPaneID)

  #expect(model.movePaneToNewTab(paneID))
  let created = model.tabs[1]
  #expect(model.mergeTab(id: created.id, intoPane: remainingPaneID, direction: .up))

  #expect(model.tabs.map(\.id) == [tab.id])
  #expect(tab.runtime(for: paneID) === runtime)
  #expect(tab.layout.allPanes.map(\.id) == [paneID, remainingPaneID])
}

@Test("拖成独立标签后控制桥沿用 Pane 短 ID 并投影到新标签")
@MainActor
func movePaneToNewTabKeepsControlPaneIdentity() async throws {
  let (model, _, paneID) = makeSplitModel()
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let bridge = AsterControlBridge(socketPath: "/tmp/aster-pane-to-tab.sock", binaryPath: nil)
  bridge.attach(model: model)
  let shortIDBefore = try #require(bridge.registry.currentPaneID(for: paneID))

  #expect(model.movePaneToNewTab(paneID))
  try await Task.sleep(for: .milliseconds(100))

  #expect(bridge.registry.currentPaneID(for: paneID) == shortIDBefore)
  let createdShortID = try #require(bridge.registry.currentTabID(for: model.tabs[1].id))
  #expect(bridge.projectPane(paneID)?.tabID == createdShortID.description)
}

@Test("把 Pane 的拖动把手拖到左侧标签栏会生成独立标签")
@MainActor
func draggingPaneHandleOntoTheSidebarCreatesATab() throws {
  // 编辑器 Pane：不起真实 PTY 与 Ghostty surface。
  let defaults = paneToTabDefaults()
  let left = PaneDescriptor(
    kind: .editor, workingDirectory: "/tmp/pane-left", resourcePath: "/tmp/pane-left/a.md")
  let right = PaneDescriptor(
    kind: .editor, workingDirectory: "/tmp/pane-right", resourcePath: "/tmp/pane-right/b.md")
  let snapshot = WorkspaceTabSnapshot(
    id: UUID(),
    title: "split",
    layout: .split(axis: .horizontal, first: .leaf(left), second: .leaf(right), ratio: 0.5)
  )
  defaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshot.id, tabs: [snapshot])),
    forKey: "aster.workspace.snapshot.v1"
  )
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(
    model: model, preferences: AppPreferences(defaults: defaults))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.layoutIfNeeded()

  let sidebar = try #require(
    controller.view.paneToTabDescendants.first { $0.identifier?.rawValue == "workspace-sidebar" })
  let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
  let handles = controller.view.paneToTabDescendants.compactMap { $0 as? PaneDragHandleView }
  // 把手按 Pane 顺序安装；取最右边那个，对应 `right`。
  let handle = try #require(
    handles.max { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX })
  handle.isRevealed = true

  func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }
  let drop = NSPoint(x: sidebarFrame.midX, y: sidebarFrame.midY)
  NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: drop), atStart: false)
  NSApp.postEvent(try mouseEvent(.leftMouseUp, at: drop), atStart: false)
  let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
  handle.mouseDown(with: try mouseEvent(.leftMouseDown, at: start))

  #expect(model.tabs.count == 2)
  #expect(model.tabs[0].layout == .leaf(left))
  #expect(model.tabs[1].layout == .leaf(right))
  #expect(model.selectedTabID == snapshot.id)
}
