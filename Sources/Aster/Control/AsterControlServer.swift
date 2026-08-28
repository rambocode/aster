import AsterCore
import Foundation

/// Unix domain socket 监听器（POSIX + DispatchSource）。职责只到「连接 + 分帧 + 回写」，
/// 方法语义在 AsterControlDispatcher。安全要点：目录 0700、socket 0600、`getpeereid` 同 uid、
/// 单行 1 MiB 上限、最多 64 连接。
final class AsterControlServer: @unchecked Sendable {
  enum StartResult: Equatable {
    case listening
    /// 已有一个活的 Aster 实例占着 socket：本进程不提供控制服务，也不注入 ASTER_ENV。
    case alreadyRunning
  }

  enum ServerError: Error, Equatable {
    case pathTooLong
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case invalidDirectory
  }

  static let maximumConnections = 64
  static let environmentPathKey = AsterControlProtocol.socketPathOverrideKey
  static let maximumPathBytes = AsterControlProtocol.maximumSocketPathBytes

  let socketPath: String
  private let ioQueue = DispatchQueue(label: "io.local.aster.control", qos: .userInitiated)
  private let onRequest: @Sendable (AsterControlRequest, AsterControlConnection) -> Void
  /// 连接断开回调：dispatcher 据此注销事件订阅；等待者由连接自身取消任务来清理。
  private let onDisconnect: @Sendable (AsterControlConnection) -> Void
  /// 对端校验注入点：默认要求 uid 与本进程 euid 相同；测试可注入拒绝一切的校验器。
  private let peerValidator: @Sendable (uid_t, gid_t) -> Bool
  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: [UUID: AsterControlConnection] = [:]
  private(set) var isListening = false

  init(
    socketPath: String,
    peerValidator: (@Sendable (uid_t, gid_t) -> Bool)? = nil,
    onDisconnect: @escaping @Sendable (AsterControlConnection) -> Void = { _ in },
    onRequest: @escaping @Sendable (AsterControlRequest, AsterControlConnection) -> Void
  ) {
    self.socketPath = socketPath
    self.peerValidator = peerValidator ?? { uid, _ in uid == geteuid() }
    self.onDisconnect = onDisconnect
    self.onRequest = onRequest
  }

  /// 默认路径由 AsterCore 的 `AsterControlProtocol.defaultSocketPath` 决定，server 与 CLI 共用同一实现。
  static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    AsterControlSocketLocation.defaultPath(environment: environment)
  }

  var connectionCount: Int { ioQueue.sync { connections.count } }

  /// 同步启动：准备目录、探测旧 socket、bind/listen。
  func start() throws -> StartResult {
    try ioQueue.sync { try startLocked() }
  }

  private func startLocked() throws -> StartResult {
    guard !isListening else { return .listening }
    guard socketPath.utf8.count <= Self.maximumPathBytes else { throw ServerError.pathTooLong }
    let directory = (socketPath as NSString).deletingLastPathComponent
    try Self.preparePrivateDirectory(directory)

    if FileManager.default.fileExists(atPath: socketPath) {
      // stale 探测：能连上说明另一实例活着；连不上就是遗留文件，删掉重建。
      if Self.canConnect(to: socketPath) { return .alreadyRunning }
      unlink(socketPath)
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ServerError.socketFailed(errno) }
    var address = Self.makeAddress(socketPath)
    // umask 包裹 bind：socket 文件一出生就是 0600，不给其它用户任何连接窗口；随后再 chmod 兜底。
    let previousMask = umask(0o077)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    umask(previousMask)
    guard bound == 0 else {
      let code = errno
      Darwin.close(fd)
      throw ServerError.bindFailed(code)
    }
    chmod(socketPath, 0o600)
    guard listen(fd, 16) == 0 else {
      let code = errno
      Darwin.close(fd)
      unlink(socketPath)
      throw ServerError.listenFailed(code)
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    listenFD = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
    source.setEventHandler { [weak self] in self?.acceptPending() }
    source.setCancelHandler { [fd] in _ = Darwin.close(fd) }
    acceptSource = source
    source.resume()
    isListening = true
    return .listening
  }

  private func acceptPending() {
    while true {
      let client = Darwin.accept(listenFD, nil, nil)
      guard client >= 0 else { return }
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(client, &uid, &gid) == 0, peerValidator(uid, gid) else {
        Darwin.close(client)
        continue
      }
      guard connections.count < Self.maximumConnections else {
        Darwin.close(client)
        continue
      }
      _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
      var noSigpipe: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
      let connection = AsterControlConnection(
        fd: client, ioQueue: ioQueue, onRequest: onRequest,
        onClose: { [weak self] connection in
          self?.ioQueue.async { self?.connections[connection.id] = nil }
          self?.onDisconnect(connection)
        })
      connections[connection.id] = connection
      connection.start()
    }
  }

  /// 停止监听并关闭全部连接、删除 socket 文件。写路径已是非阻塞，ioQueue 不会被慢客户端占住；
  /// 仍以 1s 为上限等待，保证 applicationWillTerminate 绝不会挂在这里。
  func stop() {
    let finished = DispatchSemaphore(value: 0)
    ioQueue.async {
      defer { finished.signal() }
      self.stopLocked()
    }
    _ = finished.wait(timeout: .now() + 1)
  }

  private func stopLocked() {
    do {
      guard isListening else { return }
      isListening = false
      acceptSource?.cancel()
      acceptSource = nil
      listenFD = -1
      for connection in connections.values { connection.close() }
      connections.removeAll()
      unlink(socketPath)
    }
  }

  /// 目录必须是非符号链接的真实目录且为 0700（与 AsterCLIRequestService 同一规则）。
  static func preparePrivateDirectory(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
        throw ServerError.invalidDirectory
      }
    } else {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  }

  /// 把路径拷进 sockaddr_un.sun_path（已由 maximumPathBytes 保证不截断）。
  static func makeAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in bytes.prefix(buffer.count - 1).enumerated() { buffer[index] = byte }
    }
    return address
  }

  /// 阻塞式探测连接（只用于 stale 判断，超时由内核默认 connect 行为决定，本地 socket 即刻返回）。
  static func canConnect(to path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var address = makeAddress(path)
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    } == 0
  }
}
