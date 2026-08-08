import Foundation

public enum WorkflowPortablePathVariable: String, CaseIterable, Codable, Equatable, Sendable {
  case currentFolder = "{{current_folder}}"
  case homeFolder = "{{home_folder}}"
  case recipeLocation = "{{recipe_location}}"
}

/// 解析可移植 Recipe 路径时由调用现场提供的三个稳定基准目录。
public struct WorkflowPortablePathContext: Equatable, Sendable {
  public let currentFolder: URL
  public let homeFolder: URL
  public let recipeLocation: URL

  public init(currentFolder: URL, homeFolder: URL, recipeLocation: URL) {
    self.currentFolder = currentFolder
    self.homeFolder = homeFolder
    self.recipeLocation = recipeLocation
  }
}

public enum WorkflowPortablePathError: Error, Equatable {
  case invalidPath
  case invalidBaseDirectory
  case pathOutsideBase
  case unknownVariable
  case pathEscapesBase
}

/// Recipe 可移植路径的纯转换边界。
///
/// 替换时必须命中完整目录边界；解析外部变量时拒绝 `..`，避免恶意 Recipe 借基准目录
/// 逃逸到任意位置。这里仅描述路径，不检查文件是否存在，也不读取文件系统。
public enum WorkflowPortablePath {
  /// 在尚无解析上下文时验证 Recipe 中的路径模板。允许绝对路径或三个公开变量，拒绝
  /// 相对路径、未知变量和任何 `..` 组件。
  public static func validateTemplate(_ path: String) throws {
    try validateRawPath(path)
    let tokens = WorkflowPortablePathVariable.allCases.map(\.rawValue) + ["{{home}}"]
    if path.hasPrefix("/") {
      guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
        throw WorkflowPortablePathError.pathEscapesBase
      }
      return
    }
    for token in tokens where path == token || path.hasPrefix(token + "/") {
      let suffix = String(path.dropFirst(token.count))
      guard !suffix.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
        throw WorkflowPortablePathError.pathEscapesBase
      }
      return
    }
    if path.hasPrefix("{{") { throw WorkflowPortablePathError.unknownVariable }
    throw WorkflowPortablePathError.invalidPath
  }

  public static func makePortable(
    _ absolutePath: String,
    replacing baseDirectory: URL,
    with variable: WorkflowPortablePathVariable
  ) throws -> String {
    let path = try normalizedAbsolutePath(absolutePath)
    let base = try normalizedBase(baseDirectory)
    guard path == base || path.hasPrefix(base == "/" ? "/" : base + "/") else {
      throw WorkflowPortablePathError.pathOutsideBase
    }
    if path == base { return variable.rawValue }
    let suffix = String(path.dropFirst(base == "/" ? 0 : base.count))
    return variable.rawValue + suffix
  }

  public static func resolve(
    _ portablePath: String,
    context: WorkflowPortablePathContext
  ) throws -> String {
    try validateRawPath(portablePath)
    let mappings: [(tokens: [String], base: URL)] = [
      ([WorkflowPortablePathVariable.currentFolder.rawValue], context.currentFolder),
      // `{{home}}` is accepted as a compatibility spelling; new exports use the explicit token.
      ([WorkflowPortablePathVariable.homeFolder.rawValue, "{{home}}"], context.homeFolder),
      ([WorkflowPortablePathVariable.recipeLocation.rawValue], context.recipeLocation),
    ]

    for mapping in mappings {
      for token in mapping.tokens where portablePath == token || portablePath.hasPrefix(token + "/")
      {
        let base = try normalizedBase(mapping.base)
        let suffix = String(portablePath.dropFirst(token.count))
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
          throw WorkflowPortablePathError.pathEscapesBase
        }
        let relative = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        let resolved =
          relative.isEmpty
          ? URL(fileURLWithPath: base)
          : URL(
            fileURLWithPath: relative, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
        let normalized = resolved.standardizedFileURL.path
        guard normalized == base || normalized.hasPrefix(base == "/" ? "/" : base + "/") else {
          throw WorkflowPortablePathError.pathEscapesBase
        }
        return normalized
      }
    }

    if portablePath.hasPrefix("{{") { throw WorkflowPortablePathError.unknownVariable }
    return try normalizedAbsolutePath(portablePath)
  }

  private static func normalizedBase(_ url: URL) throws -> String {
    guard url.isFileURL else { throw WorkflowPortablePathError.invalidBaseDirectory }
    return try normalizedAbsolutePath(url.path)
  }

  private static func normalizedAbsolutePath(_ rawPath: String) throws -> String {
    try validateRawPath(rawPath)
    guard rawPath.hasPrefix("/") else { throw WorkflowPortablePathError.invalidPath }
    let normalized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    guard !normalized.isEmpty else { throw WorkflowPortablePathError.invalidPath }
    return normalized
  }

  private static func validateRawPath(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= WorkflowRecipeTOML.maximumPathBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw WorkflowPortablePathError.invalidPath }
  }
}

