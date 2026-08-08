import Foundation

/// Recipe 保存范围。取值与 `.ottyrecipe` 的 `recipe.scope` 保持一致。
public enum WorkflowRecipeScope: String, Codable, Equatable, Sendable {
  case tab
  case window
  case commands
}

/// Recipe 在内部数据库中可保存的内容级别。
///
/// 外部 TOML 文件不会携带 scrollback；导出 `.includeScrollback` Recipe 时，编码器只输出
/// 布局和命令，解码后自然降级为 `.includeCommands` 或 `.layoutOnly`。
public enum WorkflowRecipeContent: String, Codable, Equatable, Sendable {
  case layoutOnly
  case includeCommands
  case includeScrollback
}

/// Shell Integration 命令历史的来源。由旧 Recipe replay 的命令不能再次保存进新 Recipe。
public enum WorkflowRecipeCommandOrigin: String, Codable, Equatable, Sendable {
  case shellIntegration
  case recipeReplay
}

public struct WorkflowRecipeCommandCandidate: Codable, Equatable, Sendable {
  public let text: String
  public let origin: WorkflowRecipeCommandOrigin

  public init(text: String, origin: WorkflowRecipeCommandOrigin) {
    self.text = text
    self.origin = origin
  }
}

/// 从 Shell Integration 的 oldest-first 历史中选择可保存命令，防止 replay 内容在多次
/// 保存、打开后层层累积。
public enum WorkflowRecipeCommandCapture {
  public static func commands(from candidates: [WorkflowRecipeCommandCandidate]) throws -> [String]
  {
    let selected = candidates.filter { $0.origin == .shellIntegration }.map(\.text)
    guard selected.count <= WorkflowRecipeTOML.maximumCommands else {
      throw WorkflowRecipeTOMLError.tooManyCommands
    }
    for command in selected {
      guard !command.isEmpty, command.utf8.count <= WorkflowRecipeTOML.maximumCommandBytes else {
        throw WorkflowRecipeTOMLError.valueTooLong("command")
      }
      guard
        !command.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        })
      else { throw WorkflowRecipeTOMLError.invalidValue("command", line: 0) }
    }
    return selected
  }
}

/// 一份 Recipe 中的 Pane。`split` 描述当前 Pane 相对前一个 Pane 的兼容拆分方向。
///
/// `kind` 和 `resourcePath` 是对旧格式的向后兼容扩展：旧 Recipe 缺少 `kind` 时按终端
/// 处理，缺少 `resource_path` 时表示 Pane 没有关联资源。精确嵌套结构由 Tab 的
/// `layout` 保存；这里继续保留线性字段，以便旧版本仍能读取基础布局和命令。
public struct WorkflowRecipePane: Codable, Equatable, Sendable {
  public var workingDirectory: String
  public var kind: PaneKind
  public var resourcePath: String?
  public var split: SplitDirection?
  public var size: Double?
  public var commands: [String]
  public var scrollback: String?

  public init(
    workingDirectory: String,
    kind: PaneKind = .terminal,
    resourcePath: String? = nil,
    split: SplitDirection? = nil,
    size: Double? = nil,
    commands: [String] = [],
    scrollback: String? = nil
  ) {
    self.workingDirectory = workingDirectory
    self.kind = kind
    self.resourcePath = resourcePath
    self.split = split
    self.size = size
    self.commands = commands
    self.scrollback = scrollback
  }

  private enum CodingKeys: String, CodingKey {
    case workingDirectory
    case kind
    case resourcePath
    case split
    case size
    case commands
    case scrollback
  }

  /// 为旧的内部 Codable 数据补齐新增字段，避免历史保存记录因缺少 `kind` 而失效。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    kind = try container.decodeIfPresent(PaneKind.self, forKey: .kind) ?? .terminal
    resourcePath = try container.decodeIfPresent(String.self, forKey: .resourcePath)
    split = try container.decodeIfPresent(SplitDirection.self, forKey: .split)
    size = try container.decodeIfPresent(Double.self, forKey: .size)
    commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
    scrollback = try container.decodeIfPresent(String.self, forKey: .scrollback)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(resourcePath, forKey: .resourcePath)
    try container.encodeIfPresent(split, forKey: .split)
    try container.encodeIfPresent(size, forKey: .size)
    try container.encode(commands, forKey: .commands)
    try container.encodeIfPresent(scrollback, forKey: .scrollback)
  }
}

