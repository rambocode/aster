import Foundation
import Testing

@testable import AsterCore

// 测 SSHHostProfile / SSHResolvedSpec / SSHHostResolver：默认项继承、库默认值、
// %h/%r/~ 展开、跳板链解析（含成环与过深）、credentialEndpoint 与 connectString 格式、
// SSHResolvedSpec 的 JSON round-trip。

private let testHome = "/Users/tester"
private let testLocalUser = "fallback-user"

/// 建一个未设置任何可继承字段的主机；用于验证「继承默认项」路径。
private func bareHost(name: String = "Host", host: String = "10.0.0.1", id: UUID = UUID())
  -> SSHHostProfile
{
  SSHHostProfile(id: id, name: name, host: host)
}

/// 测：主机字段全部留空时，解析结果应逐项继承默认项里设置的值。
@Test func sshHostProfileResolverInheritsDefaultsFields() throws {
  let defaultForward = SSHForwardRule(
    kind: .local, bind: SSHHostPort(host: "127.0.0.1", port: 8080),
    target: SSHHostPort(host: "localhost", port: 80))
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", user: "defaultUser",
    proxyCommand: "defaultProxy", auth: .password, identityFiles: ["default.key"],
    identitiesOnly: false, knownHostsFiles: [], agentForward: true, forwards: [defaultForward], keepaliveInterval: 20,
    keepaliveCountMax: 5, connectTimeout: 12, verifyHostKeys: false)
  let hostForward = SSHForwardRule(
    kind: .remote, bind: SSHHostPort(host: "0.0.0.0", port: 9090),
    target: SSHHostPort(host: "internal", port: 443))
  let host = SSHHostProfile(name: "Host1", host: "10.0.0.1", forwards: [hostForward])

  let spec = try SSHHostResolver.resolve(
    host.id, in: [defaults, host], homeDirectory: testHome, localUser: testLocalUser)

  #expect(spec.user == "defaultUser")
  #expect(spec.proxyCommand == "defaultProxy")
  #expect(spec.auth == .password)
  #expect(spec.identityFiles == ["default.key"])
  #expect(spec.agentForward == true)
  #expect(spec.keepaliveInterval == 20)
  #expect(spec.keepaliveCountMax == 5)
  #expect(spec.connectTimeout == 12)
  #expect(spec.verifyHostKeys == false)
  // 默认项的转发规则必须排在主机自己的规则前面。
  #expect(spec.forwards == [defaultForward, hostForward])
}

/// 测：既没有默认项、主机也不设置任何可选字段时，回落到库内置默认值。
@Test func sshHostProfileResolverUsesLibraryDefaultsWhenMissing() throws {
  let host = bareHost()
  let spec = try SSHHostResolver.resolve(
    host.id, in: [host], homeDirectory: testHome, localUser: testLocalUser)

  #expect(spec.port == 22)
  #expect(spec.user == testLocalUser)
  #expect(spec.auth == .auto)
  #expect(spec.identityFiles.isEmpty)
  #expect(spec.agentForward == false)
  #expect(spec.proxyCommand == nil)
  #expect(spec.keepaliveInterval == 15)
  #expect(spec.keepaliveCountMax == 3)
  #expect(spec.connectTimeout == 10)
  #expect(spec.verifyHostKeys == true)
}

/// 测：`expandIdentity` 的占位符展开与 `~` 展开语义。
@Test func sshHostProfileResolverExpandIdentityPlaceholders() {
  func expand(_ path: String, host: String, user: String, homeDirectory: String) -> String {
    SSHHostResolver.expandIdentity(path, host: host, user: user, homeDirectory: homeDirectory)
  }

  #expect(expand("%h", host: "example.com", user: "u", homeDirectory: testHome) == "example.com")
  #expect(expand("%r", host: "example.com", user: "deploy", homeDirectory: testHome) == "deploy")
  #expect(expand("%%", host: "h", user: "u", homeDirectory: testHome) == "%")
  // 未知占位符原样保留 % 与后一个字符。
  #expect(expand("%x", host: "h", user: "u", homeDirectory: testHome) == "%x")
  // 末尾孤立的 %（后面没有字符）保留成单个 %。
  #expect(expand("abc%", host: "h", user: "u", homeDirectory: testHome) == "abc%")
  // 单独的 ~ 展开成整个 home。
  #expect(expand("~", host: "h", user: "u", homeDirectory: testHome) == testHome)
  // ~/ 前缀展开并拼接剩余路径。
  #expect(
    expand("~/.ssh/id_ed25519", host: "h", user: "u", homeDirectory: testHome)
      == "\(testHome)/.ssh/id_ed25519")
  // home 本身以 / 结尾时不重复拼接分隔符。
  #expect(
    expand("~/.ssh/id_ed25519", host: "h", user: "u", homeDirectory: "\(testHome)/")
      == "\(testHome)/.ssh/id_ed25519")
  // %h/%r 组合与混排。
  #expect(
    expand("%r@%h.key", host: "example.com", user: "deploy", homeDirectory: testHome)
      == "deploy@example.com.key")
}

