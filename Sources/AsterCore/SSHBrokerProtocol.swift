import Foundation

// Swift 侧的 aster-ssh 契约：控制通道消息、client 命令行与结构化错误行。
// 字段必须与 `SshRuntime/PROTOCOL.md` 保持一致，改一侧就要改另一侧。

/// SSH 引擎选择。native 走 aster-ssh broker；openssh 是回退路径，行为与改造前一致。
public enum SSHEngine: String, Codable, CaseIterable, Sendable {
  case native
  case openssh

  /// 环境变量覆盖：`ASTER_SSH_ENGINE=openssh`，便于排障与测试。
  public static let environmentKey = "ASTER_SSH_ENGINE"
}

/// 原生引擎的运行位置：client 可执行文件与 broker socket。
public struct NativeSSHEndpoint: Equatable, Sendable {
  /// `aster-ssh` 可执行文件的绝对路径。
  public var executablePath: String
  /// broker 监听的 unix socket 路径。
  public var brokerSocketPath: String

  public init(executablePath: String, brokerSocketPath: String) {
    self.executablePath = executablePath
    self.brokerSocketPath = brokerSocketPath
  }
}

/// 一次 `aster-ssh client` 调用的描述，生成 argv 直接 exec，不经 Shell。
public struct NativeSSHClientInvocation: Equatable, Sendable {
  /// 连接目标：已保存主机，或 alias / `user@host:port` 文本。
  public enum Target: Equatable, Sendable {
    case host(UUID)
    case text(String)
  }

  public var endpoint: NativeSSHEndpoint
  public var target: Target
  /// 请求远端 pty（对应 OpenSSH `-tt`）。
  public var tty: Bool
  /// 后台调用：不允许弹出交互认证（对应 OpenSSH `BatchMode=yes`）。
  public var noPrompt: Bool
  public var connectTimeout: Int?
  /// 远端命令 argv；为空表示请求交互 Shell。
  public var remoteCommand: [String]

  public init(
    endpoint: NativeSSHEndpoint,
    target: Target,
    tty: Bool = false,
    noPrompt: Bool = true,
    connectTimeout: Int? = nil,
    remoteCommand: [String] = []
  ) {
    self.endpoint = endpoint
    self.target = target
    self.tty = tty
    self.noPrompt = noPrompt
    self.connectTimeout = connectTimeout
    self.remoteCommand = remoteCommand
  }

  /// 生成 argv（不含可执行文件本身）。
  ///
  /// 远端命令和 OpenSSH 一样合成**一个**经 POSIX 单引号转义的字符串：SSH exec 请求本来就
  /// 只有一个字符串，由远端登录 Shell 解释，转义是保证 argv 字面传递的唯一手段。
  public func arguments() -> [String] {
    var argv = ["client", "--broker", endpoint.brokerSocketPath]
    switch target {
    case .host(let id): argv += ["--host-id", id.uuidString]
    case .text(let text): argv += ["--target", text]
    }
    if tty { argv.append("--tty") }
    if noPrompt { argv.append("--no-prompt") }
    if let connectTimeout { argv += ["--connect-timeout", String(connectTimeout)] }
    if !remoteCommand.isEmpty {
      argv += ["--", RemoteSSHInvocation.shellQuoted(remoteCommand)]
    }
    return argv
  }
}

/// client 失败时写在 stderr 最后一行的结构化错误。
public struct NativeSSHErrorLine: Codable, Equatable, Sendable {
  /// 行前缀；后面跟一个 JSON 对象。
  public static let prefix = "aster-ssh-error "

  public var kind: RemoteSSHFailureKind
  public var detail: String

  public init(kind: RemoteSSHFailureKind, detail: String) {
    self.kind = kind
    self.detail = detail
  }