public struct WorkflowRecipeTab: Codable, Equatable, Sendable {
  public var title: String
  public var panes: [WorkflowRecipePane]
  /// 可选的精确分屏树。为 `nil` 时表示来自旧 Recipe，调用方按 `panes` 的线性
  /// `split/size` 信息重建；非空时必须与 `panes` 的叶节点顺序和描述完全一致。
  public var layout: PaneLayout?

  public init(title: String, panes: [WorkflowRecipePane], layout: PaneLayout? = nil) {
    self.title = title
    self.panes = panes
    self.layout = layout
  }
}

/// Otty Workflows 的可移植 Recipe 领域模型。
///
/// `commands` 只用于 `.commands` scope；Tab/Window Recipe 的命令位于对应 Pane。来源和
/// 信任状态不写进 Recipe 内容，避免复制文件时把本机信任一并传播。
public struct WorkflowRecipe: Codable, Equatable, Sendable {
  public var name: String
  public var version: Int
  public var scope: WorkflowRecipeScope
  public var content: WorkflowRecipeContent
  public var tabs: [WorkflowRecipeTab]
  public var commands: [String]

  public init(
    name: String,
    version: Int = 1,
    scope: WorkflowRecipeScope,
    content: WorkflowRecipeContent,
    tabs: [WorkflowRecipeTab] = [],
    commands: [String] = []
  ) {
    self.name = name
    self.version = version
    self.scope = scope
    self.content = content
    self.tabs = tabs
    self.commands = commands
  }

  /// 按 Tab、Pane 顺序返回所有命令，供信任提示完整展示将要 replay 的内容。
  public var allCommands: [String] {
    if scope == .commands { return commands }
    return tabs.flatMap { $0.panes.flatMap(\.commands) }
  }
}

/// 调用导入器时由上层明确提供的来源类别。
public enum WorkflowRecipeImportSource: Equatable, Sendable {
  case savedRecipe
  case recipeFile
}

/// 导入后的来源证据。内部 Recipe 隐式可信；外部文件绑定其精确字节的 SHA-256。
public enum WorkflowRecipeSource: Equatable, Sendable {
  case savedRecipe
  case recipeFile(sha256: String)
}

public struct WorkflowRecipeEnvelope: Equatable, Sendable {
  public let recipe: WorkflowRecipe
  public let source: WorkflowRecipeSource

  public init(recipe: WorkflowRecipe, source: WorkflowRecipeSource) {
    self.recipe = recipe
    self.source = source
  }
}

public enum WorkflowRecipeTOMLError: Error, Equatable {
  case invalidFileExtension
  case notRegularFile
  case fileTooLarge
  case invalidUTF8
  case malformedLine(Int)
  case unsupportedTable(String, line: Int)
  case unknownKey(String, line: Int)
  case duplicateKey(String, line: Int)
  case missingValue(String)
  case invalidValue(String, line: Int)
  case unsupportedVersion(Int)
  case invalidStructure
  case tooManyTabs
  case tooManyPanes
  case tooManyCommands
  case layoutTooDeep
  case duplicatePaneIdentifier
  case valueTooLong(String)
}

/// `.ottyrecipe` 的有界 TOML 编解码入口。
///
/// 这里有意只接受官方 Recipe 文档公开的表和标量类型，不把它做成宽松的通用 TOML
/// 解析器。拒绝未知结构可以避免拼写错误被静默忽略，也让外部文件在创建任何运行态前
/// 完成大小、数量和字符串边界校验。
public enum WorkflowRecipeTOML {
  public static let maximumEncodedBytes = 2 * 1_024 * 1_024
  public static let maximumTabs = 32
  public static let maximumPanes = 64
  public static let maximumCommands = 128
  public static let maximumCommandBytes = 4_096
  public static let maximumPathBytes = 4_096
  /// 布局载荷另设上限，避免小量 Pane 借递归 Codable 字符串消耗完整 2 MiB 文件预算。
  public static let maximumLayoutBytes = 256 * 1_024
  public static let maximumLayoutDepth = 16

