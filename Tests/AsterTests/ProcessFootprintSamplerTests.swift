import Darwin
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Suite("ProcessFootprintSampler")
struct ProcessFootprintSamplerTests {
  /// 忙等约 `duration` 秒，用来制造确定量级的 CPU 时间。
  private func burnCPU(seconds duration: Double) {
    let deadline = ProcessInfo.processInfo.systemUptime + duration
    var counter: UInt64 = 0
    while ProcessInfo.processInfo.systemUptime < deadline { counter &+= 1 }
    #expect(counter > 0)
  }

  @Test("采样包含当前进程，且父进程与内存读数可信")
  func sampleContainsCurrentProcess() throws {
    let sample = ProcessFootprintSampler.sample()
    let mine = try #require(sample.readings[getpid()])
    #expect(mine.parentPID == getppid())
    #expect(mine.memoryBytes > 0)
    #expect(mine.cpuSeconds > 0)
    // 全机进程数量级：只读到个位数说明 proc_listallpids 的返回值被误当成字节数了。
    #expect(sample.readings.count > 20)
  }

  @Test("连续两次采样的 uptime 递增")
  func uptimeIncreasesBetweenSamples() {
    let first = ProcessFootprintSampler.sample()
    burnCPU(seconds: 0.01)
    let second = ProcessFootprintSampler.sample()
    #expect(second.uptime > first.uptime)
  }

  @Test("忙等后当前进程的 CPU 秒数增长且量级正确")
  func cpuSecondsGrowInRealSeconds() throws {
    let before = try #require(ProcessFootprintSampler.sample().readings[getpid()])
    burnCPU(seconds: 0.2)
    let after = try #require(ProcessFootprintSampler.sample().readings[getpid()])
    let delta = after.cpuSeconds - before.cpuSeconds
    // 这条断言专门盯 mach 时基换算：把计数直接当纳秒读，Apple Silicon 上只有真实值的
    // 二十四分之一（约 0.008 秒），会落到下界之外。
    #expect(delta > 0.05)
    #expect(delta < 1.0)
  }

  @Test("当前进程树的占用可以算出来")
  func footprintOfCurrentProcessTree() throws {
    let first = ProcessFootprintSampler.sample()
    burnCPU(seconds: 0.2)
    let second = ProcessFootprintSampler.sample()
    let footprint = try #require(
      ProcessFootprintCalculator.footprint(root: getpid(), current: second, previous: first))
    #expect(footprint.processes >= 1)
    #expect(footprint.memoryBytes > 0)
    let cpuPercent = try #require(footprint.cpuPercent)
    #expect(cpuPercent > 0)
  }

  @Test("单次采样耗时在毫秒量级")
  func sampleIsFastEnough() {
    // 先跑一次预热（时基、缓冲区分配），再量三次取最大值。
    _ = ProcessFootprintSampler.sample()
    var worst = Duration.zero
    var processes = 0
    for _ in 0..<3 {
      let clock = ContinuousClock()
      var sample = ProcessSample(uptime: 0, readings: [:])
      let elapsed = clock.measure { sample = ProcessFootprintSampler.sample() }
      worst = max(worst, elapsed)
      processes = sample.readings.count
    }
    print("[ProcessFootprintSampler] \(processes) 个进程，单次采样最慢 \(worst)")
    // 看板每 3 秒采一次，100ms 已经是极宽松的上界，只用来兜住数量级退化。
    #expect(worst < .milliseconds(100))
  }
}
