import Foundation
import Testing

@testable import AsterCore

/// P3.1 / A10：SSH target 的 OpenSSH 语义解析、连接前拒绝规则与 argv 生成。

// MARK: - 解析：OpenSSH 语义

@Test func remoteSSHTargetParsesAliasWithoutGuessingPort() throws {
  let target = try RemoteSSHTarget.parse("myhost")
  #expect(target.rawText == "myhost")
  #expect(target.user == nil)
  #expect(target.host == "myhost")
  // 未写端口就不能臆测 22：真实端口由 SSH 配置决定。
  #expect(target.port == nil)
  #expect(target.isURI == false)
}

@Test func remoteSSHTargetParsesUserAtHost() throws {
  let target = try RemoteSSHTarget.parse("user@host")
  #expect(target.user == "user")
  #expect(target.host == "host")
  #expect(target.port == nil)
}

@Test func remoteSSHTargetSplitsUserAtLastAtSign() throws {
  // OrbStack 的 `root@ubuntu@orb`：OpenSSH 按**最后一个** `@` 拆分，
  // 按第一个 `@` 拆会得到 user=root、host=ubuntu@orb，连到错误的机器。
  let target = try RemoteSSHTarget.parse("root@ubuntu@orb")
  #expect(target.user == "root@ubuntu")
  #expect(target.host == "orb")
  #expect(target.rawText == "root@ubuntu@orb")
}

@Test func remoteSSHTargetParsesURIWithExplicitPort() throws {
  let target = try RemoteSSHTarget.parse("ssh://user@host:2222")
  #expect(target.isURI)
  #expect(target.user == "user")
  #expect(target.host == "host")
  #expect(target.port == 2222)
}

@Test func remoteSSHTargetURIWithoutPortKeepsPortNil() throws {
  let target = try RemoteSSHTarget.parse("ssh://host")
  #expect(target.isURI)
  #expect(target.host == "host")
  #expect(target.port == nil)
}

@Test func remoteSSHTargetParsesBracketedIPv6URI() throws {
  let target = try RemoteSSHTarget.parse("ssh://[2001:db8::1]:22")
  #expect(target.host == "2001:db8::1")
  #expect(target.port == 22)
  #expect(target.rawText == "ssh://[2001:db8::1]:22")
}

@Test func remoteSSHTargetParsesBareIPv6WithoutBrackets() throws {
  // OpenSSH 只在 `ssh://` URI 里理解方括号；非 URI 形式必须写裸地址。
  let target = try RemoteSSHTarget.parse("root@ubuntu@::1")
  #expect(target.user == "root@ubuntu")
  #expect(target.host == "::1")
  #expect(target.port == nil)
  #expect(target.rawText == "root@ubuntu@::1")
}

@Test func remoteSSHTargetRejectsBracketedIPv6OutsideURI() {
  // 非 URI 的 `[::1]` 交给 ssh 必然是 `Could not resolve hostname [::1]`，
  // 注定失败的形式必须在连接前拒绝，而不是等 SSH 层报错。
  #expect(throws: RemoteSSHTargetError.self) { _ = try RemoteSSHTarget.parse("[::1]") }
  #expect(throws: RemoteSSHTargetError.self) { _ = try RemoteSSHTarget.parse("user@[::1]") }
}

// MARK: - 连接前拒绝

@Test func remoteSSHTargetRejectsEmptyInput() {
  #expect(throws: RemoteSSHTargetError.empty) { _ = try RemoteSSHTarget.parse("") }
  #expect(throws: RemoteSSHTargetError.empty) { _ = try RemoteSSHTarget.parse("   \n\t ") }
}

@Test func remoteSSHTargetRejectsOptionLikeInput() {
  #expect(throws: RemoteSSHTargetError.optionLike("-oProxyCommand=id")) {
    _ = try RemoteSSHTarget.parse("-oProxyCommand=id")
  }
  #expect(throws: RemoteSSHTargetError.self) { _ = try RemoteSSHTarget.parse("-v") }
}

@Test func remoteSSHTargetRejectsShellMetacharacters() {
  // 采用允许表实现，因此这里逐个确认常见 Shell 元字符确实落在表外。
  let metacharacters: [String] = [
    ";", "|", "&", "$", "`", " ", "'", "\"", "(", ")", "*", "?", "<", ">", "\\", "\n", "\t",
  ]
  for character in metacharacters {
    #expect(throws: RemoteSSHTargetError.self, "未拒绝元字符 \(character.debugDescription)") {
      _ = try RemoteSSHTarget.parse("host\(character)x")
    }
  }
}

