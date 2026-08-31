import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("Autocomplete 服务持久化脱敏学习并可清空")
@MainActor
func autocompleteServicePersistsSecretSafeLearning() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let service = try AutocompleteService(
    baseDirectory: directory,
    bundledSpecURL: repositoryAutocompleteSpecURL
  )

  #expect(
    service.record(
      command: "curl --token private-value https://example.test",
      directory: "/project",
      exitStatus: 0,
      ignorePatterns: [],
      knownOptions: ["--token"],
      sessionIdentifier: "session-a"
    ))
  let reloaded = try AutocompleteService(
    baseDirectory: directory,
    bundledSpecURL: repositoryAutocompleteSpecURL
  )
  // 空 prompt 不再返回任何候选，用命令前缀查询学习库。
  let result = reloaded.suggestions(
    line: "curl",
    directory: "/project",
    sessionIdentifier: "session-a",
    controls: ControlConfiguration()
  )

  #expect(result.candidates.contains { $0.insertText == "curl https://example.test" })
  #expect(!result.candidates.contains { $0.insertText.contains("private-value") })
  try reloaded.clearLearning()
  #expect(
    reloaded.suggestions(
      line: "curl", directory: "/project", sessionIdentifier: "session-a",
      controls: ControlConfiguration()
    ).candidates.allSatisfy { $0.kind != .learnedCommand && $0.kind != .snippet }
  )
}

@Test("关闭本地学习后仅保留规格候选且不读取 README")
@MainActor
func autocompleteServiceDisablesAllLocalLearningSources() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let project = directory.appendingPathComponent("project", isDirectory: true)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  try "```bash\nswift test\n```\n".write(
    to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
  let service = try AutocompleteService(
    baseDirectory: directory.appendingPathComponent("state", isDirectory: true),
    bundledSpecURL: repositoryAutocompleteSpecURL
  )
  _ = service.record(
    command: "git status", directory: project.path, exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session-a")
  var controls = ControlConfiguration()
  controls.autocompleteOnDeviceLearning = false

  // 用 "git" 而不是空 prompt：空行不再产生任何候选，规格候选也要靠前缀才出现。
  let result = service.suggestions(
    line: "git", directory: project.path, sessionIdentifier: "session-a", controls: controls)

  #expect(result.candidates.contains { $0.kind == .command })
  #expect(!result.candidates.contains { $0.insertText == "git status" })
  #expect(!result.candidates.contains { $0.insertText == "swift test" })
}

@Test("README 扫描拒绝符号链接和超限文件")
@MainActor
func autocompleteServiceReadsOnlySafeReadmeFiles() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let external = directory.appendingPathComponent("external.md")
  try "```sh\necho unsafe\n```".write(to: external, atomically: true, encoding: .utf8)
  let project = directory.appendingPathComponent("project", isDirectory: true)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: project.appendingPathComponent("README.md"), withDestinationURL: external)
  let service = try AutocompleteService(
    baseDirectory: directory.appendingPathComponent("state", isDirectory: true),
    bundledSpecURL: repositoryAutocompleteSpecURL
  )

  #expect(service.readmeCommands(in: project.path).isEmpty)

  try FileManager.default.removeItem(at: project.appendingPathComponent("README.md"))
  try Data(repeating: 0x41, count: AutocompleteService.maximumReadmeBytes + 1)
    .write(to: project.appendingPathComponent("README.md"))
  #expect(service.readmeCommands(in: project.path).isEmpty)
}

@Test("手动 Fig 更新保留本地 help 规格且不改写学习库")
@MainActor
func autocompleteServiceManualUpdatePreservesLocalSpecs() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let service = try AutocompleteService(
    baseDirectory: directory,
    bundledSpecURL: repositoryAutocompleteSpecURL
  )
  try service.installLocalSpec(
    AutocompleteCommandSpec(
      name: "acme", subcommands: [AutocompleteCommandSpec(name: "deploy")]))
  _ = service.record(
    command: "acme deploy", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session-a")
  let payload = Data(
    """
    {"schemaVersion":2,"sourceRevision":"manual-revision","commands":[
      {"name":"git","subcommands":[{"name":"status"}]},
      {"name":"new-cli"}
    ]}
    """.utf8)

  try service.applyFigUpdatePayload(payload, minimumCommandCount: 2)

  #expect(service.specDatabase.sourceRevision == "manual-revision")
  #expect(
    service.specDatabase.commands.first(where: { $0.name == "acme" })?
      .subcommands.map(\.name) == ["deploy"]
  )
  #expect(
    service.suggestions(
      line: "acme", directory: "/project", sessionIdentifier: "session-a",
      controls: ControlConfiguration()
    ).candidates.contains { $0.insertText == "acme deploy" }
  )
}

