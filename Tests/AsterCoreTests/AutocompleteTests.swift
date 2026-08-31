import Foundation
import Testing

@testable import AsterCore

@Test("Autocomplete 配置默认值与 Otty 行为一致")
func autocompleteConfigurationDefaultsMatchReferenceBehavior() {
  let controls = ControlConfiguration()

  #expect(controls.resolvedAutocompleteShortcut == .tab)
  #expect(controls.resolvedAutocompleteCandidatePanel == .escape)
  #expect(controls.resolvedAutocompleteInlineSuggestion)
  #expect(controls.resolvedAutocompleteOnDeviceLearning)
  #expect(controls.resolvedAutocompleteHistoryIgnore.isEmpty)
  #expect(controls.resolvedAutocompleteDescriptionLanguage == .system)
  #expect(
    AutocompleteDescriptionLanguage.system.resolved(
      preferredLanguageIdentifiers: ["zh-Hans-SG"]
    ) == .chinese
  )
  #expect(
    AutocompleteDescriptionLanguage.system.resolved(
      preferredLanguageIdentifiers: ["en-SG"]
    ) == .english
  )
}

@Test("Shell 命令分词保留引号参数并报告当前 token 范围")
func shellCommandTokenizerTracksQuotedTokensAndCursor() {
  let parsed = ShellCommandTokenizer.tokenize("git commit -m \"hello world\" --am")

  #expect(parsed.tokens == ["git", "commit", "-m", "hello world", "--am"])
  #expect(parsed.currentToken == "--am")
  #expect(parsed.currentTokenStart == 28)

  let trailingSpace = ShellCommandTokenizer.tokenize("git checkout ")
  #expect(trailingSpace.tokens == ["git", "checkout"])
  #expect(trailingSpace.currentToken.isEmpty)
  #expect(trailingSpace.currentTokenStart == 13)
}

@Test("学习数据库不存储 secret、遵守忽略模式并清理失败命令")
func autocompleteLearningProtectsSecretsAndPrunesFailures() {
  var learning = AutocompleteLearningDatabase(capacity: 20)
  let start = Date(timeIntervalSinceReferenceDate: 1_000)

  let storedSecretSafeCommand = learning.complete(
      command: "curl --token super-secret https://example.test",
      directory: "/project",
      exitStatus: 0,
      ignorePatterns: [],
      knownOptions: ["--token"],
      sessionIdentifier: "session-a",
      at: start
    )
  #expect(storedSecretSafeCommand)
  #expect(learning.entries.map(\.command) == ["curl https://example.test"])
  #expect(!learning.entries[0].command.contains("super-secret"))

  let storedIgnoredCommand = learning.complete(
      command: "ssh production",
      directory: "/project",
      exitStatus: 0,
      ignorePatterns: ["ssh *"],
      knownOptions: [],
      sessionIdentifier: "session-a",
      at: start
    )
  #expect(!storedIgnoredCommand)
  let storedMissingCommand = learning.complete(
      command: "gti status",
      directory: "/project",
      exitStatus: 127,
      ignorePatterns: [],
      knownOptions: [],
      sessionIdentifier: "session-a",
      at: start
    )
  #expect(!storedMissingCommand)

  _ = learning.complete(
    command: "git status --porcelain",
    directory: "/project",
    exitStatus: 0,
    ignorePatterns: [],
    knownOptions: ["--porcelain"],
    sessionIdentifier: "session-a",
    at: start
  )
  let storedInvalidOption = learning.complete(
      command: "git status --porcelan",
      directory: "/project",
      exitStatus: 2,
      ignorePatterns: [],
      knownOptions: ["--porcelain"],
      sessionIdentifier: "session-a",
      at: start.addingTimeInterval(1)
    )
  #expect(!storedInvalidOption)
  #expect(!learning.entries.contains { $0.command.contains("--porcelan") })

  let storedFailedCommandWithoutDetailedSpec = learning.complete(
    command: "acme deploy --verbose",
    directory: "/project",
    exitStatus: 1,
    ignorePatterns: [],
    knownOptions: [],
    sessionIdentifier: "session-a",
    at: start.addingTimeInterval(2)
  )
  #expect(storedFailedCommandWithoutDetailedSpec)
}

