import Foundation
import Testing

@testable import AsterCore

@Test("Open Quickly 按过滤器、模糊命中与来源优先级搜索")
func openQuicklyFiltersAndRanksAllWorkspaceTargets() {
  let items = [
    OpenQuicklyItem(id: "tab", kind: .opened, title: "API Server", detail: "~/api"),
    OpenQuicklyItem(id: "folder", kind: .folder, title: "api-client", detail: "/src/api-client", score: 8),
    OpenQuicklyItem(id: "ssh", kind: .ssh, title: "prod-api", detail: "deploy@prod", score: 2),
    OpenQuicklyItem(id: "recipe", kind: .recipe, title: "Review API", detail: "recipe"),
  ]
  let index = OpenQuicklyIndex(items: items)

  #expect(index.search(query: "api", filter: .all).map(\.id) == ["tab", "folder", "recipe", "ssh"])
  #expect(index.search(query: "pa", filter: .ssh).map(\.id) == ["ssh"])
  #expect(index.search(query: "", filter: .folder).map(\.id) == ["folder"])
}

@Test("Open Quickly 的「当前」过滤器包含提示词且排序紧跟 Pane")
func openQuicklyCurrentFilterIncludesPromptsAfterPanes() {
  let items = [
    OpenQuicklyItem(id: "tab", kind: .opened, title: "API Server", detail: "~/api"),
    OpenQuicklyItem(id: "pane", kind: .current, title: "kimi", detail: "~/api"),
    OpenQuicklyItem(id: "prompt", kind: .prompt, title: "修复 api 超时", detail: "kimi 会话"),
    OpenQuicklyItem(id: "folder", kind: .folder, title: "api-client", detail: "/src/api-client"),
  ]
  let index = OpenQuicklyIndex(items: items)

  // 「当前」过滤器同时返回 pane 与 prompt,且 prompt 紧跟 current 之后。
  #expect(index.search(query: "", filter: .current).map(\.id) == ["pane", "prompt"])
  // 「全部」中 prompt 排在 current 之后、recipe 等其他类型之前。
  #expect(index.search(query: "", filter: .all).map(\.id) == ["tab", "folder", "pane", "prompt"])
  // 单类型过滤器不包含 prompt。
  #expect(index.search(query: "", filter: .agent).isEmpty)
}

@Test("Open Quickly 分组保序且不丢项")
func openQuicklySectionsGroupInSearchOrder() {
  let items = [
    OpenQuicklyItem(id: "tab", kind: .opened, title: "a"),
    OpenQuicklyItem(id: "pane1", kind: .current, title: "b"),
    OpenQuicklyItem(id: "pane2", kind: .current, title: "c"),
    OpenQuicklyItem(id: "prompt", kind: .prompt, title: "d"),
  ]
  let sections = OpenQuicklyIndex.sections(for: items)

  #expect(sections.map(\.kind) == [.opened, .current, .prompt])
  #expect(sections.flatMap(\.items).map(\.id) == items.map(\.id))
  #expect(sections[1].items.map(\.id) == ["pane1", "pane2"])
}

@Test("Outline 从 Markdown、结构化配置、diff 和 transcript 生成有界跳转项")
func workspaceOutlineParsesSupportedPaneContent() {
  let markdown = WorkspaceOutlineParser.parse(
    "# Title\ntext\n## Usage\n",
    kind: .markdown
  )
  #expect(markdown.map(\.title) == ["Title", "Usage"])
  #expect(markdown.map(\.line) == [1, 3])

  let json = WorkspaceOutlineParser.parse(
    #"{"name":"aster","nested":{"enabled":true}}"#,
    kind: .json
  )
  #expect(json.map(\.title) == ["name", "nested"])

  let diff = WorkspaceOutlineParser.parse(
    "diff --git a/a.swift b/a.swift\n+++ b/a.swift\n@@ -1 +1 @@\n",
    kind: .diff
  )
  #expect(diff.first?.title == "a.swift")

  let transcript = WorkspaceOutlineParser.parse(
    "{\"type\":\"user\",\"message\":\"first prompt\"}\n{\"role\":\"assistant\",\"content\":\"skip\"}\n",
    kind: .jsonLinesTranscript
  )
  #expect(transcript.map(\.title) == ["first prompt"])
}

