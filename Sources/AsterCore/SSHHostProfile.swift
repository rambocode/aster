import Foundation

// 已保存的 SSH 主机配置（移植自 tty7 `SshProfile`，Apache-2.0）。
//
// 只保存连接参数，**不保存任何秘密**：口令与私钥 passphrase 只在钥匙串里
// （`SSHCredentialStore`），broker 只在内存里拿到。空字段表示「继承默认项」，
// 默认项自身的空字段表示「用库默认值」。

/// 主机与端口对。
public struct SSHHostPort: Codable, Equatable, Hashable, Sendable {
  public var host: String
  public var port: Int

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }
}

/// 认证方式。`auto` 依次尝试 agent → 密钥文件 → 口令 / 键盘交互。
public enum SSHAuthMode: String, Codable, CaseIterable, Sendable {
  case auto
  case password
  case publicKey
  case agent
  case keyboardInteractive
}

/// 端口转发类型：本地（-L）、远端（-R）、动态 SOCKS（-D）。
public enum SSHForwardKind: String, Codable, CaseIterable, Sendable {
  case local
  case remote
  case dynamic
}

/// 一条静态端口转发规则，随连接建立。动态转发的 `target` 被忽略。
public struct SSHForwardRule: Codable, Equatable, Hashable, Sendable {
  public var kind: SSHForwardKind
  public var bind: SSHHostPort
  public var target: SSHHostPort
  public var description: String

  public init(kind: SSHForwardKind, bind: SSHHostPort, target: SSHHostPort, description: String = "") {
    self.kind = kind
    self.bind = bind
    self.target = target
    self.description = description
  }
}

/// 一台已保存的 SSH 主机。
public struct SSHHostProfile: Codable, Equatable, Identifiable, Sendable {
  /// 「默认」项的固定 ID。它不代表真实主机，只提供被继承的字段值。
  public static let defaultsProfileID = UUID(uuidString: "00000000-0000-4000-8000-00000000d0d0")!
  /// 从 `~/.ssh/config` 导入的主机所在分组。设置页把这一组排在最前。
  public static let importedGroup = "~/.ssh/config"

  public let id: UUID
  public var name: String
  /// 单个可选分组名；nil 表示「未分组」。
  public var group: String?

  public var host: String
  /// nil 表示继承默认项（再缺省为 22）。
  public var port: Int?
  /// 空串表示继承默认项（再缺省为本机用户名）。
  public var user: String
  /// 跳板主机，引用另一条配置。
  public var jumpHostID: UUID?
  public var proxyCommand: String?
  public var socksProxy: SSHHostPort?
  public var httpProxy: SSHHostPort?

  /// nil 表示继承默认项（再缺省为 `.auto`）。
  public var auth: SSHAuthMode?
  /// 私钥路径，可含 `~`、`%h`、`%r`；为空表示继承默认项。
  public var identityFiles: [String]
  /// 只用 `identityFiles` 里的密钥（OpenSSH `IdentitiesOnly`）；nil 表示继承默认项。
  public var identitiesOnly: Bool?
  /// 自定义 known_hosts 文件（OpenSSH `UserKnownHostsFile`），可含 `~`；nil 或空表示继承默认项，
  /// 再缺省为 `~/.ssh/known_hosts`。OrbStack 等工具靠它把主机密钥放在自己的文件里。
  public var knownHostsFiles: [String]?
  public var agentForward: Bool?

  /// 静态转发规则。与默认项的规则合并（默认项在前）。
  public var forwards: [SSHForwardRule]

  public var keepaliveInterval: Int?
  public var keepaliveCountMax: Int?
  public var connectTimeout: Int?
  public var verifyHostKeys: Bool?

  public init(
    id: UUID = UUID(),
    name: String,
    group: String? = nil,
    host: String = "",
    port: Int? = nil,
    user: String = "",
    jumpHostID: UUID? = nil,
    proxyCommand: String? = nil,
    socksProxy: SSHHostPort? = nil,
    httpProxy: SSHHostPort? = nil,
    auth: SSHAuthMode? = nil,
    identityFiles: [String] = [],
    identitiesOnly: Bool? = nil,
    knownHostsFiles: [String]? = nil,
    agentForward: Bool? = nil,
    forwards: [SSHForwardRule] = [],
    keepaliveInterval: Int? = nil,
    keepaliveCountMax: Int? = nil,
    connectTimeout: Int? = nil,
    verifyHostKeys: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.group = group
    self.host = host
    self.port = port
    self.user = user
    self.jumpHostID = jumpHostID
    self.proxyCommand = proxyCommand
    self.socksProxy = socksProxy
    self.httpProxy = httpProxy
    self.auth = auth
    self.identityFiles = identityFiles
    self.identitiesOnly = identitiesOnly
    self.knownHostsFiles = knownHostsFiles
    self.agentForward = agentForward
    self.forwards = forwards
    self.keepaliveInterval = keepaliveInterval
    self.keepaliveCountMax = keepaliveCountMax
    self.connectTimeout = connectTimeout
    self.verifyHostKeys = verifyHostKeys
  }

