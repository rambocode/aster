import Foundation
import Testing
@testable import Aster

@Test("Ghostty 启动命令保留参数中的引号与 Shell 特殊字符")
func ghosttyLaunchPreservesLiteralArguments() throws {
  let literal = "quote'\" dollar$(printf expanded) `printf expanded` \\ space\nline"
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", GhosttyConfiguration.launchCommand(
    shell: "/usr/bin/printf", arguments: ["%s", literal])]
  process.standardOutput = pipe
  try process.run()
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  #expect(String(decoding: output, as: UTF8.self) == literal)
}

@Test("Ghostty 启动命令支持含空格与引号的可执行路径并保留退出码")
func ghosttyLaunchPreservesExecutablePathAndExitStatus() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-launch-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appendingPathComponent("shell ' \" $ ` literal")
  try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", GhosttyConfiguration.launchCommand(
    shell: executable.path, arguments: ["-c", "exit 7"])]
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 7)
}
