import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// A23(a) 黑洞远端启动基准：配置了一台黑洞地址（192.0.2.1）的远端机器后，
/// Local 首个受管终端 running（有 PID）的耗时相对无远端基线增加不得超过 200ms。
///
/// 测量对象是 App 侧路径：ManagedTerminalCoordinator.connect() → createTerminal() → PID。
/// 黑洞远端由独立协调器并发连接，验证 Local 不阻塞等待远端。

/// 本仓库构建出的运行时二进制。
@MainActor
private func runtimeBinaryPath() -> String {
  let file = URL(fileURLWithPath: #filePath)
  let repository = file.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  return repository.appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
}

/// 为一次测量创建隔离的状态父目录。
private func makeIsolatedStateParent(tag: String) throws -> URL {
  let base = URL(fileURLWithPath: "/tmp/aster-a23-blackhole", isDirectory: true)
  try? FileManager.default.createDirectory(
    at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let directory = base.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return directory
}

/// 单次测量：创建协调器 → connect → createTerminal → 返回耗时（秒）。
/// 每次使用独立状态目录，避免服务复用。
@MainActor
private func measureLocalStartup(binary: String, tag: String) throws -> (elapsed: Double, pid: Int32) {
  let stateParent = try makeIsolatedStateParent(tag: tag)
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: stateParent.path,
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "a23-\(tag)",
    ])
  let start = ContinuousClock.now
  let identity = coordinator.connect()
  guard identity != nil else {
    throw BlackholeTestError.connectFailed("coordinator.connect() returned nil")
  }
  let created = try coordinator.createTerminal(
    workingDirectory: "/tmp", argv: ["/bin/sh", "-c", "sleep 60"])
  let elapsed = ContinuousClock.now - start
  guard let pid = created.pid, created.state == .running else {
    throw BlackholeTestError.noRunningTerminal("state=\(created.state), pid=\(String(describing: created.pid))")
  }
  // 清理：先终止终端，再显式停止服务。服务不会因为终端全部结束而自动退出，
  // 不停的话每次迭代都会留下一个 aster-session 进程。
  coordinator.terminate(created.reference)
  let stop = Process()
  stop.executableURL = URL(fileURLWithPath: binary)
  stop.arguments = ["server", "stop", stateParent.path, "a23-\(tag)"]
  stop.standardOutput = FileHandle.nullDevice
  stop.standardError = FileHandle.nullDevice
  try? stop.run()
  stop.waitUntilExit()
  return (elapsed.asSeconds, pid)
}

private enum BlackholeTestError: Error {
  case connectFailed(String)
  case noRunningTerminal(String)
}

private extension Duration {
  /// 转换为秒数。
  var asSeconds: Double {
    let (seconds, attoseconds) = components
    return Double(seconds) + Double(attoseconds) / 1e18
  }
}

/// 计算排序数组的百分位值。
private func percentile(_ sorted: [Double], _ p: Double) -> Double {
  guard !sorted.isEmpty else { return 0 }
  let index = (p / 100.0) * Double(sorted.count - 1)
  let lower = Int(index)
  let upper = min(lower + 1, sorted.count - 1)
  let fraction = index - Double(lower)
  return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
}