public enum WorkflowRecipeTrustStoreError: Error, Equatable {
  case invalidDigest
  case tooManyDigests
}

/// 外部 Recipe 的本机信任集合。只保存 SHA-256，不保存路径，因此移动文件不改变信任，
/// 修改任意字节则一定产生新的首次打开审查。
public struct WorkflowRecipeTrustStore: Codable, Equatable, Sendable {
  public static let maximumDigests = 10_000
  public private(set) var sha256Digests: Set<String>

  public init(sha256Digests: Set<String> = []) {
    self.sha256Digests = Set(
      sha256Digests.lazy.map { $0.lowercased() }.filter(Self.isValidSHA256).sorted()
        .prefix(Self.maximumDigests)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case sha256Digests
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decoded = try container.decodeIfPresent([String].self, forKey: .sha256Digests) ?? []
    self.init(sha256Digests: Set(decoded))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sha256Digests.sorted(), forKey: .sha256Digests)
  }

  @discardableResult
  public mutating func trust(_ source: WorkflowRecipeSource) throws -> Bool {
    guard case .recipeFile(let digest) = source else { return false }
    let normalized = digest.lowercased()
    guard Self.isValidSHA256(normalized) else { throw WorkflowRecipeTrustStoreError.invalidDigest }
    guard sha256Digests.count < Self.maximumDigests || sha256Digests.contains(normalized) else {
      throw WorkflowRecipeTrustStoreError.tooManyDigests
    }
    return sha256Digests.insert(normalized).inserted
  }

