import Darwin
import Foundation

enum ShellIntegrationInstallerError: Error, Equatable, LocalizedError {
  case missingResource(String)
  case fileTooLarge(String)
  case unsupportedFile(String)
  case malformedManagedBlock(String)
  case rollbackFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingResource(let path): "缺少 Shell 集成资源：\(path)"
    case .fileTooLarge(let path): "Shell 启动文件超过安全大小限制：\(path)"
    case .unsupportedFile(let path): "Shell 启动文件不是普通文件：\(path)"
    case .malformedManagedBlock(let path): "Shell 启动文件中的 Aster 受管区块不完整：\(path)"
    case .rollbackFailed(let path): "Shell 启动文件更新失败且无法恢复，请检查：\(path)"
    }
  }
}

/// 安装和移除 Bash 及 tmux 子 Shell 所需的最小受管 rc 区块。
///
/// 普通 zsh/fish Pane 使用进程级环境注入，不修改用户配置。Bash 没有等价入口，而
/// tmux 创建的子 Shell 不再经过 Pane 启动计划，因此只有这些边界写入带守卫的区块。
/// 编辑会保留区块外字节、文件权限和符号链接；特殊文件及超大文件直接拒绝。
struct ShellIntegrationInstaller {
  static let startMarker = "# >>> Aster shell integration >>>"
  static let endMarker = "# <<< Aster shell integration <<<"

  private static let separatorAddedSuffix = " (separator added)"
  private static let maximumRCBytes = 1_048_576

  /// 单个启动文件经完整读取、类型检查和 marker 校验后的写入计划。先为所有目标生成
  /// 计划，再进行任何内容写入，避免后置文件损坏时留下只安装了一半的集成区块。
  private struct ManagedEdit {
    let target: URL
    let contents: Data
    let originalContents: Data?
    let permissions: NSNumber?
  }

  let resourceDirectory: URL
  let homeDirectory: URL
  let tmuxAvailable: Bool
  private let fileManager: FileManager

  init(
    resourceDirectory: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    tmuxAvailable: Bool? = nil,
    fileManager: FileManager = .default
  ) {
    self.resourceDirectory = resourceDirectory
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    self.tmuxAvailable = tmuxAvailable ?? Self.executableExists(named: "tmux")
  }

  /// 使用户启动文件与总开关一致。所有目标会先完成类型、大小、编码和 marker 预检；
  /// 通过后才逐个原子替换，因此可预见的输入错误不会留下部分安装状态。
  func reconcile(enabled: Bool) throws {
    let zshResource = resourceDirectory.appendingPathComponent("aster-integration.zsh")
    let bashResource = resourceDirectory.appendingPathComponent("aster-integration.bash")
    let fishResource = resourceDirectory.appendingPathComponent("aster-integration.fish")
    if enabled {
      for resource in [zshResource, bashResource, fishResource] {
        guard fileManager.isReadableFile(atPath: resource.path) else {
          throw ShellIntegrationInstallerError.missingResource(resource.path)
        }
      }
    }

    let bashBlock = enabled ? bourneBlock(resource: bashResource, requiresTMUX: false) : nil
    let zshBlock = enabled && tmuxAvailable
      ? bourneBlock(resource: zshResource, requiresTMUX: true) : nil
    let fishURL = homeDirectory.appendingPathComponent(
      ".config/fish/conf.d/aster-shell-integration.fish")
    let fishBlock = enabled && tmuxAvailable ? fishManagedBlock(resource: fishResource) : nil
    let requests: [(URL, [String]?)] = [
      (homeDirectory.appendingPathComponent(".bashrc"), bashBlock),
      (homeDirectory.appendingPathComponent(".bash_profile"), bashBlock),
      (homeDirectory.appendingPathComponent(".zshrc"), zshBlock),
      (fishURL, fishBlock),
    ]

    // `compactMap` 必须完整成功才会返回，因此这里之前不会修改任何启动文件。
    let edits = try requests.compactMap { try prepareManagedEdit(at: $0.0, block: $0.1) }
    var attempted: [ManagedEdit] = []
    do {
      for edit in edits {
        // `apply` 可能在替换内容后、恢复权限时失败，因此写入前就纳入回滚集合。
        attempted.append(edit)
        try apply(edit)
      }
    } catch {
      var failedRollbackPath: String?
      for edit in attempted.reversed() {
        do {
          try restore(edit)
        } catch {
          // 一个目标无法恢复时仍继续撤销其它目标，最大限度减少半安装范围。
          if failedRollbackPath == nil { failedRollbackPath = edit.target.path }
        }
      }
      if let failedRollbackPath {
        throw ShellIntegrationInstallerError.rollbackFailed(failedRollbackPath)
      }
      throw error
    }
  }

  private func bourneBlock(resource: URL, requiresTMUX: Bool) -> [String] {
    var conditions = [
      "[[ \"${TERM_PROGRAM:-}\" == \"aster\" ]]",
      "[[ \"${ASTER_DISABLE_INTEGRATION:-0}\" != \"1\" ]]",
    ]
    if requiresTMUX { conditions.append("[[ -n \"${TMUX:-}\" ]]") }
    return [
      "if \(conditions.joined(separator: " && ")); then",
      "  source \(Self.shellQuoted(resource.path))",
      "fi",
    ]
  }

