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
  let result = reloaded.suggestions(
    line: "",
    directory: "/project",
    sessionIdentifier: "session-a",
    controls: ControlConfiguration()
  )

  #expect(result.candidates.contains { $0.insertText == "curl https://example.test" })
  #expect(!result.candidates.contains { $0.insertText.contains("private-value") })
  try reloaded.clearLearning()
  #expect(
    reloaded.suggestions(
      line: "", directory: "/project", sessionIdentifier: "session-a",
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

  let result = service.suggestions(
    line: "", directory: project.path, sessionIdentifier: "session-a", controls: controls)

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
      name: "acme", subcommands: [AutocompleteSpecItem(name: "deploy")]))
  _ = service.record(
    command: "acme deploy", directory: "/project", exitStatus: 0,
    ignorePatterns: [], knownOptions: [], sessionIdentifier: "session-a")
  let payload = Data(
    """
    {"sha":"manual-revision","truncated":false,"tree":[
      {"path":"src/git.ts","type":"blob"},
      {"path":"src/new-cli.ts","type":"blob"}
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
      line: "", directory: "/project", sessionIdentifier: "session-a",
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
  #expect(spec?.subcommands.first?.description == "safe")
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
      line: "", directory: "/project", sessionIdentifier: "session",
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
  #expect(AutocompleteService.figTreeURL.absoluteString.contains("/trees/master?recursive=1"))
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
