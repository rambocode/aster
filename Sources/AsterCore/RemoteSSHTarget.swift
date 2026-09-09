import Foundation

/// 远程工作模式的 SSH target 解析与 argv 生成。
///
/// 固定约束（`docs/developer/remote-work.md` §4.1 第 3、4 条）：
/// 1. target 原文保存进机器配置，连接时**原样**作为 `ssh` 的一个 argv 元素传递；
///    本地不经过 `/bin/sh -c`，因此本地不存在 Shell 二次解释。
/// 2. 不自行按第一个 `@` 拆分。`root@ubuntu@orb` 由 OpenSSH 按最后一个 `@` 解释成
///    user=`root@ubuntu`、host=`orb`；本类型的拆分只用于显示与诊断，不参与 argv。
/// 3. 以选项开头（`-`）或含 Shell 元字符的 target 在**连接前**拒绝，绝不交给 ssh。

/// target 解析失败原因。全部在建立连接之前产生。
public enum RemoteSSHTargetError: Error, Equatable, Sendable {
  /// 空串或只有空白。
  case empty
  /// 以 `-` 开头，会被 OpenSSH 当成选项。
  case optionLike(String)
  /// 含不在允许字符集内的字符（覆盖全部 Shell 元字符与空白）。
  case unsupportedCharacter(String)
  /// `ssh://` URI 结构非法。
  case invalidURI(String)
  /// 端口不是 1–65535 的十进制整数。
  case invalidPort(String)
  /// 拆分后没有 host 段。
  case missingHost
}

/// 已通过前置校验的 SSH target。
///
/// `rawText` 是唯一进入 argv 的字段；`user`/`host`/`port` 只用于界面显示、
/// attention 文案和诊断，不重新拼装命令行。
public struct RemoteSSHTarget: Equatable, Sendable {
  /// 原始 target 文本（已去掉首尾空白），机器配置保存的就是它。
  public let rawText: String
  /// OpenSSH 语义下的用户名段；无显式用户时为 nil（由 SSH 配置决定）。
  public let user: String?
  /// 主机段（alias、主机名或 IP 字面量）。URI 形式的 IPv6 已去掉方括号；非 URI 形式不接受方括号。
  public let host: String
  /// 显式端口；未指定时为 nil，不臆测 22。
  public let port: Int?
  /// 是否来自 `ssh://` URI 形式。
  public let isURI: Bool

  /// 允许出现在 target 里的字符集。采用允许表而不是禁止表：任何未列出的字符
  /// （空格、`;`、`&`、`|`、`$`、反引号、引号、括号、通配符、换行等）都被拒绝，
  /// 这样新增的 Shell 元字符不会因为漏列而放行。
  private static let allowedCharacters: Set<Character> = {
    var set = Set<Character>()
    for scalar in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(Character(UnicodeScalar(scalar))) }
    for scalar in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(Character(UnicodeScalar(scalar))) }
    for scalar in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(Character(UnicodeScalar(scalar))) }
    for character in ".-_@:[]%" { set.insert(character) }
    return set
  }()

  /// 解析并校验 target。任何失败都发生在连接之前。
  public static func parse(_ raw: String) throws -> RemoteSSHTarget {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RemoteSSHTargetError.empty }
    guard !trimmed.hasPrefix("-") else { throw RemoteSSHTargetError.optionLike(trimmed) }

    let uriPrefix = "ssh://"
    let isURI = trimmed.lowercased().hasPrefix(uriPrefix)
    // `/` 只在 URI 的 scheme 分隔符里合法；非 URI target 出现 `/` 一律拒绝，
    // 避免把路径或选项片段当作主机名传给 ssh。
    let body = isURI ? String(trimmed.dropFirst(uriPrefix.count)) : trimmed
    for character in body where !allowedCharacters.contains(character) {
      throw RemoteSSHTargetError.unsupportedCharacter(String(character))
    }
    guard !body.isEmpty else { throw RemoteSSHTargetError.missingHost }

    let (userPart, hostPart) = splitUser(body)
    if isURI {
      let (host, port) = try splitHostAndPort(hostPart)
      guard !host.isEmpty else { throw RemoteSSHTargetError.missingHost }
      return RemoteSSHTarget(rawText: trimmed, user: userPart, host: host, port: port, isURI: true)
    }
    // 非 URI 形式没有 `host:port` 语法（`:` 在 scp 里才是路径分隔符），也**不接受**
    // 方括号包裹的 IPv6 字面量：OpenSSH 只在 `ssh://` URI 里理解方括号，非 URI 形式
    // 传 `[::1]` 必然得到 `Could not resolve hostname [::1]`。既然注定连不上，就必须
    // 按「连接前拒绝」处理，而不是让它跑到 SSH 层才失败。裸 `::1` 是合法写法。
    guard !hostPart.contains("["), !hostPart.contains("]") else {
      throw RemoteSSHTargetError.unsupportedCharacter("[]")
    }
    guard !hostPart.isEmpty else { throw RemoteSSHTargetError.missingHost }
    return RemoteSSHTarget(rawText: trimmed, user: userPart, host: hostPart, port: nil, isURI: false)
  }

  /// 按 OpenSSH 语义在**最后一个** `@` 处拆用户名，保证 `root@ubuntu@orb` 正确。
  private static func splitUser(_ body: String) -> (String?, String) {
    guard let index = body.lastIndex(of: "@") else { return (nil, body) }
    let user = String(body[body.startIndex..<index])
    let host = String(body[body.index(after: index)...])
    return (user.isEmpty ? nil : user, host)
  }

  /// URI 形式的 `host[:port]`，其中 host 可以是 `[IPv6]`。
  private static func splitHostAndPort(_ text: String) throws -> (String, Int?) {
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else {
        throw RemoteSSHTargetError.invalidURI(text)
      }
      let host = String(text[text.index(after: text.startIndex)..<close])
      let rest = String(text[text.index(after: close)...])
      if rest.isEmpty { return (host, nil) }
      guard rest.hasPrefix(":") else { throw RemoteSSHTargetError.invalidURI(text) }
      return (host, try parsePort(String(rest.dropFirst())))
    }
    // 无方括号时多个 `:` 说明是裸 IPv6 字面量，此时不能把最后一段当端口。
    let colonCount = text.filter { $0 == ":" }.count
    if colonCount == 0 { return (text, nil) }
    if colonCount > 1 { return (text, nil) }
    let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    return (String(parts[0]), try parsePort(String(parts[1])))
  }

  private static func parsePort(_ text: String) throws -> Int {
    guard let value = Int(text), value >= 1, value <= 65535, String(value) == text else {
      throw RemoteSSHTargetError.invalidPort(text)
    }
    return value
  }

  /// 用于 attention 文案与日志的脱敏描述：只暴露 target 原文，不含任何凭据。
  public var displayDescription: String {
    if let port { return "\(rawText) (host=\(host), port=\(port))" }
    return rawText
  }
}

