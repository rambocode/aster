import Foundation

/// P4.2 客户端半边：布局事务客户端（乐观并发）。
///
/// 依据 `docs/developer/remote-work.md` §5：修改布局使用乐观并发，每个结构变更都必须
/// 携带 `expectedRevision`；冲突时服务端返回 `revision_conflict`。
///
/// 关键约束：服务端错误信封里的 `currentRevision` **可能存在也可能不存在**。两条路都要走：
/// 1. 有 `currentRevision` → 直接用它重试；
/// 2. 没有 → 用 `session.snapshot` 重新取快照拿新 revision 再重试。
/// `retryWithFreshSnapshot` 把两条路统一起来，且**只重试一次**——无限重试会在两客户端
/// 持续互相打断时变成活锁，也会让用户看不到真实冲突。

/// 布局事务错误。
public enum WorkspaceTransactionError: Error, Equatable, Sendable {
  /// 乐观并发冲突。`currentRevision` 由服务端可选提供；nil 表示必须重新取快照。
  case revisionConflict(currentRevision: UInt64?)
  /// 重试之后仍然冲突。不再继续重试，交给调用方决定。
  case conflictAfterRetry(currentRevision: UInt64?)
  /// 响应缺少必需字段。
  case malformedReply(String)
  /// 其它服务端错误，原样透传 code。
  case serviceError(code: String, message: String?)
}

/// 一次结构变更的结果：新的 revision + 变更后的对象。
public struct WorkspaceTransactionResult<Value: Equatable & Sendable>: Equatable, Sendable {
  public var revision: UInt64
  public var value: Value

  public init(revision: UInt64, value: Value) {
    self.revision = revision
    self.value = value
  }
}

/// `pane.split` 的结果：新窗格 + 该窗格里新建终端的实测状态。
///
/// 用具名结构而不是元组：元组无法遵循 `Equatable`/`Sendable`，也无法在界面层安全传递。
public struct RemotePaneSplitResult: Equatable, Sendable {
  public var pane: RemotePane
  public var terminal: ManagedTerminalStatus

  public init(pane: RemotePane, terminal: ManagedTerminalStatus) {
    self.pane = pane
    self.terminal = terminal
  }
}

/// 新建受管终端的参数，对应 schema 的 `$defs/terminalSpec`。
public struct RemoteTerminalSpec: Equatable, Sendable {
  /// 执行机器上的绝对路径。由服务端校验存在性，不回落到本机目录。
  public var cwd: String
  public var argv: [String]

  public init(cwd: String, argv: [String]) {
    self.cwd = cwd
    self.argv = argv
  }
}

/// `session.restore` 里单个窗格的恢复记录（P6.4）。
public struct RemoteSessionRestoreEntry: Equatable, Sendable {
  public var paneID: String
  public var oldTerminalID: String
  public var newTerminalID: String
  /// 服务端选择的恢复路径：`new_shell` / `history_replay` / `agent_restore` / `failed`。
  public var path: String
  public var failureReason: String?

  public init(
    paneID: String, oldTerminalID: String, newTerminalID: String, path: String,
    failureReason: String? = nil
  ) {
    self.paneID = paneID
    self.oldTerminalID = oldTerminalID
    self.newTerminalID = newTerminalID
    self.path = path
    self.failureReason = failureReason
  }
}

/// `session.restore` 的完整结果：每个失效窗格的新旧 terminalID 映射，以及是否早已恢复过。
///
/// 服务端每次冷启动只允许恢复一次；`alreadyRestored == true` 时 `entries` 为空，
/// 调用方应重新取快照而不是再次请求。
public struct RemoteSessionRestoreResult: Equatable, Sendable {
  public var revision: UInt64
  public var entries: [RemoteSessionRestoreEntry]
  public var alreadyRestored: Bool

  public init(revision: UInt64, entries: [RemoteSessionRestoreEntry], alreadyRestored: Bool) {
    self.revision = revision
    self.entries = entries
    self.alreadyRestored = alreadyRestored
  }
}

extension ManagedSessionCommand {
  /// 结构变更共用的前缀与 `--expected-revision`。
  ///
  /// 集中生成的原因与 P2 相同：本机与 SSH 两条传输必须使用同一份 argv 形状。
  private static func structurePrefix(
    _ endpoint: ManagedSessionEndpoint,
    _ noun: String,
    _ verb: String,
    expectedRevision: UInt64
  ) -> [String] {
    [
      noun, verb, endpoint.stateParentPath, endpoint.sessionName,
      "--expected-revision", String(expectedRevision),
    ]
  }