@Test("学习与固定命令按当前目录、会话加权和时间 frecency 排序")
func autocompleteLearningRanksSessionAndFolderCommands() {
  var learning = AutocompleteLearningDatabase(capacity: 20)
  let old = Date(timeIntervalSinceReferenceDate: 1_000)
  let now = old.addingTimeInterval(8 * 86_400)
  _ = learning.complete(
    command: "git status", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "old-session", at: old)
  _ = learning.complete(
    command: "npm test", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "current", at: now)
  let firstPin = learning.pin(command: "npm run deploy", directory: "/project", at: now)
  let secondPin = learning.pin(command: "npm run deploy", directory: "/project", at: now)
  #expect(firstPin)
  #expect(secondPin)

  let matches = learning.suggestions(
    prefix: "", directory: "/project", sessionIdentifier: "current", now: now)

  #expect(matches.first?.command == "npm run deploy")
  #expect(matches.dropFirst().first?.command == "npm test")
  #expect(matches.last?.command == "git status")
}

@Test("补全学习历史与固定命令可以独立清除")
func autocompleteLearningClearsCategoriesIndependently() {
  let now = Date(timeIntervalSinceReferenceDate: 2_000)
  var learning = AutocompleteLearningDatabase(capacity: 20)
  _ = learning.complete(
    command: "git status", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session-a", at: now)
  _ = learning.pin(command: "npm run deploy", directory: "/project", at: now)

  learning.clearHistory()
  #expect(learning.entries.map(\.command) == ["npm run deploy"])
  #expect(learning.entries[0].useCount == 0)
  #expect(learning.entries[0].pinCount == 1)

  _ = learning.complete(
    command: "npm run deploy", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session-b", at: now)
  learning.clearPinnedCommands()
  #expect(learning.entries.map(\.command) == ["npm run deploy"])
  #expect(learning.entries[0].useCount == 1)
  #expect(learning.entries[0].pinCount == 0)
}

@Test("README 只提取 Shell fenced code block 中的命令")
func readmeCommandScannerExtractsShellFences() {
  let markdown = """
  # Build

  ```bash
  $ swift build
  swift test --no-parallel
  # explanation
  ```

  ```json
  { "command": "do-not-learn" }
  ```

  ```console
  % ./scripts/release.sh --dry-run
  output line
  ```
  """

  #expect(
    ReadmeCommandScanner.commands(in: markdown)
      == ["swift build", "swift test --no-parallel", "./scripts/release.sh --dry-run"]
  )
}

@Test("常见工具与 command-not-found 输出可生成本地纠错候选")
func commandCorrectionParserRecognizesCommonSuggestions() {
  #expect(
    CommandCorrectionParser.suggestion(
      command: "git statsu",
      output: "git: 'statsu' is not a git command. See 'git --help'.\n\nThe most similar command is\n\tstatus",
      knownCommands: ["git", "npm"]
    ) == "git status"
  )
  #expect(
    CommandCorrectionParser.suggestion(
      command: "gti status",
      output: "zsh: command not found: gti",
      knownCommands: ["git", "npm"]
    ) == "git status"
  )
  #expect(
    CommandCorrectionParser.suggestion(
      command: "npm isntall",
      output: "Unknown command: \"isntall\"\n\nDid you mean this?\n  npm install",
      knownCommands: ["npm"]
    ) == "npm install"
  )
  #expect(
    CommandCorrectionParser.suggestion(
      command: "cargo buidl",
      output: "error: no such command: `buidl`\nhelp: a command with a similar name exists: `build`",
      knownCommands: ["cargo"]
    ) == "cargo build"
  )
  #expect(
    CommandCorrectionParser.suggestion(
      command: "pip instal",
      output: "ERROR: unknown command \"instal\" - maybe you meant \"install\"",
      knownCommands: ["pip"]
    ) == "pip install"
  )
}

