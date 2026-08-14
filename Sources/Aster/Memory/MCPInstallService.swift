import Foundation

/// `aster-memory-mcp` 的一键安装服务：把 MCP server 注册进项目根目录的 `.mcp.json`，
/// 让 Claude Code 在该项目下自动连上 Aster 的跨 Agent 记忆库。
///
/// 只提供服务 API，不涉及任何 UI。核心约束：
/// - `.mcp.json` 是**用户的**项目文件，可能已注册别的 server，因此永远读-改-写，
///   只管理 `aster-memory` 这一项，其余键（含我们这项里用户自加的 `env`/`args`）原样保留；
/// - 写入走「临时文件 + fsync + rename」原子发布，中途崩溃不会留下半截 JSON；
/// - 目标必须是当前用户拥有的普通文件，符号链接 / FIFO / 设备文件一律拒绝，
///   避免通过项目目录里的伪造文件把写操作重定向到别处。
enum MCPInstallService {
  /// 我们在 `.mcp.json` 里管理的唯一键名。
  static let serverKey = "aster-memory"
  /// 构建产物名，App bundle 与 SwiftPM 调试目录里同名。
  static let executableName = "aster-memory-mcp"
  /// `.mcp.json` 的读取上限：正常配置只有几百字节，1 MiB 已经远超合理范围。
  static let maximumConfigurationBytes = 1_024 * 1_024

  /// 安装状态，供 UI 决定按钮文案（安装 / 已安装 / 需要修复）。
  enum State: Equatable {
    case notInstalled
    /// 已安装且记录的路径与当前解析结果一致。
    case installed(commandPath: String)
    /// 已安装但记录的路径不是当前可执行文件（App 被移动或从 .build 装过）。
    case outdated(commandPath: String, expected: String)
  }

  enum ServiceError: Error, Equatable {
    /// 解析不到 `aster-memory-mcp` 可执行文件。
    case executableNotFound
    /// 目标不是当前用户拥有的普通文件（符号链接、FIFO、他人文件等）。
    case unsafeConfigurationFile(String)
    /// `.mcp.json` 超过体积上限，拒绝解析。
    case configurationTooLarge(String)
    /// `.mcp.json` 不是合法 JSON 对象，或 `mcpServers` 不是对象。
    case malformedConfiguration(String)
    /// 目录不可写、rename 失败等。
    case writeFailed(String)

    /// 面向用户的中文描述，UI 直接展示。
    var localizedMessage: String {
      switch self {
      case .executableNotFound:
        "找不到 aster-memory-mcp 可执行文件，请重新安装 Aster 或使用完整构建产物。"
      case .unsafeConfigurationFile(let path):
        "拒绝写入 \(path)：它不是当前用户拥有的普通文件。"
      case .configurationTooLarge(let path):
        "\(path) 超过 1 MiB，已拒绝解析。"
      case .malformedConfiguration(let path):
        "\(path) 不是合法的 MCP 配置（应为 JSON 对象）。"
      case .writeFailed(let path):
        "写入 \(path) 失败，请检查目录权限。"
      }
    }
  }

  // MARK: - 可执行文件解析

