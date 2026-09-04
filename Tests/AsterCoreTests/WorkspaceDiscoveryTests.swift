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

/// 小节顺序是设计稿直接规定的用户可见契约，用一条断言把整条链钉死，
/// 避免以后新增 kind 时只改 priority 而漏掉它在「全部」里的落位。
@Test("Open Quickly 全部视图按设计稿的小节顺序排列且文件垫底")
func openQuicklyAllFilterFollowsDesignedSectionOrder() {
  let items = [
    OpenQuicklyItem(id: "file", kind: .file, title: "a"),
    OpenQuicklyItem(id: "agent", kind: .agent, title: "a"),
    OpenQuicklyItem(id: "ssh", kind: .ssh, title: "a"),
    OpenQuicklyItem(id: "recipe", kind: .recipe, title: "a"),
    OpenQuicklyItem(id: "prompt", kind: .prompt, title: "a"),
    OpenQuicklyItem(id: "current", kind: .current, title: "a"),
    OpenQuicklyItem(id: "folder", kind: .folder, title: "a"),
    OpenQuicklyItem(id: "recent", kind: .recent, title: "a"),
    OpenQuicklyItem(id: "opened", kind: .opened, title: "a"),
    OpenQuicklyItem(id: "window", kind: .window, title: "a"),
  ]
  let index = OpenQuicklyIndex(items: items)

  #expect(
    index.search(query: "", filter: .all).map(\.id) == [
      "window", "opened", "recent", "folder", "current",
      "prompt", "recipe", "ssh", "agent", "file",
    ])
}

@Test("Open Quickly 的「已打开」过滤器同时返回窗口与标签且窗口在前")
func openQuicklyOpenedFilterIncludesWindowsBeforeTabs() {
  let items = [
    OpenQuicklyItem(id: "tab", kind: .opened, title: "API Server", detail: "~/api"),
    OpenQuicklyItem(id: "window", kind: .window, title: "API Server", detail: "3 tabs"),
    OpenQuicklyItem(id: "folder", kind: .folder, title: "api-client", detail: "~/src"),
  ]
  let index = OpenQuicklyIndex(items: items)

  #expect(index.search(query: "", filter: .opened).map(\.id) == ["window", "tab"])
  // 窗口不属于任何其它单类型过滤器。
  #expect(index.search(query: "", filter: .folder).map(\.id) == ["folder"])
  #expect(index.search(query: "", filter: .recent).isEmpty)
}

@Test("Open Quickly 的文件条目只出现在「全部」与「文件」过滤器下")
func openQuicklyFileItemsOnlyAppearUnderAllAndFileFilters() {
  let items = [
    OpenQuicklyItem(id: "tab", kind: .opened, title: "notes"),
    OpenQuicklyItem(id: "deep", kind: .file, title: "notes.md", detail: "wiki/demo", score: -2),
    OpenQuicklyItem(id: "shallow", kind: .file, title: "notes.txt", detail: "wiki", score: -1),
  ]
  let index = OpenQuicklyIndex(items: items)

  // 文件永远排在其它类型之后；同为文件时按 score 降序，即路径浅的在前。
  #expect(index.search(query: "", filter: .all).map(\.id) == ["tab", "shallow", "deep"])
  #expect(index.search(query: "", filter: .file).map(\.id) == ["shallow", "deep"])
  #expect(index.search(query: "", filter: .opened).map(\.id) == ["tab"])
  #expect(index.search(query: "", filter: .folder).isEmpty)
}

@Test("Open Quickly 分组把窗口独立成一节并排在标签页之前")
func openQuicklySectionsSeparateWindowsFromTabs() {
  let items = OpenQuicklyIndex(items: [
    OpenQuicklyItem(id: "tab1", kind: .opened, title: "b"),
    OpenQuicklyItem(id: "window1", kind: .window, title: "a"),
    OpenQuicklyItem(id: "window2", kind: .window, title: "b"),
    OpenQuicklyItem(id: "file1", kind: .file, title: "c"),
  ]).search(query: "", filter: .all)
  let sections = OpenQuicklyIndex.sections(for: items)

  #expect(sections.map(\.kind) == [.window, .opened, .file])
  #expect(sections[0].items.map(\.id) == ["window1", "window2"])
  #expect(sections.flatMap(\.items).count == 4)
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

@Test("SSH 命令解析最后一个 at 作为主机分隔并保留配置参数")
func sshCommandInvocationExtractsDestinationWithoutExecutingShellSyntax() throws {
  let invocation = try #require(SSHCommandInvocation.parse("ssh -vv -p 32222 root@ubuntu@orb"))
  #expect(invocation.destination == "root@ubuntu@orb")
  #expect(invocation.fallbackHostName == "orb")
  #expect(invocation.explicitUser == "root@ubuntu")
  #expect(invocation.configurationArguments == ["-vv", "-p", "32222", "root@ubuntu@orb"])

  let combined = try #require(SSHCommandInvocation.parse("ssh -vp 32222 orb"))
  #expect(combined.configurationArguments == ["-vp", "32222", "orb"])

  #expect(SSHCommandInvocation.parse("ssh -G orb") == nil)
  #expect(SSHCommandInvocation.parse("echo ssh orb") == nil)
  #expect(SSHCommandInvocation.parse("ssh") == nil)
}

@Test("SSH 配置输出提取最终服务器地址用户与端口")
func sshResolvedEndpointParsesConfigurationOutput() throws {
  let endpoint = try #require(
    SSHResolvedEndpoint(
      configurationOutput: """
        user root@ubuntu
        hostname 127.0.0.1
        port 32222
        canonicalizehostname false
        """))
  #expect(endpoint == SSHResolvedEndpoint(hostName: "127.0.0.1", user: "root@ubuntu", port: 32222))
  #expect(SSHResolvedEndpoint(configurationOutput: "hostname bad host\n") == nil)
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

@Test("Info 的进程树保留 Shell 根节点并按父子关系稳定排列")
func workspaceProcessParserBuildsRootedTreeForInfo() {
  let output = """
      92  91 /usr/bin/python3 child.py
      50   1 /bin/zsh
      91  50 /usr/bin/make test
      93   1 /usr/bin/make unrelated
    """

  let processes = WorkspaceProcessParser.processTree(
    from: output,
    rootProcessIdentifier: 50
  )

  #expect(processes.map(\.processIdentifier) == [50, 91, 92])
  #expect(processes.map(\.parentProcessIdentifier) == [1, 50, 91])
}

@Test("监听端口解析器关联 PID 并拒绝超限输入")
func listeningPortParserReadsMachineFields() {
  let ports = ListeningPortParser.parse("p91\ncnode\nn127.0.0.1:8080\np92\ncpython3\nn*:3000\n")

  #expect(ports == [
    ListeningPort(processIdentifier: 91, endpoint: "127.0.0.1:8080", processName: "node"),
    ListeningPort(processIdentifier: 92, endpoint: "*:3000", processName: "python3"),
  ])
  #expect(ListeningPortParser.parse(String(repeating: "x", count: 2_100_000)).isEmpty)
}

