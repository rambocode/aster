import AsterCore
import Darwin
import Foundation

enum AgentSetupServiceError: Error, Equatable, LocalizedError {
  case executableUnavailable(String)
  case unsafePath(String)
  case unsupportedFile(String)
  case fileTooLarge(String)
  case invalidConfiguration(String)
  case managedEntryConflict(String)
  case malformedManagedBlock(String)
  case configurationChanged(String)
  case integrationResourceUnavailable
  case rollbackFailed(String)

  var errorDescription: String? {
    switch self {
    case .executableUnavailable(let command):
      "未在 PATH 中检测到 \(command)，请先安装对应 Agent。"
    case .unsafePath(let path):
      "Agent 集成目标不在当前用户目录内：\(path)"
    case .unsupportedFile(let path):
      "Agent 配置必须是普通文件，且路径中不能包含符号链接：\(path)"
    case .fileTooLarge(let path):
      "Agent 配置超过安全大小限制：\(path)"
    case .invalidConfiguration(let path):
      "Agent 配置格式无效，Aster 未作任何修改：\(path)"
    case .managedEntryConflict(let path):
      "Aster 预留的集成位置已被其它内容占用：\(path)"
    case .malformedManagedBlock(let path):
      "Agent 配置中的 Aster 受管区块不完整：\(path)"
    case .configurationChanged(let path):
      "Agent 配置在安装期间被其它进程修改，Aster 已停止写入：\(path)"
    case .integrationResourceUnavailable:
      "找不到签名的 Agent lifecycle hook 资源。"
    case .rollbackFailed(let path):
      "Agent 集成安装失败且无法完整恢复，请检查：\(path)"
    }
  }
}

/// 设置页消费的只读检测结果。`integrationInstalled` 表示 Planner 已不再要求任何
/// 写入；Codex 的 hook 文件和 `[features].hooks` 因而必须同时满足才算安装完成。
struct AgentSetupStatus: Equatable {
  let provider: AgentProvider
  /// 按与 shell 一致的候选目录优先级找到的 CLI 绝对路径。保留探测到的入口路径，
  /// 不解析 symlink，设置页才能显示用户实际通过 Homebrew、nvm 等安装的位置。
  let executablePath: String?
  let managedIntegrationInstalled: Bool
  let requiredFeatureEnabled: Bool?
  let plan: AgentSetupPlan

  var executableAvailable: Bool { executablePath != nil }

  /// 集成文件状态与 CLI 路径是两条独立证据。用户切换 Node 版本或 GUI 暂时拿不到
  /// PATH 时，已经写入的受管 hook 不能因此被误报为“未安装”。
  var integrationInstalled: Bool {
    managedIntegrationInstalled && requiredFeatureEnabled != false
  }
}

/// 内置代码 Agent 的最小增量安装边界。
///
/// Planner 决定“需要做什么”，本服务只负责安全地把语义步骤落到当前用户目录：
/// JSON 只维护事件数组中带 `_aster` 标识的条目，TOML 只维护带双 marker 的区块或 Planner
/// 明确指定的布尔键，plugin/extension 则使用独立文件。所有目标先完成路径、类型、
/// 大小和格式预检，再以原子替换写入；跨文件步骤失败时会恢复本次安装前的内容。
struct AgentSetupService {
  static let maximumConfigurationBytes = 1_048_576
  static let managedJSONKey = "_aster"
  static let managedArtifactFileName = "aster-agent-integration.ts"
  static let managedTOMLStartMarker = "# >>> Aster managed agent integration >>>"
  static let managedTOMLEndMarker = "# <<< Aster managed agent integration <<<"

  private static let schemaVersion = 1
  private static let artifactMarker = "// Aster managed agent integration v1"

  private struct ExistingFile {
    let data: Data
    let permissions: NSNumber?
  }

  /// 单个目标完成预检后的原子替换计划。`original` 为 nil 表示安装前文件不存在，
  /// 回滚时只删除这个精确文件，不递归删除可能已经创建的父目录。
  private struct PreparedEdit {
    let target: URL
    let contents: Data
    let original: ExistingFile?
  }

  let homeDirectory: URL
  private let executableLocator: AgentExecutableLocator
  private let fileManager: FileManager
  private let integrationScriptURL: URL?

