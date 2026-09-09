import AsterCore
import Foundation

/// `aster machine …` 与 `aster session list|create|stop|delete` 的 CLI 前端（P4.8）。
///
/// 这组命令在 `AsterCLIArguments.parse` **之前**被拦截：机器与命名会话的动作作用域是
/// 客户端配置与某台机器上的注册表，与既有 `agent/pane/events` 的「当前工作区」作用域
/// 不同，因此它们有自己的一套参数与目标解析规则。
///
/// 硬规则（R17）：跨机器写入必须显式给出 `--machine`，不能靠「当前选中项」补全。
enum MachineCommands {
  /// 解析结果：方法名 + params。
  struct Invocation {
    var method: String
    var params: JSONValue?
    /// 文本模式的渲染器。
    var render: (JSONValue) throws -> String
  }

  static let usage = """
    机器与命名会话：
      machine list
      machine add --label <标签> --ssh-target <target> --session <会话名>
      machine rename <id或标签> <新标签>
      machine enable|disable|remove <id或标签>
      session list --machine <id或标签>
      session create|stop|delete --machine <id或标签> --name <会话名>
    """

  /// 摘出 `--json` / `--format <text|json>`，返回剩余 argv 与是否输出 JSON。
  ///
  /// 必须成对摘取而不是过滤字符串：一台机器完全可以叫 `json`，全局过滤会把它吃掉。
  static func extractOutputFormat(_ argv: [String]) -> ([String], Bool) {
    var rest: [String] = []
    var wantsJSON = false
    var index = 0
    while index < argv.count {
      switch argv[index] {
      case "--json":
        wantsJSON = true
        index += 1
      case "--format":
        if index + 1 < argv.count {
          wantsJSON = argv[index + 1] == "json"
          index += 2
        } else {
          index += 1
        }
      default:
        rest.append(argv[index])
        index += 1
      }
    }
    return (rest, wantsJSON)
  }

  /// 判断这组 argv 是否属于本模块。返回 false 表示交回旧解析器。
  static func matches(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    if first == "machine" { return true }
    // `session` 下只接管新增的四个子命令，既有 snapshot/terminals/detach/end 保持原路径。
    guard first == "session", argv.count > 1 else { return false }
    return ["list", "create", "stop", "delete"].contains(argv[1])
  }

  /// 解析 argv。失败抛 `ControlClientError.usage`。
  static func parse(_ argv: [String]) throws -> Invocation {
    guard let group = argv.first else { throw usageError("缺少命令") }
    let rest = Array(argv.dropFirst())
    return group == "machine" ? try parseMachine(rest) : try parseSession(rest)
  }

  private static func parseMachine(_ argv: [String]) throws -> Invocation {
    guard let subcommand = argv.first else { throw usageError("machine 需要子命令") }
    let rest = Array(argv.dropFirst())
    switch subcommand {
    case "list":
      try expectEmpty(rest, command: "machine list")
      return Invocation(method: "machine.list", params: nil, render: renderMachineList)

    case "add":
      let options = try options(rest, command: "machine add")
      let label = try require(options, "--label", command: "machine add")
      let target = try require(options, "--ssh-target", command: "machine add")
      let session = try require(options, "--session", command: "machine add")
      return Invocation(
        method: "machine.add",
        params: .object(["label": .string(label), "sshTarget": .string(target),
          "sessionName": .string(session)]),
        render: renderMachineRow)

    case "rename":
      guard rest.count == 2 else {
        throw usageError("machine rename 需要 <id或标签> <新标签>")
      }
      return Invocation(
        method: "machine.rename",
        params: .object(["machine": .string(rest[0]), "label": .string(rest[1])]),
        render: renderMachineRow)

    case "enable", "disable", "remove":
      guard rest.count == 1 else {
        throw usageError("machine \(subcommand) 需要 <id或标签>")
      }
      return Invocation(
        method: "machine.\(subcommand)",
        params: .object(["machine": .string(rest[0])]),
        render: renderMachineRow)

    default:
      throw usageError("未知子命令: machine \(subcommand)")
    }
  }

