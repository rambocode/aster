import Foundation

/// OSC 133 FinalTerm Command Status (FTCS) 事件。Aster 只接受协议定义的最小形态，
/// 不从控制序列接收命令文本，避免恶意程序借标记通道把敏感内容写入持久状态。
public enum ShellIntegrationEvent: Equatable, Sendable {
  case promptStart
  case inputStart
  case commandStart
  case commandFinished(exitStatus: Int?)

  public init?(payload: String) {
    switch payload {
    // Ghostty 按 FinalTerm 扩展在 A 后附加 `cl=line`，它只描述提示符行语义，
    // 不携带命令正文。仅接受这个已知属性，继续拒绝 C 后的任意文本，避免扩大
    // 控制序列可伪造的业务输入面。
    case "A", "A;cl=line": self = .promptStart
    case "B": self = .inputStart
    case "C": self = .commandStart
    case "D": self = .commandFinished(exitStatus: nil)
    default:
      guard payload.hasPrefix("D;"), payload.dropFirst(2).allSatisfy(\.isNumber),
        let status = Int(payload.dropFirst(2)), status >= 0
      else { return nil }
      self = .commandFinished(exitStatus: status)
    }
  }
}

/// Shell Integration 上报的当前别名名称。只接收名称，不接收 alias 展开内容，避免
/// 凭据或复杂 Shell 语法进入应用；payload 上限与名称字符集也阻止控制序列注入。
public struct ShellAliasReport: Equatable, Sendable {
  public let names: [String]

  public init?(payload: String) {
    guard payload.hasPrefix("Aliases="), payload.utf8.count <= 8_192,
      payload.unicodeScalars.allSatisfy({ scalar in
        scalar.value >= 0x20 && scalar.value <= 0x7E
      })
    else { return nil }
    let source = payload.dropFirst("Aliases=".count)
    let values = source.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
    guard values.count <= 500, values.allSatisfy({ value in
      !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy(allowed.contains)
    }) else { return nil }
    names = Array(Set(values)).sorted()
  }
}

/// 不依赖渲染框架的终端网格位置。row 使用包含已裁剪 scrollback 的单调绝对行号，
/// 因而缓冲区到达上限后继续输出也不会让历史命令锚点漂移。
public struct TerminalGridPoint: Equatable, Sendable {
  public let column: Int
  public let row: Int

  public init(column: Int, row: Int) {
    self.column = max(column, 0)
    self.row = max(row, 0)
  }
}

/// 一条已完成命令的提示符、输入和输出边界。命令文本不属于此记录；后续本地学习层
/// 只能从用户输入路径取得文本，并按隐私规则脱敏后另行存储。
public struct ShellCommandMark: Equatable, Sendable {
  public let promptStart: TerminalGridPoint
  public let inputStart: TerminalGridPoint
  public let outputStart: TerminalGridPoint
  public let outputEnd: TerminalGridPoint
  public let exitStatus: Int?
  /// 命令完成（OSC 133 D）落记录的本地时间，供 Outline 显示相对时间；仅展示用。
  public let finishedAt: Date?
}

/// 正在运行的命令尚未拥有输出终点和退出状态，但 Outline 仍需要其可靠的提示符与输入锚点。
/// 它只存在于当前 Pane 的运行态，命令完成后会被完整 `ShellCommandMark` 取代。
public struct ShellRunningCommand: Equatable, Sendable {
  public let promptStart: TerminalGridPoint
  public let inputStart: TerminalGridPoint
  public let outputStart: TerminalGridPoint
}

/// 将有序 OSC 133 事件折叠成有界命令时间线，供 Outline、命令跳转、退出状态和
/// Autocomplete 成功判定复用。乱序或缺失标记会被丢弃，绝不跨提示符拼接伪记录。
public struct ShellCommandTimeline: Equatable, Sendable {
  public private(set) var marks: [ShellCommandMark] = []
  public private(set) var integrationDetected = false
  public private(set) var isCommandRunning = false

  private let capacity: Int
  private var promptStart: TerminalGridPoint?
  private var inputStart: TerminalGridPoint?
  private var outputStart: TerminalGridPoint?

  /// 当前等待用户编辑的提示符输入起点。命令开始或完成后立即清空，避免把输出区
  /// 误当成可删除文本。
  public var currentInputStart: TerminalGridPoint? {
    isCommandRunning ? nil : inputStart
  }

  /// 最近完成命令明确提供的退出码。最后一条记录没有状态时返回 nil，调用方不得
  /// 沿用更早命令的徽标，否则会把未知结果误报成已知成功或失败。
  public var latestExitStatus: Int? {
    marks.last?.exitStatus
  }

  /// 当前命令只在完整收到 A/B/C 后公开。缺失或乱序 OSC 标记不会产生可导航的伪记录。
  public var runningCommand: ShellRunningCommand? {
    guard isCommandRunning, let promptStart, let inputStart, let outputStart else { return nil }
    return ShellRunningCommand(
      promptStart: promptStart,
      inputStart: inputStart,
      outputStart: outputStart
    )
  }

  public init(capacity: Int = 1_000) {
    self.capacity = max(capacity, 1)
  }