@Test("文件参数补全区分普通文件与目录并进行 Shell 转义")
@MainActor
func autocompleteServiceCompletesSafeFileArguments() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let project = directory.appendingPathComponent("project", isDirectory: true)
  try FileManager.default.createDirectory(
    at: project.appendingPathComponent("My Folder", isDirectory: true),
    withIntermediateDirectories: true)
  try Data().write(to: project.appendingPathComponent("demo.txt"))
  try Data().write(to: project.appendingPathComponent(".hidden"))
  let service = try AutocompleteService(
    baseDirectory: directory.appendingPathComponent("state", isDirectory: true),
    bundledSpecURL: repositoryAutocompleteSpecURL
  )

  let files = service.suggestions(
    line: "cat d", directory: project.path, sessionIdentifier: "session",
    controls: ControlConfiguration())
  let folders = service.suggestions(
    line: "cd My", directory: project.path, sessionIdentifier: "session",
    controls: ControlConfiguration())

  #expect(files.candidates.contains { $0.insertText == "demo.txt" && $0.kind == .file })
  #expect(folders.candidates.contains { $0.insertText == "My\\ Folder/" && $0.kind == .folder })
  #expect(!files.candidates.contains { $0.insertText.contains(".hidden") })
}

@Test("未知命令 help 探测使用网络沙箱和最小环境生成本地规格")
func autocompleteHelpProbeParsesSandboxedExecutable() async throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appendingPathComponent("acme")
  let sideEffect = directory.appendingPathComponent("probe-side-effect")
  let script = """
    #!/bin/sh
    printf 'must not exist' > "$HOME/probe-side-effect"
    printf 'Commands:\n  deploy  %s\nOptions:\n  --help  Show help\n' "${API_TOKEN:-safe}"
    """
  try script.write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

  let spec = await AutocompleteHelpProbe.probe(
    command: "acme",
    environment: [
      "PATH": directory.path,
      "HOME": directory.path,
      "API_TOKEN": "must-not-leak",
    ]
  )

  #expect(spec?.subcommands.map(\.name) == ["deploy"])
  #expect(spec?.subcommands.first?.description.english == "safe")
  #expect(spec?.options.map(\.name) == ["--help"])
  #expect(!FileManager.default.fileExists(atPath: sideEffect.path))
}

@Test("aster learn URL 必须携带私有 token 才能固定目录命令")
@MainActor
func autocompleteServiceAuthenticatesLearnURL() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let service = try AutocompleteService(
    baseDirectory: directory,
    bundledSpecURL: repositoryAutocompleteSpecURL
  )
  let commandHex = Data("npm run deploy".utf8).map { String(format: "%02x", $0) }.joined()
  let directoryHex = Data("/project".utf8).map { String(format: "%02x", $0) }.joined()
  let invalid = URL(
    string: "aster://learn?token=invalid&command=\(commandHex)&directory=\(directoryHex)")!
  let valid = URL(
    string: "aster://learn?token=\(service.cliToken)&command=\(commandHex)&directory=\(directoryHex)")!

  #expect(service.handleLearnURL(invalid) == .rejected)
  #expect(service.handleLearnURL(valid) == .learned)
  #expect(
    service.suggestions(
      line: "npm", directory: "/project", sessionIdentifier: "session",
      controls: ControlConfiguration()
    ).candidates.first?.insertText == "npm run deploy"
  )
  #expect(
    try String(contentsOf: directory.appendingPathComponent("cli-token"), encoding: .utf8)
      == service.cliToken
  )
  let tokenAttributes = try FileManager.default.attributesOfItem(
    atPath: directory.appendingPathComponent("cli-token").path)
  #expect((tokenAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test("安装的 aster CLI 脚本通过 POSIX sh 语法检查")