/// 测：A→B→C 的跳板链能正确解析成嵌套的 SSHResolvedSpec。
@Test func sshHostProfileResolverJumpChainResolvesNestedSpec() throws {
  let hostC = SSHHostProfile(name: "C", host: "c.example.com")
  let hostB = SSHHostProfile(name: "B", host: "b.example.com", jumpHostID: hostC.id)
  let hostA = SSHHostProfile(name: "A", host: "a.example.com", jumpHostID: hostB.id)

  let spec = try SSHHostResolver.resolve(
    hostA.id, in: [hostA, hostB, hostC], homeDirectory: testHome, localUser: testLocalUser)

  #expect(spec.host == "a.example.com")
  let jumpB = try #require(spec.jump)
  #expect(jumpB.spec.host == "b.example.com")
  let jumpC = try #require(jumpB.spec.jump)
  #expect(jumpC.spec.host == "c.example.com")
  #expect(jumpC.spec.jump == nil)
}

/// 测：跳板成环（A→B→A）必须抛 `.jumpCycle`。
@Test func sshHostProfileResolverJumpCycleThrows() {
  let idA = UUID()
  let idB = UUID()
  let hostA = SSHHostProfile(id: idA, name: "A", host: "a.example.com", jumpHostID: idB)
  let hostB = SSHHostProfile(id: idB, name: "B", host: "b.example.com", jumpHostID: idA)

  #expect(throws: SSHHostResolutionError.jumpCycle(idA)) {
    try SSHHostResolver.resolve(
      idA, in: [hostA, hostB], homeDirectory: testHome, localUser: testLocalUser)
  }
}

/// 建一条长度为 `count` 的跳板链：host[0] → host[1] → … → host[count-1]（终点不再跳）。
private func makeJumpChain(count: Int) -> [SSHHostProfile] {
  let ids = (0..<count).map { _ in UUID() }
  return (0..<count).map { index in
    SSHHostProfile(
      id: ids[index], name: "H\(index)", host: "h\(index).example.com",
      jumpHostID: index + 1 < count ? ids[index + 1] : nil)
  }
}

/// 测：跳板深度上限恰好为 `maximumJumpDepth`——链条内的深度能解析，多一跳就报 `.jumpTooDeep`。
///
/// `resolve` 内部检查发生在「即将解析第 k 个跳板」时，此时 `visited.count == k`；
/// 因此 8 跳（9 台主机）的链条应成功，9 跳（10 台主机）的链条应失败，
/// 这里按源码里 `visited.count <= maximumJumpDepth` 的精确语义来断言边界。
@Test func sshHostProfileResolverJumpDepthBoundary() throws {
  #expect(SSHHostResolver.maximumJumpDepth == 8)

  let okChain = makeJumpChain(count: 9)
  let okSpec = try SSHHostResolver.resolve(
    okChain[0].id, in: okChain, homeDirectory: testHome, localUser: testLocalUser)
  // 走到底：一路展开 8 层 jump 都不出错。
  var cursor: SSHResolvedSpecBox? = okSpec.jump
  var depth = 1
  while let box = cursor {
    depth += 1
    cursor = box.spec.jump
  }
  #expect(depth == 9)

  let tooDeepChain = makeJumpChain(count: 10)
  #expect(throws: SSHHostResolutionError.jumpTooDeep) {
    try SSHHostResolver.resolve(
      tooDeepChain[0].id, in: tooDeepChain, homeDirectory: testHome, localUser: testLocalUser)
  }
}