  /// 从 stderr 里找最后一条结构化错误行；没有或解析失败返回 nil（调用方回退到文本分类）。
  public static func parse(standardError: String) -> NativeSSHErrorLine? {
    for line in standardError.split(whereSeparator: \.isNewline).reversed()
    where line.hasPrefix(prefix) {
      let json = Data(line.dropFirst(prefix.count).utf8)
      return try? JSONDecoder().decode(NativeSSHErrorLine.self, from: json)
    }
    return nil
  }
}

extension RemoteSSHFailureKind: Codable {}

// MARK: - 控制通道（App ↔ broker，JSON Lines）

/// 键盘交互认证里的一条提示。
public struct SSHAuthPrompt: Codable, Equatable, Sendable {
  public var text: String
  public var echo: Bool

  public init(text: String, echo: Bool) {
    self.text = text
    self.echo = echo
  }
}

/// 认证请求类型。
public enum SSHAuthRequestKind: String, Codable, Sendable {
  case password
  case passphrase
  case keyboardInteractive
}

/// broker 发来的凭证请求。
public struct SSHAuthRequest: Codable, Equatable, Sendable {
  public var id: String
  /// 凭证键 `user@host:port`，也是钥匙串账户名。
  public var endpoint: String
  public var kind: SSHAuthRequestKind
  public var hostID: UUID?
  /// passphrase 请求时的私钥路径。
  public var keyFile: String?
  /// passphrase 请求时私钥文件内容 SHA-512 的小写 hex，是钥匙串账户名。
  public var keyDigest: String?
  public var name: String?
  public var instruction: String?
  public var prompts: [SSHAuthPrompt]
  public var attempt: Int
  /// false 时只能用钥匙串作答，不得弹窗。
  public var interactive: Bool

  public init(
    id: String, endpoint: String, kind: SSHAuthRequestKind, hostID: UUID? = nil,
    keyFile: String? = nil, keyDigest: String? = nil, name: String? = nil,
    instruction: String? = nil, prompts: [SSHAuthPrompt] = [], attempt: Int = 1,
    interactive: Bool = true
  ) {
    self.id = id
    self.endpoint = endpoint
    self.kind = kind
    self.hostID = hostID
    self.keyFile = keyFile
    self.keyDigest = keyDigest
    self.name = name
    self.instruction = instruction
    self.prompts = prompts
    self.attempt = attempt
    self.interactive = interactive
  }
}

/// 主机密钥确认状态。
public enum SSHHostKeyStatus: String, Codable, Sendable {
  case unknown
  case changed
}

/// broker 发来的主机密钥确认请求。
public struct SSHHostKeyRequest: Codable, Equatable, Sendable {
  public var id: String
  public var endpoint: String
  public var algorithm: String
  public var fingerprint: String
  public var status: SSHHostKeyStatus
  public var interactive: Bool

  public init(
    id: String, endpoint: String, algorithm: String, fingerprint: String,
    status: SSHHostKeyStatus, interactive: Bool = true
  ) {
    self.id = id
    self.endpoint = endpoint
    self.algorithm = algorithm
    self.fingerprint = fingerprint
    self.status = status
    self.interactive = interactive
  }
}

/// 连接状态。
public enum SSHLinkState: String, Codable, Sendable {
  case connecting
  case connected
  case reconnecting
  case failed
  case closed
}

/// broker 上报的一条连接状态。
public struct SSHLinkStateEvent: Codable, Equatable, Sendable {
  public var endpoint: String
  public var hostID: UUID?
  public var target: String?
  public var state: SSHLinkState
  public var attempt: Int?
  public var errorKind: RemoteSSHFailureKind?
  public var detail: String?

  public init(
    endpoint: String, hostID: UUID? = nil, target: String? = nil, state: SSHLinkState,
    attempt: Int? = nil, errorKind: RemoteSSHFailureKind? = nil, detail: String? = nil
  ) {
    self.endpoint = endpoint
    self.hostID = hostID
    self.target = target
    self.state = state
    self.attempt = attempt
    self.errorKind = errorKind
    self.detail = detail
  }
}

