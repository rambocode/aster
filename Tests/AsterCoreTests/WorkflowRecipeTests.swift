import Foundation
import Testing

@testable import AsterCore

@Test("官方 TOML Recipe 示例可导入、稳定导出并保留来源摘要")
func workflowRecipeTOMLRoundTripsOfficialWindowShape() throws {
  let source = """
    [recipe]
    name = "deploy-prod-debug"
    version = 1
    scope = "window"

    [[window.tabs]]
    title = "API"

    [[window.tabs.panes]]
    cwd = "{{current_folder}}/api"
    commands = ["tail -F log/prod.log"]

    [[window.tabs.panes]]
    cwd = "{{current_folder}}/api"
    split = "right"
    size = 0.5
    commands = ["make deploy"]
    """
  let data = Data(source.utf8)

  let imported = try WorkflowRecipeTOML.decode(data, source: .recipeFile)

  #expect(imported.source == .recipeFile(sha256: WorkflowSHA256.digest(data)))
  #expect(imported.recipe.name == "deploy-prod-debug")
  #expect(imported.recipe.version == 1)
  #expect(imported.recipe.scope == .window)
  #expect(imported.recipe.content == .includeCommands)
  #expect(imported.recipe.tabs.count == 1)
  #expect(imported.recipe.tabs[0].panes.count == 2)
  #expect(imported.recipe.tabs[0].layout == nil)
  #expect(imported.recipe.tabs[0].panes.allSatisfy { $0.kind == .terminal })
  #expect(imported.recipe.tabs[0].panes.allSatisfy { $0.resourcePath == nil })
  #expect(imported.recipe.tabs[0].panes[1].split == .right)
  #expect(imported.recipe.tabs[0].panes[1].size == 0.5)

  let exported = try WorkflowRecipeTOML.encode(imported.recipe)
  let restored = try WorkflowRecipeTOML.decode(exported, source: .recipeFile)
  #expect(restored.recipe == imported.recipe)
}

@Test("TOML Recipe 无损往返嵌套分屏比例和非终端 Pane")
func workflowRecipeTOMLRoundTripsNestedMixedPaneLayout() throws {
  let terminal = PaneDescriptor(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    kind: .terminal,
    workingDirectory: "{{current_folder}}"
  )
  let editor = PaneDescriptor(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    kind: .editor,
    workingDirectory: "{{current_folder}}/docs",
    resourcePath: "{{current_folder}}/docs/guide.md"
  )
  let browser = PaneDescriptor(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
    kind: .fileBrowser,
    workingDirectory: "{{current_folder}}",
    resourcePath: "{{current_folder}}/Sources"
  )
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(terminal),
    second: .split(
      axis: .vertical,
      first: .leaf(editor),
      second: .leaf(browser),
      ratio: 0.37
    ),
    ratio: 0.61
  )
  let recipe = WorkflowRecipe(
    name: "Mixed workspace",
    scope: .tab,
    content: .includeCommands,
    tabs: [
      WorkflowRecipeTab(
        title: "Mixed",
        panes: [
          WorkflowRecipePane(
            workingDirectory: terminal.workingDirectory,
            kind: terminal.kind,
            commands: ["git status"]
          ),
          WorkflowRecipePane(
            workingDirectory: editor.workingDirectory,
            kind: editor.kind,
            resourcePath: editor.resourcePath,
            split: .right
          ),
          WorkflowRecipePane(
            workingDirectory: browser.workingDirectory,
            kind: browser.kind,
            resourcePath: browser.resourcePath,
            split: .down
          ),
        ],
        layout: layout
      )
    ]
  )

  let data = try WorkflowRecipeTOML.encode(recipe)
  let text = String(decoding: data, as: UTF8.self)
  let restored = try WorkflowRecipeTOML.decode(data, source: .recipeFile).recipe

  #expect(text.contains("layout = \""))
  #expect(text.contains("kind = \"editor\""))
  #expect(text.contains("resource_path = \"{{current_folder}}/docs/guide.md\""))
  #expect(restored == recipe)
  #expect(restored.tabs[0].layout == layout)
}

