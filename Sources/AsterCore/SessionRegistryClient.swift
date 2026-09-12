import Foundation

/// P4.1 客户端半边：命名会话注册表。
///
/// 依据 `docs/developer/remote-work.md` §4.1 与 §4.2 操作结果表：
/// - 注册表作用域（`session.list/create/attach/stop/delete`）不绑定单个命名会话，
///   因此使用独立的 `ManagedRegistryEndpoint`，它**没有** `sessionName`。
/// - 停止只结束该会话的全部进程并保留布局快照；删除要求已停止，活动会话必须把
///   服务端 `session_running` 原样暴露出来，不能改写成通用失败。
/// - 参数形状集中在 `ManagedSessionCommand`，本机与 SSH 两条传输复用同一份 argv。

/// 命名会话的运行状态。与 `SessionConnectionState`（客户端连接）严格分开：
/// 会话停止不等于机器离线，机器离线也不等于会话已停止。
public enum NamedSessionState: String, Codable, Equatable, Sendable, CaseIterable {
  case running
  case stopped
  case attention
}

/// 注册表里一条命名会话的描述。
///
/// `serverID` / `serverEpoch` 只有在会话有活动服务实例时才存在；停止的会话没有
/// 运行中的服务实例，所以这两个字段可缺失，缺失不代表身份未知，而代表当前无实例。
public struct NamedSessionDescriptor: Codable, Equatable, Sendable, Identifiable {
  public var sessionID: String
  public var name: String
  public var state: NamedSessionState
  public var serverID: String?
  public var serverEpoch: String?

  public var id: String { sessionID }

  public init(
    sessionID: String,
    name: String,
    state: NamedSessionState,
    serverID: String? = nil,
    serverEpoch: String? = nil
  ) {
    self.sessionID = sessionID
    self.name = name
    self.state = state
    self.serverID = serverID
    self.serverEpoch = serverEpoch
  }
}

/// 注册表作用域的定位信息。
///
/// 注册表操作跨越该 `stateParentPath` 下的**全部**命名会话，因此这里刻意不带
/// `sessionName`；带上会话名会诱导调用方把注册表动作误用成会话内动作。
public struct ManagedRegistryEndpoint: Equatable, Sendable {
  public var machineProfileID: UUID
  public var binaryPath: String
  public var stateParentPath: String

  public init(
    machineProfileID: UUID = MachineProfile.localProfileID,
    binaryPath: String,
    stateParentPath: String
  ) {
    self.machineProfileID = machineProfileID
    self.binaryPath = binaryPath
    self.stateParentPath = stateParentPath
  }

  /// 从已有会话端点派生注册表端点，避免调用方手工复制路径而写错。
  public init(_ endpoint: ManagedSessionEndpoint) {
    self.init(
      machineProfileID: endpoint.machineProfileID,
      binaryPath: endpoint.binaryPath,
      stateParentPath: endpoint.stateParentPath
    )
  }

  /// 在本注册表内定位一个命名会话的会话端点。
  public func sessionEndpoint(name: String) -> ManagedSessionEndpoint {
    ManagedSessionEndpoint(
      machineProfileID: machineProfileID,
      binaryPath: binaryPath,
      stateParentPath: stateParentPath,
      sessionName: name
    )
  }
}

/// 会话选择器：CLI 同时接受名称与 sessionID（`<name-or-id>`）。
///
/// 用独立类型而不是裸字符串，是为了让调用方在使用停止/删除这类破坏性动作时
/// 必须显式说明用的是哪种标识，避免把显示名当成身份。
public enum NamedSessionSelector: Equatable, Sendable {
  case name(String)
  case sessionID(String)

  /// CLI 位置参数的文本形式。
  public var argument: String {
    switch self {
    case .name(let value): value
    case .sessionID(let value): value
    }
  }
}

extension ManagedSessionError {
  /// 服务端拒绝删除运行中会话。调用方据此提示“先停止再删除”，不改写成通用错误。
  public var isSessionRunning: Bool {
    if case .serviceError(let code, _) = self { return code == "session_running" }
    return false
  }

  /// 服务端找不到该会话。
  public var isSessionNotFound: Bool {
    if case .serviceError(let code, _) = self { return code == "session_not_found" }
    return false
  }

  /// 同名会话已存在。
  public var isSessionExists: Bool {
    if case .serviceError(let code, _) = self { return code == "session_exists" }
    return false
  }
}

extension ManagedSessionCommand {
  /// `aster-session session list <state-parent>`
  public static func sessionList(_ endpoint: ManagedRegistryEndpoint) -> [String] {
    ["session", "list", endpoint.stateParentPath]
  }

  /// `aster-session session create <state-parent> <name>`
  public static func sessionCreate(_ endpoint: ManagedRegistryEndpoint, name: String) -> [String] {
    ["session", "create", endpoint.stateParentPath, name]
  }

  /// `aster-session session attach <state-parent> <name-or-id>`
  public static func sessionAttach(
    _ endpoint: ManagedRegistryEndpoint,
    selector: NamedSessionSelector
  ) -> [String] {
    ["session", "attach", endpoint.stateParentPath, selector.argument]
  }

