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
        global:aster) ;;
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

  /// `subcommandPath` 非空时探测的是子命令(`docker compose --help`)。上游 Fig 规格
  /// 里存在大量“有名字但没内容”的子命令壳子(`docker compose` 就是空的)，只有探测
  /// 子命令自己的 help 才能把它填起来。
  static func probe(
    command: String,
    subcommandPath: [String] = [],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> AutocompleteCommandSpec? {
    await Task.detached(priority: .utility) {
      probeSynchronously(
        command: command, subcommandPath: subcommandPath, environment: environment)
    }.value
  }

  private static func probeSynchronously(
    command: String,
    subcommandPath: [String],
    environment: [String: String]
  ) -> AutocompleteCommandSpec? {
    // 子命令路径同样走命令名白名单：它会被原样拼进 argv，绝不能带空格或元字符。
    guard isSafeCommandName(command), subcommandPath.count <= 4,
      subcommandPath.allSatisfy(isSafeCommandName),
      FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
      let executable = resolveExecutable(command, path: environment["PATH"] ?? "/usr/bin:/bin")
    else { return nil }

    let leafName = subcommandPath.last ?? command
    for suffix in [["--help"], ["-h"], ["help"]] {
      guard let output = run(
        executable: executable,
        arguments: subcommandPath + suffix,
        environment: minimalEnvironment(from: environment)
      ) else { continue }
      if let spec = HelpAutocompleteSpecParser.parse(command: leafName, output: output) {
        return spec
      }
    }
    return nil
  }

  static func resolveExecutable(_ command: String, path: String) -> URL? {
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

  static func isSafeCommandName(_ command: String) -> Bool {
    guard !command.isEmpty, command.utf8.count <= 128 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
    return command.unicodeScalars.allSatisfy(allowed.contains)
  }

  /// 重建一份可用于 PATH 查找的搜索路径。
  ///
  /// `aster learn <binary>` 的请求体不携带调用方 shell 的 PATH,而 Finder 启动的 App
  /// 继承的是系统默认 PATH——通常没有 `/opt/homebrew/bin`,于是用户能在终端里跑的
  /// 命令在这里一个都找不到。这里按 macOS `path_helper` 的规则从磁盘重建:读
  /// `/etc/paths` 与 `/etc/paths.d/*`,再并上进程自身的 PATH 与常见的用户 bin 目录。
  /// 全程只读文件,不 fork 任何进程。
  static func searchPath(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    var directories: [String] = []
    var seen: Set<String> = []
    func add(_ path: String) {
      guard path.hasPrefix("/"), path.utf8.count <= 4_096, seen.insert(path).inserted,
        directories.count < 128
      else { return }
      directories.append(path)
    }
    for value in (environment["PATH"] ?? "").split(separator: ":") { add(String(value)) }

    let fileManager = FileManager.default
    func appendLines(of url: URL) {
      guard let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]), values.isRegularFile == true, values.isSymbolicLink != true,
        (values.fileSize ?? 0) <= 4_096, let data = try? Data(contentsOf: url)
      else { return }
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        add(line.trimmingCharacters(in: .whitespaces))
      }
    }
    appendLines(of: URL(fileURLWithPath: "/etc/paths"))
    if let entries = try? fileManager.contentsOfDirectory(
      at: URL(fileURLWithPath: "/etc/paths.d"), includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])
    {
      for entry in entries.sorted(by: { $0.path < $1.path }).prefix(64) { appendLines(of: entry) }
    }
    if let home = environment["HOME"], home.hasPrefix("/") {
      add(home + "/.local/bin")
      add(home + "/bin")
    }
    for fallback in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] { add(fallback) }
    return directories.joined(separator: ":")
  }
}

/// 动态候选的按目录缓存。补全跑在主线程的 150ms 防抖窗口里,每次按键都重新枚举
/// `.git/refs` 或 Homebrew 的 tap 目录是不可接受的。
///
/// 失效凭据用「见证文件的 (mtime, size)」组合,**外加一个硬 TTL**。TTL 不是保险丝
/// 而是必需品:目录的 mtime 不会因为子目录内的文件变化而更新——新建
/// `refs/heads/feature/x` 只改 `refs/heads/feature` 的 mtime,不改 `refs/heads`,
/// 单靠 mtime 会漏更新。
@MainActor
final class AutocompleteDynamicCache {
  private struct Entry {
    let items: [AutocompleteDynamicItem]
    let witness: [String]
    let loadedAt: Date
  }

