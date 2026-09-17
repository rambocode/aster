// OSC 7 工作目录上报的解析规则。本机目录与远端目录在同一个入口分流，
// 使终端会话层不必重复判断 host 归属，也不会把远端路径当成本机路径使用。

import Foundation

/// 一次远端 OSC 7 上报的结果：上报主机名与该主机上的绝对路径。
///
/// `host` 保留上报原文（只做小写归一化留给调用方决定），因为它同时是界面上
/// 标识服务器的显示名；`path` 一定是已解码的绝对路径。
public struct RemoteWorkingDirectory: Equatable, Sendable {
  public let host: String
  public let path: String

  public init(host: String, path: String) {
    self.host = host
    self.path = path
  }
}

/// OSC 7 上报值的分类结果。
///
/// - `local`：可直接当作本机绝对路径使用。
/// - `remote`：属于另一台主机，禁止当成本机路径解析文件或跑本地工具。
/// - `invalid`：空值、超限、含控制字符或不是绝对路径，一律丢弃。
public enum RemoteWorkingDirectoryReport: Equatable, Sendable {
  case local(String)
  case remote(RemoteWorkingDirectory)
  case invalid

  /// 单条上报允许的最大字节数。终端输出是不可信输入，超限直接判为无效。
  public static let maximumPayloadBytes = 4_096

  /// 恒定视为本机的主机名集合（不含本机真实主机名）。
  public static let loopbackHostNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

  /// 本进程所在机器的主机名集合：回环名 + 完整主机名 + 短主机名。
  public static var defaultLocalHostNames: Set<String> {
    let machine = ProcessInfo.processInfo.hostName.lowercased()
    let short = machine.split(separator: ".").first.map(String.init) ?? machine
    return loopbackHostNames.union([machine, short])
  }

  /// 解析一条 OSC 7 上报值。
  ///
  /// - Parameters:
  ///   - payload: OSC 7 的负载原文（不含 `7;` 前缀）。既接受 `file://host/path`，
  ///     也接受部分 Shell 直接上报的裸绝对路径。
  ///   - localHostNames: 视为本机的主机名（小写）。默认取当前机器。
  /// - Returns: 分类结果；任何不可信或不可用的值返回 `.invalid`。
  public static func parse(
    _ payload: String,
    localHostNames: Set<String> = defaultLocalHostNames
  ) -> Self {
    guard !payload.isEmpty, payload.utf8.count <= maximumPayloadBytes else { return .invalid }
    // 控制字符只会来自伪造或损坏的序列；放行会让路径被当成多行命令或屏幕指令。
    guard !payload.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      return .invalid
    }

    if let url = URL(string: payload), url.isFileURL {
      let path = url.path.removingPercentEncoding ?? url.path
      guard isAbsolutePath(path) else { return .invalid }
      let host = url.host ?? ""
      if host.isEmpty || localHostNames.contains(host.lowercased()) { return .local(path) }
      return .remote(RemoteWorkingDirectory(host: host, path: path))
    }

    // 非 URL 值只可能是本机 Shell 直接上报的路径；相对路径没有可用基准，丢弃。
    let path = payload.removingPercentEncoding ?? payload
    guard isAbsolutePath(path) else { return .invalid }
    return .local(path)
  }

  /// 绝对路径判定：必须以 `/` 开头且不含 NUL。
  private static func isAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.utf8.contains(0)
  }
}
