import Foundation

/// P4.2 客户端半边：服务端会话快照的值类型。
///
/// 与 `SessionRuntime/protocol/operations.schema.json` 的 `$defs/workspace`、`$defs/tab`、
/// `$defs/layout0…layout16`、`$defs/pane`、`$defs/terminal` 一一对应。
///
/// 归属规则（`docs/developer/remote-work.md` §3.3）：工作区/标签/窗格/远端 cwd 的权威
/// 在所属会话服务，客户端只缓存远端引用；`revision` 来自响应信封顶层（session 作用域
/// 响应必带），不是 result 内部字段。

/// 快照解码错误。必需字段缺失必须明确报错，绝不用默认值补全成“看起来正常”的结构。
public enum RemoteSnapshotError: Error, Equatable, Sendable {
  /// 缺少 schema 要求的必需字段。
  case missingField(String)
  /// 分屏树超过协议 `semanticLimits.maximumLayoutDepth`（16）。
  case layoutTooDeep(depth: Int)
  /// `kind` 不是 `leaf` / `split`。
  case invalidLayoutKind(String)
  /// 分屏比例不在 `(0, 1)` 开区间内。
  case invalidRatio(Double)
  /// 标识符不是协议要求的小写 UUID 文本。
  case invalidIdentifier(String)
}

/// 协议规定的分屏树最大深度（`semanticLimits.maximumLayoutDepth`）。
public let remoteLayoutMaximumDepth = 16

/// 共享结构里的一个窗格。只承载受管终端，绝不承载本地文件/编辑器/预览/Web 资源。
public struct RemotePane: Codable, Equatable, Sendable {
  public var paneID: String
  public var terminalID: String
  public var title: String?

  public init(paneID: String, terminalID: String, title: String? = nil) {
    self.paneID = paneID
    self.terminalID = terminalID
    self.title = title
  }
}

/// 递归分屏树。`indirect` 对应 schema 里 layout0…layout16 的展开写法。
public indirect enum RemoteLayoutNode: Codable, Equatable, Sendable {
  case leaf(RemotePane)
  case split(axis: SplitAxis, ratio: Double, first: RemoteLayoutNode, second: RemoteLayoutNode)

  private enum CodingKeys: String, CodingKey {
    case kind, pane, axis, ratio, first, second
  }

  /// 按 `kind` 判别式解码；未知字段被忽略（向前兼容），必需字段缺失明确报错。
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "leaf":
      self = .leaf(try container.decode(RemotePane.self, forKey: .pane))
    case "split":
      let ratio = try container.decode(Double.self, forKey: .ratio)
      guard ratio.isFinite, ratio > 0, ratio < 1 else {
        throw RemoteSnapshotError.invalidRatio(ratio)
      }
      self = .split(
        axis: try container.decode(SplitAxis.self, forKey: .axis),
        ratio: ratio,
        first: try container.decode(RemoteLayoutNode.self, forKey: .first),
        second: try container.decode(RemoteLayoutNode.self, forKey: .second)
      )
    default:
      throw RemoteSnapshotError.invalidLayoutKind(kind)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .leaf(let pane):
      try container.encode("leaf", forKey: .kind)
      try container.encode(pane, forKey: .pane)
    case .split(let axis, let ratio, let first, let second):
      try container.encode("split", forKey: .kind)
      try container.encode(axis, forKey: .axis)
      try container.encode(ratio, forKey: .ratio)
      try container.encode(first, forKey: .first)
      try container.encode(second, forKey: .second)
    }
  }

  /// 树的实际深度（叶为 1）。深度校验在解码完成后单独执行：Codable 无法在递归过程中
  /// 传递计数器，而控制帧上限 1 MiB 已经限制了输入规模，所以先解码再校验是安全的。
  public var depth: Int {
    switch self {
    case .leaf: 1
    case .split(_, _, let first, let second): 1 + max(first.depth, second.depth)
    }
  }

  /// 深度超过协议上限时报错。调用方在应用快照之前必须先做这一步。
  public func validateDepth() throws {
    let depth = self.depth
    guard depth <= remoteLayoutMaximumDepth else {
      throw RemoteSnapshotError.layoutTooDeep(depth: depth)
    }
  }

  /// 树内全部窗格，按从左到右的稳定顺序。
  public var allPanes: [RemotePane] {
    switch self {
    case .leaf(let pane): [pane]
    case .split(_, _, let first, let second): first.allPanes + second.allPanes
    }
  }
}