/// 一次 `ssh` 调用的完整描述。生成的是 argv 数组，调用方直接 exec，不经 Shell。
public struct RemoteSSHInvocation: Equatable, Sendable {
  /// 已校验的 target。
  public var target: RemoteSSHTarget
  /// 私有临时配置文件路径（`-F`）。`manage_ssh_config=false` 时为 nil，直接用用户配置。
  public var configurationFile: String?
  /// 附加 `-o key=value`；调用方给出的是完整 `key=value` 文本。
  public var options: [String]
  /// 远端要执行的 argv。为空表示只建立连接（用于认证探测）。
  public var remoteCommand: [String]
  /// 连接超时秒数。
  public var connectTimeout: Int

  public init(
    target: RemoteSSHTarget,
    configurationFile: String? = nil,
    options: [String] = [],
    remoteCommand: [String] = [],
    connectTimeout: Int = 10
  ) {
    self.target = target
    self.configurationFile = configurationFile
    self.options = options
    self.remoteCommand = remoteCommand
    self.connectTimeout = connectTimeout
  }

  /// OpenSSH 可执行文件的固定路径。不从 PATH 搜索，避免被环境劫持。
  public static let executablePath = "/usr/bin/ssh"

  /// 生成 argv。
  ///
  /// 关键点：`--` 结束选项解析后才放 target，因此即使某个 target 通过了字符校验
  /// 也不会被当成选项；远端命令逐个做 POSIX 单引号转义再拼成一行，因为 OpenSSH
  /// 必定把远端命令交给登录 Shell，转义是唯一能保证 argv 字面传递的手段。
  public func arguments() -> [String] {
    var argv: [String] = []
    if let configurationFile { argv += ["-F", configurationFile] }
    argv += ["-o", "BatchMode=yes"]
    argv += ["-o", "ConnectTimeout=\(connectTimeout)"]
    for option in options { argv += ["-o", option] }
    argv += ["--", target.rawText]
    if !remoteCommand.isEmpty { argv.append(RemoteSSHInvocation.shellQuoted(remoteCommand)) }
    return argv
  }

  /// 把远端 argv 转成一条对 POSIX Shell 安全的命令行。
  public static func shellQuoted(_ argv: [String]) -> String {
    argv.map(quote).joined(separator: " ")
  }

  /// POSIX 单引号转义：`'` 写成 `'\''`，其余字符全部字面保留。
  public static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
