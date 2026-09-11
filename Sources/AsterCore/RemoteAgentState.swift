import Foundation

/// 远端 Agent 的运行状态（P5）。与协议层的 agent 对象对齐，用于 JSON 解码服务响应。

/// 远端 Agent 的状态枚举。
public enum RemoteAgentStatus: String, Codable, Equatable, Sendable, CaseIterable {
  case idle
  case working
  case blocked
  case done
  case unknown
}

/// 状态来源权威等级。
public enum RemoteAgentAuthority: String, Codable, Equatable, Sendable {
  /// hook 集成上报的权威状态。
  case hook
  /// 屏幕检测推断的状态。
  case screen
  /// 静默启发式（无 hook 也无屏幕检测时的兜底）。
  case heuristic
}

/// 单个远端 Agent 的完整信息。可从服务端 JSON 响应解码。
public struct RemoteAgentInfo: Codable, Equatable, Sendable {
  /// 所属终端 ID。
  public var terminalID: String
  /// Agent provider 标识。
  public var provider: AgentProvider
  /// 当前运行状态。
  public var state: RemoteAgentStatus
  /// Agent 会话名（provider 上报的显示名）。
  public var name: String?
  /// provider 原生会话标识（用于续接）。
  public var nativeSession: String?
  /// 状态来源。
  public var source: RemoteAgentAuthority
  /// 是否有未读完成通知。
  public var unread: Bool

  public init(
    terminalID: String,
    provider: AgentProvider,
    state: RemoteAgentStatus,
    name: String? = nil,
    nativeSession: String? = nil,
    source: RemoteAgentAuthority = .heuristic,
    unread: Bool = false
  ) {
    self.terminalID = terminalID
    self.provider = provider
    self.state = state
    self.name = name
    self.nativeSession = nativeSession
    self.source = source
    self.unread = unread
  }
}

/// 根据 provider 能力决定使用哪种状态权威。
public enum RemoteAgentStateAuthority {
  /// 确定给定 provider 应使用的状态检测权威。
  ///
  /// 与本地 `TerminalSession.syncAgentScreenMonitor` 的规则一致，而不是"有 hook 就 hook"：
  /// 只有 hook 覆盖完整生命周期（`fullLifecycleHooks`：openCode/pi/omp/kimiCode）的
  /// provider 才由 hook 单独裁决状态。Claude Code、Codex、Grok Build 这类 hook 只有
  /// 部分事件（Grok 没有权限请求与 Stop 事件），"等待批准"与"回到空闲"只能从屏幕看出，
  /// 所以它们以屏幕为状态权威，hook 只负责识别 provider、绑定原生会话并提供工作证据；
  /// 隐藏/分离后没有画面时才退回 hook 上报的状态。
  public static func resolve(for provider: AgentProvider) -> RemoteAgentAuthority {
    if provider.capabilities.contains(.fullLifecycleHooks) {
      return .hook
    }
    if provider.detectionManifestID != nil {
      return .screen
    }
    if provider.supportsManagedIntegration {
      return .hook
    }
    return .heuristic
  }
}