@Test("SSH config 只读取真实 Host 别名并跳过通配规则")
func sshConfigParserExtractsConnectableHosts() {
  let config = """
    Host *
      User default
    Host prod prod-alt
      HostName prod.example.com
      User deploy
      Port 2222
    Host !blocked staging
      HostName stage.example.com
    """

  let hosts = SSHConfigParser.parse(config)
  #expect(hosts.map(\.alias) == ["prod", "prod-alt", "staging"])
  #expect(hosts.first?.destination == "deploy@prod.example.com")
  #expect(hosts.first?.port == 2222)
}

@Test("Git porcelain v2 解析变更、分支和 rename 且拒绝超限输入")
func gitStatusParserProducesBoundedSummary() {
  let status = """
    # branch.head feature/ui
    # branch.oid abcdef1234567890
    1 .M N... 100644 100644 100644 abc def Sources/A.swift
    2 R. N... 100644 100644 100644 abc def R100 Sources/New.swift\tSources/Old.swift
    ? Notes.txt
    """
  let summary = GitStatusParser.parsePorcelainV2(status)

  #expect(summary.branch == "feature/ui")
  #expect(summary.changes.map(\.path) == ["Sources/A.swift", "Sources/New.swift", "Notes.txt"])
  #expect(summary.changes[1].originalPath == "Sources/Old.swift")
  #expect(GitStatusParser.parsePorcelainV2(String(repeating: "x", count: 2_000_000)).changes.isEmpty)
}

@Test("全局搜索保留 tab/pane/行定位并限制每个文档结果数")
func globalWorkspaceSearchReturnsStableLocations() {
  let documents = [
    WorkspaceSearchDocument(tabID: UUID(), paneID: UUID(), title: "one", lines: ["hello", "API error", "api ready"]),
    WorkspaceSearchDocument(tabID: UUID(), paneID: UUID(), title: "two", lines: ["api route"]),
  ]
  let results = GlobalWorkspaceSearch.search(
    documents: documents,
    query: "api",
    options: .init(caseSensitive: false, regularExpression: false),
    maximumResults: 2
  )

  #expect(results.count == 2)
  #expect(results.map(\.line) == [2, 3])
  #expect(results.allSatisfy { !$0.preview.isEmpty })
}

@Test("命令面板公开 Pane、Window 与 App scope")
func commandPalettePreservesActionScope() {
  let commands = [
    PaletteCommand(id: "find", title: "查找", scope: .pane),
    PaletteCommand(id: "close-window", title: "关闭窗口", scope: .window),
    PaletteCommand(id: "settings", title: "打开设置", scope: .application),
  ]

  #expect(CommandPalette.filter(commands, query: "窗口").first?.scope == .window)
}

@Test("进程列表按真实父子关系收敛且忽略同名无关进程")
func workspaceProcessParserFindsDescendantsInArbitraryOrder() {
  let output = """
      92  91 /usr/bin/python3 child.py
      50   1 /bin/zsh
      91  50 /usr/bin/make test
      93   1 /usr/bin/make unrelated
    """

  let processes = WorkspaceProcessParser.descendants(
    from: output,
    rootProcessIdentifier: 50
  )

  #expect(processes.map(\.processIdentifier) == [91, 92])
  #expect(processes.map(\.command) == ["/usr/bin/make test", "/usr/bin/python3 child.py"])
}