@Test("规格、历史、固定命令和 README 共用候选引擎且返回补全文本")
func autocompleteEngineCombinesSourcesAndRanksKinds() {
  let database = AutocompleteSpecDatabase(
    sourceRevision: "test",
    commands: [
      AutocompleteCommandSpec(
        name: "git",
        description: LocalizedAutocompleteDescription(
          english: "Distributed version control", chinese: "分布式版本控制"),
        subcommands: [
          AutocompleteCommandSpec(
            name: "checkout", description: LocalizedAutocompleteDescription(english: "切换分支"),
            aliases: ["co"],
            options: [
              AutocompleteOptionSpec(
                names: ["-b"], description: "新建分支",
                args: [AutocompleteArgumentSpec(name: "branch")])
            ],
            arguments: [
              AutocompleteArgumentSpec(
                name: "branch", suggestions: [AutocompleteSpecItem(name: "main")])
            ]),
          AutocompleteCommandSpec(
            name: "cherry-pick", description: LocalizedAutocompleteDescription(english: "应用提交")),
        ],
        options: [AutocompleteOptionSpec(names: ["-h", "--help"], description: "显示帮助")]
      )
    ]
  )
  let engine = AutocompleteEngine(specDatabase: database)

  let result = engine.suggestions(
    for: AutocompleteQuery(line: "git ch", directory: "/project"),
    learned: [],
    pinned: [],
    readmeCommands: []
  )

  #expect(result.candidates.map(\.insertText) == ["checkout", "cherry-pick"])
  #expect(result.candidates.allSatisfy { $0.kind == .subcommand })
  #expect(result.ghostText == "eckout")
  #expect(result.replacementStart == 4)

  // 嵌套规格:子命令(含别名)下钻后给出该层的选项、位置参数候选;带参选项吞掉下一个 token。
  let nestedOption = engine.suggestions(
    for: AutocompleteQuery(line: "git co -", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [])
  #expect(nestedOption.candidates.map(\.insertText) == ["-b"])
  #expect(nestedOption.candidates.first?.kind == .option)
  let rootOption = engine.suggestions(
    for: AutocompleteQuery(line: "git --", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [])
  #expect(rootOption.candidates.map(\.insertText) == ["--help"])
  #expect(rootOption.candidates.first?.displayText == "-h, --help")
  let positional = engine.suggestions(
    for: AutocompleteQuery(line: "git checkout m", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [])
  #expect(positional.candidates.map(\.insertText) == ["main"])
  #expect(positional.candidates.first?.kind == .argument)
  let afterOptionArgument = engine.suggestions(
    for: AutocompleteQuery(line: "git checkout -b ", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [])
  #expect(afterOptionArgument.candidates.isEmpty)

  let folderFirst = engine.suggestions(
    for: AutocompleteQuery(line: "n", directory: "/project"),
    learned: [AutocompleteLearnedSuggestion(command: "git status", score: 100)],
    pinned: [AutocompleteLearnedSuggestion(command: "npm run deploy", score: 1_000)],
    readmeCommands: ["swift test"]
  )
  #expect(folderFirst.candidates.first?.kind == .snippet)
  #expect(folderFirst.candidates.first?.insertText == "npm run deploy")

  // 空 prompt 必须完全安静：面板一弹出就会吞掉回车，用户会以为终端卡住了。
  // 历史、固定命令和 README 都不能在没有任何输入时冒出来。
  for blankLine in ["", " ", "   "] {
    let blank = engine.suggestions(
      for: AutocompleteQuery(line: blankLine, directory: "/project"),
      learned: [AutocompleteLearnedSuggestion(command: "git status", score: 100)],
      pinned: [AutocompleteLearnedSuggestion(command: "npm run deploy", score: 1_000)],
      readmeCommands: ["swift test"]
    )
    #expect(blank.candidates.isEmpty)
    #expect(blank.ghostText == nil)
  }

  let aliases = engine.suggestions(
    for: AutocompleteQuery(line: "gs", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [], aliases: ["gs", "gst"]
  )
  #expect(aliases.candidates.map(\.insertText) == ["gst"])
  #expect(aliases.candidates.first?.kind == .alias)
}

@Test("Prompt 输入跟踪器支持 UTF-8、光标移动、删除和提交")
func promptInputTrackerModelsEditableCommandLine() {
  let tracker = PromptInputTracker()
  tracker.beginPrompt()
  #expect(tracker.receive(Array("echo 终端".utf8)).isEmpty)
  #expect(tracker.line == "echo 终端")

  _ = tracker.receive([0x1B, 0x5B, 0x44])  // Left
  #expect(!tracker.isCursorAtEnd)
  _ = tracker.receive([0x7F])  // Backspace
  #expect(tracker.line == "echo 端")
  #expect(tracker.receive([0x0A]) == ["echo 端"])
  #expect(tracker.line.isEmpty)

  tracker.beginPrompt()
  _ = tracker.receive([0x1B, 0x5B, 0x41])  // Up: shell history cannot be reconstructed safely.
  #expect(!tracker.isReliable)
}

@Test("内置 Fig 规格库包含完整的嵌套子命令、选项与参数")
func bundledFigCommandDatabaseContainsExpectedCoverage() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let data = try Data(
    contentsOf: root.appendingPathComponent("Resources/autocomplete/fig-specs.json"))
  let database = try AutocompleteSpecStore.decode(data)

  #expect(database.schemaVersion == 2)
  #expect(database.sourceDate?.isEmpty == false)
  #expect(database.commands.count >= 700)
  let git = try #require(database.command(named: "git"))
  #expect(git.subcommands.count >= 30)
  let commit = try #require(git.subcommand(named: "commit"))
  #expect(!commit.description.english.isEmpty)
  #expect(commit.options.contains { $0.names.contains("--amend") })
  #expect(git.options.contains { $0.names.contains("--no-pager") })
  #expect(database.commands.contains { $0.name == "git" })
  #expect(database.commands.contains { $0.name == "npm" })
  #expect(database.commands.contains { $0.name == "kubectl" })
  #expect(database.commands.contains { $0.name == "docker" })
  #expect(database.commands.contains { $0.name == "aws" })
}

@Test("Autocomplete 持久化入口先拒绝超限数据")
func autocompleteStoresRejectOversizedData() {
  let oversized = Data(repeating: 0x41, count: AutocompleteLearningStore.maximumEncodedBytes + 1)

  #expect(throws: AutocompleteStoreError.fileTooLarge) {
    try AutocompleteLearningStore.decode(oversized)
  }
  let oversizedSpec = Data(repeating: 0x41, count: AutocompleteSpecStore.maximumEncodedBytes + 1)
  #expect(throws: AutocompleteStoreError.fileTooLarge) {
    try AutocompleteSpecStore.decode(oversizedSpec)
  }

  let unsupported = Data("{\"schemaVersion\":1,\"sourceRevision\":\"test\",\"commands\":[]}".utf8)
  #expect(throws: AutocompleteStoreError.unsupportedSchema) {
    try AutocompleteSpecStore.decode(unsupported)
  }
}

@Test("规格文件更新只接受完整的 schema v2 文件并保留已有中文描述")
func figAutocompleteUpdateParserValidatesAndMergesChinese() throws {
  let payload = Data(
    """
    {
      "schemaVersion": 2,
      "sourceRevision": "npm-9.9.9",
      "sourceDate": "2026-08-26",
      "commands": [
        {"name":"git","description":"Distributed version control","subcommands":[{"name":"status"}]},
        {"name":"new-cli","description":{"english":"New","chinese":"新工具"}}
      ]
    }
    """.utf8)
  let existing = AutocompleteSpecDatabase(
    sourceRevision: "old",
    commands: [
      AutocompleteCommandSpec(
        name: "git",
        description: LocalizedAutocompleteDescription(english: "old", chinese: "分布式版本控制")
      )
    ])

  let updated = try FigAutocompleteUpdateParser.database(
    from: payload,
    preserving: existing,
    minimumCommandCount: 2
  )

  #expect(updated.sourceRevision == "npm-9.9.9")
  #expect(updated.sourceDate == "2026-08-26")
  #expect(updated.commands.map(\.name) == ["git", "new-cli"])
  #expect(updated.commands.first?.subcommands.map(\.name) == ["status"])
  #expect(updated.commands.first?.description.chinese == "分布式版本控制")
  #expect(updated.commands.last?.description.chinese == "新工具")

  // 只有名称清单(旧的 GitHub tree 响应)不再是合法更新载荷。
  let tree = Data("{\"sha\":\"x\",\"truncated\":false,\"tree\":[]}".utf8)
  #expect(throws: AutocompleteStoreError.self) {
    try FigAutocompleteUpdateParser.database(from: tree, preserving: existing, minimumCommandCount: 1)
  }
  // 编码后再解码保持等价;空描述/空子项不写入,纯英文描述编码为字符串而非对象。
  let encoded = try AutocompleteSpecStore.encode(updated)
  #expect(try AutocompleteSpecStore.decode(encoded) == updated)
  #expect(String(decoding: encoded, as: UTF8.self).contains("{\"name\":\"status\"}"))
  let englishOnly = try AutocompleteSpecStore.encode(
    AutocompleteSpecDatabase(
      sourceRevision: "x",
      commands: [AutocompleteCommandSpec(name: "ls", description: .init(english: "List"))]))
  #expect(String(decoding: englishOnly, as: UTF8.self).contains("\"description\":\"List\""))
}