  public mutating func receive(_ event: ShellIntegrationEvent, at point: TerminalGridPoint) {
    integrationDetected = true
    switch event {
    case .promptStart:
      promptStart = point
      inputStart = nil
      outputStart = nil
      isCommandRunning = false
    case .inputStart:
      guard promptStart != nil else { return }
      inputStart = point
    case .commandStart:
      guard promptStart != nil, inputStart != nil else {
        outputStart = nil
        isCommandRunning = false
        return
      }
      outputStart = point
      isCommandRunning = true
    case .commandFinished(let exitStatus):
      defer {
        promptStart = nil
        inputStart = nil
        outputStart = nil
        isCommandRunning = false
      }
      guard let promptStart, let inputStart, let outputStart else { return }
      marks.append(
        ShellCommandMark(
          promptStart: promptStart,
          inputStart: inputStart,
          outputStart: outputStart,
          outputEnd: point,
          exitStatus: exitStatus,
          finishedAt: Date()
        )
      )
      if marks.count > capacity {
        marks.removeFirst(marks.count - capacity)
      }
    }
  }

  public func previousCommand(beforeOrAt row: Int) -> ShellCommandMark? {
    marks.last { $0.promptStart.row <= row }
  }

  public func nextCommand(after row: Int) -> ShellCommandMark? {
    marks.first { $0.promptStart.row > row }
  }
}

public struct PromptSelectionDeletionPlan: Equatable, Sendable {
  /// 从当前 Shell 光标移动到选区末端的列数；负数向左，正数向右。
  public let horizontalMovement: Int
  public let deleteCount: Int

  public init(horizontalMovement: Int, deleteCount: Int) {
    self.horizontalMovement = horizontalMovement
    self.deleteCount = deleteCount
  }
}

/// 把终端视觉选区转换成行编辑器可安全执行的删除计划。Unicode 宽度、换行折叠和
/// 矩形选区无法仅凭网格位置无损映射到 readline 字符，因此这些情况宁可退化为复制。
public enum PromptSelectionDeletionPolicy {
  public static func plan(
    inputStart: TerminalGridPoint,
    cursor: TerminalGridPoint,
    selectionStart: TerminalGridPoint,
    selectionEnd: TerminalGridPoint,
    selectedText: String,
    rectangular: Bool,
    commandRunning: Bool
  ) -> PromptSelectionDeletionPlan? {
    guard !rectangular, !commandRunning, !selectedText.isEmpty,
      selectedText.utf8.allSatisfy({ (0x20...0x7E).contains($0) }),
      inputStart.row == cursor.row,
      selectionStart.row == cursor.row,
      selectionEnd.row == cursor.row
    else { return nil }
    let lowerColumn = min(selectionStart.column, selectionEnd.column)
    let upperColumn = lowerColumn + selectedText.utf8.count
    guard lowerColumn >= inputStart.column,
      upperColumn <= max(selectionStart.column, selectionEnd.column),
      upperColumn >= lowerColumn
    else { return nil }
    return PromptSelectionDeletionPlan(
      horizontalMovement: upperColumn - cursor.column,
      deleteCount: selectedText.utf8.count
    )
  }
}

public enum IntegratedShell: String, Equatable, Sendable {
  case zsh
  case bash
  case fish
}

/// 支持 Shell 的会话级环境注入计划。Bash 没有可靠的仅当前进程启动文件入口，实际
/// source 由受管 rc block 完成；这里仍注入同一开关和资源路径，供 block 做双重校验。
public struct ShellIntegrationLaunchPlan: Equatable, Sendable {
  public let shell: IntegratedShell
  public let environment: [String: String]

  public static func make(
    shellPath: String,
    enabled: Bool,
    resourceDirectory: String,
    inheritedEnvironment: [String: String]
  ) -> ShellIntegrationLaunchPlan? {
    guard enabled, inheritedEnvironment["ASTER_DISABLE_INTEGRATION"] != "1",
      !resourceDirectory.isEmpty
    else { return nil }

    let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
    guard let shell = IntegratedShell(rawValue: shellName) else { return nil }
    var environment = inheritedEnvironment
    environment["ASTER_INTEGRATION"] = "1"
    environment["ASTER_SHELL_INTEGRATION_DIR"] = resourceDirectory

    switch shell {
    case .zsh:
      let hadZDOTDIR = inheritedEnvironment["ZDOTDIR"] != nil
      environment["ASTER_REAL_ZDOTDIR"] = inheritedEnvironment["ZDOTDIR"]
        ?? (inheritedEnvironment["HOME"] ?? "")
      environment["ASTER_REAL_ZDOTDIR_SET"] = hadZDOTDIR ? "1" : "0"
      environment["ZDOTDIR"] = "\(resourceDirectory)/zsh"
    case .fish:
      let fishDataDirectory = "\(resourceDirectory)/fish"
      let inheritedDirectories = inheritedEnvironment["XDG_DATA_DIRS"]
        ?? "/usr/local/share:/usr/share"
      let directories = ([fishDataDirectory] + inheritedDirectories.split(separator: ":").map(String.init))
        .reduce(into: [String]()) { result, item in
          if !item.isEmpty, !result.contains(item) { result.append(item) }
        }
      environment["ASTER_FISH_DATA_DIR"] = fishDataDirectory
      environment["XDG_DATA_DIRS"] = directories.joined(separator: ":")
    case .bash:
      break
    }
    return ShellIntegrationLaunchPlan(shell: shell, environment: environment)
  }
}
