import Foundation
import Testing

@testable import AsterCore

@Test("关闭当前标签后会选择右侧相邻标签")
func closingSelectedTabChoosesNeighbor() {
  let first = TerminalTab(id: UUID(), title: "api", workingDirectory: "/tmp/api")
  let second = TerminalTab(id: UUID(), title: "web", workingDirectory: "/tmp/web")
  var workspace = WorkspaceState(tabs: [first, second], selectedTabID: first.id)

  workspace.closeTab(id: first.id)

  #expect(workspace.tabs == [second])
  #expect(workspace.selectedTabID == second.id)
}

@Test("工作区始终保留至少一个终端标签")
func closingLastTabCreatesReplacement() {
  let only = TerminalTab(id: UUID(), title: "shell", workingDirectory: "/tmp")
  var workspace = WorkspaceState(tabs: [only], selectedTabID: only.id)

  workspace.closeTab(id: only.id)

  #expect(workspace.tabs.count == 1)
  #expect(workspace.selectedTabID == workspace.tabs[0].id)
}

@Test("命令面板同时按标题和关键词过滤")
func commandPaletteFiltersKeywords() {
  let commands = [
    PaletteCommand(id: "split", title: "向右分屏", keywords: ["pane", "split"]),
    PaletteCommand(id: "settings", title: "打开设置", keywords: ["preferences"]),
  ]

  #expect(CommandPalette.filter(commands, query: "pane").map(\.id) == ["split"])
  #expect(CommandPalette.filter(commands, query: "设置").map(\.id) == ["settings"])
}