  /// `session snapshot <state-parent> <name>`
  public static func sessionSnapshot(_ endpoint: ManagedSessionEndpoint) -> [String] {
    ["session", "snapshot", endpoint.stateParentPath, endpoint.sessionName]
  }

  /// `session restore <state-parent> <name> --rows <r> --columns <c>`
  ///
  /// 冷恢复（P6.4）：服务端为持久化布局里已失效的窗格创建新终端。尺寸只是初始值，
  /// 显示桥附加后会按真实画面重新调整。
  public static func sessionRestore(
    _ endpoint: ManagedSessionEndpoint, rows: Int, columns: Int
  ) -> [String] {
    [
      "session", "restore", endpoint.stateParentPath, endpoint.sessionName,
      "--rows", String(rows), "--columns", String(columns),
    ]
  }

  /// `workspace list <state-parent> <name>`
  public static func workspaceList(_ endpoint: ManagedSessionEndpoint) -> [String] {
    ["workspace", "list", endpoint.stateParentPath, endpoint.sessionName]
  }

  /// `workspace create … --title <t> --cwd <abs> -- <argv...>`
  public static func workspaceCreate(
    _ endpoint: ManagedSessionEndpoint,
    expectedRevision: UInt64,
    title: String,
    terminal: RemoteTerminalSpec
  ) -> [String] {
    structurePrefix(endpoint, "workspace", "create", expectedRevision: expectedRevision)
      + ["--title", title, "--cwd", terminal.cwd, "--"] + terminal.argv
  }

  /// `workspace update … --workspace <id> --title <t>`
  public static func workspaceUpdate(
    _ endpoint: ManagedSessionEndpoint,
    workspaceID: String,
    expectedRevision: UInt64,
    title: String
  ) -> [String] {
    structurePrefix(endpoint, "workspace", "update", expectedRevision: expectedRevision)
      + ["--workspace", workspaceID, "--title", title]
  }

  /// `workspace close … --workspace <id>`
  public static func workspaceClose(
    _ endpoint: ManagedSessionEndpoint,
    workspaceID: String,
    expectedRevision: UInt64
  ) -> [String] {
    structurePrefix(endpoint, "workspace", "close", expectedRevision: expectedRevision)
      + ["--workspace", workspaceID]
  }

  /// `tab create … --workspace <id> --title <t> --cwd <abs> -- <argv...>`
  public static func tabCreate(
    _ endpoint: ManagedSessionEndpoint,
    workspaceID: String,
    expectedRevision: UInt64,
    title: String,
    terminal: RemoteTerminalSpec
  ) -> [String] {
    ["tab", "create", endpoint.stateParentPath, endpoint.sessionName]
      + ["--workspace", workspaceID, "--expected-revision", String(expectedRevision)]
      + ["--title", title, "--cwd", terminal.cwd, "--"] + terminal.argv
  }

  /// `tab update … --tab <id> --title <t>`
  public static func tabUpdate(
    _ endpoint: ManagedSessionEndpoint,
    tabID: String,
    expectedRevision: UInt64,
    title: String
  ) -> [String] {
    structurePrefix(endpoint, "tab", "update", expectedRevision: expectedRevision)
      + ["--tab", tabID, "--title", title]
  }

  /// `tab close … --tab <id>`
  public static func tabClose(
    _ endpoint: ManagedSessionEndpoint,
    tabID: String,
    expectedRevision: UInt64
  ) -> [String] {
    structurePrefix(endpoint, "tab", "close", expectedRevision: expectedRevision) + ["--tab", tabID]
  }

  /// `pane split … --pane <id> --direction <d> --cwd <abs> -- <argv...>`
  public static func paneSplit(
    _ endpoint: ManagedSessionEndpoint,
    paneID: String,
    direction: SplitDirection,
    expectedRevision: UInt64,
    terminal: RemoteTerminalSpec
  ) -> [String] {
    ["pane", "split", endpoint.stateParentPath, endpoint.sessionName]
      + ["--pane", paneID, "--direction", direction.rawValue]
      + ["--expected-revision", String(expectedRevision)]
      + ["--cwd", terminal.cwd, "--"] + terminal.argv
  }

  /// `pane update … --pane <id> --title <t>`
  public static func paneUpdate(
    _ endpoint: ManagedSessionEndpoint,
    paneID: String,
    expectedRevision: UInt64,
    title: String
  ) -> [String] {
    structurePrefix(endpoint, "pane", "update", expectedRevision: expectedRevision)
      + ["--pane", paneID, "--title", title]
  }