@MainActor
func asterCLIScriptIsSyntacticallyValid() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = directory.appendingPathComponent("aster")
  try AsterCLIScript.contents.write(to: script, atomically: true, encoding: .utf8)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-n", script.path]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()

  #expect(process.terminationStatus == 0)
  #expect(AsterCLIScript.contents.contains("ASTER_CLI_REQUEST_V1"))
  #expect(AsterCLIScript.contents.contains("requests_directory=\"$state_directory/requests\""))
  #expect(!AsterCLIScript.contents.contains("aster://learn?token="))
  #expect(AsterCLIScript.contents.contains("/usr/bin/xxd -p"))
  #expect(AsterCLIScript.contents.contains("9;4;5;%s;watch"))
  #expect(AsterCLIScript.contents.contains("6974;Badge=%s"))
  #expect(AutocompleteService.figSpecsURL.absoluteString.hasSuffix("/Resources/autocomplete/fig-specs.json"))
}

@Test("aster watch 保留命令退出码并发送开始与完成状态")
@MainActor
func asterCLIWatchReportsProgressAndExitStatus() throws {
  let directory = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = directory.appendingPathComponent("aster")
  try AsterCLIScript.contents.write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  let pipe = Pipe()
  let process = Process()
  process.executableURL = script
  process.arguments = ["watch", "/bin/sh", "-c", "exit 7"]
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

  #expect(process.terminationStatus == 7)
  #expect(output.contains("\u{1B}]9;4;3\u{7}"))
  #expect(output.contains("\u{1B}]9;4;5;7;watch\u{7}"))
}

/// 记录每个来源被真正读了几次，用于验证缓存生效。
private final class SpyDynamicReader: AutocompleteDynamicReader, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var callCount = 0
  var items: [AutocompleteDynamicItem] = []

  func items(
    for source: AutocompleteDynamicSource, directory: String
  ) -> [AutocompleteDynamicItem] {
    lock.lock()
    defer { lock.unlock() }
    callCount += 1
    return items
  }
}

@Test("help 探测挑最深的不完整层级，完整的层级不产生任何探测")
@MainActor
func autocompleteServiceProbesDeepestIncompleteSubcommand() throws {
  let state = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: state) }
  let service = try AutocompleteService(
    baseDirectory: state, bundledSpecURL: repositoryAutocompleteSpecURL)

  // 内置规格里 docker 有 58 个子命令但 0 个选项 → 顶层不完整。
  #expect(
    service.helpProbeTarget(for: "docker ")
      == AutocompleteService.HelpProbeTarget(command: "docker", subcommandPath: []))
  // `docker compose` 是个只有名字的壳子 → 探测这一层，而不是顶层。
  #expect(
    service.helpProbeTarget(for: "docker compose ")
      == AutocompleteService.HelpProbeTarget(command: "docker", subcommandPath: ["compose"]))
  // 完全没有规格的命令探测顶层。
  #expect(
    service.helpProbeTarget(for: "zzzznosuch ")
      == AutocompleteService.HelpProbeTarget(command: "zzzznosuch", subcommandPath: []))
  // 选项 token 不参与下钻。
  #expect(service.helpProbeTarget(for: "docker --debug ")?.subcommandPath == [])
}

@Test("子命令探测结果挂到规格树对应位置，不变成顶层命令")
@MainActor
func autocompleteServiceAttachesProbedSubcommandSpec() throws {
  let state = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: state) }
  let service = try AutocompleteService(
    baseDirectory: state, bundledSpecURL: repositoryAutocompleteSpecURL)

  try service.installLocalSpec(
    AutocompleteCommandSpec(
      name: "compose",
      subcommands: [AutocompleteCommandSpec(name: "up", description: .init(english: "Start"))],
      options: [AutocompleteOptionSpec(names: ["--profile"], description: "Profile")]),
    command: "docker", subcommandPath: ["compose"])

  // 不能凭空多出一条叫 compose 的顶层命令。
  #expect(service.specDatabase.command(named: "compose") == nil)
  let result = service.suggestions(
    line: "docker compose u",
    directory: state.path,
    sessionIdentifier: "session",
    controls: ControlConfiguration()
  )
  #expect(result.candidates.contains { $0.insertText == "up" && $0.kind == .subcommand })

  // 内置规格里 docker 原有的 58 个子命令不能被这次挂载冲掉。
  #expect((service.specDatabase.command(named: "docker")?.subcommands.count ?? 0) >= 58)
}