@Test("Recipe Web Pane 只允许 HTTP(S) URL 并可无损往返")
func workflowRecipeWebPaneRejectsLocalSchemes() throws {
  let web = PaneDescriptor(
    kind: .web,
    workingDirectory: "{{current_folder}}",
    resourcePath: "https://example.com/docs?q=aster"
  )
  let recipe = WorkflowRecipe(
    name: "Web docs",
    scope: .tab,
    content: .layoutOnly,
    tabs: [
      WorkflowRecipeTab(
        title: "Docs",
        panes: [
          WorkflowRecipePane(
            workingDirectory: web.workingDirectory,
            kind: web.kind,
            resourcePath: web.resourcePath
          )
        ],
        layout: .leaf(web)
      )
    ]
  )

  let restored = try WorkflowRecipeTOML.decode(
    WorkflowRecipeTOML.encode(recipe), source: .recipeFile)
  #expect(restored.recipe.tabs[0].layout == .leaf(web))

  var unsafe = recipe
  unsafe.tabs[0].panes[0].resourcePath = "file:///tmp/secret"
  unsafe.tabs[0].layout = .leaf(PaneDescriptor(
    id: web.id,
    kind: .web,
    workingDirectory: web.workingDirectory,
    resourcePath: "file:///tmp/secret"
  ))
  #expect(throws: WorkflowPortablePathError.invalidPath) {
    try WorkflowRecipeTOML.encode(unsafe)
  }
}

@Test("布局扩展拒绝过深树、重复 Pane 标识和描述不一致")
func workflowRecipeRejectsInvalidExtendedLayouts() throws {
  let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
  let first = PaneDescriptor(
    id: duplicateID,
    kind: .terminal,
    workingDirectory: "/work"
  )
  let second = PaneDescriptor(
    id: duplicateID,
    kind: .editor,
    workingDirectory: "/work",
    resourcePath: "/work/readme.md"
  )
  let duplicateLayout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(first),
    second: .leaf(second),
    ratio: 0.5
  )
  let duplicateRecipe = WorkflowRecipe(
    name: "Duplicate",
    scope: .tab,
    content: .layoutOnly,
    tabs: [
      WorkflowRecipeTab(
        title: "Duplicate",
        panes: [
          WorkflowRecipePane(workingDirectory: "/work"),
          WorkflowRecipePane(
            workingDirectory: "/work",
            kind: .editor,
            resourcePath: "/work/readme.md",
            split: .right
          ),
        ],
        layout: duplicateLayout
      )
    ]
  )
  #expect(throws: WorkflowRecipeTOMLError.duplicatePaneIdentifier) {
    try WorkflowRecipeTOML.validate(duplicateRecipe)
  }

  let terminal = PaneDescriptor(kind: .terminal, workingDirectory: "/work")
  let mismatchedRecipe = WorkflowRecipe(
    name: "Mismatch",
    scope: .tab,
    content: .layoutOnly,
    tabs: [
      WorkflowRecipeTab(
        title: "Mismatch",
        panes: [
          WorkflowRecipePane(
            workingDirectory: terminal.workingDirectory,
            kind: .preview,
            resourcePath: "/work/index.html"
          )
        ],
        layout: .leaf(terminal)
      )
    ]
  )
  #expect(throws: WorkflowRecipeTOMLError.invalidStructure) {
    try WorkflowRecipeTOML.validate(mismatchedRecipe)
  }

  var deepLayout = PaneLayout.leaf(
    PaneDescriptor(kind: .terminal, workingDirectory: "/work/0"))
  var deepPanes = [WorkflowRecipePane(workingDirectory: "/work/0")]
  for index in 1...WorkflowRecipeTOML.maximumLayoutDepth {
    let path = "/work/\(index)"
    deepLayout = .split(
      axis: .vertical,
      first: deepLayout,
      second: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: path)),
      ratio: 0.5
    )
    deepPanes.append(WorkflowRecipePane(workingDirectory: path, split: .down))
  }
  let deepRecipe = WorkflowRecipe(
    name: "Deep",
    scope: .tab,
    content: .layoutOnly,
    tabs: [WorkflowRecipeTab(title: "Deep", panes: deepPanes, layout: deepLayout)]
  )
  #expect(throws: WorkflowRecipeTOMLError.layoutTooDeep) {
    try WorkflowRecipeTOML.validate(deepRecipe)
  }
}

