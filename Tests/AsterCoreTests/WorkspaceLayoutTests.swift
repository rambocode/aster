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
