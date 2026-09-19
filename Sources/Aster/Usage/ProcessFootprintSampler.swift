// 用 libproc 读全机进程的 CPU 时间与内存。只读，不 shell out。
import AsterCore
import Foundation

enum ProcessFootprintSampler {
  /// 采一次样。同步、可在任意线程调用；调用方负责放到后台。
  ///
  /// 读不到的进程（无权限、已退出）直接跳过。
  static func sample() -> ProcessSample {
    // 骨架：由「进程占用」任务实现。
    ProcessSample(uptime: ProcessInfo.processInfo.systemUptime, readings: [:])
  }
}