/// broker → App 的一条消息。未知类型解码成 `.unknown`，保证向前兼容。
public enum SSHBrokerEvent: Equatable, Sendable {
  case ready(socket: String, version: String)
  case authRequest(SSHAuthRequest)
  case authResult(id: String, accepted: Bool)
  case hostKeyConfirm(SSHHostKeyRequest)
  case linkState(SSHLinkStateEvent)
  case log(level: String, message: String)
  case unknown(type: String)

  private struct Envelope: Decodable { var type: String }
  private struct Ready: Decodable { var socket: String; var version: String }
  private struct AuthResult: Decodable { var id: String; var accepted: Bool }
  private struct Log: Decodable { var level: String; var message: String }

  /// 解码一行 JSON。行本身不是合法 JSON 时抛错，由调用方记录后丢弃。
  public static func decode(line: Data) throws -> SSHBrokerEvent {
    let decoder = JSONDecoder()
    let type = try decoder.decode(Envelope.self, from: line).type
    switch type {
    case "ready":
      let value = try decoder.decode(Ready.self, from: line)
      return .ready(socket: value.socket, version: value.version)
    case "auth.request": return .authRequest(try decoder.decode(SSHAuthRequest.self, from: line))
    case "auth.result":
      let value = try decoder.decode(AuthResult.self, from: line)
      return .authResult(id: value.id, accepted: value.accepted)
    case "hostkey.confirm":
      return .hostKeyConfirm(try decoder.decode(SSHHostKeyRequest.self, from: line))
    case "link.state": return .linkState(try decoder.decode(SSHLinkStateEvent.self, from: line))
    case "log":
      let value = try decoder.decode(Log.self, from: line)
      return .log(level: value.level, message: value.message)
    default: return .unknown(type: type)
    }
  }
}

/// App → broker 的一条消息。
public enum SSHBrokerCommand: Equatable, Sendable {
  case profilesSync([UUID: SSHResolvedSpec])
  /// `secret` 为 nil 表示取消；键盘交互用 `responses`。
  case authAnswer(id: String, secret: String?, responses: [String]?)
  case hostKeyAnswer(id: String, accept: Bool)
  case disconnect(endpoint: String)
  case shutdown

  /// 编码成一行 JSON（不含换行）。
  public func encodedLine() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    switch self {
    case .profilesSync(let specs):
      struct Body: Encodable { let type = "profiles.sync"; var profiles: [String: SSHResolvedSpec] }
      let profiles = Dictionary(uniqueKeysWithValues: specs.map { ($0.key.uuidString, $0.value) })
      return try encoder.encode(Body(profiles: profiles))
    case .authAnswer(let id, let secret, let responses):
      struct Body: Encodable {
        let type = "auth.answer"
        var id: String
        var secret: String?
        var responses: [String]?
        // 显式写出 null：broker 用它区分「取消」和「字段缺失」。
        func encode(to encoder: Encoder) throws {
          var container = encoder.container(keyedBy: CodingKeys.self)
          try container.encode(type, forKey: .type)
          try container.encode(id, forKey: .id)
          try container.encode(secret, forKey: .secret)
          try container.encode(responses, forKey: .responses)
        }
        enum CodingKeys: String, CodingKey { case type, id, secret, responses }
      }
      return try encoder.encode(Body(id: id, secret: secret, responses: responses))
    case .hostKeyAnswer(let id, let accept):
      struct Body: Encodable { let type = "hostkey.answer"; var id: String; var accept: Bool }
      return try encoder.encode(Body(id: id, accept: accept))
    case .disconnect(let endpoint):
      struct Body: Encodable { let type = "disconnect"; var endpoint: String }
      return try encoder.encode(Body(endpoint: endpoint))
    case .shutdown:
      struct Body: Encodable { let type = "shutdown" }
      return try encoder.encode(Body())
    }
  }
}

// MARK: - config 子命令输出（PROTOCOL.md §5）

