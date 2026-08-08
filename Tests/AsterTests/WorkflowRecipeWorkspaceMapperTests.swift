import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("Recipe 布局路径可移植往返保留嵌套比例、Pane 类型和资源")
func workflowRecipeLayoutMapperPreservesExactLayout() throws {
  let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
  let terminal = PaneDescriptor(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    kind: .terminal,
    workingDirectory: "/Users/tester/project"
  )
  let editor = PaneDescriptor(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    kind: .editor,
    workingDirectory: "/Users/tester/project",
    resourcePath: "/Users/tester/project/README.md"
  )
  let browser = PaneDescriptor(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
    kind: .fileBrowser,
    workingDirectory: "/Users/tester/project/Sources",
    resourcePath: "/Users/tester/project/Sources"
  )
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(terminal),
    second: .split(
      axis: .vertical,
      first: .leaf(editor),
      second: .leaf(browser),
      ratio: 0.37
    ),
    ratio: 0.62
  )

  let portable = WorkflowRecipeWorkspaceMapper.makePortable(layout, home: home)
  let restored = try WorkflowRecipeWorkspaceMapper.resolve(
    portable,
    context: WorkflowPortablePathContext(
      currentFolder: URL(fileURLWithPath: "/tmp/current"),
      homeFolder: home,
      recipeLocation: URL(fileURLWithPath: "/tmp/recipes")
    )
  )

  #expect(portable.allPanes[0].workingDirectory == "{{home_folder}}/project")
  #expect(portable.allPanes[1].resourcePath == "{{home_folder}}/project/README.md")
  #expect(restored == layout)
}

@Test("重复打开同一 Recipe 会生成互不冲突的 Pane 运行身份")
func workflowRecipeLayoutMapperRegeneratesRuntimePaneIdentifiers() {
  let source = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(PaneDescriptor(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      kind: .terminal,
      workingDirectory: "/tmp"
    )),
    second: .leaf(PaneDescriptor(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      kind: .editor,
      workingDirectory: "/tmp",
      resourcePath: "/tmp/readme.md"
    )),
    ratio: 0.37
  )

  let first = WorkflowRecipeWorkspaceMapper.instantiate(source)
  let second = WorkflowRecipeWorkspaceMapper.instantiate(source)
  let sourceIDs = Set(source.allPanes.map(\.id))
  let firstIDs = Set(first.allPanes.map(\.id))
  let secondIDs = Set(second.allPanes.map(\.id))

  #expect(sourceIDs.isDisjoint(with: firstIDs))
  #expect(firstIDs.isDisjoint(with: secondIDs))
  #expect(first.axis == .horizontal)
  #expect(first.allPanes.map(\.kind) == [.terminal, .editor])
  #expect(first.allPanes.map(\.resourcePath) == [nil, "/tmp/readme.md"])
}