/// 一个标签：标题 + 递归分屏树。
public struct RemoteTab: Codable, Equatable, Sendable {
  public var tabID: String
  public var title: String
  public var layout: RemoteLayoutNode

  public init(tabID: String, title: String, layout: RemoteLayoutNode) {
    self.tabID = tabID
    self.title = title
    self.layout = layout
  }
}

/// 一个工作区。`cwd` 是执行机器上的绝对路径，已由服务端校验过存在性。
public struct RemoteWorkspace: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var title: String
  public var cwd: String
  public var tabs: [RemoteTab]

  public init(workspaceID: String, title: String, cwd: String, tabs: [RemoteTab]) {
    self.workspaceID = workspaceID
    self.title = title
    self.cwd = cwd
    self.tabs = tabs
  }
}

/// 一次 `session.snapshot` 的完整投影输入。
///
/// `revision` 用于乐观并发：任何结构变更都必须携带 `expectedRevision`，冲突时服务端
/// 返回 `revision_conflict`。`terminals` 是终端实例的实测状态，`workspaces` 只保存
/// 结构与引用；用 terminalID 关联两者，不用 paneID 证明进程存活。
public struct RemoteSessionSnapshot: Codable, Equatable, Sendable {
  public var revision: UInt64
  public var workspaces: [RemoteWorkspace]
  public var terminals: [ManagedTerminalStatus]

  public init(
    revision: UInt64,
    workspaces: [RemoteWorkspace],
    terminals: [ManagedTerminalStatus]
  ) {
    self.revision = revision
    self.workspaces = workspaces
    self.terminals = terminals
  }

  /// 校验全部标签的分屏深度。应用快照前必须调用。
  public func validate() throws {
    for workspace in workspaces {
      for tab in workspace.tabs { try tab.layout.validateDepth() }
    }
  }

  /// 按 terminalID 建索引，供投影时查找 cwd / 运行状态。
  public var terminalsByID: [String: ManagedTerminalStatus] {
    Dictionary(
      terminals.map { ($0.reference.terminalID, $0) },
      uniquingKeysWith: { _, latest in latest })
  }
}

