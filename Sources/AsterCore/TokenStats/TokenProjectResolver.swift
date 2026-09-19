// 把 transcript 里的工作目录归一成项目键，并提供本地日换算。扫描线程内共用一个实例。
import Foundation

/// 扫描期间的共享上下文：cwd → 项目键，Unix 秒 → 本地日。
///
/// 故意不做成 `Sendable`：它带着两份可变缓存（项目键表、时区偏移），只在单个扫描线程内使用。
/// 调度由上层负责，这里不加锁，也就不为一个非核心功能付同步开销。
public final class TokenProjectResolver: TokenScanContext {
  private let fileManager: FileManager
  private var stamper: LocalDayStamper
  /// cwd → 项目键。同一个 transcript 的几万行通常共用一个 cwd，走一次文件系统就够了。
  private var keys: [String: String] = [:]

  public init(timeZone: TimeZone = .current, fileManager: FileManager = .default) {
    self.stamper = LocalDayStamper(zone: timeZone)
    self.fileManager = fileManager
  }

  public func localDay(forEpochSeconds seconds: Int64) -> Int {
    stamper.day(forEpochSeconds: seconds)
  }

  public func projectKey(forWorkingDirectory path: String) -> String {
    guard !path.isEmpty else { return TokenProject.otherKey }
    if let cached = keys[path] { return cached }
    let key = resolve(path)
    keys[path] = key
    return key
  }

  // MARK: - 归一规则

  /// 从 cwd 逐级向上找 `.git`：目录就是仓库根，文件（worktree）则折回它的主仓库根；
  /// 一路找不到就退回 cwd 本身。
  ///
  /// 折回主仓库是为了让同一个项目的多个 worktree 并成一行。否则一个人按功能开三个 worktree，
  /// 统计里就变成三个看起来互不相干的项目，而它们其实是同一份代码。
  private func resolve(_ path: String) -> String {
    let start = (path as NSString).standardizingPath
    var directory = start
    while true {
      let marker = (directory as NSString).appendingPathComponent(".git")
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: marker, isDirectory: &isDirectory) {
        if isDirectory.boolValue { return directory }
        return mainRepository(forGitFile: marker, worktree: directory) ?? directory
      }
      let parent = (directory as NSString).deletingLastPathComponent
      // 到达根目录（`/` 的父目录还是 `/`）或路径不再变短时收手。
      if parent.isEmpty || parent == directory { return start }
      directory = parent
    }
  }

  /// 解析 worktree 的 `.git` 文件，内容形如 `gitdir: /path/to/repo/.git/worktrees/<name>`，
  /// 取 `/.git/worktrees/` 之前的部分作为主仓库根。
  ///
  /// gitdir 也可能写成相对路径（`git worktree add --relative-paths`），所以先按 worktree 目录展开；
  /// 内容不符合这个形态时返回 nil，由调用方退回 worktree 目录本身。
  private func mainRepository(forGitFile file: String, worktree: String) -> String? {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
    guard let line = text.split(whereSeparator: \.isNewline).first(where: {
      $0.hasPrefix("gitdir:")
    }) else { return nil }
    let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let absolute =
      raw.hasPrefix("/")
      ? raw : (worktree as NSString).appendingPathComponent(raw)
    let gitDir = (absolute as NSString).standardizingPath
    guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
    let root = String(gitDir[gitDir.startIndex..<range.lowerBound])
    return root.isEmpty ? nil : root
  }
}

/// 记住上一次见过的 cwd 字节，让「整个文件共用一个 cwd」的常见情形只做一次 String 构造与归一。
///
/// 比 `TokenProjectResolver` 内部的字典缓存更靠前一层：那一层还需要先把字节转成 String 才能查表，
/// 而这里直接比较原始字节。
public struct TokenProjectKeyMemo {
  private var lastBytes: [UInt8] = []
  private var lastKey = TokenProject.otherKey
  private var hasLast = false

  public init() {}

  /// `range` 是 `forEachMember` 给出的带引号 cwd 值；为 nil 表示这行没有 cwd。
  public mutating func key(
    _ scan: JSONScan, _ range: Range<Int>?, context: TokenScanContext
  ) -> String {
    guard let range, !range.isEmpty, let base = scan.bytes.baseAddress else {
      return TokenProject.otherKey
    }
    if hasLast, lastBytes.count == range.count,
      lastBytes.withUnsafeBytes({ memcmp($0.baseAddress!, base + range.lowerBound, range.count) == 0
      })
    {
      return lastKey
    }
    lastBytes = Array(scan.bytes[range])
    hasLast = true
    lastKey = context.projectKey(forWorkingDirectory: scan.string(range) ?? "")
    return lastKey
  }
}
