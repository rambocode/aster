import AsterCore
import Foundation
import Testing

@testable import Aster

/// socket 传输层：权限、ping、超限断开、stale 探测、对端拒绝。
@Suite(.serialized)
struct AsterControlServerTests {
  /// 直接回 ping 的最小 server，不经 dispatcher。
  private func makeServer(path: String, peerValidator: (@Sendable (uid_t, gid_t) -> Bool)? = nil) -> AsterControlServer {
    AsterControlServer(socketPath: path, peerValidator: peerValidator) { request, connection in
      if request.method == "server.ping" {
        connection.send(AsterControlResponse(id: request.id, encoding: ServerPingResult(version: "test", pid: 1)))
      } else {
        connection.send(AsterControlResponse(id: request.id, error: AsterControlError(code: .methodNotFound, message: request.method)))
      }
    }
  }

  @Test("socket 文件 0600、目录 0700，ping 往返，未知 method 回错误")
  func listensWithPrivatePermissionsAndAnswersPing() throws {
    let path = temporaryControlSocketPath()
    let server = makeServer(path: path)
    defer { server.stop() }
    #expect(try server.start() == .listening)

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    #expect((attributes[.type] as? FileAttributeType) == .typeSocket)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
    #expect((directoryAttributes[.posixPermissions] as? Int) == 0o700)

    let client = try #require(ControlSocketClient(path: path))
    client.writeLine(#"{"id":1,"method":"server.ping"}"#)
    let response = try #require(client.readResponse())
    #expect(response.id == .number(1))
    #expect(response.result?["version"]?.stringValue == "test")
    #expect(response.result?["pid"]?.intValue == 1)

    client.writeLine(#"{"id":"x","method":"nope"}"#)
    let failed = try #require(client.readResponse())
    #expect(failed.id == .string("x"))
    #expect(failed.error?.code == .methodNotFound)

    // 非法 JSON：回 parse_error，连接保持。
    client.writeLine("not json")
    #expect(client.readResponse()?.error?.code == .parseError)
    client.writeLine(#"{"id":2,"method":"server.ping"}"#)
    #expect(client.readResponse()?.id == .number(2))

    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("超过 1 MiB 无换行的请求回 request_too_large 并断开")
  func oversizedLineIsRejected() throws {
    let path = temporaryControlSocketPath()
    let server = makeServer(path: path)
    defer { server.stop() }
    #expect(try server.start() == .listening)
    let client = try #require(ControlSocketClient(path: path))
    client.write(Data(repeating: UInt8(ascii: "a"), count: AsterControlProtocol.maximumRequestBytes + 16))
    let response = try #require(client.readResponse(timeoutMilliseconds: 5_000))
    #expect(response.error?.code == .requestTooLarge)
    #expect(client.isClosed(timeoutMilliseconds: 2_000))
  }

  @Test("stale socket 文件被清理；活实例存在时返回 alreadyRunning")
  func detectsStaleAndLiveSockets() throws {
    let path = temporaryControlSocketPath()
    try AsterControlServer.preparePrivateDirectory((path as NSString).deletingLastPathComponent)
    // 伪造一个无人监听的 socket 文件。
    let first = makeServer(path: path)
    #expect(try first.start() == .listening)
    first.stop()
    // stop 会 unlink；再手工放一个 stale 文件：用另一个 server 启动后直接丢弃监听 fd 不方便，
    // 因此改为 bind 一个临时 socket 后关闭，留下文件。
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = AsterControlServer.makeAddress(path)
    _ = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    Darwin.close(stale)
    #expect(FileManager.default.fileExists(atPath: path))

    let second = makeServer(path: path)
    defer { second.stop() }
    #expect(try second.start() == .listening)
    #expect(ControlSocketClient(path: path) != nil)

    let third = makeServer(path: path)
    #expect(try third.start() == .alreadyRunning)
    third.stop()
    // 第三个实例没有接管，第二个仍在服务。
    let client = try #require(ControlSocketClient(path: path))
    client.writeLine(#"{"id":1,"method":"server.ping"}"#)
    #expect(client.readResponse()?.result != nil)
  }

  @Test("对端校验失败时连接被立即关闭")
  func rejectsPeerWhenValidatorFails() throws {
    let path = temporaryControlSocketPath()
    let server = makeServer(path: path) { _, _ in false }
    defer { server.stop() }
    #expect(try server.start() == .listening)
    let client = try #require(ControlSocketClient(path: path))
    client.writeLine(#"{"id":1,"method":"server.ping"}"#)
    #expect(client.readResponse(timeoutMilliseconds: 1_500) == nil)
    #expect(client.isClosed(timeoutMilliseconds: 1_500))
  }

  @Test("默认路径与 AsterCore 共用一份实现（CLI 无 ASTER_SOCKET_PATH 时的目标一致）")
  func defaultPathResolution() {
    let environment = ["ASTER_CONTROL_SOCKET_PATH": "/tmp/x.sock", "TMPDIR": "/tmp"]
    #expect(AsterControlServer.defaultSocketPath(environment: environment) == AsterControlProtocol.defaultSocketPath(environment: environment))
    #expect(AsterControlServer.defaultSocketPath(environment: [:]) == AsterControlProtocol.defaultSocketPath(environment: [:]))
  }

  @Test("慢客户端不阻塞其它连接；断开时触发 onDisconnect")
  func slowClientDoesNotBlockOthers() throws {
    let path = temporaryControlSocketPath()
    let disconnected = DispatchSemaphore(value: 0)
    let server = AsterControlServer(socketPath: path, onDisconnect: { _ in disconnected.signal() }) { request, connection in
      // 用大体积结果把慢客户端的内核缓冲填满。
      let padding = String(repeating: "x", count: 64 * 1_024)
      connection.send(AsterControlResponse(id: request.id, result: ["pad": .string(padding)]))
    }
    defer { server.stop() }
    #expect(try server.start() == .listening)
    let slow = try #require(ControlSocketClient(path: path))
    // 不读响应，连续发请求让 server 侧写入进入 EAGAIN → pending 缓冲。
    for index in 0..<64 { slow.writeLine(#"{"id":\#(index),"method":"server.ping"}"#) }
    Thread.sleep(forTimeInterval: 0.2)

    let fast = try #require(ControlSocketClient(path: path))
    let started = Date()
    fast.writeLine(#"{"id":"fast","method":"server.ping"}"#)
    let response = try #require(fast.readResponse(timeoutMilliseconds: 2_000))
    #expect(response.id == .string("fast"))
    #expect(Date().timeIntervalSince(started) < 1.0)

    // 慢客户端最终也能把积压读完（DispatchSourceWrite 续写）。
    var received = 0
    while received < 64, slow.readLine(timeoutMilliseconds: 2_000) != nil { received += 1 }
    #expect(received == 64)
  }

  @Test("客户端断开后 onDisconnect 被调用")
  func disconnectCallback() throws {
    let path = temporaryControlSocketPath()
    let disconnected = DispatchSemaphore(value: 0)
    let server = AsterControlServer(socketPath: path, onDisconnect: { _ in disconnected.signal() }) { _, _ in }
    defer { server.stop() }
    #expect(try server.start() == .listening)
    var client: ControlSocketClient? = try #require(ControlSocketClient(path: path))
    client?.writeLine(#"{"id":1,"method":"server.ping"}"#)
    Thread.sleep(forTimeInterval: 0.1)
    #expect(server.connectionCount == 1)
    client = nil
    #expect(disconnected.wait(timeout: .now() + 2) == .success)
    Thread.sleep(forTimeInterval: 0.1)
    #expect(server.connectionCount == 0)
  }
}
