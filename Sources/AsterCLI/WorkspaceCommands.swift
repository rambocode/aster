import AsterCore
import Foundation

/// `aster workspace list|open|new` 的 CLI 前端：本地与远端命名工作区。
///
/// 与 `MachineCommands` 一样在 `AsterCLIArguments.parse` 之前拦截，复用它的
/// `Invocation` 与输出格式开关。open / new 是写操作，是否放行由 App 的 IPC 写门禁决定。
enum WorkspaceCommands {
  static let usage = """
    命名工作区：
      workspace list [--json]
      workspace open <名称|id|机器/工作区>
      workspace new --name <名称> [--machine <机器 id或标签>]
    """

  /// 判断这组 argv 是否属于本模块。返回 false 表示交回其它解析器。
  static func matches(_ argv: [String]) -> Bool {
    argv.first == "workspace"
  }

  /// 解析 argv（已摘掉 `--json` / `--format`）。失败抛 `ControlClientError.usage`。
  static func parse(_ argv: [String]) throws -> MachineCommands.Invocation {
    guard argv.count >= 2 else { throw usageError("workspace 需要子命令") }
    let subcommand = argv[1]
    let rest = Array(argv.dropFirst(2))
    switch subcommand {
    case "list":
      guard rest.isEmpty else {
        throw usageError("workspace list 不接受额外参数：\(rest.joined(separator: " "))")
      }
      return MachineCommands.Invocation(
        method: "workspace.list", params: nil, render: renderWorkspaceList)

    case "open":
      // 以 `--` 开头的一律当未知选项：工作区名称不会这样起，拼错的开关不该被当成名称打开。
      guard rest.count == 1, !rest[0].hasPrefix("--"), !rest[0].isEmpty else {
        throw usageError("workspace open 需要且只接受一个 <名称|id|机器/工作区>")
      }
      return MachineCommands.Invocation(
        method: "workspace.open", params: .object(["workspace": .string(rest[0])]),
        render: renderWorkspaceAction)

    case "new":
      let options = try options(rest, allowed: ["--name", "--machine"], command: "workspace new")
      guard let name = options["--name"], !name.isEmpty else {
        throw usageError("workspace new 需要 --name")
      }
      var params: [String: JSONValue] = ["name": .string(name)]
      if let machine = options["--machine"] {
        guard !machine.isEmpty else { throw usageError("workspace new 的 --machine 不能为空") }
        params["machine"] = .string(machine)
      }
      return MachineCommands.Invocation(
        method: "workspace.new", params: .object(params), render: renderWorkspaceAction)

    default:
      throw usageError("未知子命令: workspace \(subcommand)")
    }
  }

  // MARK: - 参数工具

  /// 解析 `--key value` 对；未知选项、位置参数与缺值都按用法错误拒绝。
  private static func options(
    _ argv: [String], allowed: Set<String>, command: String
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    var index = 0
    while index < argv.count {
      let key = argv[index]
      guard key.hasPrefix("--") else { throw usageError("\(command) 不接受位置参数«\(key)»") }
      guard allowed.contains(key) else { throw usageError("\(command) 不认识参数 \(key)") }
      guard index + 1 < argv.count else { throw usageError("\(command) 的 \(key) 缺少取值") }
      result[key] = argv[index + 1]
      index += 2
    }
    return result
  }

  private static func usageError(_ message: String) -> ControlClientError {
    ControlClientError(message: "aster: \(message)\n\n\(usage)", exitCode: AsterCLIExitCode.usage)
  }

  // MARK: - 文本渲染

  /// 工作区列表，一行一条，制表符分隔；首列区分本地与远端：
  /// - `local  id  名称  open|closed  最近使用时间`
  /// - `remote  机器id  机器标签  工作区id  标题  标签数  selected|-`
  ///
  /// 还没有快照的机器单独一行，末列写 `uncached`，免得被误读成「远端没有工作区」。
  static func renderWorkspaceList(_ value: JSONValue) throws -> String {
    var lines: [String] = []
    if case .array(let local)? = value["local"] {
      for workspace in local {
        lines.append(
          [
            "local", text(workspace["id"]), text(workspace["name"]),
            bool(workspace["isOpen"]) ? "open" : "closed",
            timestamp(workspace["lastActiveAtUnixMs"]),
          ].joined(separator: "\t"))
      }
    }
    if case .array(let machines)? = value["remote"] {
      for machine in machines {
        let prefix = ["remote", text(machine["machineID"]), text(machine["machineLabel"])]
        guard bool(machine["cached"]) else {
          lines.append((prefix + ["-", "-", "-", "uncached"]).joined(separator: "\t"))
          continue
        }
        guard case .array(let workspaces)? = machine["workspaces"] else { continue }
        for workspace in workspaces {
          lines.append(
            (prefix + [
              text(workspace["workspaceID"]), text(workspace["title"]),
              number(workspace["tabCount"]),
              bool(workspace["isSelected"]) ? "selected" : "-",
            ]).joined(separator: "\t"))
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  /// open / new 的结果，列与 `workspace list` 对应的那一种行一致。
  static func renderWorkspaceAction(_ value: JSONValue) throws -> String {
    if text(value["kind"]) == "remote" {
      return [
        "remote", text(value["machineID"]), text(value["machineLabel"]),
        text(value["workspaceID"]), text(value["name"]),
      ].joined(separator: "\t")
    }
    return ["local", text(value["workspaceID"]), text(value["name"])].joined(separator: "\t")
  }

  private static func text(_ value: JSONValue?, fallback: String = "") -> String {
    guard case .string(let string)? = value else { return fallback }
    return string.isEmpty ? fallback : string
  }

  private static func bool(_ value: JSONValue?) -> Bool {
    if case .bool(let flag)? = value { return flag }
    return false
  }

  private static func number(_ value: JSONValue?) -> String {
    guard case .number(let number)? = value else { return "-" }
    return String(Int(number))
  }

  /// 毫秒时间戳 → ISO 8601（本地时区），便于人读也便于脚本排序。
  private static func timestamp(_ value: JSONValue?) -> String {
    guard case .number(let milliseconds)? = value else { return "-" }
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
  }
}