@Test("监听端口按 PID 与端点去重并保持首次出现顺序")
func listeningPortParserDeduplicatesRepeatedRecords() {
  let ports = ListeningPortParser.parse(
    "p91\nn127.0.0.1:8080\nn127.0.0.1:8080\np92\nn*:3000\np91\nn127.0.0.1:8080\n"
  )

  #expect(ports == [
    ListeningPort(processIdentifier: 91, endpoint: "127.0.0.1:8080"),
    ListeningPort(processIdentifier: 92, endpoint: "*:3000"),
  ])
}

@Test("文档 Outline 保留 JSON 原始键顺序和真实源码行")
func workspaceOutlineUsesRealJSONSourceLines() {
  let json = """
    {
      "zeta": true,
      "alpha": { "nested": 1 }
    }
    """

  let items = WorkspaceOutlineParser.parse(json, kind: .json)

  #expect(items.map(\.title) == ["zeta", "alpha"])
  #expect(items.map(\.line) == [2, 3])
}

@Test("文档 Outline 复用 Agent transcript 的嵌套用户提示词契约")
func workspaceOutlineParsesNestedAgentTranscriptPrompts() {
  let transcript = """
    {"type":"response_item","payload":{"message":{"role":"user","content":[{"type":"text","text":"修复连接超时"}]}}}
    {"role":"assistant","content":"skip"}
    """

  let items = WorkspaceOutlineParser.parse(transcript, kind: .jsonLinesTranscript)

  #expect(items.map(\.title) == ["修复连接超时"])
  #expect(items.map(\.line) == [1])
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

@Test("文件树默认跳过隐藏项，开启后包含")
func workspaceFileTreeIncludeHiddenToggle() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try manager.createDirectory(at: root, withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("README.md"))
  try Data().write(to: root.appendingPathComponent(".gitignore"))
  defer { try? manager.removeItem(at: root) }

  let visible = WorkspaceFileTree.enumerate(root: root, includeHidden: false)
  #expect(visible.map(\.name) == ["README.md"])

  let all = WorkspaceFileTree.enumerate(root: root, includeHidden: true)
  #expect(all.map(\.name) == [".gitignore", "README.md"])
}

@Test("包含隐藏文件时大隐藏目录不会挤掉顶层普通项")
func workspaceFileTreeIncludeHiddenKeepsVisibleSiblings() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let build = root.appendingPathComponent(".build", isDirectory: true)
  try manager.createDirectory(at: build, withIntermediateDirectories: true)
  try manager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("README.md"))
  for index in 0..<600 {
    try Data().write(to: build.appendingPathComponent("artifact-\(index).o"))
  }
  defer { try? manager.removeItem(at: root) }

  let nodes = WorkspaceFileTree.enumerate(root: root, maximumDepth: 3, maximumItems: 500, includeHidden: true)
  let names = Set(nodes.map(\.name))
  #expect(names.contains(".build"))
  #expect(names.contains("Sources"))
  #expect(names.contains("README.md"))
  // 隐藏目录只露自身，不把数百个产物扫进有界列表。
  #expect(!names.contains("artifact-0.o"))
  #expect(nodes.count < 20)
}

@Test("文件树深度优先输出，子节点紧跟父目录")
func workspaceFileTreeEmitsChildrenImmediatelyAfterParent() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try manager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
  try manager.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("Sources/main.swift"))
  try Data().write(to: root.appendingPathComponent("README.md"))
  defer { try? manager.removeItem(at: root) }

  let names = WorkspaceFileTree.enumerate(root: root, maximumDepth: 3).map(\.name)
  #expect(names == ["README.md", "Sources", "main.swift", "Tests"])
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
