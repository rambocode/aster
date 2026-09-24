import AsterCore
import Darwin
import Foundation

// aster-cli 入口：解析参数 → 本地命令（help/version/skill/watch/tab badge）或经 socket 调 App。
// 退出码：0 成功 / 1 服务端 error / 2 参数或本地前置错误 / 69 App 不可达。

/// 把文本写到 stderr（统一入口，避免各处重复 Data 转换）。
func writeStandardError(_ text: String) {
  FileHandle.standardError.write(Data(text.utf8))
}

// 对端提前断开时 write 会触发 SIGPIPE 杀掉进程，导致拿不到错误信息；改为按 EPIPE 走错误路径。
signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment
let rawArguments = Array(CommandLine.arguments.dropFirst())

/// 摘出全局 `--socket <path>` / `--socket=<path>`（与旧解析器的全局选项同义），其余参数原样保留。
/// 分组命令（machine/host/workspace）按首个参数匹配，不先摘掉它，`aster --socket X host list`
/// 就会落到旧解析器报「未知命令」。
func extractSocketOption(_ arguments: [String]) -> (rest: [String], socket: String?) {
  var rest: [String] = []
  var socket: String?
  var index = arguments.startIndex
  while index < arguments.endIndex {
    let argument = arguments[index]
    if argument == "--socket", arguments.index(after: index) < arguments.endIndex {
      socket = arguments[arguments.index(after: index)]
      index = arguments.index(index, offsetBy: 2)
      continue
    }
    if argument.hasPrefix("--socket=") {
      socket = String(argument.dropFirst("--socket=".count))
    } else {
      rest.append(argument)
    }
    index = arguments.index(after: index)
  }
  return (rest, socket)
}

let (groupArguments, explicitSocket) = extractSocketOption(rawArguments)

// 机器、命名会话、主机与命名工作区命令在旧解析器之前拦截：它们的作用域是客户端配置、
// 某台机器上的注册表或工作区注册表，与 agent/pane/events 的「当前工作区」作用域不同，
// 参数规则也不一样。
let routedParser: (([String]) throws -> MachineCommands.Invocation)? =
  if MachineCommands.matches(groupArguments) { MachineCommands.parse }
  else if HostCommands.matches(groupArguments) { HostCommands.parse }
  else if WorkspaceCommands.matches(groupArguments) { WorkspaceCommands.parse }
  else { nil }
if let routedParser {
  do {
    // 先摘掉输出格式开关，再交给本模块的解析器；否则 `--format json` 的取值会被
    // 当成位置参数。摘取按「标志 + 取值」成对进行，不做全局字符串过滤。
    let (commandArguments, wantsJSON) = MachineCommands.extractOutputFormat(groupArguments)
    let invocation = try routedParser(commandArguments)
    let client = ControlClient(
      socketPath: try ControlClient.resolveSocketPath(explicit: explicitSocket, environment: environment),
      environment: environment)
    let result = try client.call(invocation.method, params: invocation.params)
    printLine(wantsJSON ? try prettyJSON(result) : try invocation.render(result))
    exit(AsterCLIExitCode.success)
  } catch let error as AsterControlError {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = (try? encoder.encode(error)).map { String(decoding: $0, as: UTF8.self) }
      ?? "{\"code\":\"\(error.code.rawValue)\",\"message\":\"\(error.message)\"}"
    writeStandardError(payload + "\n")
    exit(AsterCLIExitCode.serverError)
  } catch let error as ControlClientError {
    writeStandardError(error.message + "\n")
    exit(error.exitCode)
  } catch {
    writeStandardError("aster: \(error)\n")
    exit(AsterCLIExitCode.serverError)
  }
}

let parsed: AsterCLIArguments
do {
  parsed = try AsterCLIArguments.parse(rawArguments)
} catch let error as AsterCLIArgumentError {
  writeStandardError("aster: \(error.message)\n")
  exit(AsterCLIExitCode.usage)
} catch {
  writeStandardError("aster: \(error)\n")
  exit(AsterCLIExitCode.usage)
}

switch parsed.command {
case .help:
  printLine(AsterCLIArguments.usage)
  exit(AsterCLIExitCode.success)

case .version:
  // 版本真值只在 Info.plist；swift build 直接产物找不到 plist 时标 dev。
  let version = AsterCLILocations.appVersion ?? "dev"
  printLine("aster-cli \(version) (protocol \(AsterControlProtocol.version))")
  exit(AsterCLIExitCode.success)

case .skill:
  guard let url = AsterCLILocations.skillURL, let contents = try? String(contentsOf: url, encoding: .utf8)
  else {
    writeStandardError("aster: SKILL.md not found next to this executable\n")
    exit(AsterCLIExitCode.usage)
  }
  FileHandle.standardOutput.write(Data(contents.utf8))
  exit(AsterCLIExitCode.success)

default:
  break
}

// agent/events/notification 只对 Aster 内部终端开放：这些命令默认操控「当前工作区」，
// 在别的终端里跑语义不明确；`--allow-outside` 是明确知情的例外。
if parsed.requiresAsterEnv, environment["ASTER_ENV"] != "1", !parsed.allowOutside {
  writeStandardError("aster: not running inside Aster (ASTER_ENV != 1); pass --allow-outside to override\n")
  exit(AsterCLIExitCode.usage)
}

do {
  let code = try CommandRunner(arguments: parsed, environment: environment).run()
  exit(code)
} catch let error as AsterControlError {
  // 服务端错误原样以 JSON 打到 stderr，skill 可直接按 code 分支（如 agent_blocked）。
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  let payload = (try? encoder.encode(error)).map { String(decoding: $0, as: UTF8.self) }
    ?? "{\"code\":\"\(error.code.rawValue)\",\"message\":\"\(error.message)\"}"
  writeStandardError(payload + "\n")
  exit(AsterCLIExitCode.serverError)
} catch let error as ControlClientError {
  writeStandardError(error.message + "\n")
  exit(error.exitCode)
} catch {
  writeStandardError("aster: \(error)\n")
  exit(AsterCLIExitCode.serverError)
}