  private struct Key: Hashable {
    let source: AutocompleteDynamicSource
    let directory: String
  }

  private let reader: any AutocompleteDynamicReader
  private let capacity = 16
  private var entries: [Key: Entry] = [:]
  private var order: [Key] = []
  /// Homebrew 的 tap 目录可以有上万条,重读很贵而且几乎不变,给它更长的 TTL。
  private static let defaultTTL: TimeInterval = 5
  private static let brewTTL: TimeInterval = 60

  init(reader: any AutocompleteDynamicReader) {
    self.reader = reader
  }

  func items(
    for source: AutocompleteDynamicSource, directory: String, now: Date = Date()
  ) -> [AutocompleteDynamicItem] {
    let key = Key(source: source, directory: directory)
    let witness = Self.witness(for: source, directory: directory)
    let ttl = Self.ttl(for: source)
    if let entry = entries[key], entry.witness == witness,
      now.timeIntervalSince(entry.loadedAt) < ttl
    {
      touch(key)
      return entry.items
    }
    let items = reader.items(for: source, directory: directory)
    entries[key] = Entry(items: items, witness: witness, loadedAt: now)
    touch(key)
    trim()
    return items
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private func trim() {
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      entries[oldest] = nil
    }
  }

  private static func ttl(for source: AutocompleteDynamicSource) -> TimeInterval {
    switch source {
    case .brewFormulae, .brewCasks, .brewInstalledFormulae, .brewInstalledCasks, .brewTaps:
      brewTTL
    default:
      defaultTTL
    }
  }

  /// 见证文件的 (mtime, size) 指纹。只 stat 少量固定路径,不递归。
  private static func witness(
    for source: AutocompleteDynamicSource, directory: String
  ) -> [String] {
    let root = URL(fileURLWithPath: directory)
    let paths: [String]
    switch source {
    case .gitLocalBranches, .gitAllBranches, .gitRemoteBranches, .gitTags, .gitRemotes,
      .gitStashes, .gitAliases:
      paths = [".git/HEAD", ".git/packed-refs", ".git/refs/heads", ".git/config", ".git/logs/HEAD"]
    case .npmScripts:
      paths = ["package.json"]
    case .makeTargets:
      paths = ["Makefile", "makefile", "GNUmakefile"]
    case .brewFormulae, .brewCasks, .brewInstalledFormulae, .brewInstalledCasks, .brewTaps:
      // Homebrew 不在项目目录下,靠 TTL 兜底即可。
      paths = []
    }
    return paths.map { path in
      let url = root.appendingPathComponent(path)
      guard let values = try? url.resourceValues(forKeys: [
        .contentModificationDateKey, .fileSizeKey,
      ]) else { return "\(path):-" }
      let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      return "\(path):\(stamp):\(values.fileSize ?? 0)"
    }
  }
}

/// Autocomplete 的应用级边界：组合签名 Bundle 规格、用户手动更新、本地 help 规格、
/// README 和脱敏学习库。除 `updateNow()` 外不发起网络请求，也不会自动扫描项目脚本。
@MainActor
final class AutocompleteService {
  struct LearningClearSelection: OptionSet {
    let rawValue: Int
    static let history = Self(rawValue: 1 << 0)
    static let pinnedCommands = Self(rawValue: 1 << 1)
  }
  static let maximumReadmeBytes = 2 * 1_024 * 1_024
  /// 手动更新只拉取仓库里由 `scripts/build-fig-specs.mjs` 生成的同一份规格文件。
  static let figSpecsURL = URL(
    string: "https://raw.githubusercontent.com/rambocode/aster/master/Resources/autocomplete/fig-specs.json")!

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
  /// 动态候选(git 分支、npm script、Homebrew formula …)的按目录缓存。
  let dynamicCache: AutocompleteDynamicCache

