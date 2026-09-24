import Foundation

// 快连目标的纯解析（移植自 tty7 `parse_quick_connect`，Apache-2.0）。
// Open Quickly 的快连行、「保存为主机…」表单预填与手敲 ssh 命令的反推都用它；
// 不访问文件系统、不读 `~/.ssh/config`，alias 与主机名在这一层不做区分。

/// 一个可直接连接的 SSH 目标：`user@host:port` 的结构化形式。
public struct QuickConnectTarget: Equatable, Sendable {
  /// 用户名；nil 表示沿用配置或本机用户名。用户名本身可以含 `@`（例如 OrbStack 的 `root@ubuntu`）。
  public var user: String?
  /// 主机名、alias 或 IP 字面量（IPv6 不带方括号）。
  public var host: String
  /// 端口；nil 表示未指定（按 22 处理）。
  public var port: Int?

  public init(user: String?, host: String, port: Int?) {
    self.user = user
    self.host = host
    self.port = port
  }

  /// 实际端口：未指定时为 22。
  public var effectivePort: Int { port ?? 22 }

  /// 主机是否为 IPv6 字面量。
  public var isIPv6: Bool { host.contains(":") }

  /// 交给 OpenSSH 与 broker 的规范目标文本，规则见 `openSSHTarget(user:host:port:)`。
  public var normalizedTarget: String {
    Self.openSSHTarget(user: user, host: host, port: effectivePort)
  }

  /// 显示用的 `user@host:port`；端口为 22 或未指定时省略，IPv6 加方括号。
  public var displayText: String {
    let hostText = isIPv6 ? "[\(host)]" : host
    var text = user.map { "\($0)@\(hostText)" } ?? hostText
    if let port, port != 22 { text += ":\(port)" }
    return text
  }

  // MARK: - 规范目标

  /// 生成 OpenSSH 能直接接受的目标文本。
  ///
  /// 端口不是 22 或主机是 IPv6 字面量时必须用 `ssh://` URI：OpenSSH 的非 URI 形式没有
  /// `host:port` 语法，`user@host:2222` 会被整体当成主机名解析失败。机器配置的 target
  /// （`MachineFleetModel.openSSHTarget`）也走这里，两边永远一致。
  public static func openSSHTarget(user: String?, host: String, port: Int) -> String {
    let isIPv6 = host.contains(":")
    let userPart = user.map { $0.isEmpty ? "" : "\($0)@" } ?? ""
    guard port != 22 || isIPv6 else { return userPart + host }
    let hostPart = isIPv6 ? "[\(host)]" : host
    return "ssh://\(userPart)\(hostPart)" + (port == 22 ? "" : ":\(port)")
  }

  // MARK: - 解析

  /// 查询文本是否「长得像」一个连接目标：至少含 `@`、`:`、`.` 之一。
  ///
  /// 与 tty7 一致：裸词（`java`、`split`）也能被解析成主机名，但把每个搜索词都变成
  /// 「SSH 连接 …」行会淹没真正的搜索结果，所以只在带有地址特征时才给快连行。
  public static func looksLikeTarget(_ query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    return trimmed.contains(where: { $0 == "@" || $0 == ":" || $0 == "." })
  }