@Test("help 输出可生成有界的本地子命令与选项规格")
func helpOutputParserBuildsLocalCommandSpec() {
  let output = """
    Usage: acme [options] <command>

    Commands:
      deploy      Deploy the current project
      status      Show deployment state

    Options:
      -h, --help  Show help
      --profile   Select profile
    """

  let spec = HelpAutocompleteSpecParser.parse(command: "acme", output: output)

  #expect(spec?.subcommands.map(\.name) == ["deploy", "status"])
  #expect(spec?.options.map(\.name) == ["--help", "--profile"])
  #expect(spec?.subcommands.first?.description.english == "Deploy the current project")

  let unsafe = HelpAutocompleteSpecParser.parse(
    command: "acme",
    output: "Commands:\n  $(touch-owned)  Must not become insertable text"
  )
  #expect(unsafe == nil)
}

@Test("Prompt 输入跟踪器跨分片处理 UTF-8 与 CSI，并避免 CRLF 重复提交")
func promptInputTrackerHandlesSplitSequencesAndCRLF() {
  let tracker = PromptInputTracker()
  tracker.beginPrompt()
  let bytes = Array("终".utf8)
  _ = tracker.receive(Array(bytes.prefix(1)))
  _ = tracker.receive(Array(bytes.dropFirst()))
  _ = tracker.receive([0x1B, 0x5B])
  _ = tracker.receive([0x44])
  _ = tracker.receive(Array("A".utf8))

  #expect(tracker.line == "A终")
  #expect(tracker.receive([0x0D, 0x0A]) == ["A终"])
}