  init(
    baseDirectory: URL,
    bundledSpecURL: URL,
    fileManager: FileManager = .default,
    dynamicReader: (any AutocompleteDynamicReader)? = nil
  ) throws {
    self.baseDirectory = baseDirectory.standardizedFileURL
    self.fileManager = fileManager
    dynamicCache = AutocompleteDynamicCache(
      reader: dynamicReader
        ?? AutocompleteDiskDynamicReader(environment: ProcessInfo.processInfo.environment))
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
      dynamic: dynamicProvider(directory: normalizedDirectory),
      language: descriptionLanguage
    )
    let files = fileCandidates(for: line, directory: directory)
    let learnedArguments = localLearningEnabled ? learningDatabase.argumentCandidates(
      line: line, directory: normalizedDirectory, sessionIdentifier: sessionIdentifier,
      specDatabase: specDatabase) : []
    guard !files.isEmpty || !learnedArguments.isEmpty else { return base }
    // 文件候选参与统一重排,而不是无条件追加在规格候选之后。旧实现让文件永远排在
    // 最后、且只有在没有其它候选时才可能成为 ghost,于是 `cat REA<Tab>` 补不出
    // README——只要有任何一条别的候选,文件就沉底了。
    let combined = AutocompleteEngine.rank(base.candidates + files + learnedArguments, line: line)
    return .make(candidates: Array(combined.prefix(200)), line: line)
  }

  /// 为一次补全查询构造动态候选提供者。引擎只在解析到参数槽位时才回调,因此这里
  /// 传闭包而不是提前把所有来源都读一遍。
  private func dynamicProvider(directory: String) -> AutocompleteDynamicProvider {
    guard directory.hasPrefix("/") else { return .empty }
    let cache = dynamicCache
    return AutocompleteDynamicProvider { source in
      MainActor.assumeIsolated { cache.items(for: source, directory: directory) }
    }
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

  /// 撤销一次 `pin`（`aster ignore '<命令>'`）。写盘失败时回滚内存状态，与 `pin`
  /// 对称，避免磁盘和内存分叉。
  @discardableResult
  func unpin(command: String, directory: String) -> Bool {
    let previous = learningDatabase
    guard learningDatabase.unpin(command: command, directory: directory) else { return false }
    do {
      try persistLearning()
      return true
    } catch {
      learningDatabase = previous
      return false
    }
  }

  func isPinned(command: String, directory: String) -> Bool {
    learningDatabase.isPinned(command: command, directory: directory)
  }

  /// 移除一条本机 `--help` 探测生成的规格（`aster ignore <二进制名>`）。内置 Fig
  /// 规格不受影响——它不是用户学出来的，删掉只会让补全变差且无法恢复。
  @discardableResult
  func removeLocalSpec(named name: String) -> Bool {
    guard localSpecDatabase.command(named: name) != nil else { return false }
    let previousLocal = localSpecDatabase
    let previousMerged = specDatabase
    let updated = AutocompleteSpecDatabase(
      sourceRevision: "local",
      commands: localSpecDatabase.commands.filter { $0.name != name })
    do {
      let data = try AutocompleteSpecStore.encode(updated)
      try Self.writeStateFile(data, to: localSpecURL, fileManager: fileManager)
      localSpecDatabase = updated
      specDatabase = Self.merged(base: baseSpecDatabase, local: localSpecDatabase)
      return true
    } catch {
      localSpecDatabase = previousLocal
      specDatabase = previousMerged
      return false
    }
  }

  /// 本机是否存在该命令的 help 规格。内置规格不算——`ignore` 只撤销用户学到的东西。
  func hasLocalSpec(named name: String) -> Bool {
    localSpecDatabase.command(named: name) != nil
  }

  func clearLearning() throws {
    try clearLearning([.history, .pinnedCommands])
  }

  func clearLearning(_ selection: LearningClearSelection) throws {
    guard !selection.isEmpty else { return }
    let previous = learningDatabase
    if selection.contains([.history, .pinnedCommands]) {
      learningDatabase = AutocompleteLearningDatabase(capacity: previous.capacity)
    } else {
      if selection.contains(.history) { learningDatabase.clearHistory() }
      if selection.contains(.pinnedCommands) { learningDatabase.clearPinnedCommands() }
    }
    do {
      try persistLearning()
    } catch {
      learningDatabase = previous
      throw error
    }
  }

  func knownOptions(for command: String) -> Set<String> {
    Set(specDatabase.command(named: command)?.options.flatMap(\.names) ?? [])
  }

  /// 名称清单只能完成可执行文件本身；至少存在一种子项才算详细规格，否则允许
  /// 本地 help 探测补足 subcommand、option 或 argument。
  /// 一次 help 探测的目标：可执行文件加上要探测的子命令路径。
  struct HelpProbeTarget: Equatable {
    let command: String
    let subcommandPath: [String]
    /// 每会话每目标最多探测一次的去重键。
    var cacheKey: String { ([command] + subcommandPath).joined(separator: " ") }
  }

  /// 判断当前命令行需不需要做 `--help` 探测，以及探测哪一层。
  ///
  /// 沿已输入的 token 在规格树上下钻，返回**最深的那个内容不完整的层级**。这样
  /// `docker compose ` 会去探测 `docker compose --help` 而不是 `docker --help`——
  /// 上游 Fig 规格里 `docker compose` 是个只有名字、没有任何子命令和选项的壳子，
  /// 只探测顶层永远补不上它。已经完整的层级直接跳过，不产生任何进程。
  func helpProbeTarget(for line: String) -> HelpProbeTarget? {
    let parsed = ShellCommandTokenizer.tokenize(line)
    guard let command = parsed.tokens.first, !command.isEmpty else { return nil }
    // 正在输入的最后一个 token 还没定型，不参与下钻。
    let completed = parsed.currentToken.isEmpty
      ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())

    guard var node = specDatabase.command(named: command) else {
      // 完全没有规格的命令：探测顶层。
      return HelpProbeTarget(command: command, subcommandPath: [])
    }
    var path: [String] = []
    var deepestIncomplete = node.hasCompleteSpec
      ? nil : HelpProbeTarget(command: command, subcommandPath: [])
    for token in completed.prefix(4) {
      guard !token.hasPrefix("-"), let child = node.subcommand(named: token) else { break }
      node = child
      path.append(child.name)
      if !node.hasCompleteSpec {
        deepestIncomplete = HelpProbeTarget(command: command, subcommandPath: path)
      }
    }
    return deepestIncomplete
  }

  func containsDetailedSpec(for command: String) -> Bool {
    specDatabase.command(named: command)?.hasCompleteSpec ?? false
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

  /// 本地 help 规格独立保存并与内置规格按字段合并；手动更新远端清单时不会覆盖它。
  ///
  /// `subcommandPath` 非空时,探测结果是某个子命令的规格,要挂到本地规格树的对应位置
  /// 而不是当成一条顶层命令——否则 `docker compose --help` 会生成一个叫 `compose`
  /// 的顶层命令。
  ///
  /// `command` 是根命令名,`subcommandPath` **不含**它——与
  /// `AutocompleteHelpProbe.probe(command:subcommandPath:)` 的参数语义严格一致。
  /// 两者用同一套约定,是因为它们总是成对调用,不一致会静默地把规格挂到错误的位置。
  func installLocalSpec(
    _ spec: AutocompleteCommandSpec,
    command: String? = nil,
    subcommandPath: [String] = []
  ) throws {
    guard let command, !subcommandPath.isEmpty else { return try installTopLevelSpec(spec) }
    let existing = localSpecDatabase.command(named: command)
      ?? AutocompleteCommandSpec(name: command)
    try installTopLevelSpec(Self.attaching(spec, at: subcommandPath, to: existing))
  }

  /// 沿子命令路径把探测结果挂进规格树,路径上缺失的层级按名字补出空壳。
  private static func attaching(
    _ spec: AutocompleteCommandSpec,
    at path: [String],
    to parent: AutocompleteCommandSpec
  ) -> AutocompleteCommandSpec {
    guard let head = path.first else {
      return parent.merging(probed: spec)
    }
    var subcommands = parent.subcommands
    let child = subcommands.firstIndex { $0.name == head }
    let base = child.map { subcommands[$0] } ?? AutocompleteCommandSpec(name: head)
    let replaced = attaching(spec, at: Array(path.dropFirst()), to: base)
    if let child { subcommands[child] = replaced } else { subcommands.append(replaced) }
    return AutocompleteCommandSpec(
      name: parent.name, description: parent.description, aliases: parent.aliases,
      hidden: parent.hidden, subcommands: subcommands, options: parent.options,
      arguments: parent.arguments)
  }

  private func installTopLevelSpec(_ spec: AutocompleteCommandSpec) throws {
    var commands = localSpecDatabase.commands.filter { $0.name != spec.name }
    commands.append(spec)
    commands.sort { $0.name < $1.name }
    let updated = AutocompleteSpecDatabase(sourceRevision: "local", commands: commands)
    let data = try AutocompleteSpecStore.encode(updated)
    try Self.writeStateFile(data, to: localSpecURL, fileManager: fileManager)
    localSpecDatabase = updated
    specDatabase = Self.merged(base: baseSpecDatabase, local: localSpecDatabase)
  }

  /// 应用用户显式触发的规格文件更新。该入口不接触本地规格和命令学习文件。
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
    var request = URLRequest(url: Self.figSpecsURL)
    request.timeoutInterval = 60
    request.setValue("application/json", forHTTPHeaderField: "Accept")
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
      directory.hasPrefix("/")
    else { return [] }

    var token = parsed.currentToken
    var tokenStart = parsed.currentTokenStart
    let root = parsed.tokens.first.flatMap { specDatabase.command(named: $0) }
    let completed = token.isEmpty ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())
    let context = root.map { AutocompleteArgumentContext(root: $0, completed: completed) }
    var mode = context?.filesystemMode ?? .filesAndFolders
    if let context, !context.optionsTerminated, context.pendingArgument == nil,
      let equal = token.firstIndex(of: "="),
      let option = context.command.option(named: String(token[..<equal])), let argument = option.args.first
    {
      let offset = token.distance(from: token.startIndex, to: equal) + 1
      token = String(token.dropFirst(offset))
      tokenStart += offset
      mode = AutocompleteArgumentContext.filesystemMode(for: argument)
    } else if token.hasPrefix("-"), context?.optionsTerminated != true, context?.pendingArgument == nil {
      return []
    }
    guard mode != .none else { return [] }
    let rawToken = String(line.dropFirst(tokenStart))
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
        ]) else { return nil }
        let isDirectory = values.isDirectory == true
        let isRegularFile = values.isRegularFile == true
        let isSymbolicLink = values.isSymbolicLink == true
        guard isDirectory || isRegularFile || isSymbolicLink else { return nil }
        if mode == .folders, !isDirectory { return nil }
        let suffix = isDirectory ? "/" : ""
        guard let insert = AutocompleteShellInsertion.token(
          value: typedDirectory + name + suffix, typed: token, raw: rawToken,
          closeQuote: !isDirectory)
        else { return nil }
        let kind: AutocompleteCandidateKind = isDirectory ? .folder : .file
        return AutocompleteCandidate(
          insertText: insert,
          description: isDirectory ? "目录" : "文件",
          kind: kind,
          score: AutocompleteRelevance.score(kind: kind, typed: token, candidate: insert),
          replacement: .currentToken(start: tokenStart)
        )
      }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.insertText.localizedStandardCompare($1.insertText) == .orderedAscending
      }
  }

  /// 本地 help 规格与内置规格按字段并集合并，而不是整条覆盖。覆盖会丢掉内置规格
  /// 独有的嵌套子命令、参数模板与 generatorScripts（`docker compose` 就是这样丢的）。
  private static func merged(
    base: AutocompleteSpecDatabase,
    local: AutocompleteSpecDatabase
  ) -> AutocompleteSpecDatabase {
    var localByName: [String: AutocompleteCommandSpec] = [:]
    for command in local.commands { localByName[command.name] = command }
    var commands = base.commands.map { command in
      localByName.removeValue(forKey: command.name).map { command.merging(probed: $0) } ?? command
    }
    // 内置规格里根本没有的命令（用户 `aster learn` 出来的）原样加入。
    commands += localByName.values
    return AutocompleteSpecDatabase(
      sourceRevision: base.sourceRevision,
      sourceDate: base.sourceDate,
      commands: commands.sorted { $0.name < $1.name }
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
