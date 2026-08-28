import Darwin
import Foundation

/// `aster` 命令的安装服务：把 `/usr/local/bin/aster`（不可写时 `~/.local/bin/aster`）做成指向
/// App 内 `aster-cli` 的符号链接。取代旧的「写一份 sh 启动器」方案：symlink 让 App 升级后
/// CLI 自动跟着更新，也让 CLI 能通过自身路径上溯找到 bundle 来拉起 App。
///
/// 只提供服务 API，不涉及 UI。约束：
/// - 目标位置若是旧 sh 脚本（带 Aster 标记）则直接替换；若是来历不明的普通文件则拒绝覆盖；
/// - 发布走「临时 symlink + rename」原子替换，任何时刻 `aster` 都指向一个完整目标；
/// - 目录列表可注入，便于测试在临时目录里验证。
enum AsterCLIInstaller {
  /// 构建产物名，App bundle 与 SwiftPM 调试目录里同名。
  static let executableName = "aster-cli"
  /// 安装到 PATH 里的命令名。
  static let commandName = "aster"
  /// 旧 sh 启动器的识别标记（见 AutocompleteService.swift 的 AsterCLIScript.contents）。
  static let legacyScriptMarkers = ["Aster CLI 启动器", "ASTER_CLI_REQUEST_V1"]
  /// 识别旧脚本时只读文件头部，避免把一个巨大的同名文件整个读进内存。
  static let legacyProbeBytes = 16 * 1_024

  /// 安装状态，供 UI 决定按钮文案。
  enum State: Equatable {
    case notInstalled
    /// symlink 存在且指向当前 `aster-cli`。
    case installed(path: String)
    /// symlink 存在但指向别处（App 被移动、或从 .build 装过）。
    case outdated(path: String, expected: String)
    /// 目标位置是旧版写入的 sh 启动器脚本，安装会覆盖它。
    case legacyScript(path: String)
  }

  enum ServiceError: Error, Equatable {
    /// 解析不到 `aster-cli` 可执行文件。
    case executableNotFound
    /// 目标位置是来历不明的普通文件或目录，拒绝覆盖。
    case foreignTarget(String)
    /// 没有任何候选目录可写。
    case noWritableDirectory
    /// symlink / rename 失败。
    case writeFailed(String)

    /// 面向用户的中文描述，UI 直接展示。
    var localizedMessage: String {
      switch self {
      case .executableNotFound:
        "找不到 aster-cli 可执行文件，请重新安装 Aster 或使用完整构建产物。"
      case .foreignTarget(let path):
        "拒绝覆盖 \(path)：它不是 Aster 安装的命令。"
      case .noWritableDirectory:
        "/usr/local/bin 与 ~/.local/bin 都不可写。"
      case .writeFailed(let path):
        "写入 \(path) 失败，请检查目录权限。"
      }
    }
  }

  // MARK: - 定位

  /// 解析 `aster-cli` 的绝对路径；候选顺序与 MCPInstallService.resolveExecutableURL 一致：
  /// 与主程序同目录（.app 与 .build 都命中）→ bundle 的 Contents/MacOS → bundle 同级目录。
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

  /// 安装目录候选，按优先级：系统级 `/usr/local/bin`，其次用户级 `~/.local/bin`。
  static func defaultDirectories(home: String = NSHomeDirectory()) -> [String] {
    ["/usr/local/bin", (home as NSString).appendingPathComponent(".local/bin")]
  }

  // MARK: - 查询

