import Foundation
import Testing

@testable import AsterCore

/// 旁路通道：argv 形状、输出上限、下载大小预检与原子落盘、上传 staging 与残留清理。

// MARK: - 替身

/// 记录 argv 并按序返回预置结果的短命命令替身。
private final class RecordingRunner: RemoteSSHRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var invocations: [[String]] = []
  private var results: [RemoteSSHResult]

  init(results: [RemoteSSHResult]) { self.results = results }

  func run(arguments: [String], timeout: TimeInterval) throws -> RemoteSSHResult {
    lock.lock()
    defer { lock.unlock() }
    invocations.append(arguments)
    return results.isEmpty ? RemoteSSHResult(exitStatus: 0, standardOutput: "", standardError: "")
      : results.removeFirst()
  }

  var all: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return invocations
  }
}

/// 流式执行替身：记录参数，可选地把预置内容写进 stdout 目标文件，或直接抛错。
private final class RecordingStreamRunner: RemoteSSHStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var invocations: [[String]] = []
  private var stdinPaths: [String?] = []
  /// 写入 stdout 目标文件的内容；nil 表示不产生文件。
  var payload: Data?
  /// 非 nil 时直接抛出，用于验证失败清理路径。
  var failure: RemoteSSHError?
  var exitStatus: Int32 = 0

  func stream(
    arguments: [String],
    stdinFile: URL?,
    stdoutFile: URL?,
    maximumBytes: Int,
    timeout: TimeInterval
  ) throws -> RemoteSSHResult {
    lock.lock()
    invocations.append(arguments)
    stdinPaths.append(stdinFile?.path)
    lock.unlock()
    if let failure { throw failure }
    if let stdoutFile, let payload {
      try payload.write(to: stdoutFile)
    }
    return RemoteSSHResult(exitStatus: exitStatus, standardOutput: "", standardError: "")
  }

  var all: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return invocations
  }

  var lastStdin: String? {
    lock.lock()
    defer { lock.unlock() }
    return stdinPaths.last ?? nil
  }
}

private func makeChannel(
  runner: RecordingRunner,
  streamRunner: RecordingStreamRunner
) -> RemoteSideChannel {
  let invocation = SSHCommandInvocation.parse("ssh -p 2222 root@ubuntu@orb")!
  return RemoteSideChannel.ssh(
    invocation: invocation,
    controlDirectory: "/tmp/aster-cm-501",
    label: "ubuntu",
    runner: runner,
    streamRunner: streamRunner
  )
}

private func temporaryDirectory(named prefix: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

// MARK: - 身份

@Test func remoteSideChannelIdentityIsStablePerConnectionArguments() {
  let runner = RecordingRunner(results: [])
  let stream = RecordingStreamRunner()
  let first = makeChannel(runner: runner, streamRunner: stream)
  let second = makeChannel(runner: runner, streamRunner: stream)
  let other = RemoteSideChannel.ssh(
    invocation: SSHCommandInvocation.parse("ssh other-host")!,
    controlDirectory: "/tmp/aster-cm-501",
    label: "other",
    runner: runner,
    streamRunner: stream
  )

  #expect(first.identity.key == second.identity.key)
  #expect(first.identity.key != other.identity.key)
  #expect(first.identity.key.hasPrefix("ssh:"))
  #expect(first.controlCheckArguments?.contains("check") == true)
}

@Test func remoteSideChannelManagedIdentityUsesProfileKey() throws {
  let transport = RemoteSessionTransport(target: try RemoteSSHTarget.parse("root@ubuntu@orb"))
  let channel = RemoteSideChannel.managed(
    transport: transport,
    profileKey: "profile-1:server-9",
    label: "ubuntu",
    runner: RecordingRunner(results: []),
    streamRunner: RecordingStreamRunner()
  )

  #expect(channel.identity.key == "managed:profile-1:server-9")
  #expect(channel.controlCheckArguments == nil)
  #expect(channel.sshArguments(["/bin/sh", "-c", "true", "sh"]).contains("--"))
}

// MARK: - 脚本执行

@Test func remoteSideChannelRunPassesScriptArgumentsAsPositional() throws {
  let runner = RecordingRunner(results: [
    RemoteSSHResult(exitStatus: 0, standardOutput: "ok", standardError: "")
  ])
  let channel = makeChannel(runner: runner, streamRunner: RecordingStreamRunner())

  let result = try channel.run(
    script: "cd -- \"$1\" || exit 2", arguments: ["/etc"], timeout: 10, maximumOutputBytes: 4096)

  #expect(result.standardOutput == "ok")
  let argv = try #require(runner.all.first)
  #expect(argv.prefix(2) == ["-o", "ControlMaster=no"])
  // 目录只出现在位置参数里，脚本本身是常量。
  #expect(argv.last == "'/bin/sh' '-c' 'cd -- \"$1\" || exit 2' 'sh' '/etc'")
}

@Test func remoteSideChannelRunRejectsOversizedOutput() {
  let runner = RecordingRunner(results: [
    RemoteSSHResult(
      exitStatus: 0, standardOutput: String(repeating: "x", count: 100), standardError: "")
  ])
  let channel = makeChannel(runner: runner, streamRunner: RecordingStreamRunner())

  #expect(throws: RemoteSSHError.self) {
    try channel.run(script: "echo", timeout: 5, maximumOutputBytes: 16)
  }
}

