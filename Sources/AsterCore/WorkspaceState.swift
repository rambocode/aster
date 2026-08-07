import Foundation

/// 一个终端标签页的持久身份与可见元数据。
public struct TerminalTab: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var workingDirectory: String

  public init(id: UUID = UUID(), title: String, workingDirectory: String) {
    self.id = id
    self.title = title
    self.workingDirectory = workingDirectory
  }
}

/// 管理窗口内标签页的选择与关闭规则。
public struct WorkspaceState: Equatable, Sendable {
  public private(set) var tabs: [TerminalTab]
  public private(set) var selectedTabID: UUID

  public init(tabs: [TerminalTab], selectedTabID: UUID) {
    if tabs.isEmpty {
      let fallback = Self.makeFallbackTab()
      self.tabs = [fallback]
      self.selectedTabID = fallback.id
    } else {
      self.tabs = tabs
      self.selectedTabID =
        tabs.contains(where: { $0.id == selectedTabID })
        ? selectedTabID
        : tabs[0].id
    }
  }

  /// 关闭指定标签。关闭最后一个标签时立即创建替代会话，确保工作区可继续使用。
  public mutating func closeTab(id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let wasSelected = selectedTabID == id
    tabs.remove(at: index)

    if tabs.isEmpty {
      let fallback = Self.makeFallbackTab()
      tabs = [fallback]
      selectedTabID = fallback.id
    } else if wasSelected {
      selectedTabID = tabs[min(index, tabs.count - 1)].id
    }
  }

  private static func makeFallbackTab() -> TerminalTab {
    TerminalTab(
      title: "shell",
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )
  }
}

/// 命令面板中的可搜索动作描述。
public struct PaletteCommand: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let keywords: [String]

  public init(id: String, title: String, keywords: [String] = []) {
    self.id = id
    self.title = title
    self.keywords = keywords
  }
}

/// 为命令面板提供与 UI 无关的稳定过滤逻辑。
public enum CommandPalette {
  public static func filter(_ commands: [PaletteCommand], query: String) -> [PaletteCommand] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return commands }

    return commands.filter { command in
      ([command.title] + command.keywords).contains { value in
        value.range(
          of: needle,
          options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
      }
    }
  }
}