@Test("A23(a) 黑洞远端不令 Local 启动增加超过 200ms")
@MainActor
func blackholeRemoteDoesNotDelayLocalStartup() async throws {
  _ = NSApplication.shared
  let binary = runtimeBinaryPath()
  #expect(
    FileManager.default.isExecutableFile(atPath: binary),
    "缺少运行时二进制：\(binary)")
  guard FileManager.default.isExecutableFile(atPath: binary) else { return }

  let iterations = 7
  var baselineTimes: [Double] = []
  var blackholeTimes: [Double] = []
  var logLines: [String] = []
  let header = "=== A23(a) Blackhole Startup Baseline === \(Date())"
  logLines.append(header)
  logLines.append("binary: \(binary)")
  logLines.append("iterations: \(iterations)")
  logLines.append("")

  // --- (a) 基线：无远端配置 ---
  logLines.append("--- Condition A: no remote configured ---")
  for i in 1...iterations {
    let result = try measureLocalStartup(binary: binary, tag: "baseline-\(i)")
    baselineTimes.append(result.elapsed)
    let line = "  baseline[\(i)]: \(String(format: "%.3f", result.elapsed * 1000))ms  pid=\(result.pid)"
    logLines.append(line)
  }

  // --- (b) 黑洞远端配置：注册一台 192.0.2.1 的远端协调器，同时测量 Local ---
  logLines.append("")
  logLines.append("--- Condition B: blackhole remote (192.0.2.1) configured ---")

  // 注册黑洞远端协调器（模拟用户配置了一台不可达机器）
  let blackholeMachineID = UUID()
  let blackholeCoordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: "/tmp/aster-a23-blackhole-remote",
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "a23-blackhole",
      ManagedTerminalCoordinator.remoteTargetEnvironmentKey: "192.0.2.1",
    ],
    machineProfileID: blackholeMachineID)
  ManagedTerminalCoordinatorRegistry.register(blackholeCoordinator, for: blackholeMachineID)
  defer { ManagedTerminalCoordinatorRegistry.reset() }

  for i in 1...iterations {
    // 并发启动黑洞远端连接（模拟 App 启动时同时连接远端）
    let blackholeTask = Task.detached {
      // 黑洞远端 connectAsync 会超时，但不应阻塞 Local
      await blackholeCoordinator.connectAsync()
    }

    // 同时测量 Local 启动
    let result = try measureLocalStartup(binary: binary, tag: "blackhole-\(i)")
    blackholeTimes.append(result.elapsed)
    let line = "  blackhole[\(i)]: \(String(format: "%.3f", result.elapsed * 1000))ms  pid=\(result.pid)"
    logLines.append(line)

    // 不等黑洞完成——取消它避免测试挂起
    blackholeTask.cancel()
  }

  // --- 统计 ---
  let baselineSorted = baselineTimes.sorted()
  let blackholeSorted = blackholeTimes.sorted()

  let bp50 = percentile(baselineSorted, 50) * 1000
  let bp95 = percentile(baselineSorted, 95) * 1000
  let hp50 = percentile(blackholeSorted, 50) * 1000
  let hp95 = percentile(blackholeSorted, 95) * 1000
  let deltaP50 = hp50 - bp50
  let deltaP95 = hp95 - bp95

  logLines.append("")
  logLines.append("--- Results ---")
  logLines.append("baseline:  n=\(iterations) p50=\(String(format: "%.1f", bp50))ms p95=\(String(format: "%.1f", bp95))ms")
  logLines.append("blackhole: n=\(iterations) p50=\(String(format: "%.1f", hp50))ms p95=\(String(format: "%.1f", hp95))ms")
  logLines.append("delta:     p50=\(String(format: "%.1f", deltaP50))ms  p95=\(String(format: "%.1f", deltaP95))ms")
  logLines.append("")
  let pass = abs(deltaP95) <= 200
  logLines.append("Check: Delta p95 \(String(format: "%.1f", abs(deltaP95)))ms <= 200ms: \(pass ? "PASS" : "FAIL")")
  logLines.append("")
  logLines.append("=== END ===")

  // 写日志
  let logDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/remote-work-evidence")
  try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
  let logFile = logDir.appendingPathComponent("p8-startup-blackhole-app.log")
  try logLines.joined(separator: "\n").write(to: logFile, atomically: true, encoding: .utf8)

  // 断言
  #expect(
    abs(deltaP95) <= 200,
    "A23(a) FAIL: 黑洞远端令 Local 启动增加 \(String(format: "%.1f", abs(deltaP95)))ms > 200ms")
}
