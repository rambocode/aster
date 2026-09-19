// 用 libproc 直接读取进程的 TCP 监听端口。Info 页每 3 秒刷新一次，原先每次 fork 一个
// `lsof`（约 30ms CPU，外加进程创建与管道开销）；这里只对已知的几个 PID 做内核查询。
import AsterCore
import Darwin

enum ListeningPortScanner {
  /// 返回给定进程的 TCP LISTEN 端点，端点文本与 `lsof -nP` 一致（`*:3000`、
  /// `127.0.0.1:3000`、`[::1]:3000`），同一进程的同一端点只保留一条。
  ///
  /// 读不到的进程（已退出、属于其他用户）直接跳过，与 lsof 静默忽略的语义相同。
  static func scan(
    processes: [WorkspaceProcess], maximumResults: Int = 200
  ) -> [ListeningPort] {
    let limit = max(0, min(maximumResults, 1_000))
    var result: [ListeningPort] = []
    var seen: Set<String> = []
    for process in processes {
      let pid = process.processIdentifier
      guard pid > 0 else { continue }
      let endpoints = listeningEndpoints(of: pid)
      guard !endpoints.isEmpty else { continue }
      let name = processName(of: pid)
      for endpoint in endpoints {
        guard result.count < limit else { return result }
        guard seen.insert("\(pid)\u{0}\(endpoint)").inserted else { continue }
        result.append(ListeningPort(processIdentifier: pid, endpoint: endpoint, processName: name))
      }
    }
    return result
  }

  /// 枚举一个进程的 socket fd，挑出处于 LISTEN 状态的 TCP socket。
  private static func listeningEndpoints(of pid: Int32) -> [String] {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    // 两次调用之间进程可能新开 fd；多留一些余量，仍超出的部分留给下一轮刷新。
    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
    let used = proc_pidinfo(
      pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
    guard used > 0 else { return [] }

    var endpoints: [String] = []
    for descriptor in descriptors.prefix(Int(used) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
        info.psi.soi_kind == SOCKINFO_TCP
      else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
      endpoints.append(endpoint(for: tcp.tcpsi_ini))
    }
    return endpoints
  }

  /// 按 lsof 的写法格式化本地端点。通配地址（含 v4/v6 双栈 socket）写成 `*`。
  private static func endpoint(for socket: in_sockinfo) -> String {
    // 内核以网络字节序把端口放在 int 的低 16 位。
    let port = UInt16(truncatingIfNeeded: socket.insi_lport).bigEndian
    let isIPv4 = Int32(socket.insi_vflag) & INI_IPV4 != 0
    let isIPv6 = Int32(socket.insi_vflag) & INI_IPV6 != 0
    if isIPv4, !isIPv6 {
      var address = socket.insi_laddr.ina_46.i46a_addr4
      guard address.s_addr != 0 else { return "*:\(port)" }
      return "\(presentation(AF_INET, &address, INET_ADDRSTRLEN)):\(port)"
    }
    var address = socket.insi_laddr.ina_6
    let isWildcard = withUnsafeBytes(of: &address) { $0.allSatisfy { $0 == 0 } }
    guard !isWildcard else { return "*:\(port)" }
    return "[\(presentation(AF_INET6, &address, INET6_ADDRSTRLEN))]:\(port)"
  }

  /// `inet_ntop` 的薄封装；失败时返回 `?`，不让一条异常地址吞掉整个端口列表。
  private static func presentation(
    _ family: Int32, _ address: UnsafeRawPointer, _ capacity: Int32
  ) -> String {
    var buffer = [CChar](repeating: 0, count: Int(capacity))
    guard inet_ntop(family, address, &buffer, socklen_t(capacity)) != nil else { return "?" }
    return string(fromNullTerminated: buffer)
  }

  /// 截到第一个 NUL 再按 UTF-8 解码（`String(cString:)` 的数组重载已弃用）。
  private static func string(fromNullTerminated buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// 进程短名（对应 lsof 的 `c` 字段）。
  private static func processName(of pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    let name = string(fromNullTerminated: buffer)
    return name.isEmpty ? nil : name
  }
}
