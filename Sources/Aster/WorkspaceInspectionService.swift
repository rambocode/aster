import AsterCore
import Darwin
import Foundation

struct WorkspaceInspectionSnapshot: Sendable {
  let processes: [WorkspaceProcess]
  let listeningPorts: [ListeningPort]
  let git: GitStatusSummary
}

/// 详情面板的只读基础设施边界。所有可执行文件均为固定绝对路径，参数逐项传递；输出、
/// 运行时间和文件树规模都有上限，不经过登录 Shell，也不会执行仓库中的脚本或 hook。
enum WorkspaceInspectionService {
  static func inspect(
    directory: String,
    shellProcessIdentifier: Int32?
  ) async -> WorkspaceInspectionSnapshot {
    await Task.detached(priority: .utility) {
      let processOutput = run(
        executable: "/bin/ps",
        arguments: ["-axo", "pid=,ppid=,etime=,comm="],
        timeout: 2,
        maximumBytes: 4 * 1_024 * 1_024
      )
      let processes = shellProcessIdentifier.map {
        WorkspaceProcessParser.descendants(from: processOutput, rootProcessIdentifier: $0)
      } ?? []
      let inspectedPIDs = ([shellProcessIdentifier].compactMap { $0 } + processes.map(\.processIdentifier))
      let portOutput: String
      if inspectedPIDs.isEmpty {
        portOutput = ""
      } else {
        portOutput = run(
          executable: "/usr/sbin/lsof",
          arguments: [
            "-nP", "-a", "-p", inspectedPIDs.map(String.init).joined(separator: ","),
            "-iTCP", "-sTCP:LISTEN", "-Fpn",
          ],
          timeout: 2,
          maximumBytes: 2 * 1_024 * 1_024
        )
      }
      let gitOutput = run(
        executable: "/usr/bin/git",
        arguments: [
          "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
          "-C", directory, "status", "--porcelain=v2", "--branch", "--untracked-files=normal",
        ],
        timeout: 3,
        maximumBytes: 1 * 1_024 * 1_024
      )
      var git = GitStatusParser.parsePorcelainV2(gitOutput)
      // shortstat 只在确认处于仓库内时才采集,空仓库(无 HEAD)输出为空,解析器会返回全零。
      if git.branch != nil || git.objectID != nil {
        let statOutput = run(
          executable: "/usr/bin/git",
          arguments: [
            "-c", "core.fsmonitor=false",
            "-C", directory, "diff", "--shortstat", "HEAD",
          ],
          timeout: 2,
          maximumBytes: 512 * 1_024
        )
        git.diffStat = GitShortStatParser.parse(statOutput)
      }
      return WorkspaceInspectionSnapshot(
        processes: processes,
        listeningPorts: ListeningPortParser.parse(portOutput),
        git: git
      )
    }.value
  }

  /// Files 页只依赖目录枚举，不应排在可能触发秒级超时的 ps/lsof/Git 检查之后。
  /// 独立 utility 任务让面板先得到有界文件树，顶部页签切换也不会阻塞主线程。
  static func inspectFiles(directory: String) async -> [WorkspaceFileNode] {
    await Task.detached(priority: .utility) {
      WorkspaceFileTree.enumerate(root: URL(fileURLWithPath: directory))
    }.value
  }

  /// `Process` 的输出读取必须与子进程并行，否则大输出会填满 pipe 并与 wait 互锁。
  /// 超时或超限后先 terminate，再以 SIGKILL 保底；返回已收集的有界文本供解析器使用。
  private static func run(
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    maximumBytes: Int
  ) -> String {
    final class OutputBox: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
      var exceededLimit = false
    }

    guard FileManager.default.isExecutableFile(atPath: executable), maximumBytes > 0 else {
      return ""
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let output = OutputBox()
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      output.lock.lock()
      if output.data.count + chunk.count > maximumBytes { output.exceededLimit = true }
      if output.data.count < maximumBytes {
        output.data.append(chunk.prefix(maximumBytes - output.data.count))
      }
      let exceeded = output.exceededLimit
      output.lock.unlock()
      if exceeded, process.isRunning { process.terminate() }
    }
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return ""
    }
    if finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 0.25) == .timedOut, process.processIdentifier > 0 {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.25)
      }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    output.lock.lock()
    if output.data.count < maximumBytes {
      output.data.append(tail.prefix(maximumBytes - output.data.count))
    }
    let data = output.data
    output.lock.unlock()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