  /// 按候选目录顺序找第一个存在的 `aster`，返回其状态；都不存在即未安装。
  static func state(
    directories: [String] = defaultDirectories(),
    executableURL: URL? = nil,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> State {
    let expected = (executableURL ?? resolveExecutableURL(bundle: bundle, fileManager: fileManager))?
      .standardizedFileURL.path
    for directory in directories {
      let path = (directory as NSString).appendingPathComponent(commandName)
      switch probe(path, fileManager: fileManager) {
      case .missing, .foreign:
        continue
      case .legacyScript:
        return .legacyScript(path: path)
      case .symlink(let destination):
        guard let expected else { return .installed(path: path) }
        // 比较解析后的真实路径：/usr/local/bin 自身可能是 symlink，绝对路径写法也可能不同。
        return realPath(destination) == realPath(expected)
          ? .installed(path: path)
          : .outdated(path: path, expected: expected)
      }
    }
    return .notInstalled
  }

  // MARK: - 安装 / 卸载

  /// 安装或修复 symlink，返回最终路径。重复调用幂等。
  /// 目录选择：第一个已存在且可写的候选；都不可写时尝试创建最后一个（`~/.local/bin`）。
  @discardableResult
  static func install(
    directories: [String] = defaultDirectories(),
    executableURL: URL? = nil,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws -> String {
    guard
      let executable = executableURL
        ?? resolveExecutableURL(bundle: bundle, fileManager: fileManager)
    else { throw ServiceError.executableNotFound }
    let destination = executable.standardizedFileURL.path

    // 已有 symlink 或旧脚本的目录优先复用：避免 /usr/local/bin 与 ~/.local/bin 各留一份、
    // PATH 顺序决定谁生效的混乱局面。
    let existingDirectory = directories.first { directory in
      let path = (directory as NSString).appendingPathComponent(commandName)
      switch probe(path, fileManager: fileManager) {
      case .symlink, .legacyScript: return true
      case .missing, .foreign: return false
      }
    }
    let directory = try existingDirectory ?? selectWritableDirectory(directories, fileManager: fileManager)
    let path = (directory as NSString).appendingPathComponent(commandName)

    if case .foreign = probe(path, fileManager: fileManager) {
      throw ServiceError.foreignTarget(path)
    }
    // 临时 symlink + rename：rename 会原子替换旧 symlink 或旧脚本文件，中途崩溃不会留下空洞。
    let temporary = (directory as NSString).appendingPathComponent(".\(commandName).\(UUID().uuidString).tmp")
    guard symlink(destination, temporary) == 0 else { throw ServiceError.writeFailed(path) }
    guard rename(temporary, path) == 0 else {
      unlink(temporary)
      throw ServiceError.writeFailed(path)
    }
    return path
  }

  /// 移除所有候选目录里由 Aster 安装的 `aster`（symlink 到任意 aster-cli，或旧 sh 脚本）。
  /// 来历不明的同名文件保持不动。未安装时为无操作。
  static func uninstall(
    directories: [String] = defaultDirectories(), fileManager: FileManager = .default
  ) throws {
    for directory in directories {
      let path = (directory as NSString).appendingPathComponent(commandName)
      switch probe(path, fileManager: fileManager) {
      case .missing, .foreign:
        continue
      case .symlink(let destination):
        // 只删指向 aster-cli 的链接；用户自己指向别处的 `aster` 不是我们的。
        guard (destination as NSString).lastPathComponent == executableName else { continue }
        guard unlink(path) == 0 else { throw ServiceError.writeFailed(path) }
      case .legacyScript:
        guard unlink(path) == 0 else { throw ServiceError.writeFailed(path) }
      }
    }
  }

  // MARK: - 探测

  /// 目标位置的形态。
  private enum Probe {
    case missing
    case symlink(destination: String)
    case legacyScript
    /// 存在但既不是 symlink 也不是旧脚本（用户自己的文件 / 目录）。
    case foreign
  }

  /// `lstat` 不跟随链接；symlink 读 readlink，普通文件读头部判定旧脚本标记。
  private static func probe(_ path: String, fileManager: FileManager) -> Probe {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else { return .missing }
    switch metadata.st_mode & S_IFMT {
    case S_IFLNK:
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
      let length = readlink(path, &buffer, buffer.count - 1)
      guard length > 0 else { return .foreign }
      let destination = String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return .symlink(destination: destination)
    case S_IFREG:
      guard metadata.st_uid == geteuid() else { return .foreign }
      return isLegacyScript(path) ? .legacyScript : .foreign
    default:
      return .foreign
    }
  }

  /// 旧 sh 启动器：`#!/bin/sh` 开头且头部含 Aster 标记。
  private static func isLegacyScript(_ path: String) -> Bool {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var buffer = [UInt8](repeating: 0, count: legacyProbeBytes)
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count > 0 else { return false }
    let head = String(decoding: buffer[0..<count], as: UTF8.self)
    return head.hasPrefix("#!/bin/sh") && legacyScriptMarkers.contains { head.contains($0) }
  }

  /// 第一个已存在且可写的目录；都没有则创建最后一个候选（用户级目录）。
  private static func selectWritableDirectory(
    _ directories: [String], fileManager: FileManager
  ) throws -> String {
    if let writable = directories.first(where: { fileManager.isWritableFile(atPath: $0) }) {
      return writable
    }
    guard let fallback = directories.last else { throw ServiceError.noWritableDirectory }
    do {
      try fileManager.createDirectory(atPath: fallback, withIntermediateDirectories: true)
    } catch {
      throw ServiceError.noWritableDirectory
    }
    guard fileManager.isWritableFile(atPath: fallback) else { throw ServiceError.noWritableDirectory }
    return fallback
  }

  /// `realpath` 解析全部 symlink；失败（目标不存在）时退回标准化后的原路径。
  private static func realPath(_ path: String) -> String {
    guard let resolved = Darwin.realpath(path, nil) else {
      return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