@Test("布局和资源路径扩展分别受独立字节上限约束")
func workflowRecipeExtendedValuesRemainBounded() {
  let oversizedLayout = String(
    repeating: "x",
    count: WorkflowRecipeTOML.maximumLayoutBytes + 1
  )
  let source = Data(
    """
    [recipe]
    name = "oversized layout"
    version = 1
    scope = "tab"
    [[window.tabs]]
    title = "oversized"
    layout = "\(oversizedLayout)"
    [[window.tabs.panes]]
    cwd = "/work"
    """.utf8
  )
  #expect(throws: WorkflowRecipeTOMLError.valueTooLong("tab.layout")) {
    try WorkflowRecipeTOML.decode(source, source: .recipeFile)
  }

  let oversizedResourcePath = "/" + String(
    repeating: "r",
    count: WorkflowRecipeTOML.maximumPathBytes
  )
  let resourceRecipe = WorkflowRecipe(
    name: "oversized resource",
    scope: .tab,
    content: .layoutOnly,
    tabs: [
      WorkflowRecipeTab(
        title: "resource",
        panes: [
          WorkflowRecipePane(
            workingDirectory: "/work",
            kind: .editor,
            resourcePath: oversizedResourcePath
          )
        ]
      )
    ]
  )
  #expect(throws: WorkflowRecipeTOMLError.valueTooLong("pane.resource_path")) {
    try WorkflowRecipeTOML.validate(resourceRecipe)
  }

  let layoutDescriptors = (0..<WorkflowRecipeTOML.maximumPanes).map { index in
    PaneDescriptor(
      kind: .editor,
      workingDirectory: "/work",
      resourcePath: "/" + String(repeating: "r", count: 4_080) + "\(index)"
    )
  }
  func balancedLayout(_ panes: ArraySlice<PaneDescriptor>) -> PaneLayout {
    guard panes.count > 1 else { return .leaf(panes[panes.startIndex]) }
    let middle = panes.index(panes.startIndex, offsetBy: panes.count / 2)
    return .split(
      axis: .horizontal,
      first: balancedLayout(panes[..<middle]),
      second: balancedLayout(panes[middle...]),
      ratio: 0.5
    )
  }
  let oversizedAggregateRecipe = WorkflowRecipe(
    name: "oversized aggregate layout",
    scope: .tab,
    content: .layoutOnly,
    tabs: [
      WorkflowRecipeTab(
        title: "aggregate",
        panes: layoutDescriptors.enumerated().map { index, pane in
          WorkflowRecipePane(
            workingDirectory: pane.workingDirectory,
            kind: pane.kind,
            resourcePath: pane.resourcePath,
            split: index == 0 ? nil : .right
          )
        },
        layout: balancedLayout(layoutDescriptors[...])
      )
    ]
  )
  #expect(throws: WorkflowRecipeTOMLError.valueTooLong("tab.layout")) {
    try WorkflowRecipeTOML.validate(oversizedAggregateRecipe)
  }
}

@Test("可移植路径只替换目录边界内前缀，并拒绝变量逃逸")
func workflowRecipePortablePathsStayInsideSelectedBase() throws {
  let context = WorkflowPortablePathContext(
    currentFolder: URL(fileURLWithPath: "/checkout"),
    homeFolder: URL(fileURLWithPath: "/Users/alice"),
    recipeLocation: URL(fileURLWithPath: "/recipes")
  )

  let portable = try WorkflowPortablePath.makePortable(
    "/work/project/api",
    replacing: URL(fileURLWithPath: "/work/project"),
    with: .currentFolder
  )
  #expect(portable == "{{current_folder}}/api")
  #expect(try WorkflowPortablePath.resolve(portable, context: context) == "/checkout/api")
  #expect(
    try WorkflowPortablePath.resolve("{{home_folder}}/src", context: context) == "/Users/alice/src")
  #expect(
    try WorkflowPortablePath.resolve("{{recipe_location}}/config", context: context)
      == "/recipes/config"
  )

  #expect(throws: WorkflowPortablePathError.pathOutsideBase) {
    try WorkflowPortablePath.makePortable(
      "/work/project-copy/api",
      replacing: URL(fileURLWithPath: "/work/project"),
      with: .currentFolder
    )
  }
  #expect(throws: WorkflowPortablePathError.pathEscapesBase) {
    try WorkflowPortablePath.resolve("{{current_folder}}/../secret", context: context)
  }
}

