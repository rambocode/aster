import CryptoKit
import Darwin
import Foundation

/// Aster skill（`Resources/skills/aster/`）的安装服务：把 SKILL.md 复制到各 Agent 的 skills 目录
/// （Claude Code `~/.claude/skills/aster`、Codex `~/.codex/skills/aster`），并写 `.aster-skill-version`
/// 标记（App 版本 + SKILL.md sha256）用于判断是否过期。
///
/// 约束：
/// - 复制而不是 symlink：Agent 可能在沙箱里读 skills，指向 .app 内部的链接不一定可达，
///   App 被移动后也会失效；
/// - 只接管带标记的目录：目标已存在但没有我们的标记（用户自己写的同名 skill）视为 foreign，
///   安装与卸载都拒绝碰它；符号链接一律拒绝；
/// - 发布走「临时目录 + rename 交换」原子替换。
enum AgentSkillInstallService {
  /// 支持安装的 Agent；与 AgentProvider 解耦，只描述 skills 目录布局。
  enum Target: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    /// 该 Agent 的 skills 根目录（相对 HOME）。
    var skillsRoot: String {
      switch self {
      case .claudeCode: ".claude/skills"
      case .codex: ".codex/skills"
      }
    }
  }

  static let skillName = "aster"
  static let markerFileName = ".aster-skill-version"
  static let documentFileName = "SKILL.md"

  /// 标记文件内容（JSON）。sha256 针对 SKILL.md 正文，版本号相同但文档改了也会判过期。
  struct Marker: Codable, Equatable {
    var version: String
    var sha256: String
  }

  /// 安装状态，供 UI 决定按钮文案。
  enum State: Equatable {
    case notInstalled
    case installed(version: String)
    /// 标记与当前 App 附带的 skill 不一致，需要重新安装。
    case outdated(installed: String, expected: String)
    /// 目标存在但不是 Aster 安装的（无标记 / 符号链接 / 非目录），拒绝接管。
    case foreign(path: String)
  }

  enum ServiceError: Error, Equatable {
    /// App 附带的 skill 资源找不到。
    case sourceNotFound
    /// 目标不是 Aster 安装的目录。
    case foreignDestination(String)
    /// 复制 / rename 失败。
    case writeFailed(String)

    /// 面向用户的中文描述。
    var localizedMessage: String {
      switch self {
      case .sourceNotFound:
        "找不到 Aster 附带的 skill 资源，请重新安装 Aster 或使用完整构建产物。"
      case .foreignDestination(let path):
        "拒绝覆盖 \(path)：它不是 Aster 安装的 skill 目录。"
      case .writeFailed(let path):
        "写入 \(path) 失败，请检查目录权限。"
      }
    }
  }

  // MARK: - 定位

  /// 目标目录：`~/<skillsRoot>/aster`。
  static func destination(for target: Target, home: String = NSHomeDirectory()) -> URL {
    URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(target.skillsRoot, isDirectory: true)
      .appendingPathComponent(skillName, isDirectory: true)
  }

  /// App 附带的 skill 源目录：打包为 `Contents/Resources/skills/aster`，开发构建回退仓库 `Resources/skills/aster`。
  static func sourceDirectory(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
    var candidates: [URL] = []
    if let bundled = bundle.resourceURL {
      candidates.append(bundled.appendingPathComponent("skills/\(skillName)", isDirectory: true))
    }
    if let resources = AsterResourceLocations.resourcesDirectory(bundle: bundle, fileManager: fileManager) {
      candidates.append(resources.appendingPathComponent("skills/\(skillName)", isDirectory: true))
    }
    return candidates.first {
      fileManager.fileExists(atPath: $0.appendingPathComponent(documentFileName).path)
    }
  }

  /// 当前 App 版本；测试可注入。
  static func appVersion(bundle: Bundle = .main) -> String {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  /// 由源目录算出安装后应写入的标记。
  static func expectedMarker(source: URL, version: String) throws -> Marker {
    let document = source.appendingPathComponent(documentFileName)
    guard let data = try? Data(contentsOf: document) else { throw ServiceError.sourceNotFound }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return Marker(version: version, sha256: digest)
  }

  // MARK: - 查询

  /// 读取安装状态。源资源缺失时仍能判断「已安装」但无法判断是否过期，按 installed 返回。
  static func state(
    for target: Target,
    home: String = NSHomeDirectory(),
    source: URL? = nil,
    version: String? = nil,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> State {
    let destination = destination(for: target, home: home)
    switch probe(destination) {
    case .missing:
      return .notInstalled
    case .foreign:
      return .foreign(path: destination.path)
    case .owned(let installed):
      guard let source = source ?? sourceDirectory(bundle: bundle, fileManager: fileManager),
        let expected = try? expectedMarker(source: source, version: version ?? appVersion(bundle: bundle))
      else { return .installed(version: installed.version) }
      return installed == expected
        ? .installed(version: installed.version)
        : .outdated(installed: installed.version, expected: expected.version)
    }
  }

  // MARK: - 安装 / 卸载

  /// 安装或更新，返回目标目录。重复调用幂等。
  @discardableResult
  static func install(
    for target: Target,
    home: String = NSHomeDirectory(),
    source: URL? = nil,
    version: String? = nil,
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) throws -> URL {
    guard let source = source ?? sourceDirectory(bundle: bundle, fileManager: fileManager) else {
      throw ServiceError.sourceNotFound
    }
    let marker = try expectedMarker(source: source, version: version ?? appVersion(bundle: bundle))
    let destination = destination(for: target, home: home)
    if case .foreign = probe(destination) {
      throw ServiceError.foreignDestination(destination.path)
    }
    let parent = destination.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
      throw ServiceError.writeFailed(parent.path)
    }

    // 先在同一父目录里完整准备好新目录，再用 rename 交换：目标任何时刻要么是旧的完整版本、
    // 要么是新的完整版本，不会出现只有一半文件的 skill。
    let staging = parent.appendingPathComponent(".\(skillName).\(UUID().uuidString).tmp", isDirectory: true)
    let retired = parent.appendingPathComponent(".\(skillName).\(UUID().uuidString).old", isDirectory: true)
    var published = false
    defer {
      if !published { try? fileManager.removeItem(at: staging) }
      try? fileManager.removeItem(at: retired)
    }
    do {
      try fileManager.copyItem(at: source, to: staging)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var payload = try encoder.encode(marker)
      payload.append(0x0A)
      try payload.write(to: staging.appendingPathComponent(markerFileName), options: .atomic)
    } catch {
      throw ServiceError.writeFailed(destination.path)
    }
    // rename 不能覆盖非空目录，所以先把旧目录挪开；rename 之间再复核一次目标仍是我们的。
    if case .owned = probe(destination) {
      guard rename(destination.path, retired.path) == 0 else {
        throw ServiceError.writeFailed(destination.path)
      }
    } else if case .foreign = probe(destination) {
      throw ServiceError.foreignDestination(destination.path)
    }
    guard rename(staging.path, destination.path) == 0 else {
      // 尽力把旧目录放回去，别让用户的 skill 凭空消失。
      _ = rename(retired.path, destination.path)
      throw ServiceError.writeFailed(destination.path)
    }
    published = true
    return destination
  }

  /// 卸载：只删除带 Aster 标记的目录；foreign 目录报错，未安装为无操作。
  static func uninstall(
    for target: Target, home: String = NSHomeDirectory(), fileManager: FileManager = .default
  ) throws {
    let destination = destination(for: target, home: home)
    switch probe(destination) {
    case .missing:
      return
    case .foreign:
      throw ServiceError.foreignDestination(destination.path)
    case .owned:
      do {
        try fileManager.removeItem(at: destination)
      } catch {
        throw ServiceError.writeFailed(destination.path)
      }
    }
  }

  // MARK: - 探测

  /// 目标目录的形态。
  private enum Probe {
    case missing
    /// 我们安装的：普通目录 + 可解析的标记文件。
    case owned(Marker)
    /// 符号链接、非目录、或没有（合法）标记的目录。
    case foreign
  }

  /// `lstat` 不跟随链接：目标是 symlink 时即便指向我们的目录也算 foreign，避免经链接写到别处。
  private static func probe(_ destination: URL) -> Probe {
    var metadata = stat()
    guard lstat(destination.path, &metadata) == 0 else { return .missing }
    guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid() else { return .foreign }
    let markerURL = destination.appendingPathComponent(markerFileName)
    var markerMetadata = stat()
    guard lstat(markerURL.path, &markerMetadata) == 0,
      markerMetadata.st_mode & S_IFMT == S_IFREG,
      let data = try? Data(contentsOf: markerURL),
      let marker = try? JSONDecoder().decode(Marker.self, from: data)
    else { return .foreign }
    return .owned(marker)
  }
}