  /// 从普通 `.ottyrecipe` 文件导入，并将信任摘要绑定到实际读取的精确字节。
  public static func load(from fileURL: URL) throws -> WorkflowRecipeEnvelope {
    guard fileURL.pathExtension.lowercased() == "ottyrecipe" else {
      throw WorkflowRecipeTOMLError.invalidFileExtension
    }
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw WorkflowRecipeTOMLError.notRegularFile }
    guard (values.fileSize ?? 0) <= maximumEncodedBytes else {
      throw WorkflowRecipeTOMLError.fileTooLarge
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= maximumEncodedBytes else { throw WorkflowRecipeTOMLError.fileTooLarge }
    return try decode(data, source: .recipeFile)
  }

  /// 以原子替换写出稳定 TOML，避免中断后留下可被误信任的半文件。
  public static func save(_ recipe: WorkflowRecipe, to fileURL: URL) throws {
    guard fileURL.pathExtension.lowercased() == "ottyrecipe" else {
      throw WorkflowRecipeTOMLError.invalidFileExtension
    }
    try encode(recipe).write(to: fileURL, options: .atomic)
  }

  public static func decode(
    _ data: Data,
    source: WorkflowRecipeImportSource
  ) throws -> WorkflowRecipeEnvelope {
    guard data.count <= maximumEncodedBytes else { throw WorkflowRecipeTOMLError.fileTooLarge }
    guard let text = String(data: data, encoding: .utf8) else {
      throw WorkflowRecipeTOMLError.invalidUTF8
    }

    var parser = Parser(text: text)
    let recipe = try parser.parse()
    try validate(recipe)
    let resolvedSource: WorkflowRecipeSource =
      switch source {
      case .savedRecipe: .savedRecipe
      case .recipeFile: .recipeFile(sha256: WorkflowSHA256.digest(data))
      }
    return WorkflowRecipeEnvelope(recipe: recipe, source: resolvedSource)
  }

  /// 输出稳定、可读且可 diff 的 TOML。外部格式按官方约束永不写出 scrollback。
  public static func encode(_ recipe: WorkflowRecipe) throws -> Data {
    try validate(recipe)
    var lines = [
      "[recipe]",
      "name = \(encodeString(recipe.name))",
      "version = \(recipe.version)",
      "scope = \(encodeString(recipe.scope.rawValue))",
    ]

    if recipe.scope == .commands {
      lines.append("commands = \(encodeArray(recipe.commands))")
    } else {
      for tab in recipe.tabs {
        lines.append("")
        lines.append("[[window.tabs]]")
        lines.append("title = \(encodeString(tab.title))")
        if let layout = tab.layout {
          // PaneLayout 已有稳定 Codable 边界；把其紧凑 JSON 放进单个 TOML 字符串，可在
          // 不扩张手写 TOML 语法的前提下保留任意嵌套树，并让旧读取器忽略不了未知字段。
          lines.append("layout = \(encodeString(try encodeLayout(layout)))")
        }
        for pane in tab.panes {
          lines.append("")
          lines.append("[[window.tabs.panes]]")
          lines.append("cwd = \(encodeString(pane.workingDirectory))")
          if pane.kind != .terminal {
            lines.append("kind = \(encodeString(pane.kind.rawValue))")
          }
          if let resourcePath = pane.resourcePath {
            lines.append("resource_path = \(encodeString(resourcePath))")
          }
          if let split = pane.split {
            lines.append("split = \(encodeString(split.rawValue))")
          }
          if let size = pane.size {
            lines.append("size = \(size)")
          }
          if !pane.commands.isEmpty {
            lines.append("commands = \(encodeArray(pane.commands))")
          }
        }
      }
    }

    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    guard data.count <= maximumEncodedBytes else { throw WorkflowRecipeTOMLError.fileTooLarge }
    return data
  }

