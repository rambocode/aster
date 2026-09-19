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
  /// 一棵树最多遍历的进程数，防止异常的父子关系把这一拍拖成全机扫描。
  private static let maxProcesses = 2000

  /// 计算以 `root` 为根的进程树占用。根进程不在 `current` 里时返回 nil。
  ///
  /// CPU 只统计两次采样里都存在的进程；新出现的进程下一拍才计入，避免把它出生以来的
  /// 累计时间算成这一拍的瞬时占用。
  public static func footprint(
    root: Int32, current: ProcessSample, previous: ProcessSample?
  ) -> ProcessFootprint? {
    guard current.readings[root] != nil else { return nil }

    // 先按 parentPID 建一次子表：一次 O(n) 换掉 BFS 每层全表扫描，树越深省得越多。
    var children: [Int32: [Int32]] = [:]
    children.reserveCapacity(current.readings.count)
    for reading in current.readings.values {
      children[reading.parentPID, default: []].append(reading.pid)
    }

    // BFS 展开进程树。visited 同时承担去重和防环：内核不该给出环，但 pid 回绕或
    // 采样期间的父进程改写可能让 a↔b 互为父，没有 visited 就会死循环。
    var visited: Set<Int32> = [root]
    var queue: [Int32] = [root]
    var index = 0
    var memoryBytes: UInt64 = 0
    var cpuSeconds = 0.0
    while index < queue.count {
      let pid = queue[index]
      index += 1
      guard let reading = current.readings[pid] else { continue }
      memoryBytes &+= reading.memoryBytes
      // 只有上一拍也读到过的进程才贡献 CPU 差值；负差（计数器倒退、pid 复用）按 0 处理。
      if let previous, let earlier = previous.readings[pid] {
        cpuSeconds += max(0, reading.cpuSeconds - earlier.cpuSeconds)
      }
      for child in children[pid] ?? [] where !visited.contains(child) {
        guard visited.count < maxProcesses else { break }
        visited.insert(child)
        queue.append(child)
      }
    }

    // 没有上一拍或间隔非正（时钟未推进）时不报 CPU，避免除以 0 得出无意义的数。
    var cpuPercent: Double?
    if let previous {
      let interval = current.uptime - previous.uptime
      if interval > 0 { cpuPercent = cpuSeconds / interval * 100 }
    }
    return ProcessFootprint(
      processes: queue.count, cpuPercent: cpuPercent, memoryBytes: memoryBytes)
  }
}