@Test("外部 Recipe 按精确 SHA-256 建立信任，修改后必须重新审查")
func workflowRecipeTrustAndReplayRemainBoundToExactFileBytes() throws {
  let firstData = Data("first".utf8)
  let modifiedData = Data("second".utf8)
  let firstSource = WorkflowRecipeSource.recipeFile(sha256: WorkflowSHA256.digest(firstData))
  let modifiedSource = WorkflowRecipeSource.recipeFile(sha256: WorkflowSHA256.digest(modifiedData))
  var trustStore = WorkflowRecipeTrustStore()

  #expect(
    WorkflowRecipeTrustPolicy.requirement(
      for: firstSource,
      commands: ["git status", "make test"]
    )
      == .reviewRequired(
        sha256: WorkflowSHA256.digest(firstData), commands: ["git status", "make test"])
  )

  try trustStore.trust(firstSource)
  #expect(
    WorkflowRecipeTrustPolicy.requirement(
      for: firstSource,
      commands: ["git status"],
      trustStore: trustStore
    ) == .notRequired
  )
  #expect(
    WorkflowRecipeTrustPolicy.requirement(
      for: modifiedSource,
      commands: ["git status"],
      trustStore: trustStore
    ) == .reviewRequired(sha256: WorkflowSHA256.digest(modifiedData), commands: ["git status"])
  )
  #expect(
    WorkflowRecipeTrustPolicy.requirement(for: .savedRecipe, commands: ["rm -rf build"])
      == .notRequired
  )
  #expect(
    WorkflowRecipeTrustPolicy.requirement(for: modifiedSource, commands: []) == .notRequired
  )
}

@Test("Replay 模式保留命令顺序，并在接管 Shell 的命令后保守暂停")
func workflowRecipeReplayPlansPauseAfterShellHandoffs() {
  let commands = ["echo ready", "ssh deploy@example.com", "make deploy"]

  #expect(
    WorkflowRecipeReplayPlanner.plan(commands: commands, mode: .automatic)
      == .automatic(batches: [["echo ready", "ssh deploy@example.com"], ["make deploy"]])
  )
  #expect(
    WorkflowRecipeReplayPlanner.plan(commands: commands, mode: .confirmOnce)
      == .confirmOnce(batches: [["echo ready", "ssh deploy@example.com"], ["make deploy"]])
  )
  #expect(
    WorkflowRecipeReplayPlanner.plan(commands: commands, mode: .oneByOne)
      == .oneByOne(commands: commands)
  )
  #expect(WorkflowRecipeReplayPlanner.plan(commands: commands, mode: .skip) == .skip)
}

@Test("SHA-256 使用标准摘要，信任集合解码时清理非法值并稳定编码")
func workflowRecipeTrustStoreSanitizesPersistedDigests() throws {
  #expect(
    WorkflowSHA256.digest(Data())
      == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  )
  #expect(
    WorkflowSHA256.digest(Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  )
  #expect(
    WorkflowSHA256.digest(Data("The quick brown fox jumps over the lazy dog".utf8))
      == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
  )
  let valid = WorkflowSHA256.digest(Data("trusted".utf8))
  let external = try JSONSerialization.data(withJSONObject: [
    "sha256Digests": ["INVALID", valid.uppercased()]
  ])

  let restored = try JSONDecoder().decode(WorkflowRecipeTrustStore.self, from: external)

  #expect(restored.sha256Digests == [valid])
  let encoded = try JSONEncoder().encode(restored)
  #expect(String(decoding: encoded, as: UTF8.self).contains(valid))
}

@Test("导出内部 scrollback Recipe 时只保留外部格式承诺的布局")
func workflowRecipeExportDropsInternalScrollback() throws {
  let recipe = WorkflowRecipe(
    name: "Docs",
    scope: .tab,
    content: .includeScrollback,
    tabs: [
      WorkflowRecipeTab(
        title: "Docs",
        panes: [
          WorkflowRecipePane(workingDirectory: "/work", scrollback: "machine-local output")
        ]
      )
    ]
  )

  let data = try WorkflowRecipeTOML.encode(recipe)
  let restored = try WorkflowRecipeTOML.decode(data, source: .recipeFile).recipe

  #expect(restored.content == .layoutOnly)
  #expect(restored.tabs[0].panes[0].scrollback == nil)
  #expect(!String(decoding: data, as: UTF8.self).contains("machine-local output"))
}

