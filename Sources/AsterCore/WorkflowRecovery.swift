import Foundation

/// 最近关闭历史中的恢复粒度。三类项目共用同一个栈，恢复顺序不按类型分组。
public enum WorkflowClosedItemKind: String, Codable, Equatable, Sendable {
  case pane
  case tab
  case window
}

/// 一个可恢复的关闭事件。`originWindowID` 让交付层把 Pane 或 Tab 放回原窗口；领域层
/// 不持有 AppKit Window、进程、文件描述符等运行态对象。
public struct WorkflowClosedItem: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let kind: WorkflowClosedItemKind
  public let originWindowID: UUID
  public let closedAt: Date

  public init(id: UUID, kind: WorkflowClosedItemKind, originWindowID: UUID, closedAt: Date) {
    self.id = id
    self.kind = kind
    self.originWindowID = originWindowID
    self.closedAt = closedAt
  }
}

/// 跨 Pane、Tab、Window 的统一 LIFO 恢复历史。
///
/// 官方行为固定保留最近 12 项；数组按关闭时间的发生顺序保存（最旧在前），因此 JSON
/// 持久化稳定，`popMostRecent` 从末尾恢复。调用方负责把实际可重建快照与 `id` 关联。
public struct WorkflowRecoveryHistory: Codable, Equatable, Sendable {
  public static let maximumEntries = 12
  public private(set) var entries: [WorkflowClosedItem]

  public init(entries: [WorkflowClosedItem] = []) {
    self.entries = Array(
      entries.filter { $0.closedAt.timeIntervalSinceReferenceDate.isFinite }
        .suffix(Self.maximumEntries)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case entries
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      entries: try container.decodeIfPresent([WorkflowClosedItem].self, forKey: .entries) ?? [])
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entries, forKey: .entries)
  }

  /// 记录一次关闭事件。非法时间不会污染持久化历史。
  @discardableResult
  public mutating func record(_ item: WorkflowClosedItem) -> Bool {
    guard item.closedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
    entries.append(item)
    if entries.count > Self.maximumEntries {
      entries.removeFirst(entries.count - Self.maximumEntries)
    }
    return true
  }

  /// 返回最后关闭的项目；Pane、Tab、Window 严格共享同一 LIFO 顺序。
  public mutating func popMostRecent() -> WorkflowClosedItem? {
    entries.popLast()
  }
}

/// 上次会话结束的分类。更新重启与异常退出都绕过普通 `on-launch` 偏好。
public enum WorkflowSessionEndReason: String, Codable, Equatable, Sendable {
  case cleanQuit
  case crash
  case forceQuit
  case inPlaceUpdate
}

public enum WorkflowOnLaunchBehavior: String, Codable, Equatable, Sendable {
  case restoreSession
  case newWindow
}

public enum WorkflowSessionRecoveryDecision: Equatable, Sendable {
  case restoreSnapshot(reason: WorkflowSessionEndReason)
  case openNewWindow
  case startFreshAfterCrashLoop
}

/// 启动时的纯恢复决策。重复崩溃次数由运行层判断并折叠为 `crashLoopDetected`，因为官方
/// 文档只承诺“几次后停止自动恢复”，没有承诺可持久化的固定阈值。
public enum WorkflowSessionRecoveryPlanner {
  public static func plan(
    after reason: WorkflowSessionEndReason,
    onLaunch: WorkflowOnLaunchBehavior,
    snapshotAvailable: Bool,
    crashLoopDetected: Bool = false
  ) -> WorkflowSessionRecoveryDecision {
    if crashLoopDetected, reason == .crash || reason == .forceQuit {
      return .startFreshAfterCrashLoop
    }
    guard snapshotAvailable else { return .openNewWindow }
    switch reason {
    case .cleanQuit:
      return onLaunch == .restoreSession ? .restoreSnapshot(reason: reason) : .openNewWindow
    case .crash, .forceQuit, .inPlaceUpdate:
      return .restoreSnapshot(reason: reason)
    }
  }
}

