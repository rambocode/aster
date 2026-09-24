import AsterCore
import Foundation

/// `aster host list` 的 CLI 前端：只读列出 App 里保存的 SSH 主机。
///
/// 与 `MachineCommands` 一样在 `AsterCLIArguments.parse` 之前拦截，复用它的
/// `Invocation` 与输出格式开关，文本输出同样是制表符分隔的一行一条。
/// 输出里没有任何秘密，也不说明「是否保存了口令」。
enum HostCommands {
  static let usage = """
    已保存主机：
      host list [--json]
    """

  /// 判断这组 argv 是否属于本模块。返回 false 表示交回其它解析器。
  static func matches(_ argv: [String]) -> Bool {
    argv.first == "host"
  }

  /// 解析 argv（已摘掉 `--json` / `--format`）。失败抛 `ControlClientError.usage`。
  static func parse(_ argv: [String]) throws -> MachineCommands.Invocation {
    guard argv.count >= 2 else { throw usageError("host 需要子命令") }
    let subcommand = argv[1]
    let rest = argv.dropFirst(2)
    switch subcommand {
    case "list":
      guard rest.isEmpty else { throw usageError("host list 不接受额外参数：\(rest.joined(separator: " "))") }
      return MachineCommands.Invocation(method: "host.list", params: nil, render: renderHostList)
    default:
      throw usageError("未知子命令: host \(subcommand)")
    }
  }

  private static func usageError(_ message: String) -> ControlClientError {
    ControlClientError(message: "aster: \(message)\n\n\(usage)", exitCode: AsterCLIExitCode.usage)
  }

  // MARK: - 文本渲染

  /// 主机列表：每行「id 名称 分组 user@host:port 跳板」，缺省字段写 `-`。
  static func renderHostList(_ value: JSONValue) throws -> String {
    var lines: [String] = []
    if case .string(let error)? = value["configurationError"] {
      lines.append("! 配置错误：\(error)")
    }
    guard case .array(let hosts)? = value["hosts"] else { return lines.joined(separator: "\n") }
    for host in hosts {
      lines.append(
        [
          text(host["id"]), text(host["name"]), text(host["group"], fallback: "-"),
          text(host["target"]),
          text(host["jumpHostName"], fallback: text(host["jumpHostID"], fallback: "-")),
        ].joined(separator: "\t"))
    }
    return lines.joined(separator: "\n")
  }

  private static func text(_ value: JSONValue?, fallback: String = "") -> String {
    guard case .string(let string)? = value else { return fallback }
    return string.isEmpty ? fallback : string
  }
}