  private static func parseSession(_ argv: [String]) throws -> Invocation {
    guard let subcommand = argv.first else { throw usageError("session 需要子命令") }
    let options = try options(Array(argv.dropFirst()), command: "session \(subcommand)")
    let machine = try require(options, "--machine", command: "session \(subcommand)")
    if subcommand == "list" {
      return Invocation(
        method: "session.list", params: .object(["machine": .string(machine)]),
        render: renderSessionList)
    }
    let name = try require(options, "--name", command: "session \(subcommand)")
    return Invocation(
      method: "session.\(subcommand)",
      params: .object(["machine": .string(machine), "name": .string(name)]),
      render: renderSessionAction)
  }

  // MARK: - 参数工具

  private static func options(_ argv: [String], command: String) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < argv.count {
      let key = argv[index]
      guard key.hasPrefix("--") else {
        throw usageError("\(command) 不接受位置参数«\(key)»")
      }
      guard index + 1 < argv.count else {
        throw usageError("\(command) 的 \(key) 缺少取值")
      }
      result[key] = argv[index + 1]
      index += 2
    }
    return result
  }

  private static func require(_ options: [String: String], _ key: String, command: String) throws
    -> String
  {
    guard let value = options[key], !value.isEmpty else {
      throw usageError("\(command) 需要 \(key)")
    }
    return value
  }

  private static func expectEmpty(_ argv: [String], command: String) throws {
    guard argv.isEmpty else { throw usageError("\(command) 不接受额外参数") }
  }

  private static func usageError(_ message: String) -> ControlClientError {
    ControlClientError(
      message: "aster: \(message)\n\n\(usage)", exitCode: AsterCLIExitCode.usage)
  }

  // MARK: - 文本渲染

  /// 机器列表：每行「id 标签 会话 状态 [target]」，字段以制表符分隔，便于脚本消费。
  static func renderMachineList(_ value: JSONValue) throws -> String {
    var lines: [String] = []
    if case .string(let error)? = value["configuration_error"] ?? value["configurationError"] {
      lines.append("! 配置错误：\(error)")
    }
    guard case .array(let machines)? = value["machines"] else { return lines.joined(separator: "\n") }
    for machine in machines { lines.append(machineLine(machine)) }
    return lines.joined(separator: "\n")
  }

  static func renderMachineRow(_ value: JSONValue) throws -> String { machineLine(value) }

  private static func machineLine(_ value: JSONValue) -> String {
    let fields = [
      text(value["id"]), text(value["label"]), text(value["sessionName"]),
      text(value["state"]), text(value["sshTarget"], fallback: "-"),
      boolText(value["enabled"]) ? "enabled" : "disabled",
    ]
    return fields.joined(separator: "\t")
  }

  static func renderSessionList(_ value: JSONValue) throws -> String {
    guard case .array(let sessions)? = value["sessions"] else { return "" }
    return sessions.map { session in
      [
        text(session["sessionID"]), text(session["name"]), text(session["state"]),
        text(session["serverEpoch"], fallback: "-"),
      ].joined(separator: "\t")
    }.joined(separator: "\n")
  }

  static func renderSessionAction(_ value: JSONValue) throws -> String {
    [
      text(value["machine"]), text(value["name"]), text(value["disposition"]),
      text(value["session"]?["sessionID"], fallback: "-"),
    ].joined(separator: "\t")
  }

  private static func text(_ value: JSONValue?, fallback: String = "") -> String {
    guard case .string(let string)? = value else { return fallback }
    return string.isEmpty ? fallback : string
  }

  private static func boolText(_ value: JSONValue?) -> Bool {
    if case .bool(let flag)? = value { return flag }
    return false
  }
}