  /// 对内存中创建和外部导入的 Recipe 使用同一组结构上限。
  public static func validate(_ recipe: WorkflowRecipe) throws {
    guard recipe.version == 1 else {
      throw WorkflowRecipeTOMLError.unsupportedVersion(recipe.version)
    }
    try validateText(recipe.name, maximumBytes: 256, field: "recipe.name", allowEmpty: false)

    switch recipe.scope {
    case .commands:
      guard recipe.tabs.isEmpty, !recipe.commands.isEmpty else {
        throw WorkflowRecipeTOMLError.invalidStructure
      }
    case .tab:
      guard recipe.tabs.count == 1, recipe.commands.isEmpty else {
        throw WorkflowRecipeTOMLError.invalidStructure
      }
    case .window:
      guard !recipe.tabs.isEmpty, recipe.commands.isEmpty else {
        throw WorkflowRecipeTOMLError.invalidStructure
      }
    }

    guard recipe.tabs.count <= maximumTabs else { throw WorkflowRecipeTOMLError.tooManyTabs }
    var paneCount = 0
    var commandCount = recipe.commands.count
    var paneIDs = Set<UUID>()
    for tab in recipe.tabs {
      try validateText(tab.title, maximumBytes: 256, field: "tab.title", allowEmpty: false)
      guard !tab.panes.isEmpty else { throw WorkflowRecipeTOMLError.invalidStructure }
      paneCount += tab.panes.count
      guard paneCount <= maximumPanes else { throw WorkflowRecipeTOMLError.tooManyPanes }
      for (index, pane) in tab.panes.enumerated() {
        try validateText(
          pane.workingDirectory,
          maximumBytes: maximumPathBytes,
          field: "pane.cwd",
          allowEmpty: false
        )
        try WorkflowPortablePath.validateTemplate(pane.workingDirectory)
        if let resourcePath = pane.resourcePath {
          try validateText(
            resourcePath,
            maximumBytes: maximumPathBytes,
            field: "pane.resource_path",
            allowEmpty: false
          )
          try WorkflowPortablePath.validateTemplate(resourcePath)
        }
        if index == 0, pane.split != nil || pane.size != nil {
          throw WorkflowRecipeTOMLError.invalidStructure
        }
        if index > 0, pane.split == nil {
          throw WorkflowRecipeTOMLError.invalidStructure
        }
        if pane.size != nil, pane.split == nil {
          throw WorkflowRecipeTOMLError.invalidStructure
        }
        if let size = pane.size, !size.isFinite || !(0...1).contains(size) {
          throw WorkflowRecipeTOMLError.invalidValue("size", line: 0)
        }
        commandCount += pane.commands.count
        if let scrollback = pane.scrollback {
          try validateText(
            scrollback,
            maximumBytes: 1_048_576,
            field: "pane.scrollback",
            allowEmpty: true
          )
        }
      }

      if let layout = tab.layout {
        var layoutPanes: [PaneDescriptor] = []
        try validate(
          layout: layout,
          depth: 1,
          paneIDs: &paneIDs,
          panes: &layoutPanes
        )
        guard layoutPanes.count == tab.panes.count else {
          throw WorkflowRecipeTOMLError.invalidStructure
        }
        for (descriptor, pane) in zip(layoutPanes, tab.panes) {
          // 两份描述必须一致，防止旧线性字段与精确布局表达不同资源，导致不同版本
          // 的 Aster 打开同一文件时出现安全和行为分歧。命令只保存在 pane 表中。
          guard descriptor.kind == pane.kind,
            descriptor.workingDirectory == pane.workingDirectory,
            descriptor.resourcePath == pane.resourcePath
          else { throw WorkflowRecipeTOMLError.invalidStructure }
        }
        // 结构深度先通过上面的递归校验，再计算 Codable 载荷大小，避免让编码器先
        // 处理无界深树；公开 validate 与实际 encode 因而共享同一累计字节上限。
        _ = try encodeLayout(layout)
      }
    }
    guard commandCount <= maximumCommands else { throw WorkflowRecipeTOMLError.tooManyCommands }
    for command in recipe.allCommands {
      try validateText(
        command,
        maximumBytes: maximumCommandBytes,
        field: "command",
        allowEmpty: false,
        allowNewlines: false
      )
    }

    let hasCommands = !recipe.allCommands.isEmpty
    switch recipe.content {
    case .layoutOnly where hasCommands:
      throw WorkflowRecipeTOMLError.invalidStructure
    case .includeCommands where !hasCommands:
      throw WorkflowRecipeTOMLError.invalidStructure
    case .includeScrollback:
      // Scrollback 只属于内部 Recipe；是否每个 Pane 都有内容不影响结构有效性。
      break
    default:
      break
    }
  }

