import Foundation

/// 服务替换事务的真实 SSH 执行器：用既有的结构化 CLI 传输做「列终端 → 停服务 → 起新服务」。
///
/// 三步都走同一个 `RemoteManagedSessionClient` 与同一个命名会话端点，只有最后一步把
/// `binaryPath` 换成新安装的活动路径——替换的是二进制，不是会话；状态目录与会话名不变，
/// 新服务启动后按冷恢复（P6）恢复布局。
public struct RemoteSSHReplacementExecutor: RemoteReplacementExecuting {
  public var client: RemoteManagedSessionClient
  /// 当前运行中服务的端点（旧二进制路径）。
  public var endpoint: ManagedSessionEndpoint

  public init(client: RemoteManagedSessionClient, endpoint: ManagedSessionEndpoint) {
    self.client = client
    self.endpoint = endpoint
  }

  public func listTerminals() throws -> [ManagedTerminalStatus] {
    try client.listTerminals(endpoint)
  }

  public func stopServer() throws {
    try client.stopServer(endpoint)
  }

  /// 用新二进制启动同一命名会话，并返回握手到的新身份。
  public func startServer(binaryPath: String) throws -> SessionServerIdentity {
    var replacement = endpoint
    replacement.binaryPath = binaryPath
    _ = try client.ensureServer(replacement)
    return try client.serverStatus(replacement)
  }
}