@Test("Shell 输出捕获器按 OSC 133 C/D 边界提取同分片命令输出")
func shellCommandOutputCaptureHandlesSameChunkAndSplitMarkers() {
  var capture = ShellCommandOutputCapture(maximumOutputBytes: 64)
  let sameChunk = Array(
    "\u{1B}]133;C\u{7}line one\r\n\u{1B}]133;D;2\u{7}\u{1B}]133;A\u{7}$ ".utf8)

  let completed = capture.consume(sameChunk[...])

  #expect(completed.count == 1)
  #expect(completed[0].exitStatus == 2)
  #expect(completed[0].text == "line one\r\n")

  #expect(capture.consume(Array("\u{1B}]133;".utf8)[...]).isEmpty)
  #expect(capture.consume(Array("C\u{7}split".utf8)[...]).isEmpty)
  let split = capture.consume(Array(" output\u{1B}]133;D;0\u{7}".utf8)[...])
  #expect(split.first?.text == "split output")
  #expect(split.first?.exitStatus == 0)

  var boundedCapture = ShellCommandOutputCapture(maximumOutputBytes: 5)
  let bounded = boundedCapture.consume(
    Array("\u{1B}]133;C\u{7}12345678\u{1B}]133;D;1\u{7}".utf8)[...])
  #expect(bounded.first?.text == "45678")
}

@Test("Shell alias 报告只接受有界 ASCII 名称并稳定去重")
func shellAliasReportValidatesNames() {
  #expect(ShellAliasReport(payload: "Aliases=gs,gco,gs")?.names == ["gco", "gs"])
  #expect(ShellAliasReport(payload: "Aliases=ok,bad name") == nil)
  #expect(ShellAliasReport(payload: "Aliases=ok\u{7}evil") == nil)
  #expect(ShellAliasReport(payload: String(repeating: "a", count: 8_193)) == nil)
}

