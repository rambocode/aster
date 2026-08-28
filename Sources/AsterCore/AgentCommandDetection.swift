import Foundation

/// 可执行文件名的规范化规则，移植自 herdr `detect/mod.rs`：只看路径最后一段、
/// 忽略大小写与常见脚本/可执行后缀，供别名表与 wrapper 解包共用。
enum AgentExecutableNameNormalizer {
  /// 兼容 `/` 与 `\` 分隔符的最后一个非空路径分量；没有分隔符时返回原串。
  static func basename(_ path: String) -> String {
    let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
    guard let last = components.last(where: { !$0.isEmpty }) else { return path }
    return String(last)
  }

  /// trim + 小写 + 去掉一个 `.exe/.cmd/.bat/.ps1/.js` 后缀（只去一次，`a.cmd.exe` 只去 `.exe`）。
  static func normalizedLookupName(_ name: String) -> String {
    var lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for suffix in [".exe", ".cmd", ".bat", ".ps1", ".js"] where lowered.hasSuffix(suffix) {
      lowered.removeLast(suffix.count)
      break
    }
    return lowered
  }

  /// Muse 的启动脚本会 exec `muse-bin-<version>`（如 `muse-bin-0.1.0-R708.1`），运行中的
  /// 进程从不带裸 `muse` 名字。要求前缀后紧跟数字，`muse-binary`、裸 `muse-bin` 均不匹配。
  static func isMuseVersionedBinary(_ name: String) -> Bool {
    let normalized = normalizedLookupName(basename(name))
    guard normalized.hasPrefix("muse-bin-") else { return false }
    let rest = normalized.dropFirst("muse-bin-".count)
    return rest.first?.isASCII == true && rest.first?.isNumber == true
  }

  /// 通用运行时或 shell：其 argv[0] 不代表真正运行的程序，需要继续解包参数。
  static func isGenericRuntimeOrShell(_ name: String) -> Bool {
    let normalized = normalizedLookupName(basename(name))
    if isPythonRuntime(normalized) { return true }
    return ["sh", "bash", "zsh", "fish", "tmux", "node", "bun", "cmd", "powershell", "pwsh"]
      .contains(normalized)
  }

  /// `python`、`python3`、`python3.12` 之类的解释器名；`pythonic` 不算。
  static func isPythonRuntime(_ name: String) -> Bool {
    guard name.hasPrefix("python") else { return false }
    let version = name.dropFirst("python".count)
    if version.isEmpty { return true }
    return version.split(separator: ".", omittingEmptySubsequences: false)
      .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
  }
}

/// 从被 node/bun/python/shell 包裹的 argv 里找出真正运行的 Agent，移植自 herdr
/// `wrapped_agent_name_from_runtime_argv` 及其辅助函数。
///
/// 这样做的原因：npm/bun 安装的 Agent 常以 `node /path/to/cli.js` 运行，前台进程名只是
/// `node`；shell wrapper（`sh /tmp/bin/pi`）也一样。只看进程名会漏掉这些会话，而
/// 盲目扫描所有参数又会把 `bash -c "sleep 60" /tmp/codex` 这类误报成 Agent，因此按
/// 各运行时的选项语法定位“脚本路径”参数，eval/`-c` 形式一律放弃。
enum AgentWrappedCommandDetector {
  /// 按运行时名分派解包规则；tmux 与未知运行时不穿透。
  static func wrappedProvider(runtime: String, argv: [String]) -> AgentProvider? {
    switch runtime {
    case "node":
      cursorProviderFromBundledNodeArgv(argv)
        ?? scriptArgProvider(argv, evalFlags: ["-e", "--eval", "-p", "--print"], moduleFlags: [])
    case "bun":
      scriptArgProvider(argv, evalFlags: ["-e", "--eval", "-p", "--print"], moduleFlags: [])
    case _ where AgentExecutableNameNormalizer.isPythonRuntime(runtime):
      scriptArgProvider(argv, evalFlags: ["-c"], moduleFlags: ["-m"])
    case "sh", "bash", "zsh", "fish":
      scriptArgProvider(argv, evalFlags: ["-c"], moduleFlags: [])
    case "cmd":
      windowsCmdProvider(argv)
    case "powershell", "pwsh":
      powershellProvider(argv)
    default:
      nil
    }
  }