/// `aster-ssh config list/resolve --json` 里的一台主机。
public struct SSHConfigHostEntry: Codable, Equatable, Sendable {
  public var alias: String
  public var hostName: String?
  public var user: String?
  public var port: Int?
  public var identityFiles: [String]
  /// `UserKnownHostsFile` 原文路径（可能多个）。
  public var userKnownHostsFiles: [String]
  /// `IdentitiesOnly`。
  public var identitiesOnly: Bool?
  /// `IdentityAgent` 原文（路径、`$VAR`、`SSH_AUTH_SOCK` 或 `none`）；没写为 nil。
  public var identityAgent: String?
  public var proxyJump: String?
  public var proxyCommand: String?
  public var forwards: [SSHForwardRule]
  public var keepaliveInterval: Int?
  public var keepaliveCountMax: Int?

  public init(
    alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
    identityFiles: [String] = [], userKnownHostsFiles: [String] = [], identitiesOnly: Bool? = nil,
    identityAgent: String? = nil, proxyJump: String? = nil, proxyCommand: String? = nil,
    forwards: [SSHForwardRule] = [], keepaliveInterval: Int? = nil, keepaliveCountMax: Int? = nil
  ) {
    self.alias = alias
    self.hostName = hostName
    self.user = user
    self.port = port
    self.identityFiles = identityFiles
    self.userKnownHostsFiles = userKnownHostsFiles
    self.identitiesOnly = identitiesOnly
    self.identityAgent = identityAgent
    self.proxyJump = proxyJump
    self.proxyCommand = proxyCommand
    self.forwards = forwards
    self.keepaliveInterval = keepaliveInterval
    self.keepaliveCountMax = keepaliveCountMax
  }

  private enum CodingKeys: String, CodingKey {
    case alias, hostName, user, port, identityFiles, userKnownHostsFiles, identitiesOnly, identityAgent
    case proxyJump, proxyCommand, forwards, keepaliveInterval, keepaliveCountMax
  }

  /// 数组字段缺失时按空处理：旧版 aster-ssh 的输出没有 `userKnownHostsFiles`，不能因此整份解码失败。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    alias = try container.decode(String.self, forKey: .alias)
    hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
    user = try container.decodeIfPresent(String.self, forKey: .user)
    port = try container.decodeIfPresent(Int.self, forKey: .port)
    identityFiles = try container.decodeIfPresent([String].self, forKey: .identityFiles) ?? []
    userKnownHostsFiles =
      try container.decodeIfPresent([String].self, forKey: .userKnownHostsFiles) ?? []
    identitiesOnly = try container.decodeIfPresent(Bool.self, forKey: .identitiesOnly)
    identityAgent = try container.decodeIfPresent(String.self, forKey: .identityAgent)
    proxyJump = try container.decodeIfPresent(String.self, forKey: .proxyJump)
    proxyCommand = try container.decodeIfPresent(String.self, forKey: .proxyCommand)
    forwards = try container.decodeIfPresent([SSHForwardRule].self, forKey: .forwards) ?? []
    keepaliveInterval = try container.decodeIfPresent(Int.self, forKey: .keepaliveInterval)
    keepaliveCountMax = try container.decodeIfPresent(Int.self, forKey: .keepaliveCountMax)
  }
}

/// 导入时被忽略的一条配置（ImportReport）。
public struct SSHConfigIgnoredOption: Codable, Equatable, Sendable {
  public var file: String
  public var line: Int
  public var option: String
  public var reason: String

  public init(file: String, line: Int, option: String, reason: String) {
    self.file = file
    self.line = line
    self.option = option
    self.reason = reason
  }
}

/// `aster-ssh config list --json` 的完整输出。
public struct SSHConfigListing: Codable, Equatable, Sendable {
  public var hosts: [SSHConfigHostEntry]
  public var ignored: [SSHConfigIgnoredOption]

  public init(hosts: [SSHConfigHostEntry] = [], ignored: [SSHConfigIgnoredOption] = []) {
    self.hosts = hosts
    self.ignored = ignored
  }
}
