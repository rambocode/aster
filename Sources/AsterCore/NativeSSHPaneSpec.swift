import Foundation

// 原生 SSH Pane 的持久化规格：记在 `PaneDescriptor.nativeSSH`，重启恢复时据此重新连接。
// 只存「连到哪里」，不存 broker socket 路径——那条路径每次启动都会变，必须在启动时现取。

/// 原生 SSH Pane 连接的目标：已保存主机，或 alias / `user@host:port` 文本，二者恰有其一。
public struct NativeSSHPaneSpec: Codable, Equatable, Sendable {
  /// 已保存主机 ID（`SSHHostProfile.id`）。
  public let hostID: UUID?
  /// alias 或规范目标文本（见 `QuickConnectTarget.normalizedTarget`）。
  public let target: String?

  /// 连接已保存主机。
  public static func host(_ id: UUID) -> NativeSSHPaneSpec {
    NativeSSHPaneSpec(hostID: id, target: nil)
  }

  /// 连接 alias 或目标文本；空文本、含控制字符或以 `-` 开头（会被 ssh 当成选项）时返回 nil。
  public static func target(_ text: String) -> NativeSSHPaneSpec? {
    guard isValidTarget(text) else { return nil }
    return NativeSSHPaneSpec(hostID: nil, target: text)
  }

  private init(hostID: UUID?, target: String?) {
    self.hostID = hostID
    self.target = target
  }

  /// 对应的 `aster-ssh client` 目标。
  public var clientTarget: NativeSSHClientInvocation.Target {
    if let hostID { return .host(hostID) }
    return .text(target ?? "")
  }

  private enum CodingKeys: String, CodingKey { case hostID, target }

  /// 两个字段必须恰有一个；否则整条规格视为损坏，由 `PaneDescriptor` 退回普通本地 Pane。
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let hostID = try values.decodeIfPresent(UUID.self, forKey: .hostID)
    let target = try values.decodeIfPresent(String.self, forKey: .target)
    switch (hostID, target) {
    case (let id?, nil):
      self.init(hostID: id, target: nil)
    case (nil, let text?) where Self.isValidTarget(text):
      self.init(hostID: nil, target: text)
    default:
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "nativeSSH needs exactly one of hostID/target"))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(hostID, forKey: .hostID)
    try container.encodeIfPresent(target, forKey: .target)
  }

  /// 目标文本的最小校验：它会原样成为 argv 的一项，也可能被敲进 Shell 作为回退。
  private static func isValidTarget(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.count <= 1_024 && !text.hasPrefix("-")
      && !text.unicodeScalars.contains {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
      }
  }
}