  /// 空的默认项。首次启动时由存储补上，保证列表顶部总有一条「默认」。
  public static func emptyDefaults() -> SSHHostProfile {
    SSHHostProfile(id: defaultsProfileID, name: "Defaults")
  }

  public var isDefaults: Bool { id == Self.defaultsProfileID }

  /// 用于显示与快连的 `user@host:port` 文本；端口为 22 或未设置时省略。
  public var connectString: String {
    let hostText = host.contains(":") ? "[\(host)]" : host
    var text = user.isEmpty ? hostText : "\(user)@\(hostText)"
    if let port, port != 22 { text += ":\(port)" }
    return text
  }
}

/// 发给 broker 的解析后规格：已合并默认项、已展开路径与跳板链。
/// 字段与 `SshRuntime/PROTOCOL.md` §4.3 一一对应。
public struct SSHResolvedSpec: Codable, Equatable, Sendable {
  public var host: String
  public var port: Int
  public var user: String
  public var auth: SSHAuthMode
  public var identityFiles: [String]
  /// 只用 `identityFiles`，不遍历 agent 里的其它密钥、不试默认密钥。
  public var identitiesOnly: Bool
  /// 已展开的 known_hosts 文件；空数组表示用 `~/.ssh/known_hosts`。
  public var knownHostsFiles: [String]
  public var agentForward: Bool
  public var proxyCommand: String?
  public var socksProxy: SSHHostPort?
  public var httpProxy: SSHHostPort?
  /// 递归的跳板规格。用 class 盒子是因为值类型不能直接递归。
  public var jump: SSHResolvedSpecBox?
  public var forwards: [SSHForwardRule]
  public var keepaliveInterval: Int
  public var keepaliveCountMax: Int
  public var connectTimeout: Int
  public var verifyHostKeys: Bool

  /// 凭证在钥匙串里的账户键：`user@host:port`。跳板不参与，因为口令属于目标自身。
  public var credentialEndpoint: String {
    let hostText = host.contains(":") ? "[\(host)]" : host
    return "\(user)@\(hostText):\(port)"
  }
}

/// `SSHResolvedSpec` 的递归盒子。编码时透明展开成内层对象。
public final class SSHResolvedSpecBox: Codable, Equatable, Sendable {
  public let spec: SSHResolvedSpec

  public init(_ spec: SSHResolvedSpec) { self.spec = spec }

  public required init(from decoder: Decoder) throws {
    spec = try SSHResolvedSpec(from: decoder)
  }

  public func encode(to encoder: Encoder) throws { try spec.encode(to: encoder) }

  public static func == (lhs: SSHResolvedSpecBox, rhs: SSHResolvedSpecBox) -> Bool {
    lhs.spec == rhs.spec
  }
}

/// 解析失败原因。
public enum SSHHostResolutionError: Error, Equatable, Sendable {
  case unknownHost(UUID)
  case missingHostName(UUID)
  case jumpCycle(UUID)
  case jumpTooDeep
}

/// 把保存的配置合并默认项、展开跳板链，得到 broker 可直接使用的规格。
public enum SSHHostResolver {
  /// 跳板链的最大深度。与 broker 端的上限一致。
  public static let maximumJumpDepth = 8

  /// 解析一条主机配置。
  ///
  /// - Parameters:
  ///   - id: 要解析的主机 ID（不能是默认项）。
  ///   - profiles: 全部配置，含默认项；缺默认项时按空默认处理。
  ///   - homeDirectory: 用于展开 `~`，测试可注入。
  ///   - localUser: 用户名缺省值。
  /// - Throws: 主机不存在、主机名为空、跳板成环或过深。
  public static func resolve(
    _ id: UUID,
    in profiles: [SSHHostProfile],
    homeDirectory: String = NSHomeDirectory(),
    localUser: String = NSUserName()
  ) throws -> SSHResolvedSpec {
    let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let defaults = byID[SSHHostProfile.defaultsProfileID] ?? .emptyDefaults()
    return try resolve(
      id, byID: byID, defaults: defaults, visited: [], homeDirectory: homeDirectory,
      localUser: localUser)
  }

