import Foundation

/// 远端 Agent 原生会话引用的校验与存储（P5，为 P6 恢复做准备）。
///
/// 远程会话不能使用本地路径推断（`AgentProvider.detect(sessionFileURL:)` 依赖
/// 本地文件系统），只通过 provider 上报的 `nativeSession` 标识符做格式校验。

/// 已校验的远端会话引用记录。
public struct ValidatedRemoteSessionRef: Equatable, Sendable {
  /// 来源机器 ID。
  public var machineID: UUID
  /// Agent provider。
  public var provider: AgentProvider
  /// 原生会话标识符（已通过格式校验）。
  public var nativeSession: String
  /// 校验时间戳。
  public var validatedAt: Date

  public init(
    machineID: UUID,
    provider: AgentProvider,
    nativeSession: String,
    validatedAt: Date = Date()
  ) {
    self.machineID = machineID
    self.provider = provider
    self.nativeSession = nativeSession
    self.validatedAt = validatedAt
  }
}

/// 远端 Agent 会话引用校验器。
public enum RemoteAgentSessionReference {
  /// 校验远端 Agent 的原生会话引用格式是否合法。
  ///
  /// 不访问文件系统，只做格式校验：非空、长度合理、字符安全（字母数字加 `-._:/`）。
  /// 远端路径推断是 P6 的事，这里只保证引用本身不含注入风险字符。
  public static func validate(
    provider: AgentProvider,
    nativeSession: String,
    machineID: UUID
  ) -> Bool {
    // 基本格式校验
    guard !nativeSession.isEmpty else { return false }
    guard nativeSession.utf8.count <= 512 else { return false }
    // 不允许空字节
    guard !nativeSession.contains("\0") else { return false }
    // provider 必须支持会话续接
    guard provider.capabilities.contains(.resumeSession) else { return false }
    // 字符白名单：字母、数字、常见路径/ID 分隔符
    let allowed = CharacterSet.alphanumerics
      .union(CharacterSet(charactersIn: "-._:/~"))
    guard nativeSession.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return false
    }
    return true
  }

  /// 已校验引用的内存存储。非线程安全，调用方负责同步。
  public final class Store: @unchecked Sendable {
    private var refs: [String: ValidatedRemoteSessionRef] = [:]
    private let lock = NSLock()

    public init() {}

    /// 校验并存储引用。校验通过返回 true。
    public func validateAndStore(
      provider: AgentProvider,
      nativeSession: String,
      machineID: UUID
    ) -> Bool {
      guard validate(provider: provider, nativeSession: nativeSession, machineID: machineID) else {
        return false
      }
      let key = "\(machineID.uuidString):\(provider.rawValue):\(nativeSession)"
      let ref = ValidatedRemoteSessionRef(
        machineID: machineID,
        provider: provider,
        nativeSession: nativeSession
      )
      lock.lock()
      refs[key] = ref
      lock.unlock()
      return true
    }

    /// 获取已存储的校验引用。
    public func lookup(
      provider: AgentProvider,
      nativeSession: String,
      machineID: UUID
    ) -> ValidatedRemoteSessionRef? {
      let key = "\(machineID.uuidString):\(provider.rawValue):\(nativeSession)"
      lock.lock()
      defer { lock.unlock() }
      return refs[key]
    }

    /// 清除指定机器的所有引用。
    public func removeAll(machineID: UUID) {
      let prefix = machineID.uuidString + ":"
      lock.lock()
      refs = refs.filter { !$0.key.hasPrefix(prefix) }
      lock.unlock()
    }
  }
}
