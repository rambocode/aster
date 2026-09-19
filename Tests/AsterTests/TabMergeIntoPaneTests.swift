// 把侧栏标签拖进当前标签的 Pane：运行态搬家、事件重新接线与持久化。
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
private func tabMergeTestDefaults() -> UserDefaults {
  let suite = "AsterTabMergeTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 建一个「目标标签（单 Pane）+ 源标签（左右两个 Pane）」的窗口模型，目标标签处于选中。
@MainActor
private func makeMergeFixture(
  defaults: UserDefaults
) -> (model: AppModel, target: TerminalTabItem, source: TerminalTabItem) {
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let target = model.tabs[0]
  model.newTab(workingDirectory: "/tmp/merge-source", position: .end, hasContent: true)
  let source = model.tabs[1]
  source.split(direction: .right)
  model.select(target)
  return (model, target, source)
}

@Test("标签并入 Pane 时原样搬运运行态且不进最近关闭")
@MainActor
func mergeTabMovesRuntimesWithoutRestartingThem() throws {
  let (model, target, source) = makeMergeFixture(defaults: tabMergeTestDefaults())
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let targetPaneID = target.activePaneID
  let sourceLayout = source.layout
  let sourceActivePaneID = source.activePaneID
  let sourceRuntimes = sourceLayout.allPanes.compactMap { source.runtime(for: $0.id) }
  #expect(sourceRuntimes.count == 2)

  #expect(model.mergeTab(id: source.id, intoPane: targetPaneID, direction: .down))

  #expect(model.tabs.map(\.id) == [target.id])
  #expect(model.selectedTab === target)
  #expect(model.recentlyClosedSnapshots.isEmpty)
  // 源标签的分屏结构整棵落在目标 Pane 下方。
  #expect(
    target.layout
      == .split(
        axis: .vertical,
        first: .leaf(try #require(target.layout.descriptor(forPane: targetPaneID))),
        second: sourceLayout,
        ratio: 0.5
      ))
  // 运行态是同一个对象：PTY、滚动历史都没有重建。
  for runtime in sourceRuntimes {
    #expect(target.runtime(for: runtime.id) === runtime)
    #expect(source.runtime(for: runtime.id) == nil)
  }
  #expect(target.activePaneID == sourceActivePaneID)
}

@Test("并入后会话事件进入新标签，旧标签不再响应")
@MainActor
func mergeTabRewiresSessionCallbacksToTheReceivingTab() throws {
  let (model, target, source) = makeMergeFixture(defaults: tabMergeTestDefaults())
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let targetPaneID = target.activePaneID
  let movedPaneID = try #require(source.layout.firstPaneID)
  let session = try #require(source.runtime(for: movedPaneID)?.terminalSession)
  let sourceTitleBefore = source.title

  #expect(model.mergeTab(id: source.id, intoPane: targetPaneID, direction: .right))

  target.setActivePane(targetPaneID)
  session.onRequestPaneFocus?()
  #expect(target.activePaneID == movedPaneID)
  session.onTitleUpdate?(2, "merged-title")
  #expect(target.title == "merged-title")
  #expect(source.title == sourceTitleBefore)
}

@Test("当前标签不能并进自己，失败时工作区保持原样")
@MainActor
func mergeTabRejectsTheSelectedTab() {
  let (model, target, source) = makeMergeFixture(defaults: tabMergeTestDefaults())
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let layoutBefore = target.layout

  #expect(!model.canMergeTab(id: target.id))
  #expect(!model.mergeTab(id: target.id, intoPane: target.activePaneID, direction: .right))
  // 目标 Pane 不存在：载荷要还给源标签，源标签继续可用。
  #expect(!model.mergeTab(id: source.id, intoPane: UUID(), direction: .right))

  #expect(model.tabs.map(\.id) == [target.id, source.id])
  #expect(target.layout == layoutBefore)
  #expect(source.layout.allPanes.allSatisfy { source.runtime(for: $0.id) != nil })
}

@Test("并入后的布局会写进工作区快照")
@MainActor
func mergeTabPersistsTheCombinedLayout() throws {
  let defaults = tabMergeTestDefaults()
  var fixture: (model: AppModel, target: TerminalTabItem, source: TerminalTabItem)? =
    makeMergeFixture(defaults: defaults)
  let model = try #require(fixture?.model)
  let target = try #require(fixture?.target)
  let source = try #require(fixture?.source)
  #expect(model.mergeTab(id: source.id, intoPane: target.activePaneID, direction: .left))
  let expectedPaneIDs = target.layout.allPanes.map(\.id)
  for tab in model.tabs { tab.stop(immediately: true) }
  fixture = nil

  let restored = AppModel(defaults: defaults)
  restored.ensureInitialTab()
  defer { for tab in restored.tabs { tab.stop(immediately: true) } }
  #expect(restored.tabs.count == 1)
  #expect(restored.tabs.first?.layout.allPanes.map(\.id) == expectedPaneIDs)
}

@Test("并入后控制桥沿用 Pane 短 ID 并把它投影到新标签")
@MainActor
func mergeTabKeepsControlPaneIdentity() async throws {
  let (model, target, source) = makeMergeFixture(defaults: tabMergeTestDefaults())
  defer { for tab in model.tabs { tab.stop(immediately: true) } }
  let bridge = AsterControlBridge(socketPath: "/tmp/aster-tab-merge.sock", binaryPath: nil)
  bridge.attach(model: model)
  let movedPaneID = try #require(source.layout.firstPaneID)
  let shortIDBefore = try #require(bridge.registry.currentPaneID(for: movedPaneID))

  #expect(model.mergeTab(id: source.id, intoPane: target.activePaneID, direction: .right))
  // 控制桥在下一轮主队列同步标签与 Pane；源标签消失不能把搬走的 Pane 当成已关闭。
  try await Task.sleep(for: .milliseconds(100))

  #expect(bridge.registry.currentPaneID(for: movedPaneID) == shortIDBefore)
  let targetShortID = try #require(bridge.registry.currentTabID(for: target.id))
  #expect(bridge.projectPane(movedPaneID)?.tabID == targetShortID.description)
}
