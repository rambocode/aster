// `aster pane close|split` 与 `aster tab new|close|focus|rename` 的参数解析。
// 从 AsterCLIArguments.swift 拆出来：那个文件已经接近长度上限，结构命令单独成组。

import Foundation

extension AsterCLIArguments {
  /// `pane close | split`：改变窗口结构的 pane 子命令。
  static func parseLayoutPane(_ arguments: [String], subcommand: String) throws -> AsterCLICommand {
    switch subcommand {
    case "close":
      let parsed = try parseOptions(
        arguments, command: "pane close", flags: ["--current"], valued: ["--pane"])
      // 关闭会结束 Pane 里的进程：不接受「没写目标就关调用者自己」的缺省行为。
      guard let pane = try paneSelector(parsed, allowPositional: true, command: "pane close") else {
        throw AsterCLIArgumentError("pane close 需要 <pane>、--pane <id> 或 --current")
      }
      return .paneClose(PaneCloseParams(pane: pane))
    case "split":
      let parsed = try parseOptions(
        arguments, command: "pane split", flags: ["--current"], valued: ["--pane", "--direction"])
      var direction = SplitDirection.right
      if let raw = parsed.values["--direction"] {
        guard let value = SplitDirection(rawValue: raw) else {
          throw AsterCLIArgumentError("--direction 只支持 right | left | down | up")
        }
        direction = value
      }
      return .paneSplit(
        pane: try paneSelector(parsed, allowPositional: true, command: "pane split"),
        direction: direction)
    default:
      throw AsterCLIArgumentError("未知子命令: pane \(subcommand)")
    }
  }

  // MARK: tab

  /// `tab new | close | focus | rename`。close / focus / rename 必须显式指定标签（或 `--current`）。
  /// `<tab>` 接受标签短 ID，也接受标签里任意 Pane 的 selector。
  static func parseTab(_ input: [String]) throws -> AsterCLICommand {
    guard let subcommand = input.first else {
      throw AsterCLIArgumentError("tab 需要子命令：new | close | focus | rename")
    }
    let arguments = Array(input.dropFirst())
    let command = "tab \(subcommand)"
    switch subcommand {
    case "new":
      let parsed = try parseOptions(arguments, command: command, flags: [], valued: ["--cwd", "--window"])
      guard parsed.positionals.isEmpty else {
        throw AsterCLIArgumentError("tab new 不接受位置参数（目录用 --cwd）")
      }
      if let cwd = parsed.values["--cwd"], cwd.isEmpty {
        throw AsterCLIArgumentError("--cwd 不能为空")
      }
      let params = TabNewParams(window: parsed.values["--window"], cwd: nil)
      try mapValidation { try params.validate() }
      return .tabNew(window: params.window, cwd: parsed.values["--cwd"])
    case "close", "focus":
      let parsed = try parseOptions(arguments, command: command, flags: ["--current"], valued: [])
      guard parsed.positionals.count <= 1 else {
        throw AsterCLIArgumentError("\(command) 只接受一个 <tab>")
      }
      let params = TabTargetParams(tab: try requiredTarget(parsed, command: command))
      try mapValidation { try params.validate() }
      return subcommand == "close" ? .tabClose(params) : .tabFocus(params)
    case "rename":
      let parsed = try parseOptions(
        arguments, command: command, flags: ["--current", "--clear"], valued: [])
      // 位置参数是 `[<tab>] [<title>]`：给了 --current 就没有 <tab>，给了 --clear 就没有 <title>。
      var positionals = parsed.positionals
      let tab: String
      if parsed.flags.contains("--current") {
        tab = "current"
      } else {
        guard !positionals.isEmpty else {
          throw AsterCLIArgumentError("tab rename 需要 <tab> 或 --current")
        }
        tab = positionals.removeFirst()
      }
      let title: String?
      if parsed.flags.contains("--clear") {
        guard positionals.isEmpty else {
          throw AsterCLIArgumentError("tab rename 的 --clear 不能和 <title> 同时给出")
        }
        title = nil
      } else {
        guard positionals.count == 1, !positionals[0].isEmpty else {
          throw AsterCLIArgumentError("tab rename 需要一个 <title>（带空格请加引号），或 --clear 恢复自动标题")
        }
        title = positionals[0]
      }
      let params = TabRenameParams(tab: tab, title: title)
      try mapValidation { try params.validate() }
      return .tabRename(params)
    default:
      throw AsterCLIArgumentError("未知子命令: tab \(subcommand)")
    }
  }
}
