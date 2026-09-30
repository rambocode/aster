// 侧栏「工作区」区块与标签过滤：只显示当前工作区的标签、切换后刷新、标签移到别的工作区。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

private extension NSView {
  var groupSidebarDescendants: [NSView] { subviews.flatMap { [$0] + $0.groupSidebarDescendants } }
}

/// 两个工作区的窗口：「前端」有两个标签，「后端」有一个。用编辑器 Pane，避免起真实 PTY。
@MainActor
private struct WorkspaceGroupFixture {
  let model: AppModel
  let preferences: AppPreferences
  let controller: WorkspaceViewController
  let window: NSWindow
  let frontend = WorkspaceGroup(name: "前端")
  let backend = WorkspaceGroup(name: "后端")
  let tabIDs = (0..<3).map { _ in UUID() }

  init(layout: TabBarLayout = .vertical) throws {
    let suite = "AsterWorkspaceGroupSidebarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let groupIDs = [frontend.id, frontend.id, backend.id]
    let snapshots = zip(tabIDs, groupIDs).enumerated().map { index, pair in
      WorkspaceTabSnapshot(
        id: pair.0, title: "group-tab-\(index)",
        layout: .leaf(
          PaneDescriptor(
            kind: .editor, workingDirectory: "/tmp/group-\(index)",
            resourcePath: "/tmp/group-\(index)/note.md")),
        workspaceGroupID: pair.1)
    }
    defaults.set(
      try JSONEncoder().encode(
        WorkspaceSnapshot(
          selectedTabID: tabIDs[0], tabs: snapshots,
          workspaceGroups: [frontend, backend], selectedWorkspaceGroupID: frontend.id)),
      forKey: "aster.workspace.snapshot.v1")
    model = AppModel(defaults: defaults)
    model.ensureInitialTab()
    preferences = AppPreferences(defaults: defaults)
    preferences.tabBarLayout = layout
    controller = WorkspaceViewController(model: model, preferences: preferences)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentViewController = controller
    window.layoutIfNeeded()
  }

  /// 模型变化 → scheduleRefresh → 下一轮主队列重建视图树。
  func settle() async throws {
    try await Task.sleep(for: .milliseconds(60))
    window.layoutIfNeeded()
  }

  /// 当前视图树里的标签行 id（按出现顺序去重）。
  var renderedTabIDs: [UUID] {
    var seen: [UUID] = []
    for row in controller.view.groupSidebarDescendants.compactMap({ $0 as? TabRowButton }) {
      let raw = row.identifier?.rawValue.replacingOccurrences(of: "workspace-tab-row-", with: "")
      if let id = raw.flatMap(UUID.init(uuidString:)), !seen.contains(id) { seen.append(id) }
    }
    return seen
  }

  var groupRows: [WorkspaceGroupRowView] {
    controller.view.groupSidebarDescendants.compactMap { $0 as? WorkspaceGroupRowView }
  }

  var tabsEyebrow: String? {
    (controller.view.groupSidebarDescendants.first {
      $0.identifier?.rawValue == "workspace-sidebar-foreground"
    } as? NSTextField)?.stringValue
  }
}

@Test("侧栏只显示当前工作区的标签，工作区区块列出全部工作区并高亮当前项")
@MainActor
func workspaceGroupSidebarShowsOnlyCurrentGroupTabs() throws {
  let fixture = try WorkspaceGroupFixture()

  #expect(Set(fixture.renderedTabIDs) == Set(fixture.tabIDs[0...1]))
  #expect(fixture.model.tabs.count == 3)
  let rows = fixture.groupRows
  #expect(rows.map(\.item.name) == ["前端", "后端"])
  #expect(rows.map(\.item.isSelected) == [true, false])
  #expect(rows.map(\.item.tabCount) == [2, 1])
  #expect(fixture.tabsEyebrow == "前端 · 标签")
}