@Test("TOML 文件入口只读写有界的普通 .ottyrecipe 文件")
func workflowRecipeFileStoreValidatesExtensionAndFileKind() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let recipe = WorkflowRecipe(
    name: "Shell",
    scope: .tab,
    content: .layoutOnly,
    tabs: [
      WorkflowRecipeTab(
        title: "Shell",
        panes: [WorkflowRecipePane(workingDirectory: "{{current_folder}}")]
      )
    ]
  )
  let file = directory.appendingPathComponent("shell.ottyrecipe")

  try WorkflowRecipeTOML.save(recipe, to: file)
  let restored = try WorkflowRecipeTOML.load(from: file)

  #expect(restored.recipe == recipe)
  #expect(throws: WorkflowRecipeTOMLError.invalidFileExtension) {
    try WorkflowRecipeTOML.save(recipe, to: directory.appendingPathComponent("shell.toml"))
  }
  let directoryRecipe = directory.appendingPathComponent("folder.ottyrecipe", isDirectory: true)
  try FileManager.default.createDirectory(at: directoryRecipe, withIntermediateDirectories: true)
  #expect(throws: WorkflowRecipeTOMLError.notRegularFile) {
    try WorkflowRecipeTOML.load(from: directoryRecipe)
  }
}

@Test("导入阶段拒绝逃逸基准目录的 cwd 和无法重建的 Pane 序列")
func workflowRecipeRejectsUnsafeOrAmbiguousPanePaths() {
  let escapingPath = Data(
    """
    [recipe]
    name = "unsafe"
    version = 1
    scope = "tab"
    [[window.tabs]]
    title = "unsafe"
    [[window.tabs.panes]]
    cwd = "{{current_folder}}/../secret"
    """.utf8
  )
  #expect(throws: WorkflowPortablePathError.pathEscapesBase) {
    try WorkflowRecipeTOML.decode(escapingPath, source: .recipeFile)
  }

  let missingSplit = Data(
    """
    [recipe]
    name = "ambiguous"
    version = 1
    scope = "tab"
    [[window.tabs]]
    title = "ambiguous"
    [[window.tabs.panes]]
    cwd = "/work"
    [[window.tabs.panes]]
    cwd = "/work/api"
    """.utf8
  )
  #expect(throws: WorkflowRecipeTOMLError.invalidStructure) {
    try WorkflowRecipeTOML.decode(missingSplit, source: .recipeFile)
  }
}

@Test("保存 Recipe 时跳过由旧 Recipe replay 的命令，避免命令层层累积")
func workflowRecipeCaptureOnlyKeepsObservedShellCommands() throws {
  let candidates = [
    WorkflowRecipeCommandCandidate(text: "pnpm dev", origin: .shellIntegration),
    WorkflowRecipeCommandCandidate(text: "make old", origin: .recipeReplay),
    WorkflowRecipeCommandCandidate(text: "git status", origin: .shellIntegration),
  ]

  #expect(
    try WorkflowRecipeCommandCapture.commands(from: candidates) == ["pnpm dev", "git status"]
  )
}

@Test("最终打开决策先完成外部信任门，再按来源选择 Replay 默认值")
func workflowRecipeOpenPlannerCombinesTrustAndSourceDefaults() throws {
  let recipe = WorkflowRecipe(
    name: "Commands",
    scope: .commands,
    content: .includeCommands,
    commands: ["make test"]
  )
  let source = WorkflowRecipeSource.recipeFile(
    sha256: WorkflowSHA256.digest(Data("commands".utf8))
  )
  let envelope = WorkflowRecipeEnvelope(recipe: recipe, source: source)
  var trustStore = WorkflowRecipeTrustStore()

  #expect(
    try WorkflowRecipeOpenPlanner.plan(envelope, trustStore: &trustStore)
      == .reviewRequired(
        sha256: WorkflowSHA256.digest(Data("commands".utf8)),
        commands: ["make test"]
      )
  )
  #expect(
    try WorkflowRecipeOpenPlanner.plan(
      envelope,
      trustStore: &trustStore,
      trustChoice: .runOnce
    ) == .replay(.confirmOnce(batches: [["make test"]]))
  )
  #expect(!trustStore.contains(source))
  #expect(
    try WorkflowRecipeOpenPlanner.plan(
      envelope,
      trustStore: &trustStore,
      trustChoice: .alwaysTrust
    ) == .replay(.confirmOnce(batches: [["make test"]]))
  )
  #expect(trustStore.contains(source))
}
