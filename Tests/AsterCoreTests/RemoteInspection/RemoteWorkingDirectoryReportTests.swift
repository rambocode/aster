// OSC 7 上报分类规则的回归：本机与远端必须严格分开，可疑输入一律判无效。

import Foundation
import Testing

@testable import AsterCore

private let testLocalHostNames: Set<String> = [
  "localhost", "127.0.0.1", "::1", "mikes-macbook.local", "mikes-macbook",
]

@Test("本机 file URL 归类为本地绝对路径")
func remoteWorkingDirectoryReportAcceptsLocalFileURLs() {
  let cases = [
    "file://localhost/Users/mike/source": "/Users/mike/source",
    "file:///tmp/Aster%20QA": "/tmp/Aster QA",
    "file://127.0.0.1/var/log": "/var/log",
    "file://mikes-macbook/Users/mike": "/Users/mike",
    "file://mikes-macbook.local/Users/mike": "/Users/mike",
    // 大小写不同的主机名仍是本机。
    "file://MIKES-MacBook/Users/mike": "/Users/mike",
    // 裸绝对路径是部分 Shell 的直接上报形式。
    "/Users/mike": "/Users/mike",
  ]
  for (payload, expected) in cases {
    #expect(
      RemoteWorkingDirectoryReport.parse(payload, localHostNames: testLocalHostNames)
        == .local(expected),
      "payload=\(payload)"
    )
  }
}

@Test("其它主机的 file URL 归类为远端目录并解码路径")
func remoteWorkingDirectoryReportDetectsRemoteHosts() {
  #expect(
    RemoteWorkingDirectoryReport.parse(
      "file://ubuntu/home/x%20y", localHostNames: testLocalHostNames)
      == .remote(RemoteWorkingDirectory(host: "ubuntu", path: "/home/x y"))
  )
  #expect(
    RemoteWorkingDirectoryReport.parse(
      "file://remote.example/home/mike", localHostNames: testLocalHostNames)
      == .remote(RemoteWorkingDirectory(host: "remote.example", path: "/home/mike"))
  )
}

@Test("非 file scheme、控制字符、超长与相对路径一律判无效")
func remoteWorkingDirectoryReportRejectsUntrustedPayloads() {
  let rejected = [
    "",
    "https://example.com/home/mike",
    "ssh://ubuntu/home/mike",
    // 相对路径没有可用基准。
    "relative/path",
    "~/source",
    // 远端 host 但路径不是绝对路径。
    "file://ubuntu",
    // 控制字符只会来自伪造或损坏的序列。
    "/tmp/a\u{1B}[31mb",
    "/tmp/a\nb",
    "/tmp/a\u{7F}b",
    String(repeating: "/a", count: 2_100),
  ]
  for payload in rejected {
    #expect(
      RemoteWorkingDirectoryReport.parse(payload, localHostNames: testLocalHostNames) == .invalid,
      "payload=\(payload.prefix(40))"
    )
  }
}

@Test("默认本机主机名集合包含回环名与本机长短名")
func remoteWorkingDirectoryReportDefaultLocalHostNames() {
  let names = RemoteWorkingDirectoryReport.defaultLocalHostNames
  #expect(names.isSuperset(of: RemoteWorkingDirectoryReport.loopbackHostNames))
  let machine = ProcessInfo.processInfo.hostName.lowercased()
  #expect(names.contains(machine))
  #expect(names.contains(machine.split(separator: ".").first.map(String.init) ?? machine))
  // 默认参数下本机上报仍走本地分支。
  #expect(RemoteWorkingDirectoryReport.parse("file://\(machine)/tmp") == .local("/tmp"))
}
