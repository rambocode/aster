// 读取本机进程的 argv，供前台 Agent 识别使用。只读、不缓存，失败一律返回 nil。

import Darwin

/// 通过 `sysctl(KERN_PROCARGS2)` 读取进程启动参数。
///
/// 为什么要读 argv 而不是进程名：npm 安装的 Agent 以 `node /path/to/codex` 运行，
/// 进程名只是 `node`；只有脚本路径能区分 Codex 和 Claude Code。
enum ProcessArgumentsReader {
  /// argv 个数上限；Agent 识别只看前几个参数，异常进程也不会让解析失控。
  static let maximumArguments = 64

  /// 返回进程的 argv；进程不存在、已退出或无权限时返回 nil。
  static func arguments(of pid: Int32) -> [String]? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return nil
    }
    var buffer = [UInt8](repeating: 0, count: size)
    let status = buffer.withUnsafeMutableBytes { raw in
      sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
    }
    guard status == 0 else { return nil }
    return parse(Array(buffer.prefix(size)))
  }

  /// 解析 `KERN_PROCARGS2` 缓冲区：开头是 argc（Int32），随后是可执行路径、
  /// 若干 NUL 填充，再是 argc 个以 NUL 结尾的参数。环境变量在其后，不读。
  static func parse(_ buffer: [UInt8]) -> [String]? {
    let headerSize = MemoryLayout<Int32>.size
    guard buffer.count > headerSize else { return nil }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0 else { return nil }
    var index = headerSize
    // 跳过可执行路径及其后的 NUL 填充。
    while index < buffer.count, buffer[index] != 0 { index += 1 }
    while index < buffer.count, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    let wanted = min(Int(argc), maximumArguments)
    while index < buffer.count, arguments.count < wanted {
      let start = index
      while index < buffer.count, buffer[index] != 0 { index += 1 }
      arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return arguments.isEmpty ? nil : arguments
  }
}
