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
let parsed: AsterCLIArguments
do {
  parsed = try AsterCLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
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
