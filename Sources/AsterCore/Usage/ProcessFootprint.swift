// 会话看板的进程占用：纯数据与纯算术，不碰 libproc。
import Foundation

/// 一个进程的一次读数。
public struct ProcessReading: Equatable, Sendable {
  public var pid: Int32
  public var parentPID: Int32
  /// 累计 CPU 时间（用户态 + 内核态），秒。
  public var cpuSeconds: Double
  /// 物理内存占用（phys_footprint），字节。
  public var memoryBytes: UInt64

  public init(pid: Int32, parentPID: Int32, cpuSeconds: Double, memoryBytes: UInt64) {
    self.pid = pid
    self.parentPID = parentPID
    self.cpuSeconds = cpuSeconds
    self.memoryBytes = memoryBytes
  }
}

/// 全机一次采样：时刻 + 所有读得到的进程。
public struct ProcessSample: Equatable, Sendable {
  /// 单调时钟秒数（不是墙上时间），只用来求两次采样的间隔。
  public var uptime: Double
  public var readings: [Int32: ProcessReading]

  public init(uptime: Double, readings: [Int32: ProcessReading]) {
    self.uptime = uptime
    self.readings = readings
  }
}

/// 一棵进程树（一个 Pane 的 shell 及其全部后代）的占用。
public struct ProcessFootprint: Equatable, Sendable {
  /// 树里的进程数（含根）。
  public var processes: Int
  /// 两次采样之间的 CPU 占用，100 = 占满一个核；还没有第二次采样时为 nil。
  public var cpuPercent: Double?
  /// 整棵树的内存之和，字节。
  public var memoryBytes: UInt64

  public init(processes: Int, cpuPercent: Double?, memoryBytes: UInt64) {
    self.processes = processes
    self.cpuPercent = cpuPercent
    self.memoryBytes = memoryBytes
  }
}

public enum ProcessFootprintCalculator {
  /// 计算以 `root` 为根的进程树占用。根进程不在 `current` 里时返回 nil。
  ///
  /// CPU 只统计两次采样里都存在的进程；新出现的进程下一拍才计入，避免把它出生以来的
  /// 累计时间算成这一拍的瞬时占用。
  public static func footprint(
    root: Int32, current: ProcessSample, previous: ProcessSample?
  ) -> ProcessFootprint? {
    // 骨架：由「进程占用」任务实现。
    nil
  }
}
