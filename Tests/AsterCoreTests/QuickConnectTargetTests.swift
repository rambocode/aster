import Foundation
import Testing

@testable import AsterCore

// QuickConnectTarget：快连目标解析、规范 target 与从手敲 ssh 命令反推。

@Test(
  "快连解析支持 user@host、端口、ssh:// 与 IPv6",
  arguments: [
    ("deploy@10.0.0.5", "deploy", "10.0.0.5", nil),
    ("deploy@10.0.0.5:2222", "deploy", "10.0.0.5", 2222),
    ("ssh://deploy@example.com:2200", "deploy", "example.com", 2200),
    ("SSH://example.com", nil, "example.com", nil),
    ("ssh://example.com/", nil, "example.com", nil),
    ("[::1]:2222", nil, "::1", 2222),
    ("root@[fe80::1]", "root", "fe80::1", nil),
    ("fe80::1", nil, "fe80::1", nil),
    ("host.example.com", nil, "host.example.com", nil),
    ("java:22", nil, "java", 22),
    ("  root@box  ", "root", "box", nil),
  ] as [(String, String?, String, Int?)])
func quickConnectParsesSupportedForms(input: String, user: String?, host: String, port: Int?) throws {
  let target = try #require(QuickConnectTarget.parse(input))
  #expect(target.user == user)
  #expect(target.host == host)
  #expect(target.port == port)
}

@Test("快连解析以最后一个 @ 分隔用户名与主机")
func quickConnectSplitsUserAtLastAt() throws {
  let target = try #require(QuickConnectTarget.parse("root@ubuntu@orb"))
  #expect(target.user == "root@ubuntu")
  #expect(target.host == "orb")
  #expect(target.normalizedTarget == "root@ubuntu@orb")
}

@Test(
  "快连解析拒绝非法端口、空主机、空白与路径",
  arguments: [
    "", "@", "root@", "java:99999", "java:0", "java:+22", "java:abc", "[::1]x", "[::1",
    "a b", "ssh://host/path", "-oProxyCommand=x", "-l@host", "host;rm",
  ])
func quickConnectRejectsInvalidInput(input: String) {
  #expect(QuickConnectTarget.parse(input) == nil)
}

@Test("规范 target：端口 22 用 user@host，其它端口与 IPv6 用 ssh:// URI")
func quickConnectNormalizedTargetMatchesOpenSSHRules() throws {
  #expect(try #require(QuickConnectTarget.parse("deploy@box")).normalizedTarget == "deploy@box")
  #expect(try #require(QuickConnectTarget.parse("deploy@box:22")).normalizedTarget == "deploy@box")
  #expect(
    try #require(QuickConnectTarget.parse("deploy@box:2222")).normalizedTarget
      == "ssh://deploy@box:2222")
  #expect(try #require(QuickConnectTarget.parse("[::1]")).normalizedTarget == "ssh://[::1]")
  #expect(
    try #require(QuickConnectTarget.parse("me@[::1]:2200")).normalizedTarget == "ssh://me@[::1]:2200")
  #expect(QuickConnectTarget.openSSHTarget(user: "", host: "box", port: 2222) == "ssh://box:2222")
}

@Test("显示文本省略 22 端口，IPv6 加方括号")
func quickConnectDisplayText() throws {
  #expect(try #require(QuickConnectTarget.parse("ssh://me@box:22")).displayText == "me@box")
  #expect(try #require(QuickConnectTarget.parse("me@[::1]:2200")).displayText == "me@[::1]:2200")
}

@Test("只有带地址特征的查询才算快连候选")
func quickConnectLooksLikeTarget() {
  #expect(QuickConnectTarget.looksLikeTarget("deploy@10.0.0.5"))
  #expect(QuickConnectTarget.looksLikeTarget("host.example.com"))
  #expect(QuickConnectTarget.looksLikeTarget("java:2222"))
  #expect(!QuickConnectTarget.looksLikeTarget("java"))
  #expect(!QuickConnectTarget.looksLikeTarget(""))
}

@Test("从 ssh 命令反推：接受目标与 -p / -l，命令行显式值优先")
func quickConnectDerivesFromSSHCommand() throws {
  let cases: [(String, QuickConnectTarget)] = [
    ("ssh deploy@box", QuickConnectTarget(user: "deploy", host: "box", port: nil)),
    ("ssh -p 2222 deploy@box", QuickConnectTarget(user: "deploy", host: "box", port: 2222)),
    ("ssh -p2200 -l admin box", QuickConnectTarget(user: "admin", host: "box", port: 2200)),
    ("ssh -l admin me@box", QuickConnectTarget(user: "admin", host: "box", port: nil)),
    ("ssh -p 2222 ssh://me@box:2200", QuickConnectTarget(user: "me", host: "box", port: 2222)),
    ("ssh -- me@box", QuickConnectTarget(user: "me", host: "box", port: nil)),
  ]
  for (command, expected) in cases {
    let invocation = try #require(SSHCommandInvocation.parse(command))
    #expect(QuickConnectTarget.derive(from: invocation) == .target(expected), "\(command)")
  }
}

@Test("从 ssh 命令反推：其它选项给出拒绝原因")
func quickConnectDeriveRejectsOtherOptions() throws {
  let cases: [(String, QuickConnectTarget.DerivationRejection)] = [
    ("ssh -i ~/.ssh/key box", .unsupportedOption("-i")),
    ("ssh -J jump box", .unsupportedOption("-J")),
    ("ssh -o ProxyCommand=nc box", .unsupportedOption("-o")),
    ("ssh -A box", .unsupportedOption("-A")),
    ("ssh -p 99999 box", .invalidPort("99999")),
  ]
  for (command, expected) in cases {
    let invocation = try #require(SSHCommandInvocation.parse(command))
    #expect(QuickConnectTarget.derive(from: invocation) == .rejected(expected), "\(command)")
  }
}