  /// 递归校验精确布局，并按稳定的 first/second 深度优先顺序收集叶节点。
  /// 先检查深度再进入子节点，避免恶意外部数据构造无界递归运行态。
  private static func validate(
    layout: PaneLayout,
    depth: Int,
    paneIDs: inout Set<UUID>,
    panes: inout [PaneDescriptor]
  ) throws {
    guard depth <= maximumLayoutDepth else {
      throw WorkflowRecipeTOMLError.layoutTooDeep
    }
    switch layout {
    case .leaf(let pane):
      guard paneIDs.insert(pane.id).inserted else {
        throw WorkflowRecipeTOMLError.duplicatePaneIdentifier
      }
      guard panes.count < maximumPanes else { throw WorkflowRecipeTOMLError.tooManyPanes }
      try validateText(
        pane.workingDirectory,
        maximumBytes: maximumPathBytes,
        field: "layout.pane.cwd",
        allowEmpty: false
      )
      try WorkflowPortablePath.validateTemplate(pane.workingDirectory)
      if let resourcePath = pane.resourcePath {
        try validateText(
          resourcePath,
          maximumBytes: maximumPathBytes,
          field: "layout.pane.resource_path",
          allowEmpty: false
        )
        try WorkflowPortablePath.validateTemplate(resourcePath)
      }
      panes.append(pane)
    case .split(_, let first, let second, let ratio):
      guard ratio.isFinite, (0.05...0.95).contains(ratio) else {
        throw WorkflowRecipeTOMLError.invalidValue("layout.ratio", line: 0)
      }
      try validate(
        layout: first,
        depth: depth + 1,
        paneIDs: &paneIDs,
        panes: &panes
      )
      try validate(
        layout: second,
        depth: depth + 1,
        paneIDs: &paneIDs,
        panes: &panes
      )
    }
  }

  private static func validateText(
    _ value: String,
    maximumBytes: Int,
    field: String,
    allowEmpty: Bool,
    allowNewlines: Bool = false
  ) throws {
    guard allowEmpty || !value.isEmpty else { throw WorkflowRecipeTOMLError.missingValue(field) }
    guard value.utf8.count <= maximumBytes else {
      throw WorkflowRecipeTOMLError.valueTooLong(field)
    }
    let containsRejectedControl = value.unicodeScalars.contains { scalar in
      if allowNewlines, scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
      return CharacterSet.controlCharacters.contains(scalar)
    }
    guard !containsRejectedControl else {
      throw WorkflowRecipeTOMLError.invalidValue(field, line: 0)
    }
  }