@Test("候选自带替换范围，ghost 与接受后缀来自同一次计算")
func autocompleteCandidateCarriesOwnReplacementSpan() {
  let engine = AutocompleteEngine(specDatabase: AutocompleteSpecDatabase(
    sourceRevision: "test",
    commands: [
      AutocompleteCommandSpec(
        name: "git",
        subcommands: [AutocompleteCommandSpec(name: "checkout")])
    ]))
  let result = engine.suggestions(
    for: AutocompleteQuery(line: "git ch", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [])
  let candidate = result.candidates.first
  #expect(candidate?.insertText == "checkout")
  // `git ch` 里 token 从第 4 个字符开始，替换范围必须落在那里。
  #expect(candidate?.replacement == .currentToken(start: 4))
  #expect(result.replacementStart == 4)
  #expect(result.ghostText == "eckout")
  #expect(candidate?.appendableSuffix(from: "git ch") == "eckout")

  // 整行候选（历史/固定/README/纠错）从行首替换。
  let learnedResult = engine.suggestions(
    for: AutocompleteQuery(line: "git ch", directory: "/project"),
    learned: [AutocompleteLearnedSuggestion(
      command: "git checkout main", score: 1, frecency: 1, isSessionMatch: true)],
    pinned: [], readmeCommands: [])
  let learned = learnedResult.candidates.first
  #expect(learned?.kind == .learnedCommand)
  #expect(learned?.replacement == .fullLine)
  #expect(learnedResult.replacementStart == 0)
  #expect(learnedResult.ghostText == "eckout main")
}

@Test("统一相关性让来源交错：热历史压过规格，冷历史输给贴合的子命令")
func autocompleteRelevanceInterleavesSourcesByFrecency() {
  let subcommand = AutocompleteRelevance.score(
    kind: .subcommand, typed: "ch", candidate: "checkout")
  let coldHistory = AutocompleteRelevance.score(
    kind: .learnedCommand, typed: "git ch", candidate: "git checkout --force origin",
    frecency: 0.1)
  let hotHistory = AutocompleteRelevance.score(
    kind: .learnedCommand, typed: "git ch", candidate: "git checkout --force origin",
    frecency: 0.95, sessionBoost: 1)
  // 这两条正是权重表注释里写死的算术，改动常量前必须重算。
  #expect(coldHistory < subcommand, "一条冷历史不该压过前缀吻合的子命令")
  #expect(hotHistory > subcommand, "本会话刚跑过的命令必须排在规格候选之前")
  // 匹配质量对所有来源共享：打得越准越靠前。
  #expect(
    AutocompleteRelevance.matchQuality(typed: "check", candidate: "checkout")
      > AutocompleteRelevance.matchQuality(typed: "ch", candidate: "checkout"))
}

@Test("相关性分数有界且同等条件下按来源权重排序")
func autocompleteRelevanceScoresRemainBounded() {
  for kind in [
    AutocompleteCandidateKind.correction, .snippet, .dynamicArgument, .learnedCommand,
    .subcommand, .argument, .option, .alias, .command, .readmeCommand, .folder, .file,
  ] {
    for frecency in [0.0, 1.0] {
      let score = AutocompleteRelevance.score(
        kind: kind, matchQuality: 1, frecency: frecency, sessionBoost: frecency, pinBoost: frecency)
      #expect(score > 0 && score <= 1_000)
    }
  }
  // frecency 全为 0、匹配质量相同时，严格按基础权重排序。
  let ordered: [AutocompleteCandidateKind] = [
    .correction, .snippet, .dynamicArgument, .subcommand, .argument,
    .option, .alias, .learnedCommand, .readmeCommand, .folder, .file,
  ]
  let weights = ordered.map { AutocompleteRelevance.baseWeight(for: $0) }
  #expect(weights == weights.sorted(by: >))
  // 历史刻意排在子命令之下：赢下来必须靠 frecency，不能靠“它是一条历史”。
  #expect(
    AutocompleteRelevance.baseWeight(for: .learnedCommand)
      < AutocompleteRelevance.baseWeight(for: .subcommand))
}

@Test("跨来源按补全后的完整命令行去重")
func autocompleteDeduplicatesByResultingCommandLine() {
  let engine = AutocompleteEngine(specDatabase: AutocompleteSpecDatabase(
    sourceRevision: "test",
    commands: [
      AutocompleteCommandSpec(
        name: "git",
        subcommands: [AutocompleteCommandSpec(name: "checkout", description: .init(english: "Switch branches"))])
    ]))
  let result = engine.suggestions(
    for: AutocompleteQuery(line: "git ch", directory: "/project"),
    learned: [AutocompleteLearnedSuggestion(
      command: "git checkout", score: 1, frecency: 0.9, isSessionMatch: true)],
    pinned: [], readmeCommands: [])
  // 历史整行 `git checkout` 与 token 候选 `checkout` 补全后是同一条命令行，
  // 必须合并成一行；旧实现按 insertText 去重完全拦不住。
  let matching = result.candidates.filter {
    $0.resultingLine(from: "git ch") == "git checkout"
  }
  #expect(matching.count == 1)
  // 合并保留了规格描述——历史条目本身没有描述。
  #expect(matching.first?.description == "Switch branches")
}