/// 测：默认项的 jumpHostID 指向某台主机时，那台主机自己解析不应形成自环（jump 为 nil），
/// 但引用它的其它主机仍能正常拿到跳板。
@Test func sshHostProfileResolverDefaultsJumpDoesNotSelfLoop() throws {
  let jumpHost = SSHHostProfile(name: "Jump", host: "jump.example.com")
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", jumpHostID: jumpHost.id)
  let hostA = SSHHostProfile(name: "A", host: "a.example.com")

  let jumpSpec = try SSHHostResolver.resolve(
    jumpHost.id, in: [defaults, jumpHost, hostA], homeDirectory: testHome, localUser: testLocalUser)
  #expect(jumpSpec.jump == nil)

  let aSpec = try SSHHostResolver.resolve(
    hostA.id, in: [defaults, jumpHost, hostA], homeDirectory: testHome, localUser: testLocalUser)
  #expect(aSpec.jump?.spec.host == "jump.example.com")
}

/// 测：主机不存在与主机名为空这两种失败。
@Test func sshHostProfileResolverUnknownHostAndMissingHostName() {
  let unknownID = UUID()
  #expect(throws: SSHHostResolutionError.unknownHost(unknownID)) {
    try SSHHostResolver.resolve(unknownID, in: [], homeDirectory: testHome, localUser: testLocalUser)
  }

  let emptyHost = SSHHostProfile(name: "Empty", host: "   ")
  #expect(throws: SSHHostResolutionError.missingHostName(emptyHost.id)) {
    try SSHHostResolver.resolve(
      emptyHost.id, in: [emptyHost], homeDirectory: testHome, localUser: testLocalUser)
  }
}

/// 测：`resolveAll` 把能解析的放进 specs，解析失败的连同原因放进 failures。
@Test func sshHostProfileResolverResolveAllCollectsFailures() {
  let good = bareHost(name: "Good", host: "good.example.com")
  let bad = SSHHostProfile(name: "Bad", host: "")

  let (specs, failures) = SSHHostResolver.resolveAll(
    [good, bad], homeDirectory: testHome, localUser: testLocalUser)

  #expect(specs[good.id]?.host == "good.example.com")
  #expect(specs[bad.id] == nil)
  #expect(failures[bad.id] == .missingHostName(bad.id))
  #expect(failures[good.id] == nil)
}

/// 测：`credentialEndpoint` 对 IPv6 地址加中括号，IPv4 与域名不加。
@Test func sshHostProfileResolverCredentialEndpointBracketsIPv6Only() throws {
  let ipv6Host = bareHost(host: "::1")
  let ipv6Spec = try SSHHostResolver.resolve(
    ipv6Host.id, in: [ipv6Host], homeDirectory: testHome, localUser: testLocalUser)
  #expect(ipv6Spec.credentialEndpoint == "\(testLocalUser)@[::1]:22")

  let ipv4Host = bareHost(host: "10.0.0.5")
  let ipv4Spec = try SSHHostResolver.resolve(
    ipv4Host.id, in: [ipv4Host], homeDirectory: testHome, localUser: testLocalUser)
  #expect(ipv4Spec.credentialEndpoint == "\(testLocalUser)@10.0.0.5:22")

  let domainHost = bareHost(host: "example.com")
  let domainSpec = try SSHHostResolver.resolve(
    domainHost.id, in: [domainHost], homeDirectory: testHome, localUser: testLocalUser)
  #expect(domainSpec.credentialEndpoint == "\(testLocalUser)@example.com:22")
}

/// 测：`SSHHostProfile.connectString` 的括号、@ 与端口省略规则。
@Test func sshHostProfileConnectStringFormatting() {
  let ipv6NoUser = SSHHostProfile(name: "N", host: "::1")
  #expect(ipv6NoUser.connectString == "[::1]")

  let withUserDefaultPort = SSHHostProfile(name: "N", host: "example.com", user: "deploy")
  #expect(withUserDefaultPort.connectString == "deploy@example.com")

  let withCustomPort = SSHHostProfile(name: "N", host: "example.com", port: 2222, user: "deploy")
  #expect(withCustomPort.connectString == "deploy@example.com:2222")

  let port22Explicit = SSHHostProfile(name: "N", host: "example.com", port: 22, user: "deploy")
  #expect(port22Explicit.connectString == "deploy@example.com")
}