  init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    executableSearchDirectories: [URL]? = nil,
    integrationScriptURL: URL? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.fileManager = fileManager
    self.integrationScriptURL = integrationScriptURL?.standardizedFileURL
      ?? AsterResourceLocations.resourcesDirectory(bundle: .main, fileManager: fileManager)?
        .appendingPathComponent("agent-integration/aster-agent-hook.sh")
    if let executableSearchDirectories {
      self.executableLocator = AgentExecutableLocator(searchDirectories: executableSearchDirectories)
    } else {
      self.executableLocator = AgentExecutableLocator(
        homeDirectory: self.homeDirectory,
        environment: environment,
        fileManager: fileManager
      )
    }
  }

  /// 只读检测既不创建目录，也不“仅凭文件存在”判定安装完成。受管 JSON/TOML
  /// 内容和独立 artifact 都必须带精确 Aster 标识；伪造的同名用户内容不会被接管。
  func status(for provider: AgentProvider) throws -> AgentSetupStatus {
    let executablePath = executableLocator.path(for: provider.commandName)
    let managedIntegrationInstalled = try detectsManagedIntegration(for: provider)
    let requiredFeatureEnabled = try detectsRequiredFeature(for: provider)
    let evidence = AgentSetupEvidence(
      executableAvailable: executablePath != nil,
      managedIntegrationInstalled: managedIntegrationInstalled,
      requiredFeatureEnabled: requiredFeatureEnabled
    )
    return AgentSetupStatus(
      provider: provider,
      executablePath: executablePath,
      managedIntegrationInstalled: managedIntegrationInstalled,
      requiredFeatureEnabled: requiredFeatureEnabled,
      plan: AgentSetupPlanner.plan(for: provider, evidence: evidence)
    )
  }

  /// 执行当前 Planner 的缺失步骤。重复调用在状态完整时不产生写入；若后续目标
  /// 写入失败，已写目标按相反顺序恢复，避免 Codex 只完成 hook 或 feature 的一半。
  @discardableResult
  func install(_ provider: AgentProvider) throws -> AgentSetupStatus {
    let current = try status(for: provider)
    if case .executableUnavailable(let command)? = current.plan.blocker {
      throw AgentSetupServiceError.executableUnavailable(command)
    }
    guard !current.plan.steps.isEmpty else { return current }

    // 必须为全部步骤成功生成 edit 才返回；在此之前不会创建目录或改写文件。
    let edits = try prepareEdits(for: current.plan.steps, provider: provider)
    var attempted: [PreparedEdit] = []
    do {
      for edit in edits {
        try apply(edit)
        // `apply` 成功后才纳入跨文件回滚；若它在写入后失败，会先在函数内部恢复。
        attempted.append(edit)
      }
      return try status(for: provider)
    } catch {
      var failedRollbackPath: String?
      for edit in attempted.reversed() {
        do {
          try restore(edit)
        } catch {
          if failedRollbackPath == nil { failedRollbackPath = edit.target.path }
        }
      }
      if let failedRollbackPath {
        throw AgentSetupServiceError.rollbackFailed(failedRollbackPath)
      }
      throw error
    }
  }

  /// 只移除带 Aster 所有权标记的 hook、TOML 区块或独立 artifact。Codex 的
  /// `[features].hooks` 可能在安装前已由用户启用，服务没有可靠 provenance 可判断
  /// 归属，因而卸载时保留该布尔值；这不会继续执行 Aster hook，也不会破坏其它 hooks。
  @discardableResult
  func uninstall(_ provider: AgentProvider) throws -> AgentSetupStatus {
    switch provider {
    case .claudeCode, .codex, .cursorCLI, .grokBuild:
      try uninstallJSONHooks(for: provider)
    case .kimiCode:
      try uninstallManagedTOMLBlock(for: provider)
    case .openCode, .pi, .omp:
      try uninstallManagedArtifact(for: provider)
    case .gemini, .githubCopilot, .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      // 仅屏幕检测的 provider 没有受管集成，卸载无事可做。
      break
    }
    return try status(for: provider)
  }

  private func uninstallJSONHooks(for provider: AgentProvider) throws {
    let path = switch provider {
    case .claudeCode, .grokBuild: "~/.claude/settings.json"
    case .codex: "~/.codex/hooks.json"
    case .cursorCLI: "~/.cursor/hooks.json"
    default: preconditionFailure("JSON provider switch must be exhaustive")
    }
    let target = try expandedManagedPath(path)
    guard let original = try readExistingRegularFile(at: target) else { return }
    var root = try decodeJSONObject(original.data, path: target.path)
    guard removingManagedHooks(from: &root, provider: provider) else { return }
    try apply(PreparedEdit(target: target, contents: try serialize(root), original: original))
  }

  /// 从 hooks 事件数组里移除当前 provider 的 Aster 条目；返回是否有改动。
  private func removingManagedHooks(from root: inout [String: Any], provider: AgentProvider) -> Bool {
    guard var hooks = root["hooks"] as? [String: Any] else { return false }
    var changed = false
    for specification in jsonHookSpecifications(for: provider) {
      guard var entries = hooks[specification.event] as? [[String: Any]] else { continue }
      let previousCount = entries.count
      entries.removeAll { entry in
        entry[Self.managedJSONKey] as? Bool == true
          && entry["_asterProvider"] as? String == provider.rawValue
      }
      guard entries.count != previousCount else { continue }
      changed = true
      if entries.isEmpty {
        hooks.removeValue(forKey: specification.event)
      } else {
        hooks[specification.event] = entries
      }
    }
    guard changed else { return false }
    if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    return true
  }

  private func serialize(_ root: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(root) else {
      throw AgentSetupServiceError.invalidConfiguration("settings")
    }
    var contents = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys]
    )
    contents.append(0x0A)
    return contents
  }

  private func uninstallManagedTOMLBlock(for provider: AgentProvider) throws {
    precondition(provider == .kimiCode)
    let target = try expandedManagedPath("~/.kimi-code/config.toml")
    guard let original = try readExistingRegularFile(at: target) else { return }
    let current = try utf8String(original.data, path: target.path)
    guard let block = try managedTOMLBlock(in: current, path: target.path),
      let range = current.range(of: block)
    else { return }
    var updated = current
    updated.removeSubrange(range)
    try apply(PreparedEdit(
      target: target,
      contents: Data(updated.utf8),
      original: original
    ))
  }

  private func uninstallManagedArtifact(for provider: AgentProvider) throws {
    let directory = switch provider {
    case .openCode: "~/.config/opencode/plugins"
    case .pi: "~/.pi/agent/extensions"
    case .omp: "~/.omp/agent/extensions"
    default: preconditionFailure("Artifact provider switch must be exhaustive")
    }
    let target = try expandedManagedPath(directory)
      .appendingPathComponent(Self.managedArtifactFileName, isDirectory: false)
    guard let original = try readExistingRegularFile(at: target) else { return }
    let text = try utf8String(original.data, path: target.path)
    guard text == generatedArtifact(for: provider) else {
      throw AgentSetupServiceError.managedEntryConflict(target.path)
    }
    // 删除前复验字节，若 Agent 或用户在检测后改写则停止，不覆盖新的外部状态。
    guard try readExistingRegularFile(at: target)?.data == original.data else {
      throw AgentSetupServiceError.configurationChanged(target.path)
    }
    try fileManager.removeItem(at: target)
  }

  private func detectsManagedIntegration(for provider: AgentProvider) throws -> Bool {
    switch provider {
    case .claudeCode, .codex, .cursorCLI, .grokBuild:
      let path = switch provider {
      case .claudeCode, .grokBuild: "~/.claude/settings.json"
      case .codex: "~/.codex/hooks.json"
      case .cursorCLI: "~/.cursor/hooks.json"
      default: preconditionFailure("JSON provider switch must be exhaustive")
      }
      let url = try expandedManagedPath(path)
      guard let existing = try readExistingRegularFile(at: url) else { return false }
      let root = try decodeJSONObject(existing.data, path: url.path)
      guard let hooks = root["hooks"] as? [String: Any] else { return false }
      return jsonHookSpecifications(for: provider).allSatisfy { specification in
        guard let entries = hooks[specification.event] as? [[String: Any]] else { return false }
        return entries.contains { entry in
          isOwnedJSONEntry(entry, provider: provider, state: specification.state)
        }
      }

    case .kimiCode:
      let url = try expandedManagedPath("~/.kimi-code/config.toml")
      guard let existing = try readExistingRegularFile(at: url) else { return false }
      let text = try utf8String(existing.data, path: url.path)
      guard let block = try managedTOMLBlock(in: text, path: url.path) else { return false }
      return block == (try generatedTOMLBlock(for: provider))

    case .openCode, .pi, .omp:
      let directory = switch provider {
      case .openCode: "~/.config/opencode/plugins"
      case .pi: "~/.pi/agent/extensions"
      case .omp: "~/.omp/agent/extensions"
      default: preconditionFailure("Artifact provider switch must be exhaustive")
      }
      let url = try expandedManagedPath(directory)
        .appendingPathComponent(Self.managedArtifactFileName, isDirectory: false)
      guard let existing = try readExistingRegularFile(at: url) else { return false }
      let text = try utf8String(existing.data, path: url.path)
      return text == generatedArtifact(for: provider)

    case .gemini, .githubCopilot, .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      // 没有受管集成可检测；状态页据此显示“未集成”，并由 Planner 给出 integrationUnavailable。
      return false
    }
  }

  private func detectsRequiredFeature(for provider: AgentProvider) throws -> Bool? {
    guard provider == .codex else { return nil }
    let url = try expandedManagedPath("~/.codex/config.toml")
    // 当前 Codex 默认启用 hooks；没有 config.toml 或没有显式 feature 键都等价于启用。
    guard let existing = try readExistingRegularFile(at: url) else { return true }
    let text = try utf8String(existing.data, path: url.path)
    // Aster 0.4.1 曾把 feature 开关错误写到顶层。当前 Codex 把顶层 `hooks` 解释为
    // HooksToml 结构体，因此任何遗留布尔值都必须进入迁移步骤，即使 features 已为 true。
    if try rootBooleanValue(named: "hooks", in: text, path: url.path) != nil { return false }
    return try featureBooleanValue(named: "hooks", in: text, path: url.path) ?? true
  }

  /// 安装前读取的 JSON 文件状态：多个步骤改同一文件时在内存里累积，只产出一个 edit，
  /// 否则第二个 edit 的 `original` 已经过期，`apply` 会报 configurationChanged。
  private struct PendingJSONFile {
    let target: URL
    let original: ExistingFile?
    var root: [String: Any]
  }

  private func prepareEdits(
    for steps: [AgentSetupStep],
    provider: AgentProvider
  ) throws -> [PreparedEdit] {
    var edits: [PreparedEdit] = []
    var pending: PendingJSONFile?
    func load(_ target: URL) throws -> PendingJSONFile {
      if let pending, pending.target == target { return pending }
      let original = try readExistingRegularFile(at: target)
      let root = try original.map { try decodeJSONObject($0.data, path: target.path) } ?? [:]
      return PendingJSONFile(target: target, original: original, root: root)
    }
    for step in steps {
      switch step {
      case .mergeManagedHooks(let path, .json):
        let target = try expandedManagedPath(path)
        var file = try load(target)
        try mergeHooks(into: &file.root, provider: provider, path: target.path)
        pending = file
      default:
        edits.append(try prepareEdit(for: step, provider: provider))
      }
    }
    if let pending {
      edits.append(PreparedEdit(
        target: pending.target, contents: try serialize(pending.root), original: pending.original))
    }
    return edits
  }

  private func prepareEdit(
    for step: AgentSetupStep,
    provider: AgentProvider
  ) throws -> PreparedEdit {
    switch step {
    case .mergeManagedHooks(let path, let format):
      let target = try expandedManagedPath(path)
      switch format {
      case .json:
        let original = try readExistingRegularFile(at: target)
        var root = try original.map { try decodeJSONObject($0.data, path: target.path) } ?? [:]
        try mergeHooks(into: &root, provider: provider, path: target.path)
        return PreparedEdit(target: target, contents: try serialize(root), original: original)
      case .toml:
        return try prepareTOMLManagedBlockEdit(at: target, provider: provider)
      }
    case .enableFeature(let path, let key):
      let target = try expandedManagedPath(path)
      return try prepareTOMLFeatureEdit(at: target, key: key)

    case .installManagedArtifact(let directory, _):
      let targetDirectory = try expandedManagedPath(directory)
      try validateDirectoryPath(targetDirectory)
      let target = targetDirectory.appendingPathComponent(
        Self.managedArtifactFileName,
        isDirectory: false
      )
      return try prepareArtifactEdit(at: target, provider: provider)
    }
  }

  /// 在内存 JSON 根对象上合并当前 provider 的 Aster hook 条目（纯内存，不写盘）。
  private func mergeHooks(
    into root: inout [String: Any],
    provider: AgentProvider,
    path: String
  ) throws {
    var hooks: [String: Any]
    if let value = root["hooks"] {
      guard let object = value as? [String: Any] else {
        throw AgentSetupServiceError.invalidConfiguration(path)
      }
      hooks = object
    } else {
      hooks = [:]
    }
    for specification in jsonHookSpecifications(for: provider) {
      var entries: [[String: Any]]
      if let existing = hooks[specification.event] {
        guard let decoded = existing as? [[String: Any]] else {
          throw AgentSetupServiceError.invalidConfiguration(path)
        }
        entries = decoded
      } else {
        entries = []
      }
      // 只替换当前 provider 的 Aster 条目。用户 hook 和其它应用条目保持原顺序。
      entries.removeAll { entry in
        entry[Self.managedJSONKey] as? Bool == true
          && entry["_asterProvider"] as? String == provider.rawValue
      }
      entries.append(try generatedJSONEntry(for: provider, state: specification.state))
      hooks[specification.event] = entries
    }
    root["hooks"] = hooks
    if provider == .cursorCLI, root["version"] == nil { root["version"] = 1 }
    guard JSONSerialization.isValidJSONObject(root) else {
      throw AgentSetupServiceError.invalidConfiguration(path)
    }
  }

  private func prepareTOMLManagedBlockEdit(
    at target: URL,
    provider: AgentProvider
  ) throws -> PreparedEdit {
    let original = try readExistingRegularFile(at: target)
    let current = try original.map { try utf8String($0.data, path: target.path) } ?? ""
    let generated = try generatedTOMLBlock(for: provider)
    let updated: String
    if let existingBlock = try managedTOMLBlock(in: current, path: target.path),
      let range = current.range(of: existingBlock)
    {
      // marker 确认所有权后原位替换；区块前后的用户表、注释和空行保持原顺序。
      var replacement = current
      replacement.replaceSubrange(range, with: generated)
      updated = replacement
    } else {
      var appended = current
      if !appended.isEmpty, !appended.hasSuffix("\n") { appended.append("\n") }
      if !appended.isEmpty, !appended.hasSuffix("\n\n") { appended.append("\n") }
      appended += generated + "\n"
      updated = appended
    }
    return PreparedEdit(
      target: target,
      contents: Data(updated.utf8),
      original: original
    )
  }

  private func prepareTOMLFeatureEdit(
    at target: URL,
    key: String
  ) throws -> PreparedEdit {
    let original = try readExistingRegularFile(at: target)
    let current = try original.map { try utf8String($0.data, path: target.path) } ?? ""
    let updated = try enablingFeatureBoolean(
      named: key,
      in: current,
      path: target.path
    )
    return PreparedEdit(target: target, contents: Data(updated.utf8), original: original)
  }

  private func prepareArtifactEdit(
    at target: URL,
    provider: AgentProvider
  ) throws -> PreparedEdit {
    let original = try readExistingRegularFile(at: target)
    if let original {
      let text = try utf8String(original.data, path: target.path)
      guard text.hasPrefix(Self.artifactMarker + "\n") else {
        throw AgentSetupServiceError.managedEntryConflict(target.path)
      }
    }
    return PreparedEdit(
      target: target,
      contents: Data(generatedArtifact(for: provider).utf8),
      original: original
    )
  }

  private struct JSONHookSpecification {
    let event: String
    let state: AgentTaskStateSignal
  }

  private func jsonHookSpecifications(for provider: AgentProvider) -> [JSONHookSpecification] {
    switch provider {
    case .claudeCode:
      [
        .init(event: "SessionStart", state: .idle),
        .init(event: "UserPromptSubmit", state: .processing),
        .init(event: "PreToolUse", state: .processing),
        .init(event: "PostToolUse", state: .processing),
        .init(event: "Stop", state: .idle),
        .init(event: "PermissionRequest", state: .awaitingInput),
      ]
    case .grokBuild:
      // Grok 读 Claude 兼容事件，但没有 PermissionRequest；awaiting-input 因此不报。
      [
        .init(event: "SessionStart", state: .idle),
        .init(event: "UserPromptSubmit", state: .processing),
        .init(event: "PreToolUse", state: .processing),
        .init(event: "PostToolUse", state: .processing),
        .init(event: "Stop", state: .idle),
      ]
    case .codex:
      [
        .init(event: "SessionStart", state: .idle),
        .init(event: "UserPromptSubmit", state: .processing),
        .init(event: "Stop", state: .idle),
        .init(event: "PermissionRequest", state: .awaitingInput),
      ]
    case .cursorCLI:
      [
        .init(event: "sessionStart", state: .idle),
        .init(event: "beforeSubmitPrompt", state: .processing),
        .init(event: "preToolUse", state: .processing),
        .init(event: "postToolUse", state: .processing),
        .init(event: "stop", state: .idle),
      ]
    case .openCode, .kimiCode, .pi, .omp,
      .gemini, .githubCopilot, .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      []
    }
  }

  private func isOwnedJSONEntry(
    _ entry: [String: Any],
    provider: AgentProvider,
    state: AgentTaskStateSignal
  ) -> Bool {
    guard entry[Self.managedJSONKey] as? Bool == true,
      entry["_asterProvider"] as? String == provider.rawValue,
      let command = try? lifecycleHookCommand(state: state, provider: provider)
    else { return false }
    if provider == .cursorCLI { return entry["command"] as? String == command }
    guard let commands = entry["hooks"] as? [[String: Any]], commands.count == 1 else {
      return false
    }
    return commands[0]["type"] as? String == "command"
      && commands[0]["command"] as? String == command
  }

  private func generatedJSONEntry(
    for provider: AgentProvider,
    state: AgentTaskStateSignal
  ) throws -> [String: Any] {
    let command = try lifecycleHookCommand(state: state, provider: provider)
    if provider == .cursorCLI {
      return [
        Self.managedJSONKey: true,
        "_asterProvider": provider.rawValue,
        "command": command,
      ]
    }
    return [
      Self.managedJSONKey: true,
      "_asterProvider": provider.rawValue,
      "hooks": [["type": "command", "command": command]],
    ]
  }

  private func generatedTOMLBlock(for provider: AgentProvider) throws -> String {
    var lines = [
      Self.managedTOMLStartMarker,
      "# schema_version = \(Self.schemaVersion)",
    ]
    let specifications: [JSONHookSpecification] = [
      .init(event: "SessionStart", state: .idle),
      .init(event: "UserPromptSubmit", state: .processing),
      .init(event: "PreToolUse", state: .processing),
      .init(event: "PostToolUse", state: .processing),
      .init(event: "Stop", state: .idle),
      .init(event: "PermissionRequest", state: .awaitingInput),
    ]
    for specification in specifications {
      let command = try lifecycleHookCommand(state: specification.state, provider: provider)
      lines += [
        "[[hooks]]",
        "event = \"\(specification.event)\"",
        "command = \"\(tomlEscaped(command))\"",
      ]
    }
    lines.append(Self.managedTOMLEndMarker)
    return lines.joined(separator: "\n")
  }

  /// hook 脚本必须是 bundle 内的普通文件（非 symlink），否则视为集成资源缺失。
  private func validatedIntegrationScriptPath() throws -> String {
    guard let integrationScriptURL,
      let values = try? integrationScriptURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey,
      ]),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else { throw AgentSetupServiceError.integrationResourceUnavailable }
    return integrationScriptURL.path
  }

  private func lifecycleHookCommand(
    state: AgentTaskStateSignal,
    provider: AgentProvider
  ) throws -> String {
    let scriptPath = try validatedIntegrationScriptPath()
    let stateValue = switch state {
    case .processing, .inputSubmitted: "processing"
    case .idle: "idle"
    case .awaitingInput: "awaiting-input"
    }
    return "/bin/sh \(shellQuoted(scriptPath)) \(stateValue) \(provider.rawValue)"
  }

  private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func tomlEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  /// OpenCode、Pi 与 omp 都从约定目录加载 TypeScript。artifact 不依赖第三方包，
  /// 只把其原生生命周期归一成所属 PTY 的有界 OSC；不执行用户命令或读取会话内容。
  private func generatedArtifact(for provider: AgentProvider) -> String {
    if provider == .pi || provider == .omp {
      return """
        \(Self.artifactMarker)
        import { closeSync, openSync, writeSync } from "node:fs";

        const provider = "\(provider.rawValue)";
        const sessionID = (value: unknown) =>
          typeof value === "string" && /^[A-Za-z0-9._:-]{1,128}$/.test(value) ? value : undefined;
        const emit = (state: "processing" | "idle", rawSessionID?: unknown) => {
          let descriptor: number | undefined;
          try {
            descriptor = openSync("/dev/tty", "w");
            const id = sessionID(rawSessionID);
            const suffix = id ? `;SessionID=${id}` : "";
            writeSync(descriptor, `\\u001B]6974;AgentState=${state};Provider=${provider}${suffix}\\u0007`);
          } catch {} finally {
            if (descriptor !== undefined) try { closeSync(descriptor); } catch {}
          }
        };

        export default function (api: any) {
          api.on("session_start", async (event: any) =>
            emit("idle", event?.session_id ?? event?.sessionId ?? event?.id));
          api.on("agent_start", async () => emit("processing"));
          api.on("tool_call", async () => emit("processing"));
          api.on("agent_end", async () => emit("idle"));
        }
        """ + "\n"
    }
    return """
    \(Self.artifactMarker)
    import { closeSync, openSync, writeSync } from "node:fs";

    const provider = "\(provider.rawValue)";
    const sessionID = (value: unknown) =>
      typeof value === "string" && /^[A-Za-z0-9._:-]{1,128}$/.test(value) ? value : undefined;
    const emit = (state: "processing" | "idle" | "awaiting-input", rawSessionID?: unknown) => {
      let descriptor: number | undefined;
      try {
        descriptor = openSync("/dev/tty", "w");
        const id = sessionID(rawSessionID);
        const suffix = id ? `;SessionID=${id}` : "";
        writeSync(descriptor, `\\u001B]6974;AgentState=${state};Provider=${provider}${suffix}\\u0007`);
      } catch {} finally {
        if (descriptor !== undefined) try { closeSync(descriptor); } catch {}
      }
    };

    export const AsterAgentIntegration = async () => ({
      event: async ({ event }: { event: { type?: string; properties?: any } }) => {
        const id = event.properties?.sessionID ?? event.properties?.session?.id
          ?? event.properties?.info?.id;
        if (event.type === "session.created" || event.type === "session.idle"
          || event.type === "tui.session.select" || event.type === "session.error") emit("idle", id);
        if (event.type === "session.status") {
          const state = event.properties?.status?.type ?? event.properties?.status;
          if (state === "idle") emit("idle", id);
          if (state === "busy" || state === "retry") emit("processing", id);
        }
      },
      "permission.ask": async () => emit("awaiting-input"),
    });

    export default AsterAgentIntegration;
    """ + "\n"
  }

  private func decodeJSONObject(_ data: Data, path: String) throws -> [String: Any] {
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AgentSetupServiceError.invalidConfiguration(path)
      }
      return object
    } catch let error as AgentSetupServiceError {
      throw error
    } catch {
      throw AgentSetupServiceError.invalidConfiguration(path)
    }
  }

  private func utf8String(_ data: Data, path: String) throws -> String {
    guard let value = String(data: data, encoding: .utf8) else {
      throw AgentSetupServiceError.invalidConfiguration(path)
    }
    return value
  }

  private func managedTOMLBlock(in text: String, path: String) throws -> String? {
    let starts = text.ranges(of: Self.managedTOMLStartMarker)
    let ends = text.ranges(of: Self.managedTOMLEndMarker)
    guard !starts.isEmpty || !ends.isEmpty else { return nil }
    guard starts.count == 1, ends.count == 1,
      starts[0].lowerBound < ends[0].lowerBound,
      isLineBoundary(starts[0].lowerBound, in: text),
      isLineBoundary(ends[0].lowerBound, in: text)
    else {
      throw AgentSetupServiceError.malformedManagedBlock(path)
    }
    return String(text[starts[0].lowerBound..<ends[0].upperBound])
  }

  private func isLineBoundary(_ index: String.Index, in text: String) -> Bool {
    index == text.startIndex || text[text.index(before: index)] == "\n"
  }

  private func rootBooleanValue(
    named key: String,
    in text: String,
    path: String
  ) throws -> Bool? {
    var value: Bool?
    var isRoot = true
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { isRoot = false }
      guard isRoot, let assignment = try booleanAssignment(in: line, key: key, path: path)
      else { continue }
      guard value == nil else { throw AgentSetupServiceError.invalidConfiguration(path) }
      value = assignment
    }
    return value
  }

  /// 读取精确 `[features]` 表中的布尔值。只识别当前安装器管理的简单表形态；重复表、
  /// 重复键或同名非布尔值均拒绝，避免在无法证明语义时改写用户配置。
  private func featureBooleanValue(
    named key: String,
    in text: String,
    path: String
  ) throws -> Bool? {
    var value: Bool?
    var insideFeatures = false
    var sawFeatures = false
    for line in text.components(separatedBy: "\n") {
      if startsTOMLTable(in: line) {
        let table = tableName(in: line)
        insideFeatures = table == "features"
        if insideFeatures {
          guard !sawFeatures else { throw AgentSetupServiceError.invalidConfiguration(path) }
          sawFeatures = true
        }
        continue
      }
      guard insideFeatures,
        let assignment = try booleanAssignment(in: line, key: key, path: path)
      else { continue }
      guard value == nil else { throw AgentSetupServiceError.invalidConfiguration(path) }
      value = assignment
    }
    return value
  }

  /// 删除旧 Aster 写入的顶层布尔值，并只在用户显式关闭 `[features].hooks` 时改为 true。
  /// feature 键缺失时沿用 Codex 的默认启用语义，不为新配置制造多余内容。
  private func enablingFeatureBoolean(
    named key: String,
    in text: String,
    path: String
  ) throws -> String {
    var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    var rootMatchIndex: Int?
    var featureMatchIndex: Int?
    var insideFeatures = false
    var sawFeatures = false
    var beforeFirstTable = true
    for index in lines.indices {
      if startsTOMLTable(in: lines[index]) {
        let table = tableName(in: lines[index])
        beforeFirstTable = false
        insideFeatures = table == "features"
        if insideFeatures {
          guard !sawFeatures else { throw AgentSetupServiceError.invalidConfiguration(path) }
          sawFeatures = true
        }
        continue
      }
      if beforeFirstTable,
        try booleanAssignment(in: lines[index], key: key, path: path) != nil
      {
        guard rootMatchIndex == nil else {
          throw AgentSetupServiceError.invalidConfiguration(path)
        }
        rootMatchIndex = index
      }
      if insideFeatures,
        try booleanAssignment(in: lines[index], key: key, path: path) != nil
      {
        guard featureMatchIndex == nil else {
          throw AgentSetupServiceError.invalidConfiguration(path)
        }
        featureMatchIndex = index
      }
    }

    if let featureMatchIndex {
      let line = lines[featureMatchIndex]
      let comment = line.firstIndex(of: "#").map { String(line[$0...]) }
      let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
      lines[featureMatchIndex] = indentation + "\(key) = true"
        + (comment.map { " " + $0 } ?? "")
    }
    if let rootMatchIndex {
      let line = lines[rootMatchIndex]
      if let commentIndex = line.firstIndex(of: "#") {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        lines[rootMatchIndex] = indentation + String(line[commentIndex...])
      } else {
        lines.remove(at: rootMatchIndex)
      }
    }
    return lines.joined(separator: "\n")
  }

  private func startsTOMLTable(in line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
  }

  /// 返回简单 TOML 表名；array table 和损坏的 header 不会被误识别为 `[features]`。
  private func tableName(in line: String) -> String? {
    let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
      .trimmingCharacters(in: .whitespaces)
    guard code.hasPrefix("["), code.hasSuffix("]"), !code.hasPrefix("[[") else { return nil }
    return code.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
  }

  /// 返回 nil 表示该行不是目标键；一旦左侧确为目标键，右侧只能是 TOML Bool，
  /// 防止把字符串、数组或损坏值静默替换成另一种类型。
  private func booleanAssignment(
    in line: String,
    key: String,
    path: String
  ) throws -> Bool? {
    let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard let equals = code.firstIndex(of: "=") else { return nil }
    let name = code[..<equals].trimmingCharacters(in: .whitespaces)
    guard name == key else { return nil }
    let rawValue = code[code.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    switch rawValue {
    case "true": return true
    case "false": return false
    default: throw AgentSetupServiceError.invalidConfiguration(path)
    }
  }

  private func expandedManagedPath(_ path: String) throws -> URL {
    guard path == "~" || path.hasPrefix("~/") else {
      throw AgentSetupServiceError.unsafePath(path)
    }
    let relative = path == "~" ? "" : String(path.dropFirst(2))
    let url = homeDirectory.appendingPathComponent(relative).standardizedFileURL
    guard url.pathComponents.starts(with: homeDirectory.pathComponents) else {
      throw AgentSetupServiceError.unsafePath(url.path)
    }
    return url
  }

  private func validateDirectoryPath(_ directory: URL) throws {
    try validateExistingAncestors(of: directory, includeTarget: true, targetMayBeDirectory: true)
  }

  private func readExistingRegularFile(at url: URL) throws -> ExistingFile? {
    try validateExistingAncestors(of: url, includeTarget: false, targetMayBeDirectory: false)
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw CocoaError(.fileReadUnknown)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw AgentSetupServiceError.unsupportedFile(url.path)
    }
    guard info.st_size <= Self.maximumConfigurationBytes else {
      throw AgentSetupServiceError.fileTooLarge(url.path)
    }
    let data = try Data(contentsOf: url)
    guard data.count <= Self.maximumConfigurationBytes else {
      // lstat 与 read 之间若文件增长，读取后的二次限制阻止竞争条件绕过上限。
      throw AgentSetupServiceError.fileTooLarge(url.path)
    }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return ExistingFile(
      data: data,
      permissions: attributes[.posixPermissions] as? NSNumber
    )
  }

  /// 检查 home 到目标之间所有已存在组件。任何 symlink 都拒绝，即使最终解析到
  /// 普通文件；这避免设置操作越出用户看到的 provider 配置树。
  private func validateExistingAncestors(
    of target: URL,
    includeTarget: Bool,
    targetMayBeDirectory: Bool
  ) throws {
    var homeInfo = stat()
    guard lstat(homeDirectory.path, &homeInfo) == 0,
      homeInfo.st_mode & S_IFMT == S_IFDIR
    else {
      // 注入的测试 home 与真实用户 home 使用同一规则：根本身也不能是 symlink。
      // 否则后续 lstat 只检查最终分量，会在路径解析时悄悄跟随这个根链接。
      throw AgentSetupServiceError.unsupportedFile(homeDirectory.path)
    }
    let homeComponents = homeDirectory.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    guard targetComponents.starts(with: homeComponents) else {
      throw AgentSetupServiceError.unsafePath(target.path)
    }
    let lastIndex = includeTarget ? targetComponents.count : targetComponents.count - 1
    guard lastIndex >= homeComponents.count else { return }
    var current = homeDirectory
    for component in targetComponents[homeComponents.count..<lastIndex] {
      current.appendPathComponent(component)
      var info = stat()
      guard lstat(current.path, &info) == 0 else {
        if errno == ENOENT { continue }
        throw CocoaError(.fileReadUnknown)
      }
      let kind = info.st_mode & S_IFMT
      let isFinal = current.standardizedFileURL == target.standardizedFileURL
      let accepted = kind == S_IFDIR || (isFinal && !targetMayBeDirectory && kind == S_IFREG)
      guard accepted else { throw AgentSetupServiceError.unsupportedFile(current.path) }
    }
  }

  private func apply(_ edit: PreparedEdit) throws {
    let parent = edit.target.deletingLastPathComponent()
    try validateDirectoryPath(parent)
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    // 创建缺失目录后再检查一次，缩小预检与写入之间被替换成 symlink 的窗口。
    try validateDirectoryPath(parent)
    let current = try readExistingRegularFile(at: edit.target)
    guard current?.data == edit.original?.data else {
      throw AgentSetupServiceError.configurationChanged(edit.target.path)
    }

    var wroteContents = false
    do {
      try edit.contents.write(to: edit.target, options: .atomic)
      wroteContents = true
      if let permissions = edit.original?.permissions {
        try fileManager.setAttributes(
          [.posixPermissions: permissions],
          ofItemAtPath: edit.target.path
        )
      }
    } catch {
      // 权限恢复等后置操作可能在原子替换成功后失败；这种情况下由当前目标自行
      // 恢复，再交给外层回滚更早的 edit，避免把未写目标误认为本次产物。
      if wroteContents {
        do {
          try restore(edit)
        } catch {
          throw AgentSetupServiceError.rollbackFailed(edit.target.path)
        }
      }
      throw error
    }
  }

  private func restore(_ edit: PreparedEdit) throws {
    let current = try readExistingRegularFile(at: edit.target)
    guard current?.data == edit.contents else {
      // 安装后若外部进程已经再次更新文件，回滚宁可报告失败也绝不覆盖新内容。
      throw AgentSetupServiceError.configurationChanged(edit.target.path)
    }
    if let original = edit.original {
      try original.data.write(to: edit.target, options: .atomic)
      if let permissions = original.permissions {
        try fileManager.setAttributes(
          [.posixPermissions: permissions],
          ofItemAtPath: edit.target.path
        )
      }
    } else if current != nil {
      try fileManager.removeItem(at: edit.target)
    }
  }
}

private extension String {
  func ranges(of needle: String) -> [Range<String.Index>] {
    guard !needle.isEmpty else { return [] }
    var result: [Range<String.Index>] = []
    var searchStart = startIndex
    while searchStart < endIndex,
      let range = range(of: needle, range: searchStart..<endIndex)
    {
      result.append(range)
      searchStart = range.upperBound
    }
    return result
  }
}
