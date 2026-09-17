import Foundation
import Testing

@testable import AsterCore

/// 流式执行器：stdin 走文件、stdout 落盘、超上限终止并删半截文件。
/// 用 `/bin/cat` 当 ssh 替身：它的 stdin/stdout 行为与 `ssh <远端命令>` 一致，
/// 但不需要真实远端，也不引入网络时序。

private func temporaryDirectory(named prefix: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func remoteSSHStreamRunnerWritesStdoutToFile() throws {
  let directory = try temporaryDirectory(named: "aster-stream")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source.txt")
  try Data("hello stream\n".utf8).write(to: source)
  let destination = directory.appendingPathComponent("out.txt")

  let runner = RemoteSSHStreamRunner(executablePath: "/bin/cat")
  let result = try runner.stream(
    arguments: [source.path], stdinFile: nil, stdoutFile: destination,
    maximumBytes: 1024, timeout: 10)

  #expect(result.exitStatus == 0)
  #expect(try String(contentsOf: destination, encoding: .utf8) == "hello stream\n")
}

@Test func remoteSSHStreamRunnerFeedsStdinFromFile() throws {
  let directory = try temporaryDirectory(named: "aster-stream-stdin")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("payload.bin")
  try Data(repeating: 0x41, count: 64 * 1024).write(to: source)
  let destination = directory.appendingPathComponent("echo.bin")

  let runner = RemoteSSHStreamRunner(executablePath: "/bin/cat")
  let result = try runner.stream(
    arguments: [], stdinFile: source, stdoutFile: destination,
    maximumBytes: 1024 * 1024, timeout: 30)

  #expect(result.exitStatus == 0)
  #expect(try Data(contentsOf: destination).count == 64 * 1024)
}

@Test func remoteSSHStreamRunnerDeletesPartialFileWhenOverLimit() throws {
  let directory = try temporaryDirectory(named: "aster-stream-limit")
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("big.bin")
  try Data(repeating: 0x42, count: 512 * 1024).write(to: source)
  let destination = directory.appendingPathComponent("partial.bin")

  let runner = RemoteSSHStreamRunner(executablePath: "/bin/cat")
  do {
    _ = try runner.stream(
      arguments: [source.path], stdinFile: nil, stdoutFile: destination,
      maximumBytes: 4096, timeout: 30)
    Issue.record("超上限应当失败")
  } catch let error as RemoteSSHError {
    #expect(error.kind == .transportFailure)
  }
  // 半截文件比没有文件更危险：用户会把它当成完整副本。
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func remoteSSHStreamRunnerReportsMissingExecutable() {
  let runner = RemoteSSHStreamRunner(executablePath: "/nonexistent/aster-ssh")
  #expect(throws: RemoteSSHError.self) {
    try runner.stream(
      arguments: [], stdinFile: nil, stdoutFile: nil, maximumBytes: 1024, timeout: 5)
  }
}

@Test func remoteSSHStreamRunnerTimesOutAndCleansUp() throws {
  let directory = try temporaryDirectory(named: "aster-stream-timeout")
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("never.bin")

  // `sleep` 只是一个必然超过超时窗口的替身，用来验证终止与清理路径。
  let runner = RemoteSSHStreamRunner(executablePath: "/bin/sleep")
  do {
    _ = try runner.stream(
      arguments: ["5"], stdinFile: nil, stdoutFile: destination, maximumBytes: 1024, timeout: 0.5)
    Issue.record("超时应当失败")
  } catch let error as RemoteSSHError {
    #expect(error.kind == .timeout)
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func remoteSSHStreamRunnerClassifiesNonZeroExit() throws {
  let directory = try temporaryDirectory(named: "aster-stream-exit")
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("out.txt")

  let runner = RemoteSSHStreamRunner(executablePath: "/bin/cat")
  do {
    _ = try runner.stream(
      arguments: [directory.appendingPathComponent("missing").path], stdinFile: nil,
      stdoutFile: destination, maximumBytes: 1024, timeout: 10)
    Issue.record("退出码非 0 应当失败")
  } catch let error as RemoteSSHError {
    #expect(error.exitStatus != 0)
  }
  #expect(!FileManager.default.fileExists(atPath: destination.path))
}