  /// `pane close … --pane <id>`
  public static func paneClose(
    _ endpoint: ManagedSessionEndpoint,
    paneID: String,
    expectedRevision: UInt64
  ) -> [String] {
    structurePrefix(endpoint, "pane", "close", expectedRevision: expectedRevision)
      + ["--pane", paneID]
  }
}

/// 布局事务回复的解码层。与 `ManagedSessionReplyDecoder` 分开，因为它必须在
/// `revision_conflict` 上保留 `currentRevision`，而通用解码会把 error 压成 `serviceError`。
public enum WorkspaceTransactionDecoder {
  /// 解析信封；`revision_conflict` 转成结构化冲突，其它错误按 code 透传。
  public static func envelope(_ text: String) throws -> [String: Any] {
    let line = text.split(separator: "\n").last.map(String.init) ?? text
    guard let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw WorkspaceTransactionError.malformedReply(String(line.prefix(256))) }
    guard let type = json["type"] as? String, type == "error" || type == "client_error" else {
      return json
    }
    let error = json["error"] as? [String: Any]
    let code = (error?["code"] as? String) ?? (json["code"] as? String) ?? "unknown"
    if code == "revision_conflict" {
      // `currentRevision` 是可选扩展：服务端带上就直接用，不带就必须重新取快照。
      // 两处都要看，因为它既可能在 error 段里，也可能被放在信封顶层。
      let current =
        (error?["currentRevision"] as? NSNumber)?.uint64Value
        ?? (json["currentRevision"] as? NSNumber)?.uint64Value
      throw WorkspaceTransactionError.revisionConflict(currentRevision: current)
    }
    throw WorkspaceTransactionError.serviceError(
      code: code, message: error?["message"] as? String)
  }

  /// 取信封顶层的新 revision。session 作用域响应必带该字段。
  public static func revision(_ json: [String: Any]) throws -> UInt64 {
    guard let value = (json["revision"] as? NSNumber)?.uint64Value else {
      throw WorkspaceTransactionError.malformedReply("missing revision")
    }
    return value
  }

  /// 取 `result` 段。
  public static func result(_ json: [String: Any]) throws -> [String: Any] {
    guard let result = json["result"] as? [String: Any] else {
      throw WorkspaceTransactionError.malformedReply("missing result")
    }
    return result
  }

  /// 取 `result.closed` / `result.deleted` 这类布尔结果。
  public static func flag(_ json: [String: Any], _ key: String) throws -> Bool {
    guard let value = try result(json)[key] as? Bool else {
      throw WorkspaceTransactionError.malformedReply("missing \(key)")
    }
    return value
  }
}

/// 布局事务客户端。传输面由注入的 `ManagedSessionClient` 提供，本机与 SSH 共用。
public struct WorkspaceTransactionClient: Sendable {
  public var client: any ManagedSessionClient
  public var endpoint: ManagedSessionEndpoint

  public init(client: any ManagedSessionClient, endpoint: ManagedSessionEndpoint) {
    self.client = client
    self.endpoint = endpoint
  }

  // MARK: - 只读