  private func fishManagedBlock(resource: URL) -> [String] {
    [
      "if test \"$TERM_PROGRAM\" = \"aster\"; and test \"$ASTER_DISABLE_INTEGRATION\" != \"1\"; and set -q TMUX",
      "  source \(Self.shellQuoted(resource.path))",
      "end",
    ]
  }

  private func prepareManagedEdit(at requestedURL: URL, block: [String]?) throws -> ManagedEdit? {
    let target = try resolvedRegularFileURL(requestedURL)
    let existing: String
    let originalContents: Data?
    var permissions: NSNumber?
    if fileManager.fileExists(atPath: target.path) {
      let attributes = try fileManager.attributesOfItem(atPath: target.path)
      if let size = attributes[.size] as? NSNumber,
        size.intValue > Self.maximumRCBytes
      {
        throw ShellIntegrationInstallerError.fileTooLarge(requestedURL.path)
      }
      permissions = attributes[.posixPermissions] as? NSNumber
      existing = try String(contentsOf: target, encoding: .utf8)
      originalContents = Data(existing.utf8)
    } else {
      existing = ""
      originalContents = nil
    }

    var cleaned = try removingManagedBlocks(from: existing, path: requestedURL.path)
    if let block {
      let addedSeparator = !cleaned.isEmpty && !cleaned.hasSuffix("\n")
      if addedSeparator { cleaned.append("\n") }
      let opening = Self.startMarker + (addedSeparator ? Self.separatorAddedSuffix : "")
      cleaned += ([opening] + block + [Self.endMarker]).joined(separator: "\n") + "\n"
    }
    guard cleaned != existing else { return nil }
    return ManagedEdit(
      target: target,
      contents: Data(cleaned.utf8),
      originalContents: originalContents,
      permissions: permissions
    )
  }

  private func apply(_ edit: ManagedEdit) throws {
    try fileManager.createDirectory(
      at: edit.target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try edit.contents.write(to: edit.target, options: .atomic)
    if let permissions = edit.permissions {
      try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: edit.target.path)
    }
  }

  /// 尽力恢复本次 reconcile 前的精确 UTF-8 内容和权限。原来不存在的文件会删除，
  /// 但保留已经创建的父目录；这样既撤销受管区块，也不递归触碰用户目录。
  private func restore(_ edit: ManagedEdit) throws {
    if let originalContents = edit.originalContents {
      try originalContents.write(to: edit.target, options: .atomic)
      if let permissions = edit.permissions {
        try fileManager.setAttributes(
          [.posixPermissions: permissions], ofItemAtPath: edit.target.path)
      }
    } else if fileManager.fileExists(atPath: edit.target.path) {
      try fileManager.removeItem(at: edit.target)
    }
  }

  /// 跟随已有符号链接编辑其普通文件目标，绝不以原子替换把链接本身变成普通文件。
  /// 缺失路径允许创建；FIFO、socket、设备文件和悬空链接均拒绝。
  private func resolvedRegularFileURL(_ requestedURL: URL) throws -> URL {
    var info = stat()
    guard lstat(requestedURL.path, &info) == 0 else {
      if errno == ENOENT { return requestedURL }
      throw CocoaError(.fileReadUnknown)
    }
    let kind = info.st_mode & S_IFMT
    if kind == S_IFLNK {
      let resolved = requestedURL.resolvingSymlinksInPath()
      var targetInfo = stat()
      guard stat(resolved.path, &targetInfo) == 0, targetInfo.st_mode & S_IFMT == S_IFREG else {
        throw ShellIntegrationInstallerError.unsupportedFile(requestedURL.path)
      }
      return resolved
    }
    guard kind == S_IFREG else {
      throw ShellIntegrationInstallerError.unsupportedFile(requestedURL.path)
    }
    return requestedURL
  }

  private func removingManagedBlocks(from original: String, path: String) throws -> String {
    var result = original
    while let start = result.range(of: Self.startMarker) {
      guard start.lowerBound == result.startIndex || result[result.index(before: start.lowerBound)] == "\n",
        let openingLineEnd = result[start.upperBound...].firstIndex(of: "\n")
      else { throw ShellIntegrationInstallerError.malformedManagedBlock(path) }
      let suffix = String(result[start.upperBound..<openingLineEnd])
      guard suffix.isEmpty || suffix == Self.separatorAddedSuffix,
        let end = result.range(of: Self.endMarker, range: openingLineEnd..<result.endIndex)
      else { throw ShellIntegrationInstallerError.malformedManagedBlock(path) }
      let endLine = result[end.upperBound...].firstIndex(of: "\n")
        .map { result.index(after: $0) } ?? end.upperBound
      var removalStart = start.lowerBound
      if suffix == Self.separatorAddedSuffix, removalStart > result.startIndex {
        removalStart = result.index(before: removalStart)
      }
      result.removeSubrange(removalStart..<endLine)
    }
    if result.contains(Self.endMarker) {
      throw ShellIntegrationInstallerError.malformedManagedBlock(path)
    }
    return result
  }

  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  private static func executableExists(named name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    return path.split(separator: ":").contains { directory in
      FileManager.default.isExecutableFile(
        atPath: URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path)
    }
  }
}