@Test func remoteSideChannelRunClassifiesTransportFailure() throws {
  let runner = RecordingRunner(results: [
    RemoteSSHResult(
      exitStatus: 255, standardOutput: "", standardError: "Permission denied (publickey).")
  ])
  let channel = makeChannel(runner: runner, streamRunner: RecordingStreamRunner())

  do {
    _ = try channel.run(script: "true", timeout: 5, maximumOutputBytes: 1024)
    Issue.record("应当抛出认证失败")
  } catch let error as RemoteSSHError {
    #expect(error.kind == .authenticationRequired)
  }
}

@Test func remoteSideChannelRunKeepsBusinessExitStatus() throws {
  let runner = RecordingRunner(results: [
    RemoteSSHResult(exitStatus: 2, standardOutput: "error=missing\n", standardError: "")
  ])
  let channel = makeChannel(runner: runner, streamRunner: RecordingStreamRunner())

  // 远端脚本用 exit 2 表达业务结果，不能被当成传输失败。
  let result = try channel.run(script: "exit 2", timeout: 5, maximumOutputBytes: 1024)
  #expect(result.exitStatus == 2)
}

// MARK: - 下载

@Test func remoteSideChannelDownloadChecksSizeThenRenamesAtomically() throws {
  let directory = try temporaryDirectory(named: "aster-download")
  defer { try? FileManager.default.removeItem(at: directory) }
  let destination = directory.appendingPathComponent("hostname")
  let runner = RecordingRunner(results: [
    RemoteSSHResult(exitStatus: 0, standardOutput: "7\n", standardError: "")
  ])
  let stream = RecordingStreamRunner()
  stream.payload = Data("ubuntu\n".utf8)
  let channel = makeChannel(runner: runner, streamRunner: stream)

  try channel.download(
    remotePath: "/etc/hostname", to: destination, maximumBytes: 1024, timeout: 30)

  #expect(try String(contentsOf: destination, encoding: .utf8) == "ubuntu\n")
  #expect(
    !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(".hostname.aster-download").path))
  #expect(try #require(stream.all.first).last == "'/bin/sh' '-c' 'exec cat -- \"$1\"' 'sh' '/etc/hostname'")
}

@Test func remoteSideChannelDownloadRejectsOversizedRemoteFile() throws {
  let directory = try temporaryDirectory(named: "aster-download-big")
  defer { try? FileManager.default.removeItem(at: directory) }
  let runner = RecordingRunner(results: [
    RemoteSSHResult(exitStatus: 0, standardOutput: "99999\n", standardError: "")
  ])
  let stream = RecordingStreamRunner()
  let channel = makeChannel(runner: runner, streamRunner: stream)

  #expect(throws: RemoteSSHError.self) {
    try channel.download(
      remotePath: "/var/log/huge", to: directory.appendingPathComponent("huge"),
      maximumBytes: 1024, timeout: 30)
  }
  // 大小预检失败时不能真的开始传输。
  #expect(stream.all.isEmpty)
}

// MARK: - 上传

@Test func remoteSideChannelUploadWritesStagingThenMoves() throws {
  let directory = try temporaryDirectory(named: "aster-upload")
  defer { try? FileManager.default.removeItem(at: directory) }
  let local = directory.appendingPathComponent("notes.txt")
  try Data("hello".utf8).write(to: local)
  let runner = RecordingRunner(results: [])
  let stream = RecordingStreamRunner()
  let channel = makeChannel(runner: runner, streamRunner: stream)

  try channel.upload(
    localURL: local, toDirectory: "/var/tmp", fileName: "notes.txt", maximumBytes: 1024,
    timeout: 60)

  #expect(
    try #require(stream.all.first).last
      == "'/bin/sh' '-c' 'umask 022; cat > \"$1\" && mv -f -- \"$1\" \"$2\"' 'sh' "
        + "'/var/tmp/.notes.txt.aster-upload' '/var/tmp/notes.txt'")
  #expect(stream.lastStdin == local.path)
  #expect(runner.all.isEmpty)
}

@Test func remoteSideChannelUploadRemovesStagingOnFailure() throws {
  let directory = try temporaryDirectory(named: "aster-upload-fail")
  defer { try? FileManager.default.removeItem(at: directory) }
  let local = directory.appendingPathComponent("notes.txt")
  try Data("hello".utf8).write(to: local)
  let runner = RecordingRunner(results: [])
  let stream = RecordingStreamRunner()
  stream.failure = RemoteSSHError(kind: .timeout, target: "ubuntu", detail: "ssh 超时")
  let channel = makeChannel(runner: runner, streamRunner: stream)

  #expect(throws: RemoteSSHError.self) {
    try channel.upload(
      localURL: local, toDirectory: "/var/tmp", fileName: "notes.txt", maximumBytes: 1024,
      timeout: 60)
  }
  #expect(
    try #require(runner.all.first).last
      == "'/bin/sh' '-c' 'rm -f -- \"$1\"' 'sh' '/var/tmp/.notes.txt.aster-upload'")
}

@Test func remoteSideChannelUploadRejectsOversizedLocalFile() throws {
  let directory = try temporaryDirectory(named: "aster-upload-big")
  defer { try? FileManager.default.removeItem(at: directory) }
  let local = directory.appendingPathComponent("big.bin")
  try Data(repeating: 0x41, count: 4096).write(to: local)
  let stream = RecordingStreamRunner()
  let channel = makeChannel(runner: RecordingRunner(results: []), streamRunner: stream)

  #expect(throws: RemoteSSHError.self) {
    try channel.upload(
      localURL: local, toDirectory: "/var/tmp", fileName: "big.bin", maximumBytes: 1024,
      timeout: 60)
  }
  #expect(stream.all.isEmpty)
}
