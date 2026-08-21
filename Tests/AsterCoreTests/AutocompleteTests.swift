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
          AutocompleteSpecItem(name: "checkout", description: "切换分支"),
          AutocompleteSpecItem(name: "cherry-pick", description: "应用提交"),
        ],
        options: [AutocompleteSpecItem(name: "--help", description: "显示帮助")]
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

@Test("内置 Fig 清单固定为 715 个直接命令规格")
func bundledFigCommandDatabaseContainsExpectedCoverage() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let data = try Data(
    contentsOf: root.appendingPathComponent("Resources/autocomplete/fig-specs.json"))
  let database = try AutocompleteSpecStore.decode(data)

  #expect(database.commands.count == 715)
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
  #expect(throws: AutocompleteStoreError.fileTooLarge) {
    try AutocompleteSpecStore.decode(oversized)
  }

  let unsupported = Data("{\"schemaVersion\":2,\"sourceRevision\":\"test\",\"commands\":[]}".utf8)
  #expect(throws: AutocompleteStoreError.unsupportedSchema) {
    try AutocompleteSpecStore.decode(unsupported)
  }
}

@Test("Fig tree 更新只接受 src 根目录下的直接命令并保留已有规格")
func figAutocompleteUpdateParserFiltersAndMergesCommands() throws {
  let payload = Data(
    """
    {
      "sha": "new-revision",
      "truncated": false,
      "tree": [
        {"path":"src/git.ts","type":"blob"},
        {"path":"src/new-cli.ts","type":"blob"},
        {"path":"src/$inject.ts","type":"blob"},
        {"path":"src/shared/ignored.ts","type":"blob"},
        {"path":"README.md","type":"blob"}
      ]
    }
    """.utf8)
  let existing = AutocompleteSpecDatabase(
    sourceRevision: "old",
    commands: [
      AutocompleteCommandSpec(
        name: "git",
        subcommands: [AutocompleteSpecItem(name: "status")]
      )
    ])

  let updated = try FigAutocompleteUpdateParser.database(
    from: payload,
    preserving: existing,
    minimumCommandCount: 2
  )

  #expect(updated.sourceRevision == "new-revision")
  #expect(updated.commands.map(\.name) == ["git", "new-cli"])
  #expect(updated.commands.first?.subcommands.map(\.name) == ["status"])
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
  #expect(spec?.subcommands.first?.description == "Deploy the current project")

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
