import AsterCore
import Foundation

/// 把任意工作目录解析成 Memory 的项目归属（PRD §15）。
///
/// 规则：优先 `git rev-parse --show-toplevel`；不是仓库时回落工作目录本身。
/// 同一个仓库下的所有 Pane / Session 因此共享同一 `projectPath`，
/// 「在 src/ 里开的终端」与「在仓库根开的终端」不会被拆成两个项目。
actor ProjectResolutionService {
  /// 进程级单例：缓存要跨窗口共享，否则每个窗口都会重复 fork git。
  static let shared = ProjectResolutionService()

  /// 目录 → 归属的缓存。git toplevel 在一个进程生命周期内几乎不变，
  /// 每条命令都 fork 一次 git 是不可接受的开销（PRD §12.1 记录不得拖慢终端）。
  private var cache: [String: ProjectIdentity] = [:]
  /// 并发去重：同一目录的首次解析可能被多个 Session 同时请求。
  private var inFlight: [String: Task<ProjectIdentity?, Never>] = [:]
  /// 缓存上限，防止长时间运行 + 频繁 cd 让字典无界增长。
  private let maximumCacheEntries = 512
  private let gitExecutablePath: String

  init(gitExecutablePath: String = "/usr/bin/git") {
    self.gitExecutablePath = gitExecutablePath
  }

  /// 解析目录的项目归属。任何失败都回落到目录本身，绝不返回 nil 之外的错误。
  /// 目录不是绝对路径时返回 nil（记录层据此跳过，不制造无法归属的数据）。
  func project(for directory: String) async -> ProjectIdentity? {
    let key = Self.normalized(directory)
    guard key.hasPrefix("/") else { return nil }
    if let cached = cache[key] { return cached }
    if let running = inFlight[key] { return await running.value }

    let executable = gitExecutablePath
    let task = Task<ProjectIdentity?, Never>.detached(priority: .utility) {
      Self.resolve(directory: key, gitExecutablePath: executable)
    }
    inFlight[key] = task
    let resolved = await task.value
    inFlight[key] = nil
    if let resolved {
      // 命中上限时整体清空而不是逐条淘汰：解析成本低、重建简单，
      // 维护 LRU 顺序的复杂度不值得。
      if cache.count >= maximumCacheEntries { cache.removeAll(keepingCapacity: true) }
      cache[key] = resolved
    }
    return resolved
  }

  /// 测试与「用户手动清缓存」用；正常运行期不调用。
  func invalidateAll() {
    cache.removeAll(keepingCapacity: true)
  }

  /// 真正的探测：两次只读 git 调用，全部有界且可取消。运行在 detached task 上。
  private static func resolve(directory: String, gitExecutablePath: String) -> ProjectIdentity? {
    let toplevel = MemoryProcessRunner.run(
      executable: gitExecutablePath,
      arguments: ["-C", directory, "rev-parse", "--show-toplevel"],
      timeout: 2,
      maximumBytes: 8 * 1_024
    )?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let toplevel, !toplevel.isEmpty, toplevel.hasPrefix("/") else {
      // 不是 git 仓库（或 git 不可用）：目录本身即项目，remote 留空。
      return ProjectIdentity.make(path: directory)
    }
    // remote 只用于展示与去重提示，取不到不影响归属，所以放在 toplevel 之后且允许失败。
    let remote = MemoryProcessRunner.run(
      executable: gitExecutablePath,
      arguments: ["-C", toplevel, "remote", "get-url", "origin"],
      timeout: 2,
      maximumBytes: 4 * 1_024
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ProjectIdentity.make(
      path: toplevel, gitRemote: (remote?.isEmpty ?? true) ? nil : remote)
  }

  /// 去掉尾斜杠，让 `/a/b` 与 `/a/b/` 命中同一条缓存。
  private static func normalized(_ path: String) -> String {
    var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }
}
