// 用 libproc 读全机进程的 CPU 时间与内存。只读，不 shell out。
import AsterCore
import Darwin
import Foundation

enum ProcessFootprintSampler {
  /// 采一次样。同步、可在任意线程调用；调用方负责放到后台。
  ///
  /// 读不到的进程（无权限、已退出）直接跳过。
  static func sample() -> ProcessSample {
    // 先取时刻再读进程：读进程本身要几毫秒，时刻取在前面只会让间隔略微偏大，
    // 也就是让 CPU% 略微偏小，比反过来虚高安全。
    let uptime = ProcessInfo.processInfo.systemUptime
    let pids = livePIDs()
    var readings: [Int32: ProcessReading] = [:]
    readings.reserveCapacity(pids.count)
    for pid in pids where pid > 0 {
      guard let reading = read(pid: pid) else { continue }
      readings[pid] = reading
    }
    return ProcessSample(uptime: uptime, readings: readings)
  }

  /// 全机当前可见的 pid 列表。
  ///
  /// 两个陷阱：
  /// 1. `proc_listallpids` 填充时返回的是**写入的 pid 个数**，不是字节数；按字节数除以
  ///    `MemoryLayout<pid_t>.size` 会只剩四分之一的进程，静默漏掉大半个机器。
  /// 2. 两次调用之间可能新建进程，所以缓冲区在容量上多留一截，并按实际长度收口。
  private static func livePIDs() -> [pid_t] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return Array(pids.prefix(min(Int(count), pids.count)))
  }

  /// 单个进程的一次读数；进程已退出或无权限读取时返回 nil。
  ///
  /// 每个 pid 只发两次系统调用：一次拿父进程，一次把 CPU 时间和内存一起拿回来。
  private static func read(pid: pid_t) -> ProcessReading? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    guard let usage = resourceUsage(of: pid) else { return nil }
    return ProcessReading(
      pid: pid,
      parentPID: pid_t(bitPattern: info.pbi_ppid),
      cpuSeconds: seconds(usage.ri_user_time + usage.ri_system_time),
      memoryBytes: usage.ri_phys_footprint)
  }

  /// 一个进程的 `rusage_info` 记录；内核不作答时返回 nil。
  private static func resourceUsage(of pid: pid_t) -> rusage_info_current? {
    var usage = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
      }
    }
    return result == 0 ? usage : nil
  }

  /// 机器的 mach 时基系数（numer / denom），只问一次。
  private static let timebase: Double = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
    return Double(info.numer) / Double(info.denom)
  }()

  /// 把 `rusage_info` 的 CPU 计数换成秒。
  ///
  /// 这两个计数是 **mach 绝对时间单位，不是纳秒**：Intel 上时基是 1/1，直接当纳秒读看着
  /// 是对的；Apple Silicon 上是 125/3，一个单位约 41.67ns，当纳秒读只有真实值的
  /// 二十四分之一。所以换算必须乘时基，不能省。
  private static func seconds(_ ticks: UInt64) -> Double {
    Double(ticks) * timebase / 1_000_000_000
  }
}
