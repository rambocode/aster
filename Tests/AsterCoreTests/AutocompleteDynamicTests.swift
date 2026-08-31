import Foundation
import Testing

@testable import AsterCore

/// 动态候选的验收。核心不变量是「绝不执行被补全的工具」——所有活数据都从磁盘上
/// 已经存在的文件读出，因此这些用例全部用临时目录搭出假的 `.git` / Homebrew 布局。

@Test("Fig 生成器脚本映射到受支持的磁盘来源，其余一律不支持")
func autocompleteDynamicSourceMapsFigGeneratorScripts() {
  func source(_ script: [String]) -> AutocompleteDynamicSource? {
    AutocompleteDynamicSource.source(forScript: script)
  }
  #expect(
    source(["git", "--no-optional-locks", "branch", "-a", "--no-color", "--sort=-committerdate"])
      == .gitAllBranches)
  #expect(
    source(["git", "--no-optional-locks", "branch", "--no-color", "--sort=-committerdate"])
      == .gitLocalBranches)
  #expect(source(["git", "--no-optional-locks", "tag", "--list", "--sort=-committerdate"]) == .gitTags)
  #expect(source(["git", "--no-optional-locks", "remote", "-v"]) == .gitRemotes)
  #expect(source(["git", "--no-optional-locks", "stash", "list"]) == .gitStashes)
  #expect(source(["brew", "formulae"]) == .brewFormulae)
  #expect(source(["brew", "casks"]) == .brewCasks)
  #expect(source(["brew", "list", "-1"]) == .brewInstalledFormulae)
  #expect(
    source(["bash", "-c", "until [[ -f package.json ]] || [[ $PWD = '/' ]]; do cd ..; done; cat package.json"])
      == .npmScripts)
  // 需要真正运行工具才能拿到数据的生成器必须映射成 nil，不能退化成 fork。
  #expect(source(["flyctl", "apps", "list", "--json"]) == nil)
  #expect(source(["kubectl", "get", "pods"]) == nil)
  #expect(source(["git", "--no-optional-locks", "log", "--oneline"]) == nil)
  #expect(source(["git", "--no-optional-locks", "status", "--short"]) == nil)
}

@Test("make 的 target 参数没有生成器脚本时靠命令路径兜底")
func autocompleteDynamicSourceFallsBackToCommandPathForMake() {
  let argument = AutocompleteArgumentSpec(name: "target")
  #expect(
    AutocompleteDynamicSource.sources(for: argument, commandPath: ["make"]) == [.makeTargets])
  #expect(AutocompleteDynamicSource.sources(for: argument, commandPath: ["git"]).isEmpty)
}

@Test("git 引用读取合并松散与打包引用并过滤非分支命名空间")
func autocompleteGitRefsReaderReadsLooseAndPackedRefs() throws {
  let root = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = root.appendingPathComponent(".git")
  try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
  try write("", to: git.appendingPathComponent("refs/heads/main"))
  try write("", to: git.appendingPathComponent("refs/heads/feature/nested"))
  try write("", to: git.appendingPathComponent("refs/tags/v0.1"))
  // 真实仓库的 packed-refs 里会混入第三方工具写入的巨量命名空间（本仓库就有
  // `refs/codex/turn-diffs/...`）；没有前缀白名单它们会被当成分支列出来。
  try write(
    """
    # pack-refs with: peeled fully-peeled sorted
    aaaa refs/heads/release
    bbbb refs/tags/v1.0
    ^cccc
    dddd refs/codex/turn-diffs/junk
    """,
    to: git.appendingPathComponent("packed-refs"))

  let reader = AutocompleteDiskDynamicReader()
  let branches = reader.items(for: .gitLocalBranches, directory: root.path).map(\.name)
  #expect(Set(branches) == ["main", "feature/nested", "release"])
  #expect(!branches.contains { $0.contains("codex") })
  let tags = reader.items(for: .gitTags, directory: root.path).map(\.name)
  #expect(Set(tags) == ["v0.1", "v1.0"])
  // 当前分支被标注并压到最后：切到自己没有意义。
  let current = reader.items(for: .gitLocalBranches, directory: root.path)
    .first { $0.name == "main" }
  #expect(current?.description == "当前分支")
  #expect((current?.rankBonus ?? 0) < 0)
}

@Test("linked worktree 通过 gitdir 与 commondir 读到共享的分支")
func autocompleteGitRefsReaderResolvesWorktreeGitFile() throws {
  let main = try makeTemporaryDirectory()
  let worktree = try makeTemporaryDirectory()
  defer {
    try? FileManager.default.removeItem(at: main)
    try? FileManager.default.removeItem(at: worktree)
  }
  // 真实的 `git worktree add` 布局：分支只存在于主仓库的 .git 里，linked worktree
  // 的 gitdir 只有自己的 HEAD 与 reflog，并用 commondir 指回共享目录。
  let mainGit = main.appendingPathComponent(".git")
  try write("", to: mainGit.appendingPathComponent("refs/heads/master"))
  try write("", to: mainGit.appendingPathComponent("refs/heads/feature"))
  let linked = mainGit.appendingPathComponent("worktrees/feature")
  try write("ref: refs/heads/feature\n", to: linked.appendingPathComponent("HEAD"))
  try write("../..\n", to: linked.appendingPathComponent("commondir"))
  try write("gitdir: \(linked.path)\n", to: worktree.appendingPathComponent(".git"))

  let reader = AutocompleteDiskDynamicReader()
  let names = Set(reader.items(for: .gitLocalBranches, directory: worktree.path).map(\.name))
  #expect(names == ["master", "feature"])
  // HEAD 仍然来自 worktree 自己的 gitdir。
  #expect(
    reader.items(for: .gitLocalBranches, directory: worktree.path)
      .first { $0.name == "feature" }?.description == "当前分支")
}