  public func contains(_ source: WorkflowRecipeSource) -> Bool {
    guard case .recipeFile(let digest) = source else { return true }
    return sha256Digests.contains(digest.lowercased())
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

public enum WorkflowRecipeTrustRequirement: Equatable, Sendable {
  case notRequired
  case reviewRequired(sha256: String, commands: [String])
}

/// 决定打开 Recipe 前是否必须展示完整命令审查。
public enum WorkflowRecipeTrustPolicy {
  public static func requirement(
    for source: WorkflowRecipeSource,
    commands: [String],
    trustStore: WorkflowRecipeTrustStore = WorkflowRecipeTrustStore()
  ) -> WorkflowRecipeTrustRequirement {
    guard !commands.isEmpty else { return .notRequired }
    switch source {
    case .savedRecipe:
      return .notRequired
    case .recipeFile(let digest):
      return trustStore.contains(source)
        ? .notRequired
        : .reviewRequired(sha256: digest.lowercased(), commands: commands)
    }
  }
}

public enum WorkflowRecipeReplayPlan: Equatable, Sendable {
  case automatic(batches: [[String]])
  case confirmOnce(batches: [[String]])
  case oneByOne(commands: [String])
  case skip
}

/// 把 Replay 模式转换为上层可执行的纯计划。批次边界保证 `ssh`、`tmux attach`、
/// `docker exec`、`su` 等接管 Shell 的命令之后，后续输入必须等内层 Shell 回到 prompt。
public enum WorkflowRecipeReplayPlanner {
  public static func plan(
    commands: [String],
    mode: RecipeReplayMode
  ) -> WorkflowRecipeReplayPlan {
    guard !commands.isEmpty, mode != .skip else { return .skip }
    switch mode {
    case .automatic:
      return .automatic(batches: batches(commands))
    case .confirmOnce:
      return .confirmOnce(batches: batches(commands))
    case .oneByOne:
      return .oneByOne(commands: commands)
    case .skip:
      return .skip
    }
  }

  private static func batches(_ commands: [String]) -> [[String]] {
    var result: [[String]] = []
    var current: [String] = []
    for command in commands {
      current.append(command)
      if WorkflowShellHandoff.requiresPromptReturn(after: command) {
        result.append(current)
        current = []
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}

/// Saved Recipes 和 Recipe Files 使用独立默认值：前者 Auto，后者 Ask Once。
public struct WorkflowRecipeReplaySettings: Equatable, Sendable {
  public var savedRecipes: RecipeReplayMode
  public var recipeFiles: RecipeReplayMode

  public init(
    savedRecipes: RecipeReplayMode = .automatic,
    recipeFiles: RecipeReplayMode = .confirmOnce
  ) {
    self.savedRecipes = savedRecipes
    self.recipeFiles = recipeFiles
  }

  public func mode(for source: WorkflowRecipeSource) -> RecipeReplayMode {
    switch source {
    case .savedRecipe: savedRecipes
    case .recipeFile: recipeFiles
    }
  }
}

public enum WorkflowRecipeTrustChoice: Equatable, Sendable {
  case alwaysTrust
  case runOnce
  case cancel
}

public enum WorkflowRecipeOpenDecision: Equatable, Sendable {
  case reviewRequired(sha256: String, commands: [String])
  case replay(WorkflowRecipeReplayPlan)
  case cancel
}

/// 合并来源信任与 Replay 设置的最终打开决策；它只返回描述，不执行命令或创建窗口。
public enum WorkflowRecipeOpenPlanner {
  public static func plan(
    _ envelope: WorkflowRecipeEnvelope,
    settings: WorkflowRecipeReplaySettings = WorkflowRecipeReplaySettings(),
    trustStore: inout WorkflowRecipeTrustStore,
    trustChoice: WorkflowRecipeTrustChoice? = nil
  ) throws -> WorkflowRecipeOpenDecision {
    let commands = envelope.recipe.allCommands
    let requirement = WorkflowRecipeTrustPolicy.requirement(
      for: envelope.source,
      commands: commands,
      trustStore: trustStore
    )
    if case .reviewRequired(let digest, let commands) = requirement {
      switch trustChoice {
      case .none:
        return .reviewRequired(sha256: digest, commands: commands)
      case .cancel:
        return .cancel
      case .runOnce:
        break
      case .alwaysTrust:
        try trustStore.trust(envelope.source)
      }
    }
    return .replay(
      WorkflowRecipeReplayPlanner.plan(
        commands: commands,
        mode: settings.mode(for: envelope.source)
      ))
  }
}

private enum WorkflowShellHandoff {
  static func requiresPromptReturn(after command: String) -> Bool {
    // 控制字符或不闭合引号无法可靠分类；按照官方“宁可多暂停”原则保守暂停。
    guard !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let words = shellWords(command)
    else { return true }

    let normalized = words.map { word in
      URL(fileURLWithPath: word).lastPathComponent.lowercased()
    }
    for (index, word) in normalized.enumerated() {
      if ["ssh", "mosh", "su", "telnet", "screen"].contains(word) { return true }
      if word == "tmux",
        normalized.dropFirst(index + 1).contains(where: {
          $0 == "attach" || $0 == "attach-session" || $0 == "a"
        })
      {
        return true
      }
      if word == "docker", normalized.dropFirst(index + 1).contains("exec") { return true }
    }
    return false
  }

  /// 只需要识别命令词而非重建 Shell AST；保留引号内空格，遇到不闭合引号返回 nil。
  private static func shellWords(_ command: String) -> [String]? {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    for character in command {
      if escaped {
        current.append(character)
        escaped = false
        continue
      }
      if character == "\\", quote != "'" {
        escaped = true
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
        } else {
          current.append(character)
        }
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
      } else if character.isWhitespace || ";|&()".contains(character) {
        if !current.isEmpty {
          words.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    guard quote == nil, !escaped else { return nil }
    if !current.isEmpty { words.append(current) }
    return words
  }
}