public enum WorkflowProcessRestoreMode: String, Codable, Equatable, Sendable {
  case none
  case whitelistedOnly
  case allRunningProcesses
}

/// 恢复 Pane 时是否可重新运行其进程。默认 `.none` 必须由设置层显式传入其它值。
public enum WorkflowProcessRecoveryPolicy {
  /// 白名单按空白分隔 token 前缀匹配：`npm run dev` 匹配附加参数，但不匹配
  /// `npm run device`。非法、空或超长命令始终拒绝，避免恢复层放大损坏快照。
  public static func shouldRerun(
    _ command: String,
    mode: WorkflowProcessRestoreMode,
    whitelist: [String]
  ) -> Bool {
    guard let commandTokens = tokens(command) else { return false }
    switch mode {
    case .none:
      return false
    case .allRunningProcesses:
      return true
    case .whitelistedOnly:
      return whitelist.contains { entry in
        guard let prefix = tokens(entry), prefix.count <= commandTokens.count else { return false }
        return Array(commandTokens.prefix(prefix.count)) == prefix
      }
    }
  }

  private static func tokens(_ command: String) -> [Substring]? {
    guard !command.isEmpty, command.utf8.count <= WorkflowRecipeTOML.maximumCommandBytes,
      !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let result = command.split(whereSeparator: { $0.isWhitespace })
    return result.isEmpty ? nil : result
  }
}

/// 单个 Pane 可恢复内容的稳定分类；各项是否启用由用户设置决定。
public enum WorkflowPaneRecoveryCategory: Equatable, Sendable {
  case multiplexer(sessionIdentifier: String)
  case codeAgent(provider: String, sessionIdentifier: String)
  case runningProcess(command: String)
  case cleanShell
}

public struct WorkflowPaneRecoverySettings: Equatable, Sendable {
  public var restoreMultiplexers: Bool
  public var restoreCodeAgents: Bool
  public var processMode: WorkflowProcessRestoreMode
  public var commandWhitelist: [String]

  public init(
    restoreMultiplexers: Bool = true,
    restoreCodeAgents: Bool = true,
    processMode: WorkflowProcessRestoreMode = .none,
    commandWhitelist: [String] = []
  ) {
    self.restoreMultiplexers = restoreMultiplexers
    self.restoreCodeAgents = restoreCodeAgents
    self.processMode = processMode
    self.commandWhitelist = Array(commandWhitelist.prefix(WorkflowRecipeTOML.maximumCommands))
  }
}

public enum WorkflowPaneRecoveryDecision: Equatable, Sendable {
  case reattachMultiplexer(sessionIdentifier: String)
  case resumeCodeAgent(provider: String, sessionIdentifier: String)
  case rerunProcess(command: String)
  case openCleanShell
}

/// 将 Pane 恢复分类与用户设置合并成描述；不拼接 Shell 字符串，也不启动进程。
public enum WorkflowPaneRecoveryPlanner {
  public static func plan(
    category: WorkflowPaneRecoveryCategory,
    settings: WorkflowPaneRecoverySettings
  ) -> WorkflowPaneRecoveryDecision {
    switch category {
    case .multiplexer(let sessionIdentifier) where settings.restoreMultiplexers:
      return .reattachMultiplexer(sessionIdentifier: sessionIdentifier)
    case .codeAgent(let provider, let sessionIdentifier) where settings.restoreCodeAgents:
      return .resumeCodeAgent(provider: provider, sessionIdentifier: sessionIdentifier)
    case .runningProcess(let command)
    where WorkflowProcessRecoveryPolicy.shouldRerun(
      command,
      mode: settings.processMode,
      whitelist: settings.commandWhitelist
    ):
      return .rerunProcess(command: command)
    default:
      return .openCleanShell
    }
  }
}