@Test("reflog 里最近切换过的分支获得更高排名")
func autocompleteGitRefsReaderRanksRecentlyCheckedOutBranches() throws {
  let root = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let git = root.appendingPathComponent(".git")
  try write("ref: refs/heads/main\n", to: git.appendingPathComponent("HEAD"))
  for name in ["main", "alpha", "beta"] {
    try write("", to: git.appendingPathComponent("refs/heads/\(name)"))
  }
  try write(
    """
    0 1 a <a@b> 1 +0000\tcheckout: moving from main to alpha
    1 2 a <a@b> 2 +0000\tcheckout: moving from alpha to beta
    """,
    to: git.appendingPathComponent("logs/HEAD"))

  let items = reader().items(for: .gitLocalBranches, directory: root.path)
  let beta = items.first { $0.name == "beta" }?.rankBonus ?? 0
  let alpha = items.first { $0.name == "alpha" }?.rankBonus ?? 0
  #expect(beta > alpha, "最近一次 checkout 的目标应排在更前面")
  #expect(alpha > 0)
}

@Test("npm script 读取会向上查找 package.json")
func autocompleteNpmScriptsReaderWalksUpToPackageJSON() throws {
  let root = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try write(
    #"{"scripts": {"build": "tsc -p .", "test": "vitest"}}"#,
    to: root.appendingPathComponent("package.json"))
  let nested = root.appendingPathComponent("src/app")
  try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

  let items = reader().items(for: .npmScripts, directory: nested.path)
  #expect(items.map(\.name) == ["build", "test"])
  #expect(items.first?.description == "tsc -p .")
}

@Test("Makefile 目标提取排除变量赋值与模式规则")
func autocompleteMakefileReaderExtractsTargets() throws {
  let root = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  try write(
    """
    CFLAGS := -O2
    .PHONY: clean install
    build: main.o
    \tcc -o build main.o
    %.o: %.c
    \tcc -c $<
    test:
    \techo hi
    """,
    to: root.appendingPathComponent("Makefile"))

  let names = Set(reader().items(for: .makeTargets, directory: root.path).map(\.name))
  #expect(names == ["clean", "install", "build", "test"])
}

@Test("Homebrew 读取合并 tap、Cellar 与 Caskroom，缺 tap 时优雅降级")
func autocompleteHomebrewReaderReadsTapsCellarAndCaskroom() throws {
  let prefix = try makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: prefix) }
  try write("", to: prefix.appendingPathComponent("Library/Taps/homebrew/homebrew-core/Formula/foo.rb"))
  // tap 根目录直接放 .rb 也是真实布局（charmbracelet 就是这样）。
  try write("", to: prefix.appendingPathComponent("Library/Taps/acme/homebrew-tools/bar.rb"))
  try FileManager.default.createDirectory(
    at: prefix.appendingPathComponent("Cellar/baz"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: prefix.appendingPathComponent("Caskroom/qux"), withIntermediateDirectories: true)

  let reader = AutocompleteDiskDynamicReader(environment: ["HOMEBREW_PREFIX": prefix.path])
  let formulae = Set(reader.items(for: .brewFormulae, directory: prefix.path).map(\.name))
  #expect(formulae == ["foo", "bar", "baz"])
  #expect(reader.items(for: .brewInstalledFormulae, directory: prefix.path).map(\.name) == ["baz"])
  #expect(reader.items(for: .brewCasks, directory: prefix.path).map(\.name).contains("qux"))
  #expect(
    Set(reader.items(for: .brewTaps, directory: prefix.path).map(\.name))
      == ["homebrew/core", "acme/tools"])

  // 完全没有 Homebrew 时不崩溃、不联网、返回空。
  let empty = AutocompleteDiskDynamicReader(environment: ["HOMEBREW_PREFIX": "/nonexistent"])
  #expect(empty.items(for: .brewFormulae, directory: prefix.path).isEmpty)
}

@Test("动态候选读取器绝不启动任何进程")
func autocompleteDynamicReaderNeverSpawnsProcesses() throws {
  // Otty 的硬约束 "never runs the tools it completes for" 只能靠源码级不变量守住：
  // 一旦有人为了图省事在这里 fork 一次 `git branch`，补全就会在用户仓库里执行命令。
  let source = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/AsterCore/AutocompleteDynamicSources.swift")
  let text = try String(contentsOf: source, encoding: .utf8)
  for forbidden in ["Process(", "posix_spawn", "NSTask", "system(", "popen("] {
    #expect(!text.contains(forbidden), "动态候选读取器不得出现 \(forbidden)")
  }
}

// MARK: - helpers

private func reader() -> AutocompleteDiskDynamicReader {
  AutocompleteDiskDynamicReader()
}

private func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-dynamic-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url.standardizedFileURL
}

private func write(_ contents: String, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try contents.write(to: url, atomically: true, encoding: .utf8)
}