  /// 递归解析；`visited` 用于检测跳板成环。
  private static func resolve(
    _ id: UUID,
    byID: [UUID: SSHHostProfile],
    defaults: SSHHostProfile,
    visited: [UUID],
    homeDirectory: String,
    localUser: String
  ) throws -> SSHResolvedSpec {
    guard !visited.contains(id) else { throw SSHHostResolutionError.jumpCycle(id) }
    guard visited.count <= maximumJumpDepth else { throw SSHHostResolutionError.jumpTooDeep }
    guard let profile = byID[id], !profile.isDefaults else {
      throw SSHHostResolutionError.unknownHost(id)
    }
    let host = profile.host.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty else { throw SSHHostResolutionError.missingHostName(id) }

    let user = firstNonEmpty(profile.user, defaults.user) ?? localUser
    let identityTemplates = profile.identityFiles.isEmpty ? defaults.identityFiles : profile.identityFiles
    let identityFiles = identityTemplates.map {
      expandIdentity($0, host: host, user: user, homeDirectory: homeDirectory)
    }
    let knownHostsTemplates =
      (profile.knownHostsFiles?.isEmpty == false ? profile.knownHostsFiles : defaults.knownHostsFiles) ?? []
    let knownHostsFiles = knownHostsTemplates.map {
      expandIdentity($0, host: host, user: user, homeDirectory: homeDirectory)
    }
    let jumpID = profile.jumpHostID ?? defaults.jumpHostID
    // 跳板主机自己不能再用默认项里的跳板，否则所有主机都会经过同一跳板形成自环。
    let jump: SSHResolvedSpecBox? =
      try jumpID.flatMap { jumpID in
        jumpID == id
          ? nil
          : SSHResolvedSpecBox(
            try resolve(
              jumpID, byID: byID, defaults: defaults, visited: visited + [id],
              homeDirectory: homeDirectory, localUser: localUser))
      }

    return SSHResolvedSpec(
      host: host,
      port: profile.port ?? defaults.port ?? 22,
      user: user,
      auth: profile.auth ?? defaults.auth ?? .auto,
      identityFiles: identityFiles,
      identitiesOnly: profile.identitiesOnly ?? defaults.identitiesOnly ?? false,
      knownHostsFiles: knownHostsFiles,
      agentForward: profile.agentForward ?? defaults.agentForward ?? false,
      proxyCommand: firstNonEmpty(profile.proxyCommand, defaults.proxyCommand),
      socksProxy: profile.socksProxy ?? defaults.socksProxy,
      httpProxy: profile.httpProxy ?? defaults.httpProxy,
      jump: jump,
      forwards: defaults.forwards + profile.forwards,
      keepaliveInterval: profile.keepaliveInterval ?? defaults.keepaliveInterval ?? 15,
      keepaliveCountMax: profile.keepaliveCountMax ?? defaults.keepaliveCountMax ?? 3,
      connectTimeout: profile.connectTimeout ?? defaults.connectTimeout ?? 10,
      verifyHostKeys: profile.verifyHostKeys ?? defaults.verifyHostKeys ?? true)
  }

  /// 解析全部可解析的主机，供 `profiles.sync` 使用；解析失败的条目跳过并返回原因。
  public static func resolveAll(
    _ profiles: [SSHHostProfile],
    homeDirectory: String = NSHomeDirectory(),
    localUser: String = NSUserName()
  ) -> (specs: [UUID: SSHResolvedSpec], failures: [UUID: SSHHostResolutionError]) {
    var specs: [UUID: SSHResolvedSpec] = [:]
    var failures: [UUID: SSHHostResolutionError] = [:]
    for profile in profiles where !profile.isDefaults {
      do {
        specs[profile.id] = try resolve(
          profile.id, in: profiles, homeDirectory: homeDirectory, localUser: localUser)
      } catch let error as SSHHostResolutionError {
        failures[profile.id] = error
      } catch {
        failures[profile.id] = .unknownHost(profile.id)
      }
    }
    return (specs, failures)
  }

  /// 展开 `%h`、`%r`、`%%` 与开头的 `~`（与 tty7 `expand_identity_placeholders` 同语义）。
  public static func expandIdentity(
    _ path: String, host: String, user: String, homeDirectory: String
  ) -> String {
    var output = ""
    var iterator = path.makeIterator()
    while let character = iterator.next() {
      guard character == "%" else {
        output.append(character)
        continue
      }
      switch iterator.next() {
      case "h": output += host
      case "r": output += user
      case "%": output.append("%")
      case let other?: output += "%\(other)"
      case nil: output.append("%")
      }
    }
    if output == "~" { return homeDirectory }
    if output.hasPrefix("~/") {
      let separator = homeDirectory.hasSuffix("/") ? "" : "/"
      return homeDirectory + separator + output.dropFirst(2)
    }
    return output
  }

  /// 返回第一个去空白后非空的值。
  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
    }
    return nil
  }
}
