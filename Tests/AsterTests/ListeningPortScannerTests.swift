import AsterCore
import Darwin
import Testing
@testable import Aster

// Info 页的监听端口经 libproc 读取，不再 fork lsof；端点写法必须与 lsof 保持一致。

/// 在本进程内开一个 TCP 监听 socket，返回 fd 与系统分配的端口。
private func openListeningSocket(family: Int32) throws -> (fd: Int32, port: UInt16) {
  let fd = socket(family, SOCK_STREAM, 0)
  try #require(fd >= 0)
  var port: UInt16 = 0
  if family == AF_INET {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    port = UInt16(bigEndian: address.sin_port)
  } else {
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_addr = in6addr_any
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    port = UInt16(bigEndian: address.sin6_port)
  }
  try #require(listen(fd, 1) == 0)
  return (fd, port)
}

@Test("原生端口扫描找到本进程的监听 socket，端点写法与 lsof 一致")
func listeningPortScannerFindsOwnSockets() throws {
  let loopback = try openListeningSocket(family: AF_INET)
  defer { close(loopback.fd) }
  let wildcard = try openListeningSocket(family: AF_INET6)
  defer { close(wildcard.fd) }

  let pid = getpid()
  let ports = ListeningPortScanner.scan(processes: [
    WorkspaceProcess(processIdentifier: pid, parentProcessIdentifier: 1, command: "test")
  ])
  let endpoints = Set(ports.map(\.endpoint))
  #expect(endpoints.contains("127.0.0.1:\(loopback.port)"))
  #expect(endpoints.contains("*:\(wildcard.port)"))
  #expect(ports.allSatisfy { $0.processIdentifier == pid && $0.protocolName == "TCP" })
  #expect(ports.first?.processName?.isEmpty == false)
  // 无效的 PID 不产生结果；结果上限为 0 时不返回任何端口。
  #expect(
    ListeningPortScanner.scan(processes: [
      WorkspaceProcess(processIdentifier: -1, parentProcessIdentifier: 1, command: "gone")
    ]).isEmpty)
  #expect(
    ListeningPortScanner.scan(
      processes: [
        WorkspaceProcess(processIdentifier: pid, parentProcessIdentifier: 1, command: "test")
      ], maximumResults: 0
    ).isEmpty)
}