  private static func encodeString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default: result.unicodeScalars.append(scalar)
      }
    }
    result += "\""
    return result
  }

  private static func encodeArray(_ values: [String]) -> String {
    "[" + values.map(encodeString).joined(separator: ", ") + "]"
  }

  /// 使用 PaneLayout 现有 Codable 表达保存完整树；排序键保证相同布局稳定输出。
  private static func encodeLayout(_ layout: PaneLayout) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(layout)
    guard data.count <= maximumLayoutBytes else {
      throw WorkflowRecipeTOMLError.valueTooLong("tab.layout")
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// 解码前先限制载荷字节数和 JSON 容器嵌套，避免在领域层深度校验前让通用解码器
  /// 处理攻击者构造的极深结构。最终 PaneLayout 深度仍由 `validate` 精确限制为 16。
  private static func decodeLayout(_ value: String, line: Int) throws -> PaneLayout {
    try validateText(
      value,
      maximumBytes: maximumLayoutBytes,
      field: "tab.layout",
      allowEmpty: false
    )
    try validateLayoutJSONContainerDepth(value)
    do {
      return try JSONDecoder().decode(PaneLayout.self, from: Data(value.utf8))
    } catch let error as WorkflowRecipeTOMLError {
      throw error
    } catch {
      throw WorkflowRecipeTOMLError.invalidValue("tab.layout", line: line)
    }
  }

  private static func validateLayoutJSONContainerDepth(_ value: String) throws {
    let maximumContainerDepth = maximumLayoutDepth * 4
    var depth = 0
    var quoted = false
    var escaped = false
    for character in value {
      if quoted {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          quoted = false
        }
        continue
      }
      if character == "\"" {
        quoted = true
      } else if character == "{" || character == "[" {
        depth += 1
        guard depth <= maximumContainerDepth else {
          throw WorkflowRecipeTOMLError.layoutTooDeep
        }
      } else if character == "}" || character == "]" {
        depth = max(depth - 1, 0)
      }
    }
  }

  private struct TabBuilder {
    var title: String?
    var layout: PaneLayout?
    var didSetLayout = false
    var panes: [PaneBuilder] = []
  }

  private struct PaneBuilder {
    var cwd: String?
    var kind: PaneKind?
    var resourcePath: String?
    var didSetResourcePath = false
    var split: SplitDirection?
    var didSetSplit = false
    var size: Double?
    var commands: [String]?
  }

  private struct Parser {
    let text: String
    var recipeName: String?
    var recipeVersion: Int?
    var recipeScope: WorkflowRecipeScope?
    var recipeCommands: [String]?
    var tabs: [TabBuilder] = []

    private enum Context {
      case none
      case recipe
      case tab(Int)
      case pane(tab: Int, pane: Int)
    }

    mutating func parse() throws -> WorkflowRecipe {
      var context = Context.none
      for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let lineNumber = offset + 1
        let line = try Self.strippingComment(String(rawLine), line: lineNumber)
          .trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }

        if line.hasPrefix("[") {
          switch line {
          case "[recipe]":
            context = .recipe
          case "[[window.tabs]]":
            guard tabs.count < WorkflowRecipeTOML.maximumTabs else {
              throw WorkflowRecipeTOMLError.tooManyTabs
            }
            tabs.append(TabBuilder())
            context = .tab(tabs.count - 1)
          case "[[window.tabs.panes]]":
            guard let tabIndex = tabs.indices.last else {
              throw WorkflowRecipeTOMLError.invalidStructure
            }
            let totalPanes = tabs.reduce(0) { $0 + $1.panes.count }
            guard totalPanes < WorkflowRecipeTOML.maximumPanes else {
              throw WorkflowRecipeTOMLError.tooManyPanes
            }
            tabs[tabIndex].panes.append(PaneBuilder())
            context = .pane(tab: tabIndex, pane: tabs[tabIndex].panes.count - 1)
          default:
            throw WorkflowRecipeTOMLError.unsupportedTable(line, line: lineNumber)
          }
          continue
        }

        guard let separator = Self.assignmentSeparator(in: line) else {
          throw WorkflowRecipeTOMLError.malformedLine(lineNumber)
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else {
          throw WorkflowRecipeTOMLError.malformedLine(lineNumber)
        }
        try assign(String(key), value: String(value), context: context, line: lineNumber)
      }

      guard let recipeName, let recipeVersion, let recipeScope else {
        throw WorkflowRecipeTOMLError.invalidStructure
      }
      let builtTabs = try tabs.map { tab -> WorkflowRecipeTab in
        guard let title = tab.title else { throw WorkflowRecipeTOMLError.missingValue("tab.title") }
        let panes = try tab.panes.map { pane -> WorkflowRecipePane in
          guard let cwd = pane.cwd else { throw WorkflowRecipeTOMLError.missingValue("pane.cwd") }
          return WorkflowRecipePane(
            workingDirectory: cwd,
            kind: pane.kind ?? .terminal,
            resourcePath: pane.resourcePath,
            split: pane.split,
            size: pane.size,
            commands: pane.commands ?? []
          )
        }
        return WorkflowRecipeTab(title: title, panes: panes, layout: tab.layout)
      }
      let commands = recipeCommands ?? []
      let hasCommands =
        !commands.isEmpty
        || builtTabs.contains { tab in
          tab.panes.contains { !$0.commands.isEmpty }
        }
      return WorkflowRecipe(
        name: recipeName,
        version: recipeVersion,
        scope: recipeScope,
        content: hasCommands ? .includeCommands : .layoutOnly,
        tabs: builtTabs,
        commands: commands
      )
    }

    private mutating func assign(
      _ key: String,
      value: String,
      context: Context,
      line: Int
    ) throws {
      switch context {
      case .recipe:
        switch key {
        case "name":
          guard recipeName == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          recipeName = try Self.parseString(value, line: line)
        case "version":
          guard recipeVersion == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          guard let parsed = Int(value) else {
            throw WorkflowRecipeTOMLError.invalidValue(key, line: line)
          }
          recipeVersion = parsed
        case "scope":
          guard recipeScope == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          let rawScope = try Self.parseString(value, line: line)
          guard let parsed = WorkflowRecipeScope(rawValue: rawScope) else {
            throw WorkflowRecipeTOMLError.invalidValue(key, line: line)
          }
          recipeScope = parsed
        case "commands":
          guard recipeCommands == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          recipeCommands = try Self.parseStringArray(value, line: line)
        default:
          throw WorkflowRecipeTOMLError.unknownKey(key, line: line)
        }
      case .tab(let tabIndex):
        switch key {
        case "title":
          guard tabs[tabIndex].title == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          tabs[tabIndex].title = try Self.parseString(value, line: line)
        case "layout":
          guard !tabs[tabIndex].didSetLayout else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          let layoutJSON = try Self.parseString(value, line: line)
          tabs[tabIndex].layout = try WorkflowRecipeTOML.decodeLayout(layoutJSON, line: line)
          tabs[tabIndex].didSetLayout = true
        default:
          throw WorkflowRecipeTOMLError.unknownKey(key, line: line)
        }
      case .pane(let tabIndex, let paneIndex):
        switch key {
        case "cwd":
          guard tabs[tabIndex].panes[paneIndex].cwd == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          tabs[tabIndex].panes[paneIndex].cwd = try Self.parseString(value, line: line)
        case "kind":
          guard tabs[tabIndex].panes[paneIndex].kind == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          let rawKind = try Self.parseString(value, line: line)
          guard let kind = PaneKind(rawValue: rawKind) else {
            throw WorkflowRecipeTOMLError.invalidValue(key, line: line)
          }
          tabs[tabIndex].panes[paneIndex].kind = kind
        case "resource_path":
          guard !tabs[tabIndex].panes[paneIndex].didSetResourcePath else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          tabs[tabIndex].panes[paneIndex].resourcePath = try Self.parseString(value, line: line)
          tabs[tabIndex].panes[paneIndex].didSetResourcePath = true
        case "split":
          guard !tabs[tabIndex].panes[paneIndex].didSetSplit else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          let rawDirection = try Self.parseString(value, line: line)
          guard let direction = SplitDirection(rawValue: rawDirection) else {
            throw WorkflowRecipeTOMLError.invalidValue(key, line: line)
          }
          tabs[tabIndex].panes[paneIndex].split = direction
          tabs[tabIndex].panes[paneIndex].didSetSplit = true
        case "size":
          guard tabs[tabIndex].panes[paneIndex].size == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          guard let parsed = Double(value), parsed.isFinite else {
            throw WorkflowRecipeTOMLError.invalidValue(key, line: line)
          }
          tabs[tabIndex].panes[paneIndex].size = parsed
        case "commands":
          guard tabs[tabIndex].panes[paneIndex].commands == nil else {
            throw WorkflowRecipeTOMLError.duplicateKey(key, line: line)
          }
          tabs[tabIndex].panes[paneIndex].commands = try Self.parseStringArray(value, line: line)
        default:
          throw WorkflowRecipeTOMLError.unknownKey(key, line: line)
        }
      case .none:
        throw WorkflowRecipeTOMLError.malformedLine(line)
      }
    }

    private static func assignmentSeparator(in line: String) -> String.Index? {
      var quoted = false
      var escaped = false
      for index in line.indices {
        let character = line[index]
        if quoted {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            quoted = false
          }
        } else if character == "\"" {
          quoted = true
        } else if character == "=" {
          return index
        }
      }
      return nil
    }

    private static func strippingComment(_ line: String, line lineNumber: Int) throws -> String {
      var quoted = false
      var escaped = false
      for index in line.indices {
        let character = line[index]
        if quoted {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            quoted = false
          }
        } else if character == "\"" {
          quoted = true
        } else if character == "#" {
          return String(line[..<index])
        }
      }
      guard !quoted, !escaped else { throw WorkflowRecipeTOMLError.malformedLine(lineNumber) }
      return line
    }

    private static func parseString(_ value: String, line: Int) throws -> String {
      guard value.first == "\"", value.last == "\"", value.count >= 2 else {
        throw WorkflowRecipeTOMLError.invalidValue(value, line: line)
      }
      var result = ""
      var index = value.index(after: value.startIndex)
      let end = value.index(before: value.endIndex)
      while index < end {
        let character = value[index]
        if character != "\\" {
          result.append(character)
          index = value.index(after: index)
          continue
        }
        index = value.index(after: index)
        guard index < end else { throw WorkflowRecipeTOMLError.invalidValue(value, line: line) }
        switch value[index] {
        case "\"": result.append("\"")
        case "\\": result.append("\\")
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        default: throw WorkflowRecipeTOMLError.invalidValue(value, line: line)
        }
        index = value.index(after: index)
      }
      return result
    }

    private static func parseStringArray(_ value: String, line: Int) throws -> [String] {
      guard value.first == "[", value.last == "]" else {
        throw WorkflowRecipeTOMLError.invalidValue(value, line: line)
      }
      let inner = value.dropFirst().dropLast()
      if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

      var elements: [String] = []
      var start = inner.startIndex
      var quoted = false
      var escaped = false
      var index = inner.startIndex
      while index < inner.endIndex {
        let character = inner[index]
        if quoted {
          if escaped {
            escaped = false
          } else if character == "\\" {
            escaped = true
          } else if character == "\"" {
            quoted = false
          }
        } else if character == "\"" {
          quoted = true
        } else if character == "," {
          let raw = inner[start..<index].trimmingCharacters(in: .whitespaces)
          elements.append(try parseString(String(raw), line: line))
          guard elements.count <= WorkflowRecipeTOML.maximumCommands else {
            throw WorkflowRecipeTOMLError.tooManyCommands
          }
          start = inner.index(after: index)
        }
        index = inner.index(after: index)
      }
      guard !quoted, !escaped else { throw WorkflowRecipeTOMLError.invalidValue(value, line: line) }
      let raw = inner[start..<inner.endIndex].trimmingCharacters(in: .whitespaces)
      elements.append(try parseString(String(raw), line: line))
      return elements
    }
  }
}