/// 从 `aster-session` 结构化回复解码快照的纯函数层。
public enum RemoteSnapshotDecoder {
  /// 解析 `session.snapshot` 的响应信封。
  ///
  /// - `revision` 取信封顶层（协议 §5：session 作用域响应必带 revision）。
  /// - `terminals` 复用 `ManagedSessionReplyDecoder.terminal`，保证与 P2 的状态映射一致。
  public static func snapshot(
    _ json: [String: Any],
    machineProfileID: UUID
  ) throws -> RemoteSessionSnapshot {
    let identity = try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: machineProfileID, from: json)
    guard let revision = (json["revision"] as? NSNumber)?.uint64Value else {
      throw RemoteSnapshotError.missingField("revision")
    }
    let result = try ManagedSessionReplyDecoder.result(json)
    guard let rawWorkspaces = result["workspaces"] as? [[String: Any]] else {
      throw RemoteSnapshotError.missingField("workspaces")
    }
    guard let rawTerminals = result["terminals"] as? [[String: Any]] else {
      throw RemoteSnapshotError.missingField("terminals")
    }
    let workspaces = try rawWorkspaces.map { try workspace($0) }
    let terminals = try rawTerminals.map {
      try ManagedSessionReplyDecoder.terminal(
        $0, server: identity.reference, serverEpoch: identity.serverEpoch)
    }
    let snapshot = RemoteSessionSnapshot(
      revision: revision, workspaces: workspaces, terminals: terminals)
    try snapshot.validate()
    return snapshot
  }

  /// 解析单个工作区。未知可选字段被忽略，必需字段缺失报明确错误。
  public static func workspace(_ raw: [String: Any]) throws -> RemoteWorkspace {
    guard let workspaceID = raw["workspaceID"] as? String, !workspaceID.isEmpty else {
      throw RemoteSnapshotError.missingField("workspaceID")
    }
    guard let title = raw["title"] as? String else {
      throw RemoteSnapshotError.missingField("title")
    }
    guard let cwd = raw["cwd"] as? String, !cwd.isEmpty else {
      throw RemoteSnapshotError.missingField("cwd")
    }
    guard let rawTabs = raw["tabs"] as? [[String: Any]] else {
      throw RemoteSnapshotError.missingField("tabs")
    }
    return RemoteWorkspace(
      workspaceID: workspaceID,
      title: title,
      cwd: cwd,
      tabs: try rawTabs.map { try tab($0) }
    )
  }

  /// 解析单个标签。
  public static func tab(_ raw: [String: Any]) throws -> RemoteTab {
    guard let tabID = raw["tabID"] as? String, !tabID.isEmpty else {
      throw RemoteSnapshotError.missingField("tabID")
    }
    guard let title = raw["title"] as? String else {
      throw RemoteSnapshotError.missingField("title")
    }
    guard let rawLayout = raw["layout"] as? [String: Any] else {
      throw RemoteSnapshotError.missingField("layout")
    }
    return RemoteTab(tabID: tabID, title: title, layout: try layout(rawLayout, depth: 1))
  }

  /// 递归解析分屏树。深度在递归过程中就地限制，超限立即停止，不先建出超大结构。
  public static func layout(_ raw: [String: Any], depth: Int = 1) throws -> RemoteLayoutNode {
    guard depth <= remoteLayoutMaximumDepth else {
      throw RemoteSnapshotError.layoutTooDeep(depth: depth)
    }
    guard let kind = raw["kind"] as? String else {
      throw RemoteSnapshotError.missingField("layout.kind")
    }
    switch kind {
    case "leaf":
      guard let rawPane = raw["pane"] as? [String: Any] else {
        throw RemoteSnapshotError.missingField("layout.pane")
      }
      return .leaf(try pane(rawPane))
    case "split":
      guard let axisText = raw["axis"] as? String, let axis = SplitAxis(rawValue: axisText) else {
        throw RemoteSnapshotError.missingField("layout.axis")
      }
      guard let ratio = (raw["ratio"] as? NSNumber)?.doubleValue else {
        throw RemoteSnapshotError.missingField("layout.ratio")
      }
      guard ratio.isFinite, ratio > 0, ratio < 1 else {
        throw RemoteSnapshotError.invalidRatio(ratio)
      }
      guard let rawFirst = raw["first"] as? [String: Any] else {
        throw RemoteSnapshotError.missingField("layout.first")
      }
      guard let rawSecond = raw["second"] as? [String: Any] else {
        throw RemoteSnapshotError.missingField("layout.second")
      }
      return .split(
        axis: axis,
        ratio: ratio,
        first: try layout(rawFirst, depth: depth + 1),
        second: try layout(rawSecond, depth: depth + 1)
      )
    default:
      throw RemoteSnapshotError.invalidLayoutKind(kind)
    }
  }

  /// 解析单个窗格。
  public static func pane(_ raw: [String: Any]) throws -> RemotePane {
    guard let paneID = raw["paneID"] as? String, !paneID.isEmpty else {
      throw RemoteSnapshotError.missingField("paneID")
    }
    guard let terminalID = raw["terminalID"] as? String, !terminalID.isEmpty else {
      throw RemoteSnapshotError.missingField("terminalID")
    }
    return RemotePane(paneID: paneID, terminalID: terminalID, title: raw["title"] as? String)
  }
}
