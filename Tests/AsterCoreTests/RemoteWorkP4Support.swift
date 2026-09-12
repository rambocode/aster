import Foundation
import Testing

@testable import AsterCore

/// P4 客户端模型层测试的共用替身与样例。
///
/// 只覆盖纯模型与解码；真实服务链路的进程证据由 P4 证据脚本生成，不用单测冒充。

/// 记录 argv 并按顺序返回预置输出的会话客户端替身。
///
/// 用 `final class` + 锁：事务客户端是值类型且会多次调用同一实例，测试要读回累计的调用日志。
final class P4ScriptedSessionClient: ManagedSessionClient, @unchecked Sendable {
  /// 一次调用的预置结果：要么是 stdout 文本，要么是抛出的传输层错误。
  enum Response {
    case output(String)
    case failure(ManagedSessionError)
  }

  private let lock = NSLock()
  private var queue: [Response]
  private var recorded: [[String]] = []

  init(responses: [Response]) { self.queue = responses }

  convenience init(outputs: [String]) {
    self.init(responses: outputs.map { .output($0) })
  }

  /// 已发生的调用 argv，按顺序。
  var invocations: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func executeStructured(binaryPath: String, arguments: [String]) throws -> String {
    lock.lock()
    recorded.append(arguments)
    let next = queue.isEmpty ? nil : queue.removeFirst()
    lock.unlock()
    guard let next else {
      throw ManagedSessionError.malformedReply("no scripted response left")
    }
    switch next {
    case .output(let text): return text
    case .failure(let error): throw error
    }
  }

  // 以下方法在 P4 客户端模型层用不到，保留为显式失败以免被误用。
  func ensureServer(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerReference {
    throw ManagedSessionError.runtimeUnavailable("unused")
  }
  func serverStatus(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerIdentity {
    throw ManagedSessionError.runtimeUnavailable("unused")
  }
  func createTerminal(
    _ endpoint: ManagedSessionEndpoint, workingDirectory: String, argv: [String]
  ) throws -> ManagedTerminalStatus {
    throw ManagedSessionError.runtimeUnavailable("unused")
  }
  func listTerminals(_ endpoint: ManagedSessionEndpoint) throws -> [ManagedTerminalStatus] {
    throw ManagedSessionError.runtimeUnavailable("unused")
  }
  func terminateTerminal(
    _ endpoint: ManagedSessionEndpoint, terminalID: String
  ) throws -> ManagedTerminalStatus {
    throw ManagedSessionError.runtimeUnavailable("unused")
  }
  func bridgeArguments(
    _ endpoint: ManagedSessionEndpoint, terminalID: String, readOnly: Bool
  ) -> [String] { [] }
}

/// 固定的样例服务身份文本。
enum P4Fixtures {
  static let serverID = "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8"
  static let serverEpoch = "48922fa9-96c1-47ae-b68e-884fcc7bd272"
  static let sessionID = "83dfae3a-991d-4f16-8e69-ddaca142b563"

  static func target() -> [String: Any] {
    ["serverID": serverID, "serverEpoch": serverEpoch, "sessionID": sessionID]
  }

  static var server: SessionServerReference {
    SessionServerReference(
      machineProfileID: MachineProfile.localProfileID, serverID: serverID, sessionID: sessionID)
  }

  static var endpoint: ManagedSessionEndpoint {
    ManagedSessionEndpoint(
      binaryPath: "/opt/aster/aster-session",
      stateParentPath: "/tmp/aster-p4",
      sessionName: "work"
    )
  }

  static var registryEndpoint: ManagedRegistryEndpoint {
    ManagedRegistryEndpoint(endpoint)
  }

  /// 把字典序列化成一行 JSON（`aster-session` 的结构化输出形态）。
  static func line(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  /// session 作用域的成功响应信封（必带 target 与 revision）。
  static func sessionResponse(
    operation: String,
    revision: UInt64,
    result: [String: Any]
  ) throws -> String {
    try line([
      "type": "response", "operation": operation, "scope": "session",
      "target": target(), "revision": NSNumber(value: revision), "result": result,
    ])
  }

  /// registry 作用域的成功响应信封（无 target / revision）。
  static func registryResponse(operation: String, result: [String: Any]) throws -> String {
    try line(["type": "response", "operation": operation, "scope": "registry", "result": result])
  }

  /// 错误信封。`currentRevision` 传 nil 时刻意不写该字段。
  static func errorEnvelope(
    operation: String,
    code: String,
    message: String = "conflict",
    retry: String = "after_query",
    currentRevision: UInt64? = nil
  ) throws -> String {
    var error: [String: Any] = ["code": code, "message": message, "retry": retry]
    if let currentRevision { error["currentRevision"] = NSNumber(value: currentRevision) }
    return try line([
      "type": "error", "operation": operation, "scope": "session", "error": error,
    ])
  }
}
