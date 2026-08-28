import Foundation

/// 清单仓库：内置清单 + 用户覆盖目录（`<id>.json`），负责编译缓存与热重载。
///
/// 加载策略移植自 herdr `load_manifest_uncached`（去掉远程更新层）：
/// - 覆盖文件存在且 id / 别名匹配、能编译 → 用覆盖；
/// - 覆盖文件解析失败 / id 不匹配 / 编译失败 → 回落内置，并在 `warning` 里说明原因；
/// - 内置清单本身必须能编译，否则视为构建期错误（`fatalError`，与 herdr panic 一致）。
public final class AgentDetectionManifestStore: @unchecked Sendable {
  /// 某个 Agent 当前生效清单的摘要，供设置页展示。
  public struct Summary: Equatable, Sendable {
    public var id: String
    public var source: String
    public var version: String?
    public var warning: String?
  }

  public let bundled: [String: String]
  public let overrideDirectory: URL?

  private let lock = NSLock()
  private var cache: [String: CompiledAgentManifest] = [:]

  /// - Parameters:
  ///   - bundled: id → JSON，默认使用生成的 `AgentDetectionBundledManifests.all`。
  ///   - overrideDirectory: 用户覆盖目录（`<id>.json`）；nil 表示不支持覆盖。
  public init(
    bundled: [String: String] = AgentDetectionBundledManifests.all,
    overrideDirectory: URL? = nil
  ) {
    self.bundled = bundled
    self.overrideDirectory = overrideDirectory
    reload()
  }

  /// 全部内置清单 id（排序后）。
  public var manifestIDs: [String] { bundled.keys.sorted() }

  /// 取某个 Agent 的已编译清单；没有内置清单的 id 返回 nil。
  public func manifest(for id: String) -> CompiledAgentManifest? {
    lock.lock()
    defer { lock.unlock() }
    return cache[id]
  }

  /// 重新读取覆盖目录并重建缓存（覆盖文件改动后调用）。
  public func reload() {
    var rebuilt: [String: CompiledAgentManifest] = [:]
    for (id, json) in bundled {
      rebuilt[id] = Self.load(id: id, bundledJSON: json, overrideDirectory: overrideDirectory)
    }
    lock.lock()
    cache = rebuilt
    lock.unlock()
  }

  /// 当前生效清单摘要，按 id 排序。
  public var summaries: [Summary] {
    lock.lock()
    defer { lock.unlock() }
    return cache.keys.sorted().compactMap { id in
      guard let compiled = cache[id] else { return nil }
      return Summary(
        id: id, source: compiled.source, version: compiled.manifest.version,
        warning: compiled.warning)
    }
  }

  /// 覆盖文件路径：`<overrideDirectory>/<id>.json`。
  public func overrideURL(for id: String) -> URL? {
    overrideDirectory?.appendingPathComponent("\(id).json")
  }

  // MARK: - 加载

  /// 覆盖优先、失败回落内置的单清单加载。
  static func load(id: String, bundledJSON: String, overrideDirectory: URL?)
    -> CompiledAgentManifest
  {
    let bundled = bundledManifest(id: id, json: bundledJSON)
    let overrideURL = overrideDirectory?.appendingPathComponent("\(id).json")
    guard let overrideURL, FileManager.default.fileExists(atPath: overrideURL.path) else {
      return compileBundled(id: id, manifest: bundled, warning: nil)
    }
    let path = overrideURL.path
    let content: String
    do {
      content = try String(contentsOf: overrideURL, encoding: .utf8)
    } catch {
      return compileBundled(
        id: id, manifest: bundled,
        warning: "ignored override \(path) because it could not be loaded: \(error.localizedDescription)")
    }
    let manifest: AgentDetectionManifest
    do {
      manifest = try AgentDetectionManifest.decode(json: content)
    } catch {
      return compileBundled(
        id: id, manifest: bundled,
        warning: "ignored override \(path) because it could not be loaded: \(error)")
    }
    // id 匹配：覆盖清单的 id / 别名命中本 id，或覆盖清单的 id 是内置清单登记的别名
    //（对应 herdr `manifest_matches_agent` 里 parse_agent_label 的别名反查）。
    guard manifest.matches(agentID: id) || bundled.aliases.contains(manifest.id) else {
      return compileBundled(
        id: id, manifest: bundled,
        warning: "ignored override \(path) because manifest id \(manifest.id) does not match \(id)")
    }
    do {
      return try CompiledAgentManifest(manifest: manifest, source: path, warning: nil)
    } catch {
      return compileBundled(
        id: id, manifest: bundled,
        warning: "ignored override \(path) because it could not be compiled: \(error)")
    }
  }

  /// 内置清单必须可解码；这是随二进制发布的数据，坏了就是构建期错误。
  static func bundledManifest(id: String, json: String) -> AgentDetectionManifest {
    do {
      return try AgentDetectionManifest.decode(json: json)
    } catch {
      fatalError("bundled \(id) manifest is invalid: \(error)")
    }
  }

  /// 内置清单必须可编译（同上，坏了就是构建期错误）。
  static func compileBundled(id: String, manifest: AgentDetectionManifest, warning: String?)
    -> CompiledAgentManifest
  {
    do {
      return try CompiledAgentManifest(manifest: manifest, source: "bundled", warning: warning)
    } catch {
      fatalError("bundled \(id) manifest could not be compiled: \(error)")
    }
  }
}
