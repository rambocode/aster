// 非阻塞回调与收尾竞态、输出完整性及有界进程生命周期回归。
import Foundation
import Testing
@testable import Aster

@Test("已进入的回调在 drain 后遇到 EAGAIN 也不会抛出 Foundation 异常")
func pipeReaderCallbackAfterDrainReturnsEmpty() throws {
  let pipe = Pipe()
  let entered = DispatchSemaphore(value: 0)
  let resume = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)
  pipe.fileHandleForReading.readabilityHandler = { handle in
    entered.signal()
    guard resume.wait(timeout: .now() + 3) == .success else { return }
    // 与生产回调相同的读取入口；availableData 在此确定性时序下会 SIGABRT。
    #expect(handle.readRemainingWithoutBlocking(maximumBytes: 1_024).isEmpty)
    done.signal()
  }
  defer {
    pipe.fileHandleForReading.readabilityHandler = nil
    resume.signal()
  }
  try pipe.fileHandleForWriting.write(contentsOf: Data("fixture\n".utf8))
  #expect(entered.wait(timeout: .now() + 3) == .success)
  pipe.fileHandleForReading.readabilityHandler = nil
  #expect(pipe.fileHandleForReading.readRemainingWithoutBlocking(maximumBytes: 1_024)
    == Data("fixture\n".utf8))
  // 写端仍开着，回调读取的是 EAGAIN，而不是 EOF。
  resume.signal()
  #expect(done.wait(timeout: .now() + 3) == .success)
}

private func runPipeFixture(_ runner: Int, _ script: String, timeout: TimeInterval = 5) -> String? {
  switch runner {
  case 0:
    return MemoryProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", script], timeout: timeout,
      maximumBytes: 256 * 1_024)
  case 1:
    return MemoryExtractionProcess.run(
      executable: "/bin/sh", arguments: ["-c", script], workingDirectory: nil,
      timeout: timeout)?.standardOutput
  default:
    return WorkspaceInspectionService.runForTesting(
      executable: "/bin/sh", arguments: ["-c", script], timeout: timeout,
      maximumBytes: 256 * 1_024)
  }
}

@Test("三种执行器完整捕获跨多个管道缓冲区的有序输出", arguments: [0, 1, 2])
func pipeReaderCapturesCompleteOrderedOutput(runner: Int) async {
  let expected = String(repeating: "0123456789abcdef", count: 8_192) + "tail\n"
  let output = await Task.detached {
    runPipeFixture(runner, "i=0; while [ $i -lt 8192 ]; do printf 0123456789abcdef; i=$((i+1)); done; printf 'tail\\n'")
  }.value
  #expect(output == expected)
}

@Test("快速退出与继承写端的孙进程不丢尾部也不等待 EOF", arguments: [0, 1, 2])
func pipeReaderRepeatedExitWithInheritedWriter(runner: Int) async {
  let started = ContinuousClock.now
  for _ in 0..<12 {
    let output = await Task.detached {
      runPipeFixture(runner, "printf 'ready\\ntail\\n'; sleep 3 &")
    }.value
    #expect(output == "ready\ntail\n")
  }
  #expect(ContinuousClock.now - started < .seconds(10))
}

@Test("超时保留原有返回语义，忽略 SIGTERM 的子进程也有界退出", arguments: [0, 1, 2])
func pipeReaderTimeoutRemainsBounded(runner: Int) async {
  let started = ContinuousClock.now
  let output = await Task.detached {
    runPipeFixture(runner, "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 30", timeout: 0.1)
  }.value
  #expect(output == (runner == 0 ? nil : "ready\n"))
  #expect(ContinuousClock.now - started < .seconds(4))
}

@Test("运行中的取消不等待 EOF，保留各执行器取消返回语义", arguments: [0, 1, 2])
func pipeReaderCancellationRemainsBounded(runner: Int) async throws {
  let task = Task.detached {
    runPipeFixture(runner, "trap '' TERM; printf 'ready\\n'; exec /bin/sleep 30", timeout: 20)
  }
  try await Task.sleep(for: .milliseconds(200))
  let started = ContinuousClock.now
  task.cancel()
  let output = await task.value
  #expect(output == (runner == 2 ? "ready\n" : nil))
  #expect(ContinuousClock.now - started < .seconds(3))
}

@Test("提炼执行器拒绝超过 stdout 上限的输出")
func pipeReaderExtractionOutputLimitRemainsBounded() async {
  let result = await Task.detached {
    MemoryExtractionProcess.run(
      executable: "/bin/sh", arguments: ["-c", "exec /usr/bin/yes x"],
      workingDirectory: nil, timeout: 5)
  }.value
  #expect(result?.standardOutput.utf8.count == MemoryExtractionProcess.maximumOutputBytes)
  #expect(result?.didTimeOut == true)
}

@Test("探测与检查执行器在连续输出时保持字节上限", arguments: [0, 2])
func pipeReaderProbeOutputLimitsRemainBounded(runner: Int) async {
  let started = ContinuousClock.now
  let output = await Task.detached {
    runPipeFixture(runner, "exec /usr/bin/yes x")
  }.value
  if runner == 0 {
    #expect(output == nil)
  } else {
    #expect(output?.utf8.count == 256 * 1_024)
  }
  #expect(ContinuousClock.now - started < .seconds(3))
}