@Test("ignore 能撤销固定命令与本机 help 规格，但不动内置规格")
@MainActor
func autocompleteServiceIgnoreUndoesLearnedItems() throws {
  let state = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: state) }
  let service = try AutocompleteService(
    baseDirectory: state, bundledSpecURL: repositoryAutocompleteSpecURL)
  let directory = state.path

  // 固定命令：learn → ignore 往返。
  #expect(service.pin(command: "npm run deploy", directory: directory))
  #expect(service.isPinned(command: "npm run deploy", directory: directory))
  #expect(service.unpin(command: "npm run deploy", directory: directory))
  #expect(!service.isPinned(command: "npm run deploy", directory: directory))
  let unpinAgain = service.unpin(command: "npm run deploy", directory: directory)
  #expect(!unpinAgain)

  // 本机 help 规格：learn <binary> → ignore <binary> 往返。
  #expect(!service.hasLocalSpec(named: "acme"))
  try service.installLocalSpec(
    AutocompleteCommandSpec(
      name: "acme", subcommands: [AutocompleteCommandSpec(name: "deploy")]))
  #expect(service.hasLocalSpec(named: "acme"))
  #expect(service.removeLocalSpec(named: "acme"))
  #expect(!service.hasLocalSpec(named: "acme"))
  #expect(service.specDatabase.command(named: "acme") == nil)
  let removeAgain = service.removeLocalSpec(named: "acme")
  #expect(!removeAgain)

  // 内置规格不是用户学出来的，ignore 绝不能删掉它——删了也无法恢复。
  #expect(service.specDatabase.command(named: "git") != nil)
  #expect(!service.hasLocalSpec(named: "git"))
  let removeBundled = service.removeLocalSpec(named: "git")
  #expect(!removeBundled)
  #expect(service.specDatabase.command(named: "git") != nil)
}

@Test("ignore 一个二进制只删本机规格，不影响同名的内置结构")
@MainActor
func autocompleteServiceIgnoreKeepsBundledStructureForProbedCommand() throws {
  let state = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: state) }
  let service = try AutocompleteService(
    baseDirectory: state, bundledSpecURL: repositoryAutocompleteSpecURL)
  let bundledSubcommands = service.specDatabase.command(named: "docker")?.subcommands.count ?? 0
  #expect(bundledSubcommands >= 58)

  // 模拟一次 `aster learn docker` 的探测结果落地。
  try service.installLocalSpec(
    AutocompleteCommandSpec(
      name: "docker",
      options: [AutocompleteOptionSpec(names: ["--tlsverify"], description: "TLS")]))
  #expect(
    service.specDatabase.command(named: "docker")?.options.contains { $0.names.contains("--tlsverify") }
      == true)

  // 撤销后本机补充的选项消失，内置的 58 个子命令原样保留。
  #expect(service.removeLocalSpec(named: "docker"))
  #expect(service.specDatabase.command(named: "docker")?.options.isEmpty == true)
  #expect(service.specDatabase.command(named: "docker")?.subcommands.count == bundledSubcommands)
}

