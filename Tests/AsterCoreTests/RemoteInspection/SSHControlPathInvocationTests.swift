import Foundation
import Testing

@testable import AsterCore

/// 场景 A 旁路 argv：固定选项前置、用户选项原样保留、控制目录策略。

@Test func sshControlPathPutsOwnOptionsBeforeUserArguments() {
  let invocation = SSHControlPathInvocation(
    configurationArguments: ["-p", "2222", "-i", "~/.ssh/id_ed25519", "root@ubuntu@orb"],
    controlDirectory: "/tmp/aster-cm-501"
  )
  let argv = invocation.arguments(remoteCommand: ["/bin/sh", "-c", "echo hi", "sh"])

  #expect(
    Array(argv.prefix(10)) == [
      "-o", "ControlMaster=no",
      "-o", "ControlPath=/tmp/aster-cm-501/%C",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=5",
      "-o", "ServerAliveInterval=5",
    ])
  // 用户 argv 紧跟其后，顺序与原命令一致，destination 仍是最后一个非远端命令元素。
  #expect(
    Array(argv.dropFirst(10).dropLast())
      == ["-p", "2222", "-i", "~/.ssh/id_ed25519", "root@ubuntu@orb"])
  #expect(argv.last == "'/bin/sh' '-c' 'echo hi' 'sh'")
}

@Test func sshControlPathOmitsRemoteCommandWhenEmpty() {
  let invocation = SSHControlPathInvocation(
    configurationArguments: ["host"], controlDirectory: "/tmp/aster-cm-501")
  #expect(invocation.arguments(remoteCommand: []).last == "host")
}

@Test func sshControlPathCheckArgumentsUseSamePrefix() {
  let invocation = SSHControlPathInvocation(
    configurationArguments: ["-F", "/Users/a/.ssh/config", "host"],
    controlDirectory: "/tmp/aster-cm-501"
  )
  let argv = invocation.checkArguments()

  #expect(argv.prefix(2) == ["-o", "ControlMaster=no"])
  #expect(argv.suffix(5) == ["-O", "check", "-F", "/Users/a/.ssh/config", "host"])
  #expect(!argv.contains("'/bin/sh'"))
}

@Test func sshControlDirectoryPolicyRejectsUnsafePaths() {
  #expect(SSHControlDirectoryPolicy.validate(path: "/tmp/aster-cm-501"))
  // macOS 的 $TMPDIR 既不在 /tmp 下，也远超 socket 路径预算。
  #expect(
    !SSHControlDirectoryPolicy.validate(
      path: "/var/folders/qr/9h8n0t_s1rn6mwsx7s0000gn/T/aster-cm-501"))
  #expect(!SSHControlDirectoryPolicy.validate(path: "/tmp/" + String(repeating: "a", count: 64)))
  #expect(!SSHControlDirectoryPolicy.validate(path: "/tmp/aster\u{7}cm"))
  #expect(!SSHControlDirectoryPolicy.validate(path: "/tmp/"))
  #expect(!SSHControlDirectoryPolicy.validate(path: ""))
  #expect(!SSHControlDirectoryPolicy.validate(path: "/tmp/aster-cm-501/"))
}
