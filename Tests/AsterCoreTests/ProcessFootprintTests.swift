import Foundation
import Testing

@testable import AsterCore

@Suite("ProcessFootprint")
struct ProcessFootprintTests {
  /// 构造一次采样：给出若干 (pid, ppid, cpu 秒, 内存字节)。
  private func sample(uptime: Double, _ entries: [(Int32, Int32, Double, UInt64)]) -> ProcessSample {
    var readings: [Int32: ProcessReading] = [:]
    for entry in entries {
      readings[entry.0] = ProcessReading(
        pid: entry.0, parentPID: entry.1, cpuSeconds: entry.2, memoryBytes: entry.3)
    }
    return ProcessSample(uptime: uptime, readings: readings)
  }

  @Test("单进程树：只算自己的内存与 CPU 差值")
  func singleProcessTree() throws {
    let previous = sample(uptime: 100, [(10, 1, 1.0, 500)])
    let current = sample(uptime: 102, [(10, 1, 2.0, 700)])
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(root: 10, current: current, previous: previous))
    #expect(footprint.processes == 1)
    #expect(footprint.memoryBytes == 700)
    // 2 秒里烧掉 1 秒 CPU = 50%
    #expect(footprint.cpuPercent == 50)
  }

  @Test("多层后代全部计入")
  func deepDescendantsAreIncluded() throws {
    let entries: [(Int32, Int32, Double, UInt64)] = [
      (10, 1, 1.0, 100), (11, 10, 1.0, 200), (12, 11, 1.0, 300), (13, 12, 1.0, 400),
    ]
    let previous = sample(uptime: 100, entries)
    let current = sample(
      uptime: 101, entries.map { ($0.0, $0.1, $0.2 + 0.25, $0.3) })
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(root: 10, current: current, previous: previous))
    #expect(footprint.processes == 4)
    #expect(footprint.memoryBytes == 1000)
    // 4 个进程各烧 0.25 秒，1 秒间隔 = 100%
    #expect(footprint.cpuPercent == 100)
  }

  @Test("不相关的进程树不计入")
  func unrelatedProcessesAreExcluded() throws {
    let entries: [(Int32, Int32, Double, UInt64)] = [
      (10, 1, 0, 100), (11, 10, 0, 200),
      (20, 1, 0, 9999), (21, 20, 0, 9999),
    ]
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(
        root: 10, current: sample(uptime: 100, entries), previous: nil))
    #expect(footprint.processes == 2)
    #expect(footprint.memoryBytes == 300)
  }

  @Test("父子成环时不死循环")
  func cyclicParentsDoNotHang() throws {
    // a 的父是 b，b 的父是 a：从 a 出发必须各访问一次就停。
    let entries: [(Int32, Int32, Double, UInt64)] = [(10, 11, 0, 100), (11, 10, 0, 200)]
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(
        root: 10, current: sample(uptime: 100, entries), previous: nil))
    #expect(footprint.processes == 2)
    #expect(footprint.memoryBytes == 300)
  }

  @Test("自己是自己的父进程时不死循环")
  func selfParentDoesNotHang() throws {
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(
        root: 10, current: sample(uptime: 100, [(10, 10, 0, 100)]), previous: nil))
    #expect(footprint.processes == 1)
    #expect(footprint.memoryBytes == 100)
  }

  @Test("新出现的进程不计入本拍 CPU，但内存立刻计入")
  func newProcessDoesNotCountCPUThisTick() throws {
    let previous = sample(uptime: 100, [(10, 1, 1.0, 100)])
    // 11 是新进程，已累计 30 秒 CPU（出生以来），本拍必须不计。
    let current = sample(uptime: 101, [(10, 1, 1.5, 100), (11, 10, 30.0, 200)])
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(root: 10, current: current, previous: previous))
    #expect(footprint.processes == 2)
    #expect(footprint.memoryBytes == 300)
    #expect(footprint.cpuPercent == 50)
  }

  @Test("进程消失后只统计仍然存在的进程")
  func vanishedProcessIsDropped() throws {
    let previous = sample(uptime: 100, [(10, 1, 1.0, 100), (11, 10, 5.0, 200)])
    let current = sample(uptime: 102, [(10, 1, 2.0, 100)])
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(root: 10, current: current, previous: previous))
    #expect(footprint.processes == 1)
    #expect(footprint.memoryBytes == 100)
    #expect(footprint.cpuPercent == 50)
  }

  @Test("CPU 时间倒退按 0 计，不出现负占用")
  func backwardCPUCountsAsZero() throws {
    let previous = sample(uptime: 100, [(10, 1, 9.0, 100), (11, 10, 1.0, 100)])
    let current = sample(uptime: 101, [(10, 1, 1.0, 100), (11, 10, 1.5, 100)])
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(root: 10, current: current, previous: previous))
    // 10 倒退按 0，只剩 11 的 0.5 秒。
    #expect(footprint.cpuPercent == 50)
  }

  @Test("采样间隔为 0 或为负时不报 CPU")
  func nonPositiveIntervalReportsNoCPU() throws {
    let previous = sample(uptime: 100, [(10, 1, 1.0, 100)])
    let zero = try #require(
      ProcessFootprintCalculator.footprint(
        root: 10, current: sample(uptime: 100, [(10, 1, 2.0, 100)]), previous: previous))
    #expect(zero.cpuPercent == nil)
    #expect(zero.memoryBytes == 100)
    let backward = try #require(
      ProcessFootprintCalculator.footprint(
        root: 10, current: sample(uptime: 99, [(10, 1, 2.0, 100)]), previous: previous))
    #expect(backward.cpuPercent == nil)
  }

  @Test("没有上一拍时 CPU 为 nil")
  func firstSampleHasNoCPU() throws {
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(
        root: 10, current: sample(uptime: 100, [(10, 1, 1.0, 100)]), previous: nil))
    #expect(footprint.cpuPercent == nil)
    #expect(footprint.processes == 1)
  }

  @Test("根进程不在本拍采样里时返回 nil")
  func missingRootReturnsNil() {
    let current = sample(uptime: 100, [(11, 10, 1.0, 100)])
    #expect(ProcessFootprintCalculator.footprint(root: 10, current: current, previous: nil) == nil)
  }

  @Test("进程数超过上限时截断而不是无限展开")
  func treeIsCappedAtUpperBound() throws {
    // 一条 5000 层的链，上限 2000。
    var entries: [(Int32, Int32, Double, UInt64)] = [(1000, 1, 0, 1)]
    for pid in Int32(1001)...Int32(6000) { entries.append((pid, pid - 1, 0, 1)) }
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(
        root: 1000, current: sample(uptime: 100, entries), previous: nil))
    #expect(footprint.processes == 2000)
  }
}