/// 无外部依赖的 SHA-256，用于把 Recipe 文件信任绑定到精确文件字节。
///
/// 摘要只承担身份比较，不用于口令派生或签名。实现遵循 FIPS 180-4 的 512-bit 分块和
/// 64 轮压缩，返回固定 64 位小写十六进制字符串，便于稳定持久化与比较。
public enum WorkflowSHA256 {
  public static func digest(_ data: Data) -> String {
    var message = Array(data)
    let bitLength = UInt64(message.count) &* 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
    }

    var hash: [UInt32] = [
      0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
      0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
    ]
    let constants: [UInt32] = [
      0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
      0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
      0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
      0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
      0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
      0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
      0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
      0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
      0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
      0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
      0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      var words = Array(repeating: UInt32(0), count: 64)
      for index in 0..<16 {
        let offset = chunkStart + index * 4
        words[index] =
          UInt32(message[offset]) << 24
          | UInt32(message[offset + 1]) << 16
          | UInt32(message[offset + 2]) << 8
          | UInt32(message[offset + 3])
      }
      for index in 16..<64 {
        let s0 =
          rotateRight(words[index - 15], by: 7)
          ^ rotateRight(words[index - 15], by: 18) ^ (words[index - 15] >> 3)
        let s1 =
          rotateRight(words[index - 2], by: 17)
          ^ rotateRight(words[index - 2], by: 19) ^ (words[index - 2] >> 10)
        words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
      }

      var a = hash[0]
      var b = hash[1]
      var c = hash[2]
      var d = hash[3]
      var e = hash[4]
      var f = hash[5]
      var g = hash[6]
      var h = hash[7]
      for index in 0..<64 {
        let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
        let choice = (e & f) ^ ((~e) & g)
        let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
        let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temporary2 = sum0 &+ majority
        h = g
        g = f
        f = e
        e = d &+ temporary1
        d = c
        c = b
        b = a
        a = temporary1 &+ temporary2
      }
      hash[0] &+= a
      hash[1] &+= b
      hash[2] &+= c
      hash[3] &+= d
      hash[4] &+= e
      hash[5] &+= f
      hash[6] &+= g
      hash[7] &+= h
    }
    return hash.map { String(format: "%08x", $0) }.joined()
  }

  private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
  }
}