@Test func remoteSSHTargetRejectsSlashOutsideURI() {
  #expect(throws: RemoteSSHTargetError.unsupportedCharacter("/")) {
    _ = try RemoteSSHTarget.parse("host/path")
  }
  #expect(throws: RemoteSSHTargetError.self) { _ = try RemoteSSHTarget.parse("../etc/passwd") }
}

@Test func remoteSSHTargetRejectsInvalidPorts() {
  for port in ["0", "65536", "abc", "22x", "022"] {
    #expect(throws: RemoteSSHTargetError.invalidPort(port), "端口 \(port) 未被拒绝") {
      _ = try RemoteSSHTarget.parse("ssh://host:\(port)")
    }
  }
}

// MARK: - argv 生成

@Test func remoteSSHInvocationForcesBatchModeAndOptionTerminator() throws {
  let target = try RemoteSSHTarget.parse("root@ubuntu@orb")
  let argv = RemoteSSHInvocation(target: target).arguments()

  let batchIndex = try #require(argv.firstIndex(of: "BatchMode=yes"))
  #expect(argv[batchIndex - 1] == "-o")

  // 没有远端命令时 target 是最后一个元素，前面必须紧跟 `--`。
  #expect(argv.last == "root@ubuntu@orb")
  #expect(argv[argv.count - 2] == "--")
  #expect(!argv.contains("-F"))
}

@Test func remoteSSHInvocationKeepsTargetTextVerbatim() throws {
  let raw = "ssh://[2001:db8::1]:22"
  let target = try RemoteSSHTarget.parse(raw)
  let argv = RemoteSSHInvocation(target: target, remoteCommand: ["/bin/true"]).arguments()

  let index = try #require(argv.firstIndex(of: raw))
  // target 未被改写成 host/port 拼装结果，且仍由 `--` 隔离。
  #expect(argv[index - 1] == "--")
  #expect(index == argv.count - 2)
}

@Test func remoteSSHInvocationNeverAutoAcceptsHostKeys() throws {
  let target = try RemoteSSHTarget.parse("myhost")
  let argv = RemoteSSHInvocation(
    target: target, configurationFile: "/tmp/aster-ssh-test/config", remoteCommand: ["/bin/true"]
  ).arguments()
  let joined = argv.joined(separator: " ")
  #expect(!joined.contains("StrictHostKeyChecking=accept-new"))
  #expect(!joined.contains("StrictHostKeyChecking=no"))
  #expect(!joined.contains("UserKnownHostsFile=/dev/null"))
  #expect(argv.first == "-F")
}

@Test func remoteSSHInvocationOmitsConfigFileWhenUnmanaged() throws {
  let target = try RemoteSSHTarget.parse("myhost")
  let transport = RemoteSessionTransport(
    target: target,
    policy: RemoteSSHPolicy(manageSSHConfig: false),
    managedConfiguration: RemoteSSHManagedConfiguration(
      directoryPath: "/tmp/aster-ssh-x",
      configurationPath: "/tmp/aster-ssh-x/config",
      controlPath: "/tmp/aster-ssh-x/c-%C")
  )
  let argv = transport.sshArguments(remoteCommand: ["/bin/true"])
  #expect(!argv.contains("-F"))
  #expect(!argv.joined(separator: " ").contains("/tmp/aster-ssh-x"))
}

@Test func remoteSSHInvocationQuotesRemoteArgumentsForPOSIXShell() throws {
  #expect(RemoteSSHInvocation.quote("a'b") == #"'a'\''b'"#)
  #expect(RemoteSSHInvocation.quote("plain") == "'plain'")

  let target = try RemoteSSHTarget.parse("myhost")
  let argv = RemoteSSHInvocation(
    target: target,
    remoteCommand: ["/usr/bin/aster-session", "server status", "a;rm -rf /"]
  ).arguments()

  // 远端命令必须压成**一个** argv 元素，否则会被 ssh 当成多个词重新拼接。
  let remote = try #require(argv.last)
  #expect(argv[argv.count - 3] == "--")
  #expect(remote == #"'/usr/bin/aster-session' 'server status' 'a;rm -rf /'"#)
}