  /// 取完整会话快照。冲突恢复与「重新可见先快照后交互」都依赖它。
  public func snapshot() throws -> RemoteSessionSnapshot {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(ManagedSessionCommand.sessionSnapshot(endpoint)))
    return try RemoteSnapshotDecoder.snapshot(json, machineProfileID: endpoint.machineProfileID)
  }

  /// 只列出工作区结构（不含终端实测状态）。
  public func listWorkspaces() throws -> WorkspaceTransactionResult<[RemoteWorkspace]> {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(ManagedSessionCommand.workspaceList(endpoint)))
    let raw = (try WorkspaceTransactionDecoder.result(json))["workspaces"] as? [[String: Any]] ?? []
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try raw.map { try RemoteSnapshotDecoder.workspace($0) }
    )
  }

  /// 请求服务端冷恢复：为快照里终端已不存在的窗格创建新终端（P6.4）。
  ///
  /// 触发时机由调用方判断（快照中有窗格引用了不在 `terminals` 里的 terminalID）。
  /// 结果只是映射表，权威结构仍要重新取快照。
  public func restoreSession(rows: Int, columns: Int) throws -> RemoteSessionRestoreResult {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(ManagedSessionCommand.sessionRestore(endpoint, rows: rows, columns: columns)))
    let result = try WorkspaceTransactionDecoder.result(json)
    let rawEntries = result["entries"] as? [[String: Any]] ?? []
    let entries = try rawEntries.map { raw -> RemoteSessionRestoreEntry in
      guard let paneID = raw["paneID"] as? String,
        let oldID = raw["oldTerminalID"] as? String,
        let newID = raw["newTerminalID"] as? String,
        let path = raw["path"] as? String
      else { throw WorkspaceTransactionError.malformedReply("malformed restore entry") }
      return RemoteSessionRestoreEntry(
        paneID: paneID, oldTerminalID: oldID, newTerminalID: newID, path: path,
        failureReason: raw["failureReason"] as? String)
    }
    return RemoteSessionRestoreResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      entries: entries,
      alreadyRestored: result["alreadyRestored"] as? Bool ?? false)
  }

  // MARK: - 结构变更

  public func createWorkspace(
    expectedRevision: UInt64,
    title: String,
    terminal: RemoteTerminalSpec
  ) throws -> WorkspaceTransactionResult<RemoteWorkspace> {
    try workspaceMutation(
      ManagedSessionCommand.workspaceCreate(
        endpoint, expectedRevision: expectedRevision, title: title, terminal: terminal))
  }

  public func updateWorkspace(
    workspaceID: String,
    expectedRevision: UInt64,
    title: String
  ) throws -> WorkspaceTransactionResult<RemoteWorkspace> {
    try workspaceMutation(
      ManagedSessionCommand.workspaceUpdate(
        endpoint, workspaceID: workspaceID, expectedRevision: expectedRevision, title: title))
  }

  public func closeWorkspace(
    workspaceID: String,
    expectedRevision: UInt64
  ) throws -> WorkspaceTransactionResult<Bool> {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(
        ManagedSessionCommand.workspaceClose(
          endpoint, workspaceID: workspaceID, expectedRevision: expectedRevision)))
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try WorkspaceTransactionDecoder.flag(json, "closed"))
  }

  public func createTab(
    workspaceID: String,
    expectedRevision: UInt64,
    title: String,
    terminal: RemoteTerminalSpec
  ) throws -> WorkspaceTransactionResult<RemoteTab> {
    try tabMutation(
      ManagedSessionCommand.tabCreate(
        endpoint, workspaceID: workspaceID, expectedRevision: expectedRevision,
        title: title, terminal: terminal))
  }

  public func updateTab(
    tabID: String,
    expectedRevision: UInt64,
    title: String
  ) throws -> WorkspaceTransactionResult<RemoteTab> {
    try tabMutation(
      ManagedSessionCommand.tabUpdate(
        endpoint, tabID: tabID, expectedRevision: expectedRevision, title: title))
  }

  public func closeTab(
    tabID: String,
    expectedRevision: UInt64
  ) throws -> WorkspaceTransactionResult<Bool> {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(
        ManagedSessionCommand.tabClose(
          endpoint, tabID: tabID, expectedRevision: expectedRevision)))
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try WorkspaceTransactionDecoder.flag(json, "closed"))
  }

  /// 拆分窗格并在新窗格里创建受管终端；返回新窗格与其终端实测状态。
  public func splitPane(
    paneID: String,
    direction: SplitDirection,
    expectedRevision: UInt64,
    terminal: RemoteTerminalSpec
  ) throws -> WorkspaceTransactionResult<RemotePaneSplitResult> {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(
        ManagedSessionCommand.paneSplit(
          endpoint, paneID: paneID, direction: direction,
          expectedRevision: expectedRevision, terminal: terminal)))
    let identity = try serverIdentity(json)
    let result = try WorkspaceTransactionDecoder.result(json)
    guard let rawPane = result["pane"] as? [String: Any],
      let rawTerminal = result["terminal"] as? [String: Any]
    else { throw WorkspaceTransactionError.malformedReply("missing pane/terminal") }
    let pane = try mapSnapshotError { try RemoteSnapshotDecoder.pane(rawPane) }
    let status = try mapSessionError {
      try ManagedSessionReplyDecoder.terminal(
        rawTerminal, server: identity.reference, serverEpoch: identity.serverEpoch)
    }
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: RemotePaneSplitResult(pane: pane, terminal: status))
  }

  public func updatePane(
    paneID: String,
    expectedRevision: UInt64,
    title: String
  ) throws -> WorkspaceTransactionResult<RemotePane> {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(
        ManagedSessionCommand.paneUpdate(
          endpoint, paneID: paneID, expectedRevision: expectedRevision, title: title)))
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try mapSnapshotError {
        try RemoteSnapshotDecoder.pane(try WorkspaceTransactionDecoder.result(json))
      })
  }

  public func closePane(
    paneID: String,
    expectedRevision: UInt64
  ) throws -> WorkspaceTransactionResult<Bool> {
    let json = try WorkspaceTransactionDecoder.envelope(
      try execute(
        ManagedSessionCommand.paneClose(
          endpoint, paneID: paneID, expectedRevision: expectedRevision)))
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try WorkspaceTransactionDecoder.flag(json, "closed"))
  }

  // MARK: - 冲突恢复

  /// 冲突后用新 revision 重试一次。
  ///
  /// 两条恢复路径都必须支持：
  /// - 服务端带回 `currentRevision` → 直接用它，省掉一次往返；
  /// - 不带 → 调用 `session.snapshot` 重新取权威 revision。
  ///
  /// 只重试一次。第二次仍冲突说明另一个客户端正在持续修改，这时把
  /// `conflictAfterRetry` 交回调用方，由界面提示用户，而不是在后台无限自旋。
  public func retryWithFreshSnapshot<Value>(
    _ operation: (UInt64) throws -> WorkspaceTransactionResult<Value>
  ) throws -> WorkspaceTransactionResult<Value> {
    let initial: UInt64
    do {
      return try operation(try snapshot().revision)
    } catch WorkspaceTransactionError.revisionConflict(let current) {
      initial = try current ?? snapshot().revision
    }
    do {
      return try operation(initial)
    } catch WorkspaceTransactionError.revisionConflict(let current) {
      throw WorkspaceTransactionError.conflictAfterRetry(currentRevision: current)
    }
  }

  /// 已知起始 revision 时的重试入口：先按已知 revision 提交，冲突再按上面的规则恢复。
  public func withConflictRetry<Value>(
    expectedRevision: UInt64,
    _ operation: (UInt64) throws -> WorkspaceTransactionResult<Value>
  ) throws -> WorkspaceTransactionResult<Value> {
    do {
      return try operation(expectedRevision)
    } catch WorkspaceTransactionError.revisionConflict(let current) {
      let fresh = try current ?? snapshot().revision
      do {
        return try operation(fresh)
      } catch WorkspaceTransactionError.revisionConflict(let latest) {
        throw WorkspaceTransactionError.conflictAfterRetry(currentRevision: latest)
      }
    }
  }

  // MARK: - 私有

  private func execute(_ arguments: [String]) throws -> String {
    do {
      return try client.executeStructured(binaryPath: endpoint.binaryPath, arguments: arguments)
    } catch let error as ManagedSessionError {
      throw Self.lift(error)
    }
  }

  /// 把传输层错误抬升成事务错误，`revision_conflict` 不能在这里被吞掉。
  private static func lift(_ error: ManagedSessionError) -> WorkspaceTransactionError {
    switch error {
    case .serviceError(let code, let message):
      code == "revision_conflict"
        ? .revisionConflict(currentRevision: nil)
        : .serviceError(code: code, message: message)
    case .malformedReply(let detail): .malformedReply(detail)
    case .runtimeUnavailable(let detail): .serviceError(code: "transport", message: detail)
    case .launchFailed(let detail): .serviceError(code: "transport", message: detail)
    case .commandFailed(_, let output): .serviceError(code: "transport", message: output)
    }
  }

  private func serverIdentity(_ json: [String: Any]) throws -> SessionServerIdentity {
    try mapSessionError {
      try ManagedSessionReplyDecoder.serverIdentity(
        machineProfileID: endpoint.machineProfileID, from: json)
    }
  }

  private func workspaceMutation(
    _ arguments: [String]
  ) throws -> WorkspaceTransactionResult<RemoteWorkspace> {
    let json = try WorkspaceTransactionDecoder.envelope(try execute(arguments))
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try mapSnapshotError {
        try RemoteSnapshotDecoder.workspace(try WorkspaceTransactionDecoder.result(json))
      })
  }

  private func tabMutation(_ arguments: [String]) throws -> WorkspaceTransactionResult<RemoteTab> {
    let json = try WorkspaceTransactionDecoder.envelope(try execute(arguments))
    return WorkspaceTransactionResult(
      revision: try WorkspaceTransactionDecoder.revision(json),
      value: try mapSnapshotError {
        try RemoteSnapshotDecoder.tab(try WorkspaceTransactionDecoder.result(json))
      })
  }

  /// 快照解码错误统一成事务错误，避免调用方要同时 catch 两套错误类型。
  private func mapSnapshotError<Value>(_ body: () throws -> Value) throws -> Value {
    do { return try body() } catch let error as RemoteSnapshotError {
      throw WorkspaceTransactionError.malformedReply(String(describing: error))
    }
  }

  private func mapSessionError<Value>(_ body: () throws -> Value) throws -> Value {
    do { return try body() } catch let error as ManagedSessionError {
      throw Self.lift(error)
    }
  }
}
