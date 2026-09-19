// 标签拖入 Pane 的 AppKit 接线：真实 TabRowButton 事件循环 → 落点判定 → 模型合并。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

private extension NSView {
  var tabDragDescendants: [NSView] { subviews.flatMap { [$0] + $0.tabDragDescendants } }
}

/// 两个单 Pane 编辑器标签的工作区窗口；用编辑器 Pane 避免起真实 PTY 与 Ghostty surface。
@MainActor
private struct TabDragFixture {
  let model: AppModel
  let controller: WorkspaceViewController
  let window: NSWindow
  let currentTab: TerminalTabItem
  let draggedTab: TerminalTabItem

  init() throws {
    let suite = "AsterTabDragUITests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let snapshots = (0..<2).map { index in
      WorkspaceTabSnapshot(
        id: UUID(),
        title: "drag-\(index)",
        layout: .leaf(
          PaneDescriptor(
            kind: .editor,
            workingDirectory: "/tmp/drag-\(index)",
            resourcePath: "/tmp/drag-\(index)/note.md"
          ))
      )
    }
    defaults.set(
      try JSONEncoder().encode(
        WorkspaceSnapshot(selectedTabID: snapshots[0].id, tabs: snapshots)),
      forKey: "aster.workspace.snapshot.v1"
    )
    model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    currentTab = model.tabs[0]
    draggedTab = model.tabs[1]
    controller = WorkspaceViewController(
      model: model, preferences: AppPreferences(defaults: defaults))
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = controller
    window.layoutIfNeeded()
  }

  /// 当前标签那个 Pane 的容器在窗口坐标系里的 frame。
  func paneFrameInWindow() throws -> NSRect {
    let host = try #require(
      controller.view.tabDragDescendants.compactMap { $0 as? ActivePaneHostView }.first)
    return host.convert(host.bounds, to: nil)
  }

  /// 在被拖标签的行上按下，随后依次投递 `points` 处的拖动事件，最后在末点抬起。
  /// 事件先进队列，`TabRowButton.mouseDown` 里的 `trackEvents` 循环会把它们取走。
  func press(thenDragThrough points: [NSPoint]) throws {
    let row = try #require(
      controller.view.tabDragDescendants.compactMap { $0 as? TabRowButton }.first {
        $0.identifier?.rawValue == "workspace-tab-row-\(draggedTab.id.uuidString)"
      })
    let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    for point in points {
      NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: point), atStart: false)
    }
    NSApp.postEvent(try mouseEvent(.leftMouseUp, at: points.last ?? start), atStart: false)
    row.mouseDown(with: try mouseEvent(.leftMouseDown, at: start))
  }

  private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      ))
  }
}

@Test("把标签拖到 Pane 底边会并到当前标签下方")
@MainActor
func draggingTabOntoPaneEdgeMergesItIntoTheCurrentTab() throws {
  let fixture = try TabDragFixture()
  let pane = try fixture.paneFrameInWindow()
  let currentPane = try #require(fixture.currentTab.layout.allPanes.first)
  let draggedPane = try #require(fixture.draggedTab.layout.allPanes.first)

  try fixture.press(thenDragThrough: [
    NSPoint(x: pane.midX, y: pane.midY),
    NSPoint(x: pane.midX, y: pane.minY + 12),
  ])

  #expect(fixture.model.tabs.map(\.id) == [fixture.currentTab.id])
  #expect(
    fixture.currentTab.layout
      == .split(axis: .vertical, first: .leaf(currentPane), second: .leaf(draggedPane), ratio: 0.5))
  // 落点高亮层只在拖动期间存在。
  #expect(
    !fixture.controller.view.tabDragDescendants.contains { $0 is PaneDropOverlayView })
}

@Test("点击标签在抬起时切换，按下期间当前标签保持不变")
@MainActor
func clickingTabSelectsItOnMouseUp() throws {
  let fixture = try TabDragFixture()

  try fixture.press(thenDragThrough: [])

  #expect(fixture.model.selectedTabID == fixture.draggedTab.id)
  #expect(fixture.model.tabs.count == 2)
}

@Test("标签拖到本窗口的非 Pane 区域只相当于一次点击")
@MainActor
func draggingTabWithinTheSidebarOnlySelectsIt() throws {
  let fixture = try TabDragFixture()
  let pane = try fixture.paneFrameInWindow()

  // 落点在 Pane 左侧的侧栏里：不并入，也不会被当成「拖出窗口」去新开窗口。
  try fixture.press(thenDragThrough: [NSPoint(x: max(pane.minX - 40, 4), y: pane.midY)])

  #expect(fixture.model.tabs.count == 2)
  #expect(fixture.model.selectedTabID == fixture.draggedTab.id)
  #expect(fixture.currentTab.layout.allPanes.count == 1)
}