@Test("补全 git 分支时从磁盘读取引用，绝不运行 git")
@MainActor
func autocompleteServiceCompletesGitBranchesWithoutRunningGit() throws {
  let state = try makeAutocompleteTemporaryDirectory()
  let project = try makeAutocompleteTemporaryDirectory()
  defer {
    try? FileManager.default.removeItem(at: state)
    try? FileManager.default.removeItem(at: project)
  }
  // 只在磁盘上摆出真实的 .git 布局；测试进程里没有任何 git 可执行文件参与。
  let git = project.appendingPathComponent(".git")
  try FileManager.default.createDirectory(
    at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
  try "ref: refs/heads/main\n".write(
    to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
  for branch in ["main", "master-fix"] {
    try "".write(
      to: git.appendingPathComponent("refs/heads/\(branch)"), atomically: true, encoding: .utf8)
  }

  let service = try AutocompleteService(
    baseDirectory: state, bundledSpecURL: repositoryAutocompleteSpecURL)
  let result = service.suggestions(
    line: "git checkout ma",
    directory: project.path,
    sessionIdentifier: "session",
    controls: ControlConfiguration()
  )
  let dynamic = result.candidates.filter { $0.kind == .dynamicArgument }
  #expect(dynamic.map(\.insertText).contains("master-fix"))
  #expect(dynamic.map(\.insertText).contains("main"))
}

@Test("动态候选按见证文件缓存，文件不变时不重复读盘")
@MainActor
func autocompleteServiceCachesDynamicCandidatesUntilWitnessChanges() throws {
  let project = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: project) }
  try "{}".write(
    to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

  let spy = SpyDynamicReader()
  spy.items = [AutocompleteDynamicItem(name: "build")]
  let cache = AutocompleteDynamicCache(reader: spy)
  let now = Date()

  #expect(cache.items(for: .npmScripts, directory: project.path, now: now).count == 1)
  #expect(cache.items(for: .npmScripts, directory: project.path, now: now).count == 1)
  #expect(spy.callCount == 1, "见证文件未变时不应重复读盘")

  // 见证文件变化后必须重新读取。
  try #"{"scripts":{"build":"x"}}"#.write(
    to: project.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
  _ = cache.items(for: .npmScripts, directory: project.path, now: now)
  #expect(spy.callCount == 2)

  // 目录 mtime 不随子目录内文件变化更新，因此硬 TTL 也必须能触发重读。
  _ = cache.items(for: .npmScripts, directory: project.path, now: now.addingTimeInterval(10))
  #expect(spy.callCount == 3)
}

@Test("PATH 从磁盘重建，覆盖 Finder 启动时缺失的用户目录")
func autocompleteHelpProbeRebuildsSearchPathFromDisk() {
  // Finder 启动的 App 继承不到用户 shell 的 PATH；重建结果必须至少包含系统
  // /etc/paths 里的条目和常见的 Homebrew 目录。
  let path = AutocompleteHelpProbe.searchPath(environment: ["PATH": "/custom/bin"])
  let directories = path.split(separator: ":").map(String.init)
  #expect(directories.first == "/custom/bin", "调用方 PATH 优先")
  #expect(directories.contains("/usr/bin"))
  #expect(directories.contains("/opt/homebrew/bin"))
  #expect(Set(directories).count == directories.count, "不得出现重复条目")
  #expect(directories.count <= 128)
  #expect(directories.allSatisfy { $0.hasPrefix("/") })
}

@Test("探测得到的二进制规格写入本地库并参与补全")
@MainActor
func autocompleteServiceInstallsProbedBinarySpec() throws {
  let state = try makeAutocompleteTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: state) }
  let service = try AutocompleteService(
    baseDirectory: state, bundledSpecURL: repositoryAutocompleteSpecURL)
  #expect(!service.containsDetailedSpec(for: "acme"))

  try service.installLocalSpec(
    AutocompleteCommandSpec(
      name: "acme",
      subcommands: [AutocompleteCommandSpec(name: "deploy", description: .init(english: "Ship it"))],
      options: [AutocompleteOptionSpec(names: ["--verbose"], description: "Chatty")]))

  #expect(service.containsDetailedSpec(for: "acme"))
  let result = service.suggestions(
    line: "acme de",
    directory: state.path,
    sessionIdentifier: "session",
    controls: ControlConfiguration()
  )
  #expect(result.candidates.contains { $0.insertText == "deploy" && $0.kind == .subcommand })
}

private var repositoryAutocompleteSpecURL: URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/autocomplete/fig-specs.json")
}

private func makeAutocompleteTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-autocomplete-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