/// 测：`SSHResolvedSpec` 的 JSON 编码把 `jump` 写成内嵌对象（而不是再包一层 `spec`），
/// 并且解码后与原值 round-trip 相等。
@Test func sshHostProfileResolvedSpecJSONRoundTripEmbedsJumpInline() throws {
  let inner = SSHResolvedSpec(
    host: "jump.example.com", port: 22, user: "deploy", auth: .auto, identityFiles: [],
    identitiesOnly: false, knownHostsFiles: [], agentForward: false, proxyCommand: nil, socksProxy: nil, httpProxy: nil, jump: nil,
    forwards: [], keepaliveInterval: 15, keepaliveCountMax: 3, connectTimeout: 10,
    verifyHostKeys: true)
  let outer = SSHResolvedSpec(
    host: "10.0.0.5", port: 2222, user: "root", auth: .publicKey, identityFiles: ["/k"],
    identitiesOnly: false, knownHostsFiles: [], agentForward: true, proxyCommand: "nc %h %p", socksProxy: SSHHostPort(host: "127.0.0.1", port: 1080),
    httpProxy: nil, jump: SSHResolvedSpecBox(inner), forwards: [], keepaliveInterval: 20,
    keepaliveCountMax: 4, connectTimeout: 8, verifyHostKeys: false)

  let data = try JSONEncoder().encode(outer)
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  let jump = try #require(json?["jump"] as? [String: Any])
  // jump 必须是「内嵌对象」，直接带 host 字段，不是再包一层 "spec"。
  #expect(jump["host"] as? String == "jump.example.com")
  #expect(jump["spec"] == nil)

  let decoded = try JSONDecoder().decode(SSHResolvedSpec.self, from: data)
  #expect(decoded == outer)
}

/// 测：`knownHostsFiles` 与 `identitiesOnly` 继承默认项，并展开 `~`（OrbStack 用自己的 known_hosts）。
@Test func sshHostProfileResolvesKnownHostsFilesAndIdentitiesOnly() throws {
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", identitiesOnly: true)
  let orb = SSHHostProfile(
    name: "orb", host: "127.0.0.1", port: 32222, user: "default",
    knownHostsFiles: ["~/.orbstack/ssh/known_hosts"])
  let plain = SSHHostProfile(name: "plain", host: "example.com")
  let hosts = [defaults, orb, plain]

  let orbSpec = try SSHHostResolver.resolve(orb.id, in: hosts, homeDirectory: "/Users/me", localUser: "me")
  #expect(orbSpec.knownHostsFiles == ["/Users/me/.orbstack/ssh/known_hosts"])
  #expect(orbSpec.identitiesOnly)

  let plainSpec = try SSHHostResolver.resolve(plain.id, in: hosts, homeDirectory: "/Users/me", localUser: "me")
  #expect(plainSpec.knownHostsFiles.isEmpty)
  let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(orbSpec)) as? [String: Any]
  #expect(json?["knownHostsFiles"] as? [String] == ["/Users/me/.orbstack/ssh/known_hosts"])
  #expect(json?["identitiesOnly"] as? Bool == true)
}

/// 测：`identityAgent` 主机优先、其次默认项，原文交给 broker 展开；跳板用自己的值；没写时不编码这个键。
@Test func sshHostProfileResolvesIdentityAgentPerHop() throws {
  let defaults = SSHHostProfile(
    id: SSHHostProfile.defaultsProfileID, name: "Defaults", identityAgent: "$DEFAULT_AGENT")
  let bastion = SSHHostProfile(name: "bastion", host: "b.example.com", identityAgent: "none")
  let own = SSHHostProfile(
    name: "own", host: "a.example.com", jumpHostID: bastion.id,
    identityAgent: " ~/Library/Group Containers/x/agent.sock ")
  let inherits = SSHHostProfile(name: "inherits", host: "c.example.com", identityAgent: "  ")
  let hosts = [defaults, bastion, own, inherits]

  let ownSpec = try SSHHostResolver.resolve(own.id, in: hosts, homeDirectory: "/Users/me", localUser: "me")
  #expect(ownSpec.identityAgent == "~/Library/Group Containers/x/agent.sock")
  #expect(ownSpec.jump?.spec.identityAgent == "none")
  let inheritsSpec = try SSHHostResolver.resolve(
    inherits.id, in: hosts, homeDirectory: "/Users/me", localUser: "me")
  #expect(inheritsSpec.identityAgent == "$DEFAULT_AGENT")

  let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ownSpec)) as? [String: Any]
  #expect(json?["identityAgent"] as? String == "~/Library/Group Containers/x/agent.sock")
  #expect((json?["jump"] as? [String: Any])?["identityAgent"] as? String == "none")

  let plain = try SSHHostResolver.resolve(
    inherits.id, in: [inherits], homeDirectory: "/Users/me", localUser: "me")
  #expect(plain.identityAgent == nil)
  let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
  #expect(plainJSON?["identityAgent"] == nil)
  #expect(try JSONDecoder().decode(SSHResolvedSpec.self, from: JSONEncoder().encode(plain)) == plain)
}
