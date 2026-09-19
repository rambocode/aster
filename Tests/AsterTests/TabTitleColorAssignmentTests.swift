import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 标签标题颜色的分配路径：恢复旧快照要补齐，新建标签不能与现有标签撞色。

@MainActor
private func makeRestoredModel(tabCount: Int) throws -> (AppModel, UserDefaults, String) {
  let suite = "TabTitleColor.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)

  let home = FileManager.default.homeDirectoryForCurrentUser.path
  // 旧快照的形态：没有 titleColor / autoTitleColorIndex 两个字段。
  let tabs = (0..<tabCount).map { index in
    WorkspaceTabSnapshot(
      id: UUID(),
      title: "restored-\(index)",
      layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home))
    )
  }
  let snapshot = WorkspaceSnapshot(selectedTabID: tabs[0].id, tabs: tabs)
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")
  return (AppModel(defaults: defaults), defaults, suite)
}

@MainActor
private func stop(_ model: AppModel, defaults: UserDefaults, suite: String) {
  for tab in model.tabs {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
  }
  defaults.removePersistentDomain(forName: suite)
}

@Test("恢复没有颜色字段的旧快照时补齐自动颜色且互不重复")
@MainActor
func restoredTabsGetDistinctAutoTitleColors() throws {
  let (model, defaults, suite) = try makeRestoredModel(tabCount: 3)
  defer { stop(model, defaults: defaults, suite: suite) }

  model.ensureInitialTab()

  let indices = model.tabs.map(\.autoTitleColorIndex)
  #expect(indices.allSatisfy { $0 != nil })
  #expect(Set(indices.compactMap { $0 }).count == model.tabs.count)
}

@Test("新建标签不会和已有标签撞色")
@MainActor
func newTabAvoidsColorsAlreadyInUse() throws {
  let (model, defaults, suite) = try makeRestoredModel(tabCount: 2)
  defer { stop(model, defaults: defaults, suite: suite) }

  model.ensureInitialTab()
  let existing = Set(model.tabs.compactMap(\.autoTitleColorIndex))
  model.newTab()

  let created = try #require(model.selectedTab?.autoTitleColorIndex)
  #expect(!existing.contains(created))
}

@Test("手动颜色优先于自动色；关掉随机开关后只保留手动色")
@MainActor
func manualColorOverridesAutoColor() throws {
  let (model, defaults, suite) = try makeRestoredModel(tabCount: 1)
  defer { stop(model, defaults: defaults, suite: suite) }

  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  #expect(tab.resolvedTitleColor(randomColorsEnabled: true) != nil)
  // 关掉随机颜色：自动色不再渲染。
  #expect(tab.resolvedTitleColor(randomColorsEnabled: false) == nil)

  let manual = HexColor(red: 0x12, green: 0x34, blue: 0x56)
  model.setTabTitleColor(manual, for: tab.id)
  #expect(tab.resolvedTitleColor(randomColorsEnabled: true) == manual)
  // 手动色与开关无关，关掉随机颜色也照样显示。
  #expect(tab.resolvedTitleColor(randomColorsEnabled: false) == manual)

  model.setTabTitleColor(nil, for: tab.id)
  #expect(tab.resolvedTitleColor(randomColorsEnabled: false) == nil)
}

@Test("换一个随机颜色会换掉当前自动色并清掉手动色")
@MainActor
func shuffleReplacesColor() throws {
  let (model, defaults, suite) = try makeRestoredModel(tabCount: 1)
  defer { stop(model, defaults: defaults, suite: suite) }

  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  model.setTabTitleColor(HexColor(red: 0, green: 0, blue: 0), for: tab.id)
  let before = try #require(tab.autoTitleColorIndex)

  model.shuffleTabTitleColor(for: tab.id)

  #expect(tab.titleColor == nil)
  #expect(tab.autoTitleColorIndex != before)
  #expect(tab.resolvedTitleColor(randomColorsEnabled: true) != nil)
}

@Test("标题颜色随工作区快照往返")
@MainActor
func titleColorSurvivesSnapshotRoundTrip() throws {
  let (model, defaults, suite) = try makeRestoredModel(tabCount: 1)
  defer { stop(model, defaults: defaults, suite: suite) }

  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let manual = HexColor(red: 0xAB, green: 0xCD, blue: 0xEF)
  model.setTabTitleColor(manual, for: tab.id)

  let snapshot = tab.snapshot
  #expect(snapshot.titleColor == manual)
  #expect(snapshot.autoTitleColorIndex == tab.autoTitleColorIndex)

  let restored = TerminalTabItem(snapshot: snapshot)
  defer { for runtime in restored.runtimes.values { runtime.terminalSession?.stop(immediately: true) } }
  #expect(restored.titleColor == manual)
  #expect(restored.autoTitleColorIndex == tab.autoTitleColorIndex)
}
