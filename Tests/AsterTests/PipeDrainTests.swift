import Foundation
import Testing
@testable import Aster

// 后台孙进程握住管道写端时，有界子进程执行器不能再永久阻塞在读 EOF 上。

@Test("子进程退出后即使孙进程仍握着 stdout，执行器也立即返回已有输出")
func processRunnerDoesNotWaitForGrandchildToClosePipe() async {
  let started = ContinuousClock.now
  // sh 打印后立刻退出，后台 sleep 继承 stdout 写端并存活 20 秒。
  let output = await Task.detached {
    MemoryProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "echo ready; sleep 20 &"], timeout: 5)
  }.value
  #expect(output == "ready\n")
  #expect(ContinuousClock.now - started < .seconds(5))
}

@Test("非阻塞读取按上限截断，空管道返回空数据")
func nonBlockingDrainHonorsLimitAndEmptyPipe() throws {
  let pipe = Pipe()
  // 写端保持打开：阻塞式读到 EOF 会永远等下去。
  #expect(pipe.fileHandleForReading.readRemainingWithoutBlocking(maximumBytes: 16).isEmpty)
  try pipe.fileHandleForWriting.write(contentsOf: Data("0123456789".utf8))
  #expect(
    pipe.fileHandleForReading.readRemainingWithoutBlocking(maximumBytes: 4) == Data("0123".utf8))
  #expect(
    pipe.fileHandleForReading.readRemainingWithoutBlocking(maximumBytes: 64)
      == Data("456789".utf8))
  #expect(pipe.fileHandleForReading.readRemainingWithoutBlocking(maximumBytes: 0).isEmpty)
}