@Test("监听端口解析器关联 PID 并拒绝超限输入")
func listeningPortParserReadsMachineFields() {
  let ports = ListeningPortParser.parse("p91\nn127.0.0.1:8080\np92\nn*:3000\n")

  #expect(ports == [
    ListeningPort(processIdentifier: 91, endpoint: "127.0.0.1:8080"),
    ListeningPort(processIdentifier: 92, endpoint: "*:3000"),
  ])
  #expect(ListeningPortParser.parse(String(repeating: "x", count: 2_100_000)).isEmpty)
}

@Test("文件树有界递归且不会跟随符号链接")
func workspaceFileTreeDoesNotEscapeThroughSymbolicLinks() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try manager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("Sources/main.swift"))
  try manager.createSymbolicLink(
    at: root.appendingPathComponent("outside"),
    withDestinationURL: manager.temporaryDirectory
  )
  defer { try? manager.removeItem(at: root) }

  let nodes = WorkspaceFileTree.enumerate(root: root, maximumDepth: 4)

  #expect(nodes.map(\.name) == ["outside", "Sources", "main.swift"])
  #expect(nodes.first(where: { $0.name == "outside" })?.isSymbolicLink == true)
  #expect(nodes.filter { $0.path.contains("outside/") }.isEmpty)
}

@Test("Git shortstat 解析汇总行并区分干净仓库与采集失败")
func gitShortStatParserParsesSummaryLine() {
  #expect(
    GitShortStatParser.parse(" 3 files changed, 10 insertions(+), 2 deletions(-)")
      == GitDiffStat(filesChanged: 3, insertions: 10, deletions: 2))
  #expect(
    GitShortStatParser.parse(" 1 file changed, 1 insertion(+)")
      == GitDiffStat(filesChanged: 1, insertions: 1, deletions: 0))
  #expect(
    GitShortStatParser.parse(" 2 files changed, 4 deletions(-)")
      == GitDiffStat(filesChanged: 2, insertions: 0, deletions: 4))
  // 干净仓库输出为空：返回全零而不是 nil，调用方能区分「干净」与「采集失败」。
  #expect(GitShortStatParser.parse("") == GitDiffStat(filesChanged: 0, insertions: 0, deletions: 0))
  #expect(GitShortStatParser.parse("fatal: not a git repository") == nil)
}

@Test("Git 变更按 XY 状态码区分暂存与未暂存分组")
func gitStatusSummarySplitsStagedAndUnstagedChanges() {
  let status = """
    1 M. N... 100644 100644 100644 abc def staged.swift
    1 .M N... 100644 100644 100644 abc def unstaged.swift
    1 MM N... 100644 100644 100644 abc def both.swift
    ? new.txt
    """
  let summary = GitStatusParser.parsePorcelainV2(status)

  #expect(summary.stagedChanges.map(\.path) == ["staged.swift", "both.swift"])
  #expect(summary.unstagedChanges.map(\.path) == ["unstaged.swift", "both.swift", "new.txt"])
}

@Test("进程解析读取 etime 列并兼容三列旧输出")
func workspaceProcessParserReadsElapsedTimeColumn() {
  let fourColumns = """
      91  50 2-03:04:05 /usr/bin/make test
      92  91    01:26 /usr/bin/python3 child.py
      50   1 10:00:00 /bin/zsh
    """
  let processes = WorkspaceProcessParser.descendants(from: fourColumns, rootProcessIdentifier: 50)

  #expect(processes.map(\.processIdentifier) == [91, 92])
  #expect(processes.first?.elapsedTime == "2-03:04:05")
  #expect(processes.last?.elapsedTime == "01:26")
  #expect(processes.last?.command == "/usr/bin/python3 child.py")

  let threeColumns = """
      91  50 /usr/bin/make test
    """
  let legacy = WorkspaceProcessParser.descendants(from: threeColumns, rootProcessIdentifier: 50)
  #expect(legacy.first?.command == "/usr/bin/make test")
  #expect(legacy.first?.elapsedTime == nil)
}
