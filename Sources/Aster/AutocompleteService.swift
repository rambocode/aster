import AsterCore
import Darwin
import Foundation
import Security

enum AutocompleteServiceError: Error, LocalizedError, Equatable {
  case invalidStateDirectory
  case unsafeStateFile(String)
  case bundledDatabaseUnavailable
  case updateResponseInvalid
  case tokenUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidStateDirectory: "Autocomplete 状态目录不可用。"
    case .unsafeStateFile(let path): "拒绝读取或覆盖非普通状态文件：\(path)"
    case .bundledDatabaseUnavailable: "找不到有效的内置 Autocomplete 规格。"
    case .updateResponseInvalid: "Fig 规格更新响应无效。"
    case .tokenUnavailable: "无法创建安全的 Aster CLI token。"
    }
  }
}

enum AutocompleteLearnURLResult: Equatable {
  case notHandled
  case rejected
  case learned
}

/// 设置页安装的 POSIX sh 启动器。保持为单一常量，便于代码测试执行 `sh -n`。
/// `watch` 与标签徽章直接操作当前 TTY；其余参数按原边界编码到私有 requests
/// 目录，并同步等待应用响应，不通过 URL、网络或 socket 传输命令内容。
enum AsterCLIScript {
  static let contents = #"""
    #!/bin/sh
    # Aster CLI 启动器：任务包装和标签徽章直接写当前 TTY，其余动作交给本机文件传输。
    if [ "${1-}" = "watch" ]; then
      shift
      quiet=0
      if [ "${1-}" = "-q" ] || [ "${1-}" = "--quiet" ]; then
        quiet=1
        shift
      fi
      if [ "$#" -eq 0 ]; then
        echo "usage: aster watch [-q|--quiet] <command> [args ...]" >&2
        exit 64
      fi
      printf '\033]9;4;3\007'
      "$@"
      status=$?
      if [ "$quiet" -eq 1 ]; then
        printf '\033]9;4;5;%s;watch;quiet\007' "$status"
      else
        printf '\033]9;4;5;%s;watch\007' "$status"
      fi
      exit "$status"
    fi
    if [ "${1-}" = "tab" ] && [ "${2-}" = "badge" ]; then
      shift 2
      if [ "${1-}" = "--clear" ]; then
        printf '\033]6974;Badge=clear\007'
        exit 0
      fi
      if [ "${1-}" != "--kind" ] || [ "$#" -ne 2 ]; then
        echo "usage: aster tab badge --kind running|completed|finished|unread|error|awaiting-input" >&2
        echo "       aster tab badge --clear" >&2
        exit 64
      fi
      case "$2" in
        running|completed|finished|unread|error|awaiting-input)
          printf '\033]6974;Badge=%s\007' "$2"
          exit 0
          ;;
        *)
          echo "aster: invalid badge kind: $2" >&2
          exit 64
          ;;
      esac
    fi

    umask 077
    state_directory="$HOME/Library/Application Support/Aster/Autocomplete"
    token_file="$state_directory/cli-token"
    requests_directory="$state_directory/requests"
    ready_file="$state_directory/cli-server-ready"
    current_uid=$(/usr/bin/id -u)

    server_is_ready() {
      [ -f "$token_file" ] && [ -r "$token_file" ] && [ ! -L "$token_file" ] || return 1
      [ -d "$requests_directory" ] && [ ! -L "$requests_directory" ] || return 1
      [ -f "$ready_file" ] && [ -r "$ready_file" ] && [ ! -L "$ready_file" ] || return 1
      [ "$(/usr/bin/stat -f '%u:%Lp' "$token_file" 2>/dev/null)" = "$current_uid:600" ] || return 1
      [ "$(/usr/bin/stat -f '%u:%Lp' "$requests_directory" 2>/dev/null)" = "$current_uid:700" ] || return 1
      [ "$(/usr/bin/stat -f '%u:%Lp' "$ready_file" 2>/dev/null)" = "$current_uid:600" ] || return 1
      server_pid=$(/bin/cat "$ready_file" 2>/dev/null)
      case "$server_pid" in
        ''|*[!0-9]*) return 1 ;;
      esac
      /bin/kill -0 "$server_pid" 2>/dev/null
    }

    if ! server_is_ready; then
      /usr/bin/open -gj -a "Aster" >/dev/null 2>&1 || true
      attempts=0
      while ! server_is_ready && [ "$attempts" -lt 50 ]; do
        /bin/sleep 0.1
        attempts=$((attempts + 1))
      done
    fi
    if ! server_is_ready; then
      echo "aster: Aster CLI service is unavailable; launch Aster once and retry" >&2
      exit 69
    fi

    token=$(/bin/cat "$token_file" 2>/dev/null)
    if [ "${#token}" -ne 64 ]; then
      echo "aster: Aster CLI token is invalid" >&2
      exit 77
    fi
    case "$token" in
      *[!0-9a-f]*)
        echo "aster: Aster CLI token is invalid" >&2
        exit 77
        ;;
    esac
    if [ "$#" -gt 256 ]; then
      echo "aster: too many CLI arguments" >&2
      exit 64
    fi

    # 只有 `pane send-text --stdin` 消费 stdin。其它命令即使把 `--stdin` 作为被执行
    # 命令参数，也不会被启动器提前读取，参数语义仍完全交给 WorkflowCLIParser。
    reads_stdin=0
    scan_state=global
    skip_global_value=0
    for argument do
      if [ "$skip_global_value" -eq 1 ]; then
        skip_global_value=0
        continue
      fi
      case "$scan_state:$argument" in
        global:otty) ;;
        global:--format) skip_global_value=1 ;;
        global:--json|global:-q|global:--quiet) ;;
        global:pane) scan_state=pane ;;
        global:*) scan_state=other ;;
        pane:send-text) scan_state=send-text ;;
        pane:*) scan_state=other ;;
        send-text:--stdin) reads_stdin=1 ;;
      esac
    done

    temporary=$(/usr/bin/mktemp "$requests_directory/.request.XXXXXXXXXX") || {
      echo "aster: cannot create CLI request" >&2
      exit 73
    }
    temporary_name=${temporary##*/}
    request_id=${temporary_name#.request.}
    request_file="$requests_directory/$request_id.request"
    response_file="$requests_directory/$request_id.response"
    stdin_file="$temporary.stdin"
    cleanup() {
      /bin/rm -f "$temporary" "$stdin_file" "$request_file" "$response_file"
    }
    trap cleanup 0 1 2 15

    stdin_hex=
    if [ "$reads_stdin" -eq 1 ]; then
      /bin/dd bs=1048577 count=1 of="$stdin_file" 2>/dev/null
      stdin_size=$(/usr/bin/stat -f '%z' "$stdin_file" 2>/dev/null)
      case "$stdin_size" in
        ''|*[!0-9]*)
          echo "aster: cannot read standard input" >&2
          exit 74
          ;;
      esac
      if [ "$stdin_size" -gt 1048576 ]; then
        echo "aster: standard input exceeds 1048576 bytes" >&2
        exit 64
      fi
      stdin_hex=$(/usr/bin/xxd -p "$stdin_file" | /usr/bin/tr -d '\n')
    fi

    {
      printf 'ASTER_CLI_REQUEST_V1\n'
      printf '%s\n' "$token"
      printf '%s' "$PWD" | /usr/bin/xxd -p | /usr/bin/tr -d '\n'
      printf '\n%s\n%s\n' "$stdin_hex" "$#"
      for argument do
        printf '%s' "$argument" | /usr/bin/xxd -p | /usr/bin/tr -d '\n'
        printf '\n'
      done
    } > "$temporary" || {
      echo "aster: cannot encode CLI request" >&2
      exit 74
    }
    request_size=$(/usr/bin/stat -f '%z' "$temporary" 2>/dev/null)
    case "$request_size" in
      ''|*[!0-9]*)
        echo "aster: cannot inspect CLI request" >&2
        exit 74
        ;;
    esac
    if [ "$request_size" -gt 3145728 ]; then
      echo "aster: CLI request exceeds size limit" >&2
      exit 64
    fi
    /bin/chmod 600 "$temporary" || exit 74
    /bin/mv "$temporary" "$request_file" || exit 74

    attempts=0
    while [ ! -e "$response_file" ] && [ "$attempts" -lt 3000 ]; do
      /bin/sleep 0.1
      attempts=$((attempts + 1))
    done
    if [ ! -f "$response_file" ] || [ -L "$response_file" ]; then
      echo "aster: timed out waiting for Aster CLI response" >&2
      exit 75
    fi
    if [ "$(/usr/bin/stat -f '%u:%Lp' "$response_file" 2>/dev/null)" != "$current_uid:600" ]; then
      echo "aster: insecure Aster CLI response" >&2
      exit 74
    fi
    response_size=$(/usr/bin/stat -f '%z' "$response_file" 2>/dev/null)
    case "$response_size" in
      ''|*[!0-9]*)
        echo "aster: invalid Aster CLI response" >&2
        exit 74
        ;;
    esac
    if [ "$response_size" -gt 8389632 ]; then
      echo "aster: Aster CLI response exceeds size limit" >&2
      exit 74
    fi

    {
      IFS= read -r response_magic
      IFS= read -r exit_code
      IFS= read -r stdout_hex
      IFS= read -r stderr_hex
    } < "$response_file"
    if [ "$response_magic" != "ASTER_CLI_RESPONSE_V1" ]; then
      echo "aster: invalid Aster CLI response" >&2
      exit 74
    fi
    case "$exit_code" in
      ''|*[!0-9]*)
        echo "aster: invalid Aster CLI exit code" >&2
        exit 74
        ;;
    esac
    if [ "$exit_code" -gt 255 ]; then
      echo "aster: invalid Aster CLI exit code" >&2
      exit 74
    fi
    case "$stdout_hex$stderr_hex" in
      *[!0-9a-f]*)
        echo "aster: invalid Aster CLI response encoding" >&2
        exit 74
        ;;
    esac
    printf '%s' "$stdout_hex" | /usr/bin/xxd -r -p
    printf '%s' "$stderr_hex" | /usr/bin/xxd -r -p >&2
    trap - 0 1 2 15
    cleanup
    exit "$exit_code"

    """#
}

/// 未知本机命令的 help 探测器。只从 PATH 解析一个可执行文件，只尝试固定的 help
/// 参数，并通过 macOS sandbox-exec 禁止全部网络访问。用户环境按 allowlist 重建，
/// API token、云凭证等不会被隐式传给被探测进程。
enum AutocompleteHelpProbe {
  private static let maximumOutputBytes = 128 * 1_024
  private static let timeout: TimeInterval = 2.5
  // help 文本本应为纯读取操作；拒绝网络和文件写入，避免第三方 CLI 的 `--help`
  // 实现产生更新、遥测、缓存或其它用户可见副作用。
  private static let sandboxProfile =
    "(version 1)(allow default)(deny network*)(deny file-write*)"

  static func probe(
    command: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> AutocompleteCommandSpec? {
    await Task.detached(priority: .utility) {
      probeSynchronously(command: command, environment: environment)
    }.value
  }

  private static func probeSynchronously(
    command: String,
    environment: [String: String]
  ) -> AutocompleteCommandSpec? {
    guard isSafeCommandName(command),
      FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
      let executable = resolveExecutable(command, path: environment["PATH"] ?? "/usr/bin:/bin")
    else { return nil }

    for arguments in [["--help"], ["-h"], ["help"]] {
      guard let output = run(
        executable: executable,
        arguments: arguments,
        environment: minimalEnvironment(from: environment)
      ) else { continue }
      if let spec = HelpAutocompleteSpecParser.parse(command: command, output: output) {
        return spec
      }
    }
    return nil
  }

  private static func resolveExecutable(_ command: String, path: String) -> URL? {
    for directory in path.split(separator: ":").prefix(128) {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
        .appendingPathComponent(command).resolvingSymlinksInPath()
      guard candidate.path.utf8.count <= 4_096,
        FileManager.default.isExecutableFile(atPath: candidate.path),
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
        values.isRegularFile == true
      else { continue }
      return candidate
    }
    return nil
  }

  private static func run(
    executable: URL,
    arguments: [String],
    environment: [String: String]
  ) -> String? {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "aster-help-probe-\(UUID().uuidString)", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch {
      return nil
    }
    defer { try? fileManager.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("output")
    guard fileManager.createFile(atPath: outputURL.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: outputURL)
    else { return nil }
    defer { try? handle.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments = ["-p", sandboxProfile, executable.path] + arguments
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    do {
      try process.run()
    } catch {
      return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      let size = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size > maximumOutputBytes { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.05)
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    try? handle.synchronize()
    guard let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maximumOutputBytes,
      let data = try? Data(contentsOf: outputURL)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func minimalEnvironment(from inherited: [String: String]) -> [String: String] {
    var result: [String: String] = [
      "PATH": inherited["PATH"] ?? "/usr/bin:/bin",
      "NO_COLOR": "1",
      "PAGER": "cat",
      "GIT_PAGER": "cat",
      "TERM": "dumb",
    ]
    for key in ["HOME", "LANG", "LC_ALL", "TMPDIR"] {
      if let value = inherited[key], value.utf8.count <= 4_096,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      {
        result[key] = value
      }
    }
    return result
  }

  private static func isSafeCommandName(_ command: String) -> Bool {
    guard !command.isEmpty, command.utf8.count <= 128 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
    return command.unicodeScalars.allSatisfy(allowed.contains)
  }
}

/// Autocomplete 的应用级边界：组合签名 Bundle 规格、用户手动更新、本地 help 规格、
/// README 和脱敏学习库。除 `updateNow()` 外不发起网络请求，也不会自动扫描项目脚本。
@MainActor
final class AutocompleteService {
  static let maximumReadmeBytes = 2 * 1_024 * 1_024
  static let figTreeURL = URL(
    string: "https://api.github.com/repos/withfig/autocomplete/git/trees/master?recursive=1")!

  private let baseDirectory: URL
  private let fileManager: FileManager
  private let learningURL: URL
  private let updatedSpecURL: URL
  private let localSpecURL: URL
  private let cliTokenURL: URL
  private var baseSpecDatabase: AutocompleteSpecDatabase
  private var localSpecDatabase: AutocompleteSpecDatabase
  private var learningDatabase: AutocompleteLearningDatabase

  private(set) var specDatabase: AutocompleteSpecDatabase
  private(set) var cliToken: String
  let cliRequestService: AsterCLIRequestService

  init(
    baseDirectory: URL,
    bundledSpecURL: URL,
    fileManager: FileManager = .default
  ) throws {
    self.baseDirectory = baseDirectory.standardizedFileURL
    self.fileManager = fileManager
    learningURL = self.baseDirectory.appendingPathComponent("learning.json")
    updatedSpecURL = self.baseDirectory.appendingPathComponent("fig-specs.json")
    localSpecURL = self.baseDirectory.appendingPathComponent("local-specs.json")
    cliTokenURL = self.baseDirectory.appendingPathComponent("cli-token")

    try Self.prepareStateDirectory(self.baseDirectory, fileManager: fileManager)
    cliToken = try Self.loadOrCreateCLIToken(at: cliTokenURL, fileManager: fileManager)
    cliRequestService = try AsterCLIRequestService(
      baseDirectory: self.baseDirectory,
      fileManager: fileManager
    )
    guard let bundledData = try? Self.readRegularFile(
      at: bundledSpecURL,
      maximumBytes: AutocompleteSpecStore.maximumEncodedBytes,
      fileManager: fileManager
    ), let bundled = try? AutocompleteSpecStore.decode(bundledData)
    else { throw AutocompleteServiceError.bundledDatabaseUnavailable }

    if let data = try? Self.readOptionalStateFile(
      at: updatedSpecURL,
      maximumBytes: AutocompleteSpecStore.maximumEncodedBytes,
      fileManager: fileManager
    ), let decoded = try? AutocompleteSpecStore.decode(data) {
      baseSpecDatabase = decoded
    } else {
      baseSpecDatabase = bundled
    }
    if let data = try? Self.readOptionalStateFile(
      at: localSpecURL,
      maximumBytes: AutocompleteSpecStore.maximumEncodedBytes,
      fileManager: fileManager
    ), let decoded = try? AutocompleteSpecStore.decode(data) {
      localSpecDatabase = decoded
    } else {
      localSpecDatabase = AutocompleteSpecDatabase(sourceRevision: "local", commands: [])
    }
    if let data = try? Self.readOptionalStateFile(
      at: learningURL,
      maximumBytes: AutocompleteLearningStore.maximumEncodedBytes,
      fileManager: fileManager
    ), let decoded = try? AutocompleteLearningStore.decode(data) {
      learningDatabase = decoded
    } else {
      learningDatabase = AutocompleteLearningDatabase()
    }
    specDatabase = Self.merged(base: baseSpecDatabase, local: localSpecDatabase)
  }

  /// 生产环境的惰性单例。测试可注入临时目录；`swift test`/`swift run` 使用进程级
  /// 临时状态，避免自动化写入真实用户的 Application Support。
  static let shared: AutocompleteService? = {
    let fileManager = FileManager.default
    let isPackagedApplication = Bundle.main.bundleURL.pathExtension == "app"
    let base: URL
    if isPackagedApplication,
      let support = try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true)
    {
      base = support.appendingPathComponent("Aster/Autocomplete", isDirectory: true)
    } else {
      base = fileManager.temporaryDirectory.appendingPathComponent(
        "Aster-Autocomplete-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
    guard let resources = AsterResourceLocations.resourcesDirectory(bundle: .main, fileManager: fileManager)
    else { return nil }
    return try? AutocompleteService(
      baseDirectory: base,
      bundledSpecURL: resources.appendingPathComponent("autocomplete/fig-specs.json"),
      fileManager: fileManager
    )
  }()

  func suggestions(
    line: String,
    directory: String,
    sessionIdentifier: String,
    controls: ControlConfiguration,
    aliases: [String] = []
  ) -> AutocompleteResult {
    let localLearningEnabled = controls.resolvedAutocompleteOnDeviceLearning
    let normalizedDirectory = directory.hasPrefix("/")
      ? URL(fileURLWithPath: directory).standardizedFileURL.path : ""
    let ranked = localLearningEnabled
      ? learningDatabase.suggestions(
        prefix: line,
        directory: normalizedDirectory,
        sessionIdentifier: sessionIdentifier
      ) : []
    let pinnedCommands = Set(
      learningDatabase.entries.lazy.filter {
        $0.directory == normalizedDirectory && $0.pinCount > 0
      }
        .map(\.command))
    let pinned = ranked.filter { pinnedCommands.contains($0.command) }
    let learned = ranked.filter { !pinnedCommands.contains($0.command) }
    let readme = localLearningEnabled ? readmeCommands(in: directory) : []
    let descriptionLanguage = controls.resolvedAutocompleteDescriptionLanguage.resolved(
      preferredLanguageIdentifiers: Locale.preferredLanguages)
    let base = AutocompleteEngine(specDatabase: specDatabase).suggestions(
      for: AutocompleteQuery(line: line, directory: directory),
      learned: learned,
      pinned: pinned,
      readmeCommands: readme,
      aliases: aliases,
      language: descriptionLanguage
    )
    let files = fileCandidates(for: line, directory: directory)
    guard !files.isEmpty else { return base }
    let existing = Set(base.candidates.map(\.insertText))
    let candidates = Array((base.candidates + files.filter { !existing.contains($0.insertText) }).prefix(200))
    guard base.candidates.isEmpty, let first = candidates.first else {
      return AutocompleteResult(
        candidates: candidates,
        ghostText: base.ghostText,
        replacementStart: base.replacementStart
      )
    }
    let parsed = ShellCommandTokenizer.tokenize(line)
    let ghost = first.insertText.hasPrefix(parsed.currentToken)
      ? String(first.insertText.dropFirst(parsed.currentToken.count)) : nil
    return AutocompleteResult(
      candidates: candidates,
      ghostText: ghost,
      replacementStart: parsed.currentTokenStart
    )
  }

  @discardableResult
  func record(
    command: String,
    directory: String,
    exitStatus: Int,
    ignorePatterns: [String],
    knownOptions: Set<String>,
    sessionIdentifier: String,
    at date: Date = Date()
  ) -> Bool {
    let previous = learningDatabase
    guard learningDatabase.complete(
      command: command,
      directory: directory,
      exitStatus: exitStatus,
      ignorePatterns: ignorePatterns,
      knownOptions: knownOptions,
      sessionIdentifier: sessionIdentifier,
      at: date
    ) else { return false }
    do {
      try persistLearning()
      return true
    } catch {
      learningDatabase = previous
      return false
    }
  }

  @discardableResult
  func pin(command: String, directory: String, at date: Date = Date()) -> Bool {
    let previous = learningDatabase
    guard learningDatabase.pin(command: command, directory: directory, at: date) else {
      return false
    }
    do {
      try persistLearning()
      return true
    } catch {
      learningDatabase = previous
      return false
    }
  }

  func clearLearning() throws {
    let previous = learningDatabase
    learningDatabase = AutocompleteLearningDatabase(capacity: previous.capacity)
    do {
      try persistLearning()
    } catch {
      learningDatabase = previous
      throw error
    }
  }

  func knownOptions(for command: String) -> Set<String> {
    Set(specDatabase.commands.first(where: { $0.name == command })?.options.map(\.name) ?? [])
  }

  /// 名称清单只能完成可执行文件本身；至少存在一种子项才算详细规格，否则允许
  /// 本地 help 探测补足 subcommand、option 或 argument。
  func containsDetailedSpec(for command: String) -> Bool {
    guard let spec = specDatabase.commands.first(where: { $0.name == command }) else {
      return false
    }
    return !spec.subcommands.isEmpty || !spec.options.isEmpty || !spec.arguments.isEmpty
  }

  /// `aster learn` 的本机 URL 入口。识别到 aster://learn 后无论成功与否都不再交给
  /// 通用 URL 打开逻辑；token 以常量时间比较，命令和目录使用严格有界 hex 解码。
  func handleLearnURL(_ url: URL) -> AutocompleteLearnURLResult {
    guard url.scheme?.lowercased() == "aster", url.host?.lowercased() == "learn" else {
      return .notHandled
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
      Self.constantTimeEqual(token, cliToken),
      let commandHex = components.queryItems?.first(where: { $0.name == "command" })?.value,
      let directoryHex = components.queryItems?.first(where: { $0.name == "directory" })?.value,
      let command = Self.decodeHex(commandHex, maximumBytes: 4_096),
      let directory = Self.decodeHex(directoryHex, maximumBytes: 4_096),
      pin(command: command, directory: directory)
    else { return .rejected }
    return .learned
  }

  /// 只读取当前目录中固定名称的普通 README 文件。符号链接、设备文件与超限文件
  /// 直接忽略，避免补全功能跨越用户看到的目录边界或阻塞在特殊文件上。
  func readmeCommands(in directory: String) -> [String] {
    guard directory.hasPrefix("/"), directory.utf8.count <= 4_096 else { return [] }
    for name in ["README.md", "README", "readme.md"] {
      let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
      guard let data = try? Self.readRegularFile(
        at: url, maximumBytes: Self.maximumReadmeBytes, fileManager: fileManager)
      else { continue }
      return ReadmeCommandScanner.commands(in: String(decoding: data, as: UTF8.self))
    }
    return []
  }

  /// 本地 help 规格独立保存并优先于 Fig 名称清单；手动更新远端清单时不会覆盖它。
  func installLocalSpec(_ spec: AutocompleteCommandSpec) throws {
    var commands = localSpecDatabase.commands.filter { $0.name != spec.name }
    commands.append(spec)
    commands.sort { $0.name < $1.name }
    let updated = AutocompleteSpecDatabase(sourceRevision: "local", commands: commands)
    let data = try AutocompleteSpecStore.encode(updated)
    try Self.writeStateFile(data, to: localSpecURL, fileManager: fileManager)
    localSpecDatabase = updated
    specDatabase = Self.merged(base: baseSpecDatabase, local: localSpecDatabase)
  }

  /// 应用用户显式触发的 Fig tree 更新。该入口不接触本地规格和命令学习文件。
  func applyFigUpdatePayload(_ data: Data, minimumCommandCount: Int = 100) throws {
    let updated = try FigAutocompleteUpdateParser.database(
      from: data,
      preserving: baseSpecDatabase,
      minimumCommandCount: minimumCommandCount
    )
    let encoded = try AutocompleteSpecStore.encode(updated)
    try Self.writeStateFile(encoded, to: updatedSpecURL, fileManager: fileManager)
    baseSpecDatabase = updated
    specDatabase = Self.merged(base: baseSpecDatabase, local: localSpecDatabase)
  }

  /// 唯一联网入口，由设置页“立即更新”按钮调用。下载先落到 URLSession 临时文件，
  /// 检查 HTTP 状态和大小后才读入内存，避免 chunked 响应绕过 Content-Length。
  func updateNow(session: URLSession = .shared) async throws -> String {
    var request = URLRequest(url: Self.figTreeURL)
    request.timeoutInterval = 30
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("AsterTerminal", forHTTPHeaderField: "User-Agent")
    let (downloadURL, response) = try await session.download(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw AutocompleteServiceError.updateResponseInvalid
    }
    let data = try Self.readRegularFile(
      at: downloadURL,
      maximumBytes: AutocompleteSpecStore.maximumEncodedBytes,
      fileManager: fileManager
    )
    try applyFigUpdatePayload(data)
    return baseSpecDatabase.sourceRevision
  }

  private func persistLearning() throws {
    let data = try AutocompleteLearningStore.encode(learningDatabase)
    try Self.writeStateFile(data, to: learningURL, fileManager: fileManager)
  }

  /// 第二个及后续 token 才查询文件系统；首 token 始终由命令规格负责。目录枚举有
  /// 500 项上限，且只读取目录项元数据，不打开候选文件。
  private func fileCandidates(for line: String, directory: String) -> [AutocompleteCandidate] {
    let parsed = ShellCommandTokenizer.tokenize(line)
    guard parsed.tokens.count >= 2 || line.last?.isWhitespace == true && !parsed.tokens.isEmpty,
      !parsed.currentToken.hasPrefix("-"), directory.hasPrefix("/")
    else { return [] }

    let token = parsed.currentToken
    let tokenPath = token.replacingOccurrences(of: "\\ ", with: " ")
    let slash = tokenPath.lastIndex(of: "/")
    let typedDirectory = slash.map { String(tokenPath[...$0]) } ?? ""
    let namePrefix = slash.map { String(tokenPath[tokenPath.index(after: $0)...]) } ?? tokenPath
    let lookupDirectory: String
    if typedDirectory.hasPrefix("/") {
      lookupDirectory = typedDirectory
    } else if typedDirectory.hasPrefix("~/") {
      lookupDirectory = NSString(string: typedDirectory).expandingTildeInPath
    } else {
      lookupDirectory = URL(fileURLWithPath: directory)
        .appendingPathComponent(typedDirectory).standardizedFileURL.path
    }
    guard let urls = try? fileManager.contentsOfDirectory(
      at: URL(fileURLWithPath: lookupDirectory),
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsSubdirectoryDescendants]
    ) else { return [] }

    return urls.lazy
      .filter { namePrefix.hasPrefix(".") || !$0.lastPathComponent.hasPrefix(".") }
      .filter { $0.lastPathComponent.hasPrefix(namePrefix) }
      .prefix(500)
      .compactMap { url -> AutocompleteCandidate? in
        let name = url.lastPathComponent
        guard name.utf8.count <= 1_024,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        guard let values = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]), values.isDirectory == true || values.isRegularFile == true || values.isSymbolicLink == true
        else { return nil }
        let escapedName = Self.shellEscaped(name)
        let suffix = values.isDirectory == true ? "/" : ""
        return AutocompleteCandidate(
          insertText: typedDirectory + escapedName + suffix,
          description: values.isDirectory == true ? "目录" : "文件",
          kind: values.isDirectory == true ? .folder : .file,
          score: values.isDirectory == true ? 80_000 : 75_000
        )
      }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.insertText.localizedStandardCompare($1.insertText) == .orderedAscending
      }
  }

  private static func shellEscaped(_ value: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+@%"))
    return value.unicodeScalars.map { scalar in
      safe.contains(scalar) ? String(scalar) : "\\" + String(scalar)
    }.joined()
  }

  private static func merged(
    base: AutocompleteSpecDatabase,
    local: AutocompleteSpecDatabase
  ) -> AutocompleteSpecDatabase {
    let localNames = Set(local.commands.map(\.name))
    return AutocompleteSpecDatabase(
      sourceRevision: base.sourceRevision,
      commands: (base.commands.filter { !localNames.contains($0.name) } + local.commands)
        .sorted { $0.name < $1.name }
    )
  }

  private static func prepareStateDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw AutocompleteServiceError.invalidStateDirectory
      }
      return
    }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  private static func loadOrCreateCLIToken(at url: URL, fileManager: FileManager) throws -> String {
    if fileManager.fileExists(atPath: url.path) {
      let data = try readRegularFile(at: url, maximumBytes: 128, fileManager: fileManager)
      if let token = String(data: data, encoding: .utf8), isValidCLIToken(token) {
        // 旧版本可能在较宽松 umask 下创建 token；每次加载都收紧到 0600，确保
        // CLI 文件传输启用前不会继续使用组或其他用户可读的鉴权材料。
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
      }
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw AutocompleteServiceError.tokenUnavailable
    }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try writeStateFile(Data(token.utf8), to: url, fileManager: fileManager)
    return token
  }

  private static func isValidCLIToken(_ token: String) -> Bool {
    token.utf8.count == 64 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let lhs = Array(left.utf8)
    let rhs = Array(right.utf8)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    let count = max(lhs.count, rhs.count)
    for index in 0..<count {
      let leftByte = index < lhs.count ? lhs[index] : 0
      let rightByte = index < rhs.count ? rhs[index] : 0
      difference |= leftByte ^ rightByte
    }
    return difference == 0
  }

  private static func decodeHex(_ value: String, maximumBytes: Int) -> String? {
    guard value.count.isMultiple(of: 2), value.count <= maximumBytes * 2,
      value.allSatisfy(\.isHexDigit)
    else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8),
      !decoded.unicodeScalars.contains(where: { $0.value == 0 })
    else { return nil }
    return decoded
  }

  private static func readOptionalStateFile(
    at url: URL,
    maximumBytes: Int,
    fileManager: FileManager
  ) throws -> Data? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try readRegularFile(at: url, maximumBytes: maximumBytes, fileManager: fileManager)
  }

  private static func readRegularFile(
    at url: URL,
    maximumBytes: Int,
    fileManager: FileManager
  ) throws -> Data {
    guard maximumBytes >= 0 else { throw AutocompleteServiceError.unsafeStateFile(url.path) }
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { throw AutocompleteServiceError.unsafeStateFile(url.path) }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0,
      metadata.st_size <= maximumBytes
    else { throw AutocompleteServiceError.unsafeStateFile(url.path) }

    var data = Data()
    data.reserveCapacity(min(Int(metadata.st_size), maximumBytes))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while data.count <= maximumBytes {
      let requested = min(buffer.count, maximumBytes - data.count + 1)
      let count = Darwin.read(descriptor, &buffer, requested)
      guard count >= 0 else { throw AutocompleteServiceError.unsafeStateFile(url.path) }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard data.count <= maximumBytes else {
      throw AutocompleteServiceError.unsafeStateFile(url.path)
    }
    return data
  }

  private static func writeStateFile(
    _ data: Data,
    to url: URL,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw AutocompleteServiceError.unsafeStateFile(url.path)
      }
    }
    try data.write(to: url, options: [.atomic])
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
