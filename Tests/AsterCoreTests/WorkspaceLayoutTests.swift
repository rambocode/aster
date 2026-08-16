import Foundation
import Testing

@testable import AsterCore

@Test("面板可以按四个方向拆分并保持目标顺序", arguments: SplitDirection.allCases)
func paneLayoutSplitsInRequestedDirection(direction: SplitDirection) throws {
  let original = PaneDescriptor(
    id: UUID(),
    kind: .terminal,
    workingDirectory: "/tmp/project"
  )
  let inserted = PaneDescriptor(
    id: UUID(),
    kind: .fileBrowser,
    workingDirectory: "/tmp/project"
  )
  let layout = PaneLayout.leaf(original)

  let result = try #require(
    layout.splitting(paneID: original.id, direction: direction, with: inserted))

  #expect(result.allPanes.map(\.id).contains(original.id))
  #expect(result.allPanes.map(\.id).contains(inserted.id))
  #expect(result.axis == (direction.isHorizontal ? .horizontal : .vertical))
  let expectedFirst = direction == .left || direction == .up ? inserted.id : original.id
  #expect(result.firstPaneID == expectedFirst)
}

@Test("关闭分屏后会提升仍存在的相邻面板")
func removingPanePromotesSibling() throws {
  let first = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let second = PaneDescriptor(kind: .editor, workingDirectory: "/tmp", resourcePath: "/tmp/a.md")
  let layout = try #require(
    PaneLayout.leaf(first).splitting(paneID: first.id, direction: .right, with: second)
  )

  let result = try #require(layout.removing(paneID: first.id))

  #expect(result == .leaf(second))
}

@Test("嵌套分屏可以按路径更新比例且不会改变相邻节点")
func updatingSplitRatioPreservesOtherNodes() throws {
  let first = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let second = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let third = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let nested = PaneLayout.split(
    axis: .horizontal,
    first: .split(axis: .vertical, first: .leaf(first), second: .leaf(second), ratio: 0.4),
    second: .leaf(third),
    ratio: 0.6
  )

  let updated = nested.updatingSplitRatio(at: [0], ratio: 0.7)

  guard case .split(_, let updatedFirst, _, let outerRatio) = updated,
    case .split(_, _, _, let innerRatio) = updatedFirst
  else {
    Issue.record("更新后应继续保持两层分屏结构")
    return
  }
  #expect(outerRatio == 0.6)
  #expect(innerRatio == 0.7)
  #expect(updated.allPanes == nested.allPanes)
}

/// 三面板参考布局：左侧 A 占一半，右侧上下再分成 B / C。
/// 覆盖「轴向匹配」「跨层向上回溯」「垂直轴子树取边缘叶」三种导航分支。
private func makeThreePaneLayout() -> (layout: PaneLayout, a: UUID, b: UUID, c: UUID) {
  let a = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let b = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let c = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(a),
    second: .split(axis: .vertical, first: .leaf(b), second: .leaf(c), ratio: 0.3),
    ratio: 0.6
  )
  return (layout, a.id, b.id, c.id)
}

@Test("方向导航会跨层找到轴向匹配的相邻面板")
func adjacentPaneNavigationCrossesNestedSplits() {
  let (layout, a, b, c) = makeThreePaneLayout()

  #expect(layout.adjacentPaneID(from: a, direction: .right) == b)
  #expect(layout.adjacentPaneID(from: b, direction: .left) == a)
  #expect(layout.adjacentPaneID(from: c, direction: .left) == a)
  #expect(layout.adjacentPaneID(from: b, direction: .down) == c)
  #expect(layout.adjacentPaneID(from: c, direction: .up) == b)
}

@Test("没有对应方向的分隔条时方向导航不返回面板")
func adjacentPaneNavigationStopsAtTreeEdges() {
  let (layout, a, b, c) = makeThreePaneLayout()

  #expect(layout.adjacentPaneID(from: a, direction: .left) == nil)
  #expect(layout.adjacentPaneID(from: a, direction: .up) == nil)
  #expect(layout.adjacentPaneID(from: b, direction: .up) == nil)
  #expect(layout.adjacentPaneID(from: c, direction: .right) == nil)
  #expect(layout.adjacentPaneID(from: UUID(), direction: .right) == nil)
}

@Test("移动分隔条只会命中轴向匹配的最近祖先分屏")
func nearestSplitPathSelectsMatchingAxis() {
  let (layout, a, b, _) = makeThreePaneLayout()

  #expect(layout.nearestSplitPath(fromPane: b, axis: .vertical) == [1])
  #expect(layout.nearestSplitPath(fromPane: b, axis: .horizontal) == [])
  #expect(layout.nearestSplitPath(fromPane: a, axis: .vertical) == nil)
  #expect(layout.splitRatio(at: [1]) == 0.3)
  #expect(layout.splitRatio(at: []) == 0.6)
  #expect(layout.splitRatio(at: [0]) == nil)
}

