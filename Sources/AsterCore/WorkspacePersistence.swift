import Foundation

/// 编辑器的可测试文档状态。`persistedText` 只记录最近一次成功读取或保存的内容，
/// 因而保存失败时不会错误清除未保存标记。
public struct DocumentBuffer: Equatable, Sendable {
  public let fileURL: URL
  public private(set) var text: String
  public private(set) var persistedText: String

  public var isDirty: Bool { text != persistedText }

  public static func load(from fileURL: URL) throws -> DocumentBuffer {
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw DocumentBufferError.notRegularFile }
    guard (values.fileSize ?? 0) <= 10 * 1_024 * 1_024 else {
      throw DocumentBufferError.fileTooLarge
    }
    let text = try String(contentsOf: fileURL, encoding: .utf8)
    return DocumentBuffer(fileURL: fileURL, text: text, persistedText: text)
  }

  public mutating func updateText(_ newValue: String) {
    text = newValue
  }

  /// 使用 Foundation 的原子替换写入，避免进程中断留下半个文件。
  public mutating func save() throws {
    try text.write(to: fileURL, atomically: true, encoding: .utf8)
    persistedText = text
  }
}

public enum DocumentBufferError: Error, Equatable {
  case notRegularFile
  case fileTooLarge
}

public enum RecipeStoreError: Error, Equatable {
  case invalidFileExtension
  case notRegularFile
  case fileTooLarge
  case tooManyTabs
  case tooManyPanes
  case layoutTooDeep
  case duplicatePaneIdentifier
  case invalidSplitRatio
  case tooManyCommands
  case editorResourcesTooLarge
}

/// `.asterrecipe` 文件的唯一编解码入口。Recipe 不保存 PID 或文件描述符，打开时仅
/// 重建标签、分屏与可选命令，避免把失效的运行态写回新会话。
public enum RecipeStore {
  public static func save(_ recipe: WorkspaceRecipe, to fileURL: URL) throws {
    guard fileURL.pathExtension.lowercased() == "asterrecipe" else {
      throw RecipeStoreError.invalidFileExtension
    }
    try validate(recipe)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(recipe).write(to: fileURL, options: .atomic)
  }

  public static func load(from fileURL: URL) throws -> WorkspaceRecipe {
    guard fileURL.pathExtension.lowercased() == "asterrecipe" else {
      throw RecipeStoreError.invalidFileExtension
    }
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw RecipeStoreError.notRegularFile }
    guard (values.fileSize ?? 0) <= 2 * 1_024 * 1_024 else {
      throw RecipeStoreError.fileTooLarge
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= 2 * 1_024 * 1_024 else { throw RecipeStoreError.fileTooLarge }
    let recipe = try JSONDecoder().decode(WorkspaceRecipe.self, from: data)
    try validate(recipe)
    return recipe
  }

  /// 在创建任何运行态或 Shell 之前验证外部 Recipe 的资源上限和结构不变量。
  public static func validate(_ recipe: WorkspaceRecipe) throws {
    guard !recipe.tabs.isEmpty, recipe.tabs.count <= 32 else {
      throw RecipeStoreError.tooManyTabs
    }
    var paneIDs = Set<UUID>()
    var paneCount = 0
    var commandCount = 0
    var editorResourceBytes = 0
    for tab in recipe.tabs {
      try validate(
        layout: tab.layout,
        depth: 1,
        paneIDs: &paneIDs,
        paneCount: &paneCount,
        editorResourceBytes: &editorResourceBytes
      )
      commandCount += tab.commands.count
      guard commandCount <= 128,
        tab.commands.allSatisfy({ $0.utf8.count <= 4_096 })
      else { throw RecipeStoreError.tooManyCommands }
    }
    guard paneCount <= 64 else { throw RecipeStoreError.tooManyPanes }
  }

  private static func validate(
    layout: PaneLayout,
    depth: Int,
    paneIDs: inout Set<UUID>,
    paneCount: inout Int,
    editorResourceBytes: inout Int
  ) throws {
    guard depth <= 16 else { throw RecipeStoreError.layoutTooDeep }
    switch layout {
    case .leaf(let pane):
      guard paneIDs.insert(pane.id).inserted else {
        throw RecipeStoreError.duplicatePaneIdentifier
      }
      paneCount += 1
      guard paneCount <= 64 else { throw RecipeStoreError.tooManyPanes }
      guard pane.workingDirectory.utf8.count <= 4_096,
        (pane.resourcePath?.utf8.count ?? 0) <= 4_096
      else { throw RecipeStoreError.tooManyPanes }
      if pane.kind == .editor, let path = pane.resourcePath {
        let values = try? URL(fileURLWithPath: path).resourceValues(
          forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true {
          editorResourceBytes += max(values?.fileSize ?? 0, 0)
          guard editorResourceBytes <= 32 * 1_024 * 1_024 else {
            throw RecipeStoreError.editorResourcesTooLarge
          }
        }
      }
    case .split(_, let first, let second, let ratio):
      guard ratio.isFinite, (0.05...0.95).contains(ratio) else {
        throw RecipeStoreError.invalidSplitRatio
      }
      try validate(
        layout: first,
        depth: depth + 1,
        paneIDs: &paneIDs,
        paneCount: &paneCount,
        editorResourceBytes: &editorResourceBytes
      )
      try validate(
        layout: second,
        depth: depth + 1,
        paneIDs: &paneIDs,
        paneCount: &paneCount,
        editorResourceBytes: &editorResourceBytes
      )
    }
  }
}

/// 会话恢复快照仅描述可重建的工作区结构，不持久化进程身份和临时焦点。
public struct WorkspaceTabSnapshot: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var layout: PaneLayout
  /// OSC 动态标题与用户固定名称/前缀。可选字段保证旧快照继续按 `title` 恢复。
  public var titleState: TerminalTitleState?
  /// 可选时间戳兼容 0.4.1 之前的工作区快照；缺失时恢复层使用当前时间。
  public var createdAt: Date?
  public var updatedAt: Date?

  public init(
    id: UUID,
    title: String,
    layout: PaneLayout,
    titleState: TerminalTitleState? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.layout = layout
    self.titleState = titleState
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
  public var selectedTabID: UUID
  public var tabs: [WorkspaceTabSnapshot]
  /// 手动分隔线位于对应标签之后。可选字段保证旧工作区快照无损升级。
  public var dividerAfterTabIDs: [UUID]?

  public init(
    selectedTabID: UUID,
    tabs: [WorkspaceTabSnapshot],
    dividerAfterTabIDs: [UUID] = []
  ) {
    self.selectedTabID = selectedTabID
    self.tabs = tabs
    self.dividerAfterTabIDs = dividerAfterTabIDs
  }
}