  /// 解析 `aster-memory-mcp` 的绝对路径。
  ///
  /// 优先顺序刻意从「与主程序同目录」开始：分发时它就在 `Aster.app/Contents/MacOS/` 里，
  /// SwiftPM 调试时则在 `.build/<配置>/` 里，两种情况都由 `executableURL` 的父目录命中；
  /// 后两个候选覆盖 `Bundle.main` 指向 .app 根目录、以及测试进程等边缘情形。
  static func resolveExecutableURL(
    bundle: Bundle = .main, fileManager: FileManager = .default
  ) -> URL? {
    var candidates: [URL] = []
    if let executable = bundle.executableURL {
      candidates.append(executable.deletingLastPathComponent().appendingPathComponent(executableName))
    }
    candidates.append(
      bundle.bundleURL
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(executableName))
    candidates.append(
      bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(executableName))
    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
      return candidate.standardizedFileURL
    }
    return nil
  }

  /// 项目根目录下的 `.mcp.json` 路径。
  static func configurationURL(projectDirectory: URL) -> URL {
    projectDirectory.appendingPathComponent(".mcp.json", isDirectory: false)
  }

  // MARK: - 查询

  /// 读取当前安装状态。文件不存在视为未安装（不是错误）。
  static func state(
    projectDirectory: URL,
    executableURL: URL? = nil,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws -> State {
    let url = configurationURL(projectDirectory: projectDirectory)
    let root = try readConfiguration(at: url, fileManager: fileManager)
    guard let servers = root["mcpServers"] as? [String: Any],
      let entry = servers[serverKey] as? [String: Any],
      let command = entry["command"] as? String, !command.isEmpty
    else { return .notInstalled }
    let expected = (executableURL ?? resolveExecutableURL(bundle: bundle, fileManager: fileManager))?
      .standardizedFileURL.path
    guard let expected else { return .installed(commandPath: command) }
    return command == expected
      ? .installed(commandPath: command)
      : .outdated(commandPath: command, expected: expected)
  }

  // MARK: - 安装 / 卸载

  /// 安装或修复注册项，返回写入的可执行文件路径。重复调用幂等。
  @discardableResult
  static func install(
    projectDirectory: URL,
    executableURL: URL? = nil,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws -> String {
    guard
      let executable = executableURL
        ?? resolveExecutableURL(bundle: bundle, fileManager: fileManager)
    else {
      throw ServiceError.executableNotFound
    }
    let command = executable.standardizedFileURL.path
    let url = configurationURL(projectDirectory: projectDirectory)
    var root = try readConfiguration(at: url, fileManager: fileManager)

    var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
    // 保留用户在我们这项下自行添加的字段（例如 env），只覆盖 command。
    var entry = (servers[serverKey] as? [String: Any]) ?? [:]
    entry["command"] = command
    servers[serverKey] = entry
    root["mcpServers"] = servers

    try writeConfiguration(root, to: url, fileManager: fileManager)
    return command
  }

  /// 移除我们的注册项，保留其余 server。未安装时为无操作。
  static func uninstall(projectDirectory: URL, fileManager: FileManager = .default) throws {
    let url = configurationURL(projectDirectory: projectDirectory)
    guard fileManager.fileExists(atPath: url.path) else { return }
    var root = try readConfiguration(at: url, fileManager: fileManager)
    guard var servers = root["mcpServers"] as? [String: Any],
      servers[serverKey] != nil
    else { return }
    servers.removeValue(forKey: serverKey)

    // 文件里除了我们自己没有任何内容时直接删除：卸载后不该在用户仓库里
    // 留下一个语义为空的 `.mcp.json`（会被误提交，也会让别的工具困惑）。
    if servers.isEmpty, root.count == 1 {
      guard isOwnedRegularFile(url, fileManager: fileManager) else {
        throw ServiceError.unsafeConfigurationFile(url.path)
      }
      do {
        try fileManager.removeItem(at: url)
      } catch {
        throw ServiceError.writeFailed(url.path)
      }
      return
    }
    root["mcpServers"] = servers
    try writeConfiguration(root, to: url, fileManager: fileManager)
  }

  // MARK: - Codex 提示

  /// 生成 Codex 的手动配置片段。
  ///
  /// 刻意**不**自动改写 `~/.codex/config.toml`：那是用户全局的、跨项目的手写配置，
  /// TOML 的注释与顺序无法无损往返，静默改写风险远高于收益。UI 展示这段让用户自己贴。
  static func codexInstructions(
    executableURL: URL? = nil, bundle: Bundle = .main, fileManager: FileManager = .default
  ) -> String {
    let command =
      (executableURL ?? resolveExecutableURL(bundle: bundle, fileManager: fileManager))?
      .standardizedFileURL.path ?? "/path/to/\(executableName)"
    return """
      把下面这段追加到 ~/.codex/config.toml，然后重启 Codex：

      [mcp_servers.\(serverKey)]
      command = "\(command)"
      args = []
      """
  }

  // MARK: - 文件读写

  /// 读取并解析 `.mcp.json`；文件不存在返回空配置。
  private static func readConfiguration(
    at url: URL, fileManager: FileManager
  ) throws -> [String: Any] {
    guard fileManager.fileExists(atPath: url.path) else { return [:] }
    guard isOwnedRegularFile(url, fileManager: fileManager) else {
      throw ServiceError.unsafeConfigurationFile(url.path)
    }
    let data = try readRegularFile(at: url)
    guard !data.isEmpty else { return [:] }
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else { throw ServiceError.malformedConfiguration(url.path) }
    // `mcpServers` 存在但类型不对时必须报错：静默覆盖会丢掉用户的配置。
    if root["mcpServers"] != nil, root["mcpServers"] as? [String: Any] == nil {
      throw ServiceError.malformedConfiguration(url.path)
    }
    return root
  }

  /// `O_NOFOLLOW` 打开 + `fstat` 复核，读满上限即判定超限。
  private static func readRegularFile(at url: URL) throws -> Data {
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw ServiceError.unsafeConfigurationFile(url.path) }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid()
    else { throw ServiceError.unsafeConfigurationFile(url.path) }
    guard metadata.st_size <= maximumConfigurationBytes else {
      throw ServiceError.configurationTooLarge(url.path)
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while data.count <= maximumConfigurationBytes {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw ServiceError.unsafeConfigurationFile(url.path) }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= maximumConfigurationBytes else {
      throw ServiceError.configurationTooLarge(url.path)
    }
    return data
  }

  /// 序列化并原子发布。
  ///
  /// 这里用 `rename` 而不是 `AsterCLIRequestService` 的 `link`：那边的目标必须不存在，
  /// 而 `.mcp.json` 需要**替换**一个已有文件。目标在 `readConfiguration` 阶段已确认是
  /// 我们拥有的普通文件，rename 前再复核一次，把 TOCTOU 窗口压到最小。
  private static func writeConfiguration(
    _ root: [String: Any], to url: URL, fileManager: FileManager
  ) throws {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    else { throw ServiceError.malformedConfiguration(url.path) }
    var payload = data
    payload.append(0x0A)  // 末尾换行：`.mcp.json` 通常进版本库，保持 POSIX 文本约定。

    // 已存在时沿用原权限：用户可能刻意把 `.mcp.json` 收紧成 0600，
    // 替换文件不该悄悄放宽它。
    var existingMode: mode_t?
    var existingMetadata = stat()
    let existed = lstat(url.path, &existingMetadata) == 0
    if existed {
      guard isOwnedRegularFile(url, fileManager: fileManager) else {
        throw ServiceError.unsafeConfigurationFile(url.path)
      }
      existingMode = existingMetadata.st_mode & 0o777
    }

    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = temporaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      // 0644：`.mcp.json` 是项目文件，可能被提交并由其它工具读取，不套用 0600。
      return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
    }
    guard descriptor >= 0 else { throw ServiceError.writeFailed(url.path) }
    if let existingMode { _ = fchmod(descriptor, existingMode) }
    var published = false
    defer {
      Darwin.close(descriptor)
      if !published { try? fileManager.removeItem(at: temporaryURL) }
    }

    try payload.withUnsafeBytes { bytes in
      guard var pointer = bytes.baseAddress else { return }
      var remaining = bytes.count
      while remaining > 0 {
        let written = Darwin.write(descriptor, pointer, remaining)
        guard written > 0 else { throw ServiceError.writeFailed(url.path) }
        remaining -= written
        pointer = pointer.advanced(by: written)
      }
    }
    guard fsync(descriptor) == 0 else { throw ServiceError.writeFailed(url.path) }
    if existed, !isOwnedRegularFile(url, fileManager: fileManager) {
      throw ServiceError.unsafeConfigurationFile(url.path)
    }
    guard rename(temporaryURL.path, url.path) == 0 else {
      throw ServiceError.writeFailed(url.path)
    }
    published = true
  }

  /// 目标必须是当前用户拥有的普通文件；`lstat` 不跟随符号链接。
  private static func isOwnedRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return false }
    return metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == geteuid()
  }
}
