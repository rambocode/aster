import Foundation

/// OSC 88 终端恢复协议(对齐 Otty 的设置语义)。程序可以声明自己重启后应如何被重新拉起:
///
/// - `OSC 88 ; query ST`                 → 终端回复 `OSC 88 ; supported ; v=1 ST`
/// - `OSC 88 ; restart=<command> ST`     → 声明恢复命令(也接受 `resume=` 前缀或裸命令)
/// - `OSC 88 ; clear ST`                 → 撤销此前的声明
///
/// 命令只保存到工作区快照,恢复时在首个 prompt 处以普通输入写入 PTY;不做任何解释执行。
public enum TerminalResumeProtocol {
  public static let version = 1
  public static let maximumPayloadBytes = 4_096
  public static let supportedResponse = "\u{1B}]88;supported;v=\(version)\u{07}"

  public enum Directive: Equatable, Sendable {
    case query
    case declare(String)
    case clear
  }

  /// 解析 OSC 88 载荷。控制字符或超长载荷直接丢弃,避免把终端转义序列写进快照。
  public static func parse(_ payload: String) -> Directive? {
    guard payload.utf8.count <= maximumPayloadBytes,
      !payload.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let trimmed = payload.trimmingCharacters(in: .whitespaces)
    switch trimmed.lowercased() {
    case "query", "?": return .query
    case "clear", "": return .clear
    default: break
    }
    for prefix in ["restart=", "resume=", "command="] where trimmed.lowercased().hasPrefix(prefix) {
      let command = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      return command.isEmpty ? .clear : .declare(command)
    }
    return .declare(trimmed)
  }
}

/// 快照中某个 Pane 的恢复命令及其来源。来源决定恢复时受哪个设置开关控制。
public struct WorkspacePaneRestoreCommand: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Equatable, Sendable {
    /// tmux / screen 重新附着(设置「恢复复用器会话」)。
    case multiplexer
    /// 程序通过 OSC 88 声明的重启命令(设置「终端恢复协议」)。
    case resumeProtocol
    /// 快照时正在前台运行的命令(设置「恢复时重新运行进程」)。
    case process
  }

  public let paneID: UUID
  public let command: String
  public let source: Source

  public init(paneID: UUID, command: String, source: Source) {
    self.paneID = paneID
    self.command = command
    self.source = source
  }
}

/// 决定一个终端 Pane 在快照/恢复时的恢复命令。纯函数,快照与恢复两端共用同一套判断:
/// 快照时用它挑出值得记录的命令,恢复时再按当时的设置决定是否真的发送。
public enum SessionRestorePlanner {
  public static let multiplexers: Set<String> = ["tmux", "screen"]

  /// 快照阶段:根据前台命令和 OSC 88 声明生成候选。优先级:OSC 88 声明 > 复用器 > 普通进程。
  /// 这里不看设置——设置在恢复时读取,避免用户改完设置还要重新退出一次才生效。
  public static func snapshotCommand(
    paneID: UUID,
    foregroundCommand: String?,
    resumeProtocolCommand: String?
  ) -> WorkspacePaneRestoreCommand? {
    if let declared = sanitized(resumeProtocolCommand) {
      return WorkspacePaneRestoreCommand(paneID: paneID, command: declared, source: .resumeProtocol)
    }
    guard let command = sanitized(foregroundCommand) else { return nil }
    if let attach = multiplexerAttachCommand(for: command) {
      return WorkspacePaneRestoreCommand(paneID: paneID, command: attach, source: .multiplexer)
    }
    return WorkspacePaneRestoreCommand(paneID: paneID, command: command, source: .process)
  }

  /// 恢复阶段:按设置决定是否发送。`restoreProcesses` 为 whitelist 时按前缀匹配 allowlist。
  public static func shouldRestore(
    _ record: WorkspacePaneRestoreCommand,
    shell: ShellConfiguration
  ) -> Bool {
    switch record.source {
    case .multiplexer: return shell.restoreMultiplexerSessions
    case .resumeProtocol: return shell.resolvedTerminalResumeProtocol
    case .process:
      guard shell.restoreProcesses else { return false }
      if shell.resolvedRestoreProcessesScope == .all { return true }
      return matchesAllowlist(record.command, allowlist: shell.resolvedRestoreProcessAllowlist)
    }
  }

  /// 把 `tmux new -s work` / `tmux a -t work` / `screen -S name` 之类的调用换算成重新附着命令。
  /// 解析不出会话名时退回无参 attach(tmux 会附着最近会话,screen -r 单会话时直接恢复)。
  public static func multiplexerAttachCommand(for command: String) -> String? {
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard let executable = tokens.first.map({ ($0 as NSString).lastPathComponent }),
      multiplexers.contains(executable)
    else { return nil }
    let name: String?
    switch executable {
    case "tmux": name = value(after: ["-t", "-s"], in: tokens)
    default: name = value(after: ["-S", "-r", "-x", "-d", "-R"], in: tokens)
    }
    let quoted = name.map { " " + ShellQuoting.singleQuoted($0) } ?? ""
    return executable == "tmux" ? "tmux attach\(quoted.isEmpty ? "" : " -t" + quoted)" : "screen -r\(quoted)"
  }

  /// 白名单按逗号分隔,每项做命令前缀匹配(`npm run` 匹配 `npm run dev`)。
  public static func matchesAllowlist(_ command: String, allowlist: [String]) -> Bool {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    return allowlist.contains { entry in
      let prefix = entry.trimmingCharacters(in: .whitespaces)
      guard !prefix.isEmpty, trimmed.hasPrefix(prefix) else { return false }
      let rest = trimmed.dropFirst(prefix.count)
      return rest.isEmpty || rest.first?.isWhitespace == true
    }
  }

  private static func value(after flags: [String], in tokens: [String]) -> String? {
    for (index, token) in tokens.enumerated() where flags.contains(token) && index + 1 < tokens.count {
      let candidate = tokens[index + 1]
      if !candidate.hasPrefix("-") && !candidate.isEmpty { return candidate }
    }
    return nil
  }

  private static func sanitized(_ command: String?) -> String? {
    guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
      command.utf8.count <= TerminalResumeProtocol.maximumPayloadBytes,
      !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return command
  }
}

/// POSIX 单引号转义,供恢复命令拼接会话名。
public enum ShellQuoting {
  public static func singleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public enum RestoreProcessesScope: String, Codable, Equatable, Sendable {
  case whitelist
  case all
}
