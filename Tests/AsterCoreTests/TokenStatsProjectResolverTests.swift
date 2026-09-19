// cwd → 项目键的归一规则：git 仓库根、worktree 折回主仓库、找不到时的兜底。
import Foundation
import Testing

@testable import AsterCore

@Suite("TokenStats 项目归属")
struct TokenStatsProjectResolverTests {
  /// 造一个临时目录树并在结束时删掉。
  private func withTemporaryTree<R>(_ body: (URL) throws -> R) rethrows -> R {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("token-project-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
  }

  /// 归一后的路径，和 resolver 内部用的是同一套规则。
  private func standardized(_ url: URL) -> String { (url.path as NSString).standardizingPath }

  @Test("向上找到 .git 目录时，该目录就是项目根")
  func gitDirectoryMarksRepositoryRoot() throws {
    try withTemporaryTree { root in
      let repo = root.appendingPathComponent("repo", isDirectory: true)
      let deep = repo.appendingPathComponent("a/b/c", isDirectory: true)
      try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

      let resolver = TokenProjectResolver()
      #expect(resolver.projectKey(forWorkingDirectory: deep.path) == standardized(repo))
      #expect(resolver.projectKey(forWorkingDirectory: repo.path) == standardized(repo))
    }
  }

  @Test("worktree 的 .git 文件折回主仓库根")
  func worktreeFoldsBackToMainRepository() throws {
    try withTemporaryTree { root in
      let manager = FileManager.default
      let main = root.appendingPathComponent("main", isDirectory: true)
      try manager.createDirectory(
        at: main.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
      let worktree = root.appendingPathComponent("main-feature", isDirectory: true)
      let inside = worktree.appendingPathComponent("src", isDirectory: true)
      try manager.createDirectory(at: inside, withIntermediateDirectories: true)
      try "gitdir: \(standardized(main))/.git/worktrees/feature\n"
        .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

      let resolver = TokenProjectResolver()
      // 同一个项目的多个 worktree 必须并成一行，否则统计里会出现三个看似无关的项目。
      #expect(resolver.projectKey(forWorkingDirectory: inside.path) == standardized(main))
    }
  }

  @Test("gitdir 写成相对路径时按 worktree 目录展开")
  func relativeGitdirIsResolved() throws {
    try withTemporaryTree { root in
      let manager = FileManager.default
      let main = root.appendingPathComponent("main", isDirectory: true)
      try manager.createDirectory(
        at: main.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
      let worktree = root.appendingPathComponent("main-feature", isDirectory: true)
      try manager.createDirectory(at: worktree, withIntermediateDirectories: true)
      try "gitdir: ../main/.git/worktrees/feature\n"
        .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

      let resolver = TokenProjectResolver()
      #expect(resolver.projectKey(forWorkingDirectory: worktree.path) == standardized(main))
    }
  }

  @Test("gitdir 内容不成形时退回 worktree 目录本身")
  func malformedGitFileFallsBackToDirectory() throws {
    try withTemporaryTree { root in
      let directory = root.appendingPathComponent("loose", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try "not a gitdir line\n"
        .write(to: directory.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

      let resolver = TokenProjectResolver()
      #expect(resolver.projectKey(forWorkingDirectory: directory.path) == standardized(directory))
    }
  }

  @Test("一路找不到 .git 时用 cwd 本身；空串归入「其他」")
  func fallsBackToWorkingDirectory() {
    let resolver = TokenProjectResolver()
    #expect(resolver.projectKey(forWorkingDirectory: "/fixture/not-a-repo") == "/fixture/not-a-repo")
    #expect(resolver.projectKey(forWorkingDirectory: "") == TokenProject.otherKey)
    // 记忆化后结果稳定。
    #expect(resolver.projectKey(forWorkingDirectory: "/fixture/not-a-repo") == "/fixture/not-a-repo")
  }
}