  /// Windows 版 Cursor 把 node.exe 与 index.js 一起放在
  /// `cursor-agent/versions/<v>/`，两者同目录且目录结构匹配时判定为 Cursor。
  static func cursorProviderFromBundledNodeArgv(_ argv: [String]) -> AgentProvider? {
    guard argv.count >= 2,
      let (runtimeParent, runtimeName) = parentAndBasename(argv[0]),
      let (scriptParent, scriptName) = parentAndBasename(argv[1]),
      runtimeName.lowercased() == "node.exe",
      scriptName.lowercased() == "index.js",
      runtimeParent.lowercased() == scriptParent.lowercased()
    else { return nil }
    let tail = runtimeParent.split(whereSeparator: { $0 == "/" || $0 == "\\" })
      .filter { !$0.isEmpty }
      .reversed()
    guard tail.count >= 3 else { return nil }
    let version = tail[tail.startIndex]
    let versions = tail[tail.index(tail.startIndex, offsetBy: 1)]
    let package = tail[tail.index(tail.startIndex, offsetBy: 2)]
    guard package.lowercased() == "cursor-agent",
      versions.lowercased() == "versions",
      !version.trimmingCharacters(in: .whitespaces).isEmpty
    else { return nil }
    return .cursorCLI
  }

  /// 拆出父目录与文件名；任一为空（如根目录或无分隔符）返回 nil。
  private static func parentAndBasename(_ path: String) -> (String, String)? {
    guard let split = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return nil }
    var parent = String(path[..<split])
    while let last = parent.last, last == "/" || last == "\\" { parent.removeLast() }
    let basename = String(path[path.index(after: split)...])
    guard !parent.isEmpty, !basename.isEmpty else { return nil }
    return (parent, basename)
  }

  /// 跳过运行时选项后取第一个位置参数当脚本路径；遇到 eval/module 类标志直接放弃，
  /// `--` 之后的第一个 token 视为脚本。
  static func scriptArgProvider(
    _ argv: [String],
    evalFlags: [String],
    moduleFlags: [String]
  ) -> AgentProvider? {
    var iterator = argv.dropFirst().makeIterator()
    while let arg = iterator.next() {
      if arg == "--" {
        return iterator.next().flatMap(providerFromPathToken)
      }
      if flagMatches(arg, evalFlags) || flagMatches(arg, moduleFlags) {
        return nil
      }
      if arg.hasPrefix("-") {
        if optionTakesValue(arg) { _ = iterator.next() }
        continue
      }
      return providerFromPathToken(arg)
    }
    return nil
  }

  /// 标志匹配同时接受 `-e`、短标志粘连值（`-e1+1`）与长标志 `=` 形式（`--eval=...`）。
  private static func flagMatches(_ arg: String, _ flags: [String]) -> Bool {
    flags.contains { flag in
      if arg == flag { return true }
      if flag.hasPrefix("-"), !flag.hasPrefix("--"), arg.hasPrefix(flag), arg.count > flag.count {
        return true
      }
      if flag.hasPrefix("--"), arg.hasPrefix(flag + "=") { return true }
      return false
    }
  }

  /// 带独立值参数的运行时选项，解包时要连值一起跳过。
  static func optionTakesValue(_ arg: String) -> Bool {
    [
      "-r", "--require", "--loader", "--import", "--experimental-loader", "--inspect-port",
      "-W", "-X", "-S", "-L", "-o",
    ].contains(arg)
  }

  /// `cmd /c <command>`：只看 `/c`、`/k` 后的命令文本。
  private static func windowsCmdProvider(_ argv: [String]) -> AgentProvider? {
    var iterator = argv.dropFirst().makeIterator()
    while let arg = iterator.next() {
      let flag = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
      switch flag {
      case "/c", "/k":
        return iterator.next().flatMap(providerFromCommandText)
      default:
        continue
      }
    }
    return nil
  }

  /// `powershell -File <path>` / `-Command <text>`；编码命令无法解析，直接放弃。
  private static func powershellProvider(_ argv: [String]) -> AgentProvider? {
    var iterator = argv.dropFirst().makeIterator()
    while let arg = iterator.next() {
      let flag = arg.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
      switch flag {
      case "-file", "-f", "/file":
        return iterator.next().flatMap(providerFromPathToken)
      case "-command", "-c", "/command", "/c":
        return iterator.next().flatMap(providerFromCommandText)
      case "-encodedcommand", "-enc", "/encodedcommand", "/enc":
        return nil
      case "-configurationname", "-executionpolicy", "-outputformat", "-psconsolefile",
        "-version", "-windowstyle", "-workingdirectory":
        _ = iterator.next()
      case _ where flag.hasPrefix("-") || flag.hasPrefix("/"):
        continue
      default:
        return providerFromPathToken(arg)
      }
    }
    return nil
  }

  /// 取命令文本的第一个 token（跳过 `&`、`.`、`call` 前缀），支持引号包裹。
  private static func providerFromCommandText(_ command: String) -> AgentProvider? {
    var rest = Substring(command)
    while let (token, next) = commandTextToken(rest) {
      let trimmed = token.trimmingCharacters(in: .whitespaces)
      if ["&", ".", "call"].contains(trimmed.lowercased()) {
        rest = next
        continue
      }
      return providerFromPathToken(trimmed)
    }
    return nil
  }

  /// 从命令文本头部切出一个 token；引号内的空格不分割。
  private static func commandTextToken(_ input: Substring) -> (String, Substring)? {
    let input = input.drop(while: \.isWhitespace)
    guard let first = input.first else { return nil }
    if first == "\"" || first == "'" {
      let start = input.index(after: input.startIndex)
      if let end = input[start...].firstIndex(of: first) {
        return (String(input[start..<end]), input[input.index(after: end)...])
      }
      return (String(input[start...]), "")
    }
    let end = input.firstIndex(where: \.isWhitespace) ?? input.endIndex
    return (String(input[..<end]), input[end...])
  }

  /// 脚本路径 token → provider：先按文件名查别名表，再按 node_modules 包路径匹配。
  /// 不解析符号链接（领域层不访问文件系统）。
  static func providerFromPathToken(_ token: String) -> AgentProvider? {
    let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
    return AgentProvider.detect(executablePath: trimmed) ?? providerFromKnownPackagePath(trimmed)
  }

  /// 已知 npm 包的入口脚本路径（按规范化后的路径分量做滑动窗口匹配）。文件名本身
  /// 是 `cli.js`/`index.js`，只能靠包路径识别。
  static func providerFromKnownPackagePath(_ path: String) -> AgentProvider? {
    let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
      .filter { !$0.isEmpty }
      .map { AgentExecutableNameNormalizer.normalizedLookupName(String($0)) }
    let patterns: [([String], AgentProvider)] = [
      (["node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli"], .pi),
      (["node_modules", "@qwen-code", "qwen-code", "dist", "index"], .qwen),
      (["node_modules", "@anthropic-ai", "claude-code", "cli"], .claudeCode),
      (["node_modules", "@openai", "codex", "bin", "codex"], .codex),
      (["node_modules", "@google", "gemini-cli", "dist", "index"], .gemini),
    ]
    for (pattern, provider) in patterns where components.count >= pattern.count {
      for start in 0...(components.count - pattern.count)
      where Array(components[start..<start + pattern.count]) == pattern {
        return provider
      }
    }
    return nil
  }
}