@Test("动态候选与历史整行合并成同一条，仍能正确接受")
func autocompleteMergesDynamicArgumentWithHistoryLine() {
  let engine = AutocompleteEngine(specDatabase: AutocompleteSpecDatabase(
    sourceRevision: "test",
    commands: [
      AutocompleteCommandSpec(
        name: "git",
        subcommands: [
          AutocompleteCommandSpec(
            name: "checkout",
            arguments: [AutocompleteArgumentSpec(
              name: "branch",
              generatorScripts: [["git", "branch", "--no-color"]])])
        ])
    ]))
  let result = engine.suggestions(
    for: AutocompleteQuery(line: "git checkout m", directory: "/project"),
    learned: [AutocompleteLearnedSuggestion(
      command: "git checkout main", score: 1, frecency: 0.8)],
    pinned: [], readmeCommands: [],
    dynamic: AutocompleteDynamicProvider { source in
      source == .gitLocalBranches ? [AutocompleteDynamicItem(name: "main")] : []
    })
  let matching = result.candidates.filter {
    $0.resultingLine(from: "git checkout m") == "git checkout main"
  }
  #expect(matching.count == 1)
  #expect(matching.first?.appendableSuffix(from: "git checkout m") == "ain")
}

@Test("补全后不同的命令行不会被合并")
func autocompleteKeepsDistinctLinesSeparate() {
  let engine = AutocompleteEngine(specDatabase: AutocompleteSpecDatabase(
    sourceRevision: "test", commands: []))
  let result = engine.suggestions(
    for: AutocompleteQuery(line: "git checkout ", directory: "/project"),
    learned: [
      AutocompleteLearnedSuggestion(command: "git checkout main", score: 1, frecency: 0.9),
      AutocompleteLearnedSuggestion(command: "git checkout dev", score: 1, frecency: 0.5),
    ],
    pinned: [], readmeCommands: [])
  #expect(result.candidates.count == 2)
  #expect(result.candidates.first?.insertText == "git checkout main")
}

@Test("aster learn 目标分类区分目录、PATH 二进制和整行命令")
func autocompleteLearnTargetClassifierSeparatesFolderBinaryAndCommand() {
  let directories: Set<String> = ["/tmp/project"]
  let executables: Set<String> = ["acme"]
  func classify(_ target: String) -> AutocompleteLearnTarget {
    AutocompleteLearnTarget.classify(
      target: target,
      isDirectory: { directories.contains($0) },
      resolveExecutable: { executables.contains($0) ? "/usr/local/bin/" + $0 : nil })
  }
  #expect(classify("/tmp/project") == .folder("/tmp/project"))
  #expect(classify("acme") == .binary(name: "acme", executable: "/usr/local/bin/acme"))
  // 含空格的一律是命令行；否则 `aster learn 'npm run build'` 会被当成可执行文件名。
  #expect(classify("npm run build") == .command("npm run build"))
  #expect(classify("rm -rf /") == .command("rm -rf /"))
  // 含 `/` 就不是 PATH 查找目标。
  #expect(classify("./tool") == .command("./tool"))
  // PATH 上找不到的裸词退回整行命令。
  #expect(classify("nosuchbinary") == .command("nosuchbinary"))
}

@Test("help 解析器把折行的描述归给上一条，不生成假候选")
func autocompleteHelpParserIgnoresWrappedDescriptionLines() throws {
  // 取自 docker --help 的真实形状：过长的描述被折到下一行。旧实现会把续行
  // `"warn",` 当成一个新选项，Otty 的面板里就能看到这个 bug。
  let output = """
    Options:
      -D, --debug              Enable debug mode
      -l, --log-level string   Set the logging level ("debug", "info",
                               "warn", "error", "fatal") (default "info")
          --tls                Use TLS; implied by --tlsverify

    Management Commands:

    Commands:
      attach      Attach local standard input, output, and error streams
                  to a running container
      build       Build an image from a Dockerfile
    """
  let spec = try #require(HelpAutocompleteSpecParser.parse(command: "docker", output: output))
  let optionNames = spec.options.flatMap(\.names)
  #expect(optionNames.contains("--debug"))
  #expect(optionNames.contains("--log-level"))
  #expect(optionNames.contains("--tls"))
  #expect(!optionNames.contains { $0.contains("warn") }, "描述续行不得变成选项")
  #expect(spec.options.count == 3)
  let subcommandNames = spec.subcommands.map(\.name)
  #expect(subcommandNames == ["attach", "build"])
  #expect(!subcommandNames.contains("to"), "描述续行不得变成子命令")
}