@Test("单击工作区行切换工作区，侧栏标签随之更新且不丢后台标签")
@MainActor
func workspaceGroupRowClickSwitchesVisibleTabs() async throws {
  let fixture = try WorkspaceGroupFixture()
  let backendRow = try #require(fixture.groupRows.first { $0.item.name == "后端" })

  #expect(backendRow.accessibilityPerformPress())
  try await fixture.settle()

  #expect(fixture.model.selectedWorkspaceGroupID == fixture.backend.id)
  #expect(fixture.model.selectedTabID == fixture.tabIDs[2])
  #expect(fixture.renderedTabIDs == [fixture.tabIDs[2]])
  #expect(fixture.groupRows.map(\.item.isSelected) == [false, true])
  #expect(fixture.tabsEyebrow == "后端 · 标签")
  // 切走的工作区只是不画，标签仍在模型里。
  #expect(fixture.model.tabs.map(\.id) == fixture.tabIDs)
}

@Test("标签右键「移到工作区」把标签移到别的工作区")
@MainActor
func tabContextMenuMovesTabToAnotherWorkspaceGroup() async throws {
  let fixture = try WorkspaceGroupFixture()
  let row = try #require(
    fixture.controller.view.groupSidebarDescendants.compactMap { $0 as? TabRowButton }.first {
      $0.identifier?.rawValue == "workspace-tab-row-\(fixture.tabIDs[1].uuidString)"
    })
  let menu = try #require(row.menu)
  let moveItem = try #require(
    menu.items.first { $0.identifier?.rawValue == "tab-menu-move-to-workspace-group" })
  let submenu = try #require(moveItem.submenu)
  #expect(submenu.items.map(\.title) == ["后端"])

  submenu.performActionForItem(at: 0)
  try await fixture.settle()

  let moved = try #require(fixture.model.tabs.first { $0.id == fixture.tabIDs[1] })
  #expect(moved.workspaceGroupID == fixture.backend.id)
  #expect(fixture.renderedTabIDs == [fixture.tabIDs[0]])
  #expect(fixture.groupRows.map(\.item.tabCount) == [1, 2])
}

@Test("只剩一个工作区时「移到工作区」禁用，删除工作区也禁用")
@MainActor
func moveToWorkspaceGroupDisabledWithSingleGroup() async throws {
  let fixture = try WorkspaceGroupFixture()
  fixture.model.deleteWorkspaceGroup(fixture.backend.id)
  try await fixture.settle()

  let rows = fixture.groupRows
  #expect(rows.map(\.item.name) == ["前端"])
  let row = try #require(
    fixture.controller.view.groupSidebarDescendants.compactMap { $0 as? TabRowButton }.first)
  let menu = try #require(row.menu)
  let moveItem = try #require(
    menu.items.first { $0.identifier?.rawValue == "tab-menu-move-to-workspace-group" })
  menu.update()
  #expect(moveItem.submenu == nil)
  #expect(!moveItem.isEnabled)
  let groupMenu = fixture.controller.makeWorkspaceGroupRowMenu(rows[0].item)
  #expect(groupMenu.items.first { $0.title == "删除工作区…" }?.isEnabled == false)
}

@Test("横向标签条开头的工作区按钮显示当前工作区，标签条只排当前工作区的标签")
@MainActor
func horizontalTabBarShowsWorkspaceGroupPopUp() throws {
  let fixture = try WorkspaceGroupFixture(layout: .top)

  let popup = try #require(
    fixture.controller.view.groupSidebarDescendants.compactMap { $0 as? WorkspaceGroupPopUpButton }
      .first)
  #expect(popup.title == "前端")
  #expect(Set(fixture.renderedTabIDs) == Set(fixture.tabIDs[0...1]))
  let menu = fixture.controller.makeWorkspaceGroupSwitchMenu()
  #expect(menu.items.prefix(2).map(\.title) == ["前端", "后端"])
  #expect(menu.items.first?.state == .on)
}