  /// `aster-session session stop <state-parent> <name-or-id>`
  public static func sessionStop(
    _ endpoint: ManagedRegistryEndpoint,
    selector: NamedSessionSelector
  ) -> [String] {
    ["session", "stop", endpoint.stateParentPath, selector.argument]
  }

  /// `aster-session session delete <state-parent> <name-or-id>`
  public static func sessionDelete(
    _ endpoint: ManagedRegistryEndpoint,
    selector: NamedSessionSelector
  ) -> [String] {
    ["session", "delete", endpoint.stateParentPath, selector.argument]
  }
}

extension ManagedSessionReplyDecoder {
  /// 解析注册表里的单条会话。
  ///
  /// `state` 未知时**直接报错**而不是猜一个值：注册表状态直接决定“能否删除”“是否
  /// 还有进程在跑”，猜错会导致误删或误报完成。
  public static func namedSession(_ raw: [String: Any]) throws -> NamedSessionDescriptor {
    guard let sessionID = raw["sessionID"] as? String, !sessionID.isEmpty else {
      throw ManagedSessionError.malformedReply("missing sessionID")
    }
    guard let name = raw["name"] as? String, !name.isEmpty else {
      throw ManagedSessionError.malformedReply("missing session name")
    }
    guard let stateText = raw["state"] as? String,
      let state = NamedSessionState(rawValue: stateText)
    else {
      throw ManagedSessionError.malformedReply("unknown session state")
    }
    return NamedSessionDescriptor(
      sessionID: sessionID,
      name: name,
      state: state,
      serverID: raw["serverID"] as? String,
      serverEpoch: raw["serverEpoch"] as? String
    )
  }

  /// 从一次注册表回复里取出 `result` 段。
  public static func result(_ json: [String: Any]) throws -> [String: Any] {
    guard let result = json["result"] as? [String: Any] else {
      throw ManagedSessionError.malformedReply("missing result")
    }
    return result
  }
}

extension ManagedSessionClient {
  /// 列出该机器上全部命名会话（含已停止的），用于侧栏与 CLI。
  public func listSessions(_ endpoint: ManagedRegistryEndpoint) throws -> [NamedSessionDescriptor] {
    let json = try ManagedSessionReplyDecoder.envelope(
      try executeStructured(
        binaryPath: endpoint.binaryPath,
        arguments: ManagedSessionCommand.sessionList(endpoint)))
    let raw = (try ManagedSessionReplyDecoder.result(json))["sessions"] as? [[String: Any]] ?? []
    return try raw.map { try ManagedSessionReplyDecoder.namedSession($0) }
  }

  /// 创建命名会话；同名已存在时服务端返回 `session_exists`，不静默复用。
  public func createSession(
    _ endpoint: ManagedRegistryEndpoint,
    name: String
  ) throws -> NamedSessionDescriptor {
    let json = try ManagedSessionReplyDecoder.envelope(
      try executeStructured(
        binaryPath: endpoint.binaryPath,
        arguments: ManagedSessionCommand.sessionCreate(endpoint, name: name)))
    return try ManagedSessionReplyDecoder.namedSession(
      try ManagedSessionReplyDecoder.result(json))
  }

  /// 附加到已存在的命名会话；这是只读查询，不创建、不启动缺失的会话。
  public func attachSession(
    _ endpoint: ManagedRegistryEndpoint,
    selector: NamedSessionSelector
  ) throws -> NamedSessionDescriptor {
    let json = try ManagedSessionReplyDecoder.envelope(
      try executeStructured(
        binaryPath: endpoint.binaryPath,
        arguments: ManagedSessionCommand.sessionAttach(endpoint, selector: selector)))
    return try ManagedSessionReplyDecoder.namedSession(
      try ManagedSessionReplyDecoder.result(json))
  }

  /// 停止命名会话：结束该会话的全部进程并保留布局快照，**只影响该会话**。
  public func stopSession(
    _ endpoint: ManagedRegistryEndpoint,
    selector: NamedSessionSelector
  ) throws -> NamedSessionDescriptor {
    let json = try ManagedSessionReplyDecoder.envelope(
      try executeStructured(
        binaryPath: endpoint.binaryPath,
        arguments: ManagedSessionCommand.sessionStop(endpoint, selector: selector)))
    return try ManagedSessionReplyDecoder.namedSession(
      try ManagedSessionReplyDecoder.result(json))
  }

  /// 删除命名会话。会话仍在运行时服务端返回 `session_running`，这里原样抛出，
  /// 让上层能明确提示“先停止”，而不是把它降级成通用失败或自动先停止再删除。
  @discardableResult
  public func deleteSession(
    _ endpoint: ManagedRegistryEndpoint,
    selector: NamedSessionSelector
  ) throws -> Bool {
    let json = try ManagedSessionReplyDecoder.envelope(
      try executeStructured(
        binaryPath: endpoint.binaryPath,
        arguments: ManagedSessionCommand.sessionDelete(endpoint, selector: selector)))
    let result = try ManagedSessionReplyDecoder.result(json)
    guard let deleted = result["deleted"] as? Bool else {
      throw ManagedSessionError.malformedReply("missing deleted flag")
    }
    return deleted
  }
}