@Test("等分拆分会重置所有层级的比例且不改变面板身份")
func equalizingRatiosResetsEveryLevel() {
  let (layout, _, _, _) = makeThreePaneLayout()

  let equalized = layout.equalizingRatios()

  #expect(equalized.splitRatio(at: []) == 0.5)
  #expect(equalized.splitRatio(at: [1]) == 0.5)
  #expect(equalized.allPanes == layout.allPanes)
}

@Test("关闭面板后焦点转移到相邻兄弟而不是第一个面板")
func neighborPaneIsPickedAfterClosing() {
  let (layout, a, b, c) = makeThreePaneLayout()

  #expect(layout.neighborPaneID(ofPane: b) == c)
  #expect(layout.neighborPaneID(ofPane: c) == b)
  #expect(layout.neighborPaneID(ofPane: a) == b)
  #expect(PaneLayout.leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")).neighborPaneID(ofPane: a) == nil)
}

@Test("面板路径可以定位到具体子树")
func paneLookupResolvesPathsAndNodes() throws {
  let (layout, a, b, _) = makeThreePaneLayout()

  #expect(layout.path(toPane: a) == [0])
  #expect(layout.path(toPane: b) == [1, 0])
  #expect(layout.path(toPane: UUID()) == nil)
  #expect(layout.node(at: [0]) == .leaf(try #require(layout.allPanes.first)))
  #expect(layout.node(at: [0, 0]) == nil)
  #expect(layout.node(at: [2]) == nil)
}

@Test("拖放到中心交换两个面板且不改变分屏结构")
func swappingPanesKeepsStructure() {
  let (layout, a, b, c) = makeThreePaneLayout()

  let swapped = layout.swappingPanes(a, c)

  #expect(swapped.firstPaneID == c)
  #expect(swapped.path(toPane: a) == [1, 1])
  #expect(swapped.path(toPane: b) == [1, 0])
  #expect(swapped.splitRatio(at: []) == layout.splitRatio(at: []))
  #expect(swapped.splitRatio(at: [1]) == layout.splitRatio(at: [1]))
  // 与自身交换、或面板不存在时保持原样。
  #expect(layout.swappingPanes(a, a) == layout)
  #expect(layout.swappingPanes(a, UUID()) == layout)
}

@Test("拖放到边缘会把面板搬到目标面板的指定一侧")
func movingPaneReattachesNextToTarget() throws {
  let (layout, a, b, c) = makeThreePaneLayout()

  // 把 B 移到 A 下方：B 原来的兄弟 C 会被提升，右侧不再有嵌套分屏。
  let moved = try #require(layout.movingPane(b, nextTo: a, direction: .down))

  #expect(moved.allPanes.count == 3)
  #expect(moved.path(toPane: a) == [0, 0])
  #expect(moved.path(toPane: b) == [0, 1])
  #expect(moved.path(toPane: c) == [1])
  #expect(moved.node(at: [0])?.axis == .vertical)

  #expect(layout.movingPane(a, nextTo: a, direction: .right) == nil)
  #expect(layout.movingPane(a, nextTo: UUID(), direction: .right) == nil)
}

@Test("Recipe 可以无损保存标签布局和命令")
func recipeRoundTripsThroughJSON() throws {
  let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp/project")
  let recipe = WorkspaceRecipe(
    name: "开发环境",
    tabs: [
      RecipeTab(title: "api", layout: .leaf(pane), commands: ["pnpm dev", "git status"])
    ],
    replayMode: .confirmOnce
  )

  let data = try JSONEncoder().encode(recipe)
  let decoded = try JSONDecoder().decode(WorkspaceRecipe.self, from: data)

  #expect(decoded == recipe)
}

@Test("标签栏布局包含 Otty 的三个可见方向")
func tabLayoutsMatchReference() {
  #expect(TabBarLayout.allCases == [.vertical, .top, .bottom])
}

// 项目分组组头的显示真值：完整路径（home 缩写为 ~）+ 尾部斜杠，同名目录不合并。
@Test("项目分组标题显示完整目录并把 home 缩写为 ~")
func projectGroupTitleShowsFullDirectory() {
  func title(_ directory: String, fallback: String = "shell") -> String {
    SidebarTabGrouping.projectGroupTitle(
      forDirectory: directory, homeDirectory: "/Users/mike", fallback: fallback)
  }

  #expect(title("/Users/mike/source/project/aster") == "~/source/project/aster/")
  // 尾部斜杠先归一化再拼接，不产生双斜杠。
  #expect(title("/Users/mike/source/ai/raglite/") == "~/source/ai/raglite/")
  #expect(title("/Users/mike") == "~/")
  // home 之外的目录保持绝对路径。
  #expect(title("/opt/homebrew/bin") == "/opt/homebrew/bin/")
  // 前缀相似但不是 home 子目录的路径不得被缩写。
  #expect(title("/Users/mike2/repo") == "/Users/mike2/repo/")
  #expect(title("/") == "/")
  // 目录缺失时回退标签标题，不产生空组头。
  #expect(title("", fallback: "zsh") == "zsh")
  // 同名目录因完整路径不同而分属不同组。
  #expect(title("/Users/mike/a/src") != title("/Users/mike/b/src"))
}