@Test("只有子命令、没有选项的规格不算完整，仍需 help 探测")
func autocompleteSpecWithoutOptionsIsNotComplete() {
  // 上游 Fig 规格里 `docker` 就是 58 个子命令 + 0 个选项；旧的宽松判定认为它已经
  // 够详细，于是顶层 flag 永远补不出来。
  let subcommandsOnly = AutocompleteCommandSpec(
    name: "docker", subcommands: [AutocompleteCommandSpec(name: "run")])
  #expect(subcommandsOnly.hasDetails)
  #expect(!subcommandsOnly.hasCompleteSpec)

  let complete = AutocompleteCommandSpec(
    name: "docker",
    subcommands: [AutocompleteCommandSpec(name: "run")],
    options: [AutocompleteOptionSpec(names: ["--debug"], description: "")])
  #expect(complete.hasCompleteSpec)

  // 纯 flag 型命令（无子命令）只要有选项就算完整。
  let flagsOnly = AutocompleteCommandSpec(
    name: "ls", options: [AutocompleteOptionSpec(names: ["-l"], description: "")])
  #expect(flagsOnly.hasCompleteSpec)
}

@Test("命令名打完还没敲空格时也给出该命令的子命令与选项")
func autocompleteOffersSubcommandsForFullyTypedCommandName() {
  let engine = AutocompleteEngine(specDatabase: AutocompleteSpecDatabase(
    sourceRevision: "test",
    commands: [
      AutocompleteCommandSpec(
        name: "docker",
        subcommands: [
          AutocompleteCommandSpec(name: "attach", description: .init(english: "Attach")),
          AutocompleteCommandSpec(name: "build", description: .init(english: "Build")),
        ],
        options: [AutocompleteOptionSpec(names: ["--debug"], description: "Debug")]),
      AutocompleteCommandSpec(name: "docker-compose"),
    ]))
  let result = engine.suggestions(
    for: AutocompleteQuery(line: "docker", directory: "/project"),
    learned: [], pinned: [], readmeCommands: [])
  let texts = result.candidates.map(\.insertText)
  // 旧实现在这里只剩一条 `docker-compose`——用户按 Tab 想看的是 docker 能做什么。
  #expect(texts.contains("docker-compose"))
  #expect(texts.contains(" attach"))
  #expect(texts.contains(" build"))
  // 面板里显示的是命令名本身，不带那个用于拼接的前导空格。
  #expect(result.candidates.contains { $0.displayText == "attach" })
  // 接受后得到 `docker attach`，空格由候选自己带上。
  let attach = result.candidates.first { $0.displayText == "attach" }
  #expect(attach?.resultingLine(from: "docker") == "docker attach")
  #expect(attach?.appendableSuffix(from: "docker") == " attach")
}

@Test("unpin 撤销固定但保留真实使用历史")
func autocompleteLearningUnpinKeepsGenuineHistory() {
  var database = AutocompleteLearningDatabase()
  let directory = "/project"
  // `#expect` 的宏展开会把接收者当成不可变值，mutating 方法必须先取到局部结果。
  // 只被固定、从未真正跑过的命令：撤销后应该整条消失。
  database.pin(command: "npm run deploy:staging", directory: directory)
  #expect(database.isPinned(command: "npm run deploy:staging", directory: directory))
  let unpinnedStaging = database.unpin(command: "npm run deploy:staging", directory: directory)
  #expect(unpinnedStaging)
  #expect(!database.isPinned(command: "npm run deploy:staging", directory: directory))
  #expect(database.suggestions(prefix: "npm", directory: directory, sessionIdentifier: "s").isEmpty)

  // 既跑过又被固定的命令：撤销只去掉固定，历史留着——用户只是不想再把它钉在最前面，
  // 不是要抹掉自己确实跑过它这件事。
  database.complete(
    command: "npm test", directory: directory, exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "s")
  database.pin(command: "npm test", directory: directory)
  let unpinnedTest = database.unpin(command: "npm test", directory: directory)
  #expect(unpinnedTest)
  #expect(!database.isPinned(command: "npm test", directory: directory))
  #expect(
    database.suggestions(prefix: "npm", directory: directory, sessionIdentifier: "s")
      .contains { $0.command == "npm test" })

  // 从没固定过的东西撤销失败，供 CLI 报出准确的错误。
  let unpinAgain = database.unpin(command: "npm test", directory: directory)
  let unpinUnknown = database.unpin(command: "never pinned", directory: directory)
  let unpinOtherDirectory = database.unpin(command: "npm test", directory: "/other")
  #expect(!unpinAgain)
  #expect(!unpinUnknown)
  #expect(!unpinOtherDirectory)
}