  /// 解析 `user@host`、`user@host:port`、`ssh://…`、`[v6]:port` 与裸主机名。
  ///
  /// 用户名与主机以**最后一个** `@` 分隔；端口必须是 1…65535 的十进制数；不带方括号而含
  /// 多个冒号的文本按 IPv6 主机处理（没有端口）。含空白、控制字符或非法主机字符时返回 nil。
  public static func parse(_ input: String) -> QuickConnectTarget? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024,
      !trimmed.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
      })
    else { return nil }
    var body = Substring(trimmed)
    if body.lowercased().hasPrefix("ssh://") { body = body.dropFirst(6) }
    // URI 结尾允许一个 `/`（`ssh://host/`）；路径部分对 SSH 没有意义，出现即视为非法。
    if body.hasSuffix("/") { body = body.dropLast() }
    guard !body.contains("/") else { return nil }

    let user: String?
    let hostPort: Substring
    if let separator = body.lastIndex(of: "@") {
      let rawUser = body[..<separator]
      user = rawUser.isEmpty ? nil : String(rawUser)
      hostPort = body[body.index(after: separator)...]
    } else {
      user = nil
      hostPort = body
    }
    guard let split = splitHostPort(hostPort), isValidHost(split.host) else { return nil }
    // 以 `-` 开头的「主机」会在回退路径里被 ssh 当成选项，直接拒绝。
    guard !split.host.hasPrefix("-"), !(user?.hasPrefix("-") ?? false) else { return nil }
    return QuickConnectTarget(user: user, host: split.host, port: split.port)
  }

  /// 拆分主机与端口；端口非法时整体返回 nil（`java:99999` 不是一个可连接目标）。
  private static func splitHostPort(_ text: Substring) -> (host: String, port: Int?)? {
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return nil }
      let host = String(text[text.index(after: text.startIndex)..<close])
      let after = text[text.index(after: close)...]
      if after.isEmpty { return (host, nil) }
      guard after.hasPrefix(":"), let port = parsePort(after.dropFirst()) else { return nil }
      return (host, port)
    }
    switch text.filter({ $0 == ":" }).count {
    case 0:
      return (String(text), nil)
    case 1:
      let colon = text.firstIndex(of: ":")!
      guard let port = parsePort(text[text.index(after: colon)...]) else { return nil }
      return (String(text[..<colon]), port)
    default:
      return (String(text), nil)
    }
  }

  /// 端口只接受纯十进制数字，拒绝 `+22`、`0` 与超出范围的值。
  private static func parsePort(_ text: Substring) -> Int? {
    guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
      let value = Int(text), (1...65_535).contains(value)
    else { return nil }
    return value
  }

  /// 主机名字符集与 `SSHCommandInvocation` 的校验一致：字母数字与 `._:-%`。
  private static func isValidHost(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 255 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-%"))
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }

  // MARK: - 从手敲的 ssh 命令反推

  /// 反推被拒绝的原因。文案由 App 层本地化，Core 只给结构化原因。
  public enum DerivationRejection: Equatable, Sendable {
    /// 用了 `-p` / `-l` 以外的选项（附带第一个出现的选项，如 `-i`）。
    case unsupportedOption(String)
    /// 选项缺少取值（如末尾的 `-p`）。
    case missingValue(String)
    /// `-p` 的取值不是合法端口。
    case invalidPort(String)
    /// 目标文本无法解析。
    case invalidDestination(String)
  }

  /// 反推结果：目标，或不能安全保存的原因。
  public enum Derivation: Equatable, Sendable {
    case target(QuickConnectTarget)
    case rejected(DerivationRejection)
  }

  /// 从一条手敲的 `ssh` 命令里提取可保存的目标。
  ///
  /// 只接受「一个目标」加可选的 `-p` / `-l`（含 `-p22` 这种附着写法）。其它选项
  /// （`-i`、`-J`、`-o`、`-A` 等）改变了连接方式，只保存 `user@host:port` 会得到一台
  /// 连不上或行为不同的主机，所以拒绝，由界面提示用户到主机设置里补全。
  /// 与 OpenSSH 一致，`-p` / `-l` 优先于目标文本里的端口和用户名。
  public static func derive(from invocation: SSHCommandInvocation) -> Derivation {
    var explicitPort: Int?
    var explicitUser: String?
    // `configurationArguments` 截止到 destination（含），最后一项就是目标本身。
    var arguments = invocation.configurationArguments.dropLast()[...]
    while let token = arguments.first {
      arguments = arguments.dropFirst()
      if token == "--" { continue }
      guard token.hasPrefix("-"), token.count >= 2 else {
        return .rejected(.invalidDestination(token))
      }
      let option = token[token.index(after: token.startIndex)]
      let optionName = "-\(option)"
      guard option == "p" || option == "l" else {
        return .rejected(.unsupportedOption(optionName))
      }
      let attached = String(token.dropFirst(2))
      let value: String
      if attached.isEmpty {
        guard let next = arguments.first else { return .rejected(.missingValue(optionName)) }
        arguments = arguments.dropFirst()
        value = next
      } else {
        value = attached
      }
      if option == "p" {
        guard let port = parsePort(Substring(value)) else { return .rejected(.invalidPort(value)) }
        explicitPort = port
      } else {
        guard !value.isEmpty, !value.hasPrefix("-") else {
          return .rejected(.missingValue(optionName))
        }
        explicitUser = value
      }
    }
    guard var target = parse(invocation.destination) else {
      return .rejected(.invalidDestination(invocation.destination))
    }
    if let explicitPort { target.port = explicitPort }
    if let explicitUser { target.user = explicitUser }
    return .target(target)
  }
}
