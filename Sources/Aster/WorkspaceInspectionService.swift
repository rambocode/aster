import AsterCore
import Darwin
import Foundation

enum WorkspaceInformationState: Equatable, Sendable {
  case ready
  case unavailable(String)
  case failed(String)
}

/// Info 的成功空结果、Pane 不适用和基础设施失败必须分开表达。否则用户会把检查失败
/// 误读为“没有进程/端口”，也无法决定是否值得重试。
struct WorkspaceInformationSnapshot: Sendable {
  let processes: [WorkspaceProcess]
  let listeningPorts: [ListeningPort]
  let state: WorkspaceInformationState

  init(
    processes: [WorkspaceProcess],
    listeningPorts: [ListeningPort],
    state: WorkspaceInformationState = .ready
  ) {
    self.processes = processes
    self.listeningPorts = listeningPorts
    self.state = state
  }
}

/// 详情控制器依赖的内部异步接口。生产环境连接固定路径的只读检查服务；测试可分别
/// 控制 Info、Git、Files 完成顺序，验证页签不会启动无关 I/O。
struct WorkspaceInspectionClient {
  let information: @MainActor (_ shellProcessIdentifier: Int32?) async -> WorkspaceInformationSnapshot
  let git: @MainActor (_ directory: String) async -> GitStatusSummary
  let files: @MainActor (_ directory: String, _ includeHidden: Bool) async -> [WorkspaceFileNode]
  /// 只有用户点开 diff 预览时才会用到，因此给出「无差异」默认实现：只验证 Info/Git/Files
  /// 加载顺序的测试不必逐个声明它。
  var diff: @MainActor (_ directory: String, _ path: String, _ staged: Bool) async -> String = {
    _, _, _ in ""
  }

  static let live = WorkspaceInspectionClient(
    information: { processIdentifier in
      await WorkspaceInspectionService.inspectInformation(
        shellProcessIdentifier: processIdentifier)
    },
    git: { directory in
      await WorkspaceInspectionService.inspectGit(directory: directory)
    },
    files: { directory, includeHidden in
      await WorkspaceInspectionService.inspectFiles(
        directory: directory, includeHidden: includeHidden)
    },
    diff: { directory, path, staged in
      await WorkspaceInspectionService.inspectDiff(
        directory: directory, path: path, staged: staged)
    }
  )
}

/// 详情面板的只读基础设施边界。所有可执行文件均为固定绝对路径，参数逐项传递；输出、
/// 运行时间和文件树规模都有上限，不经过登录 Shell，也不会执行仓库中的脚本或 hook。
enum WorkspaceInspectionService {
  /// 外部只读命令的结果必须保留失败分类。Info 不能把 `lsof` 超时或无权限错误压缩成
  /// 空端口列表；其他调用方仍可通过下方 `run` 只读取其有界输出。
  private struct CommandRunResult: Sendable {
    let output: String
    let failure: Failure?
  }

  private enum Failure: Sendable {
    case unavailable, launch, cancelled, timedOut, exceededLimit, unexpectedExit
  }

  /// 测试取消/超时语义的内部 seam。生产调用仍只使用下方固定的 `ps`、`lsof` 和
  /// `git` 绝对路径；该入口不属于模块公开 API。
  static func runForTesting(
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    maximumBytes: Int = 64 * 1_024
  ) -> String {
    run(
      executable: executable,
      arguments: arguments,
      timeout: timeout,
      maximumBytes: maximumBytes
    )
  }

  /// Info 页只需要进程树与端口。它们有数据依赖（lsof 需要 ps 得到的后代 PID），但
  /// 不再串入 Git 工作；外层取消通过 cancellation handler 传给阻塞命令任务。
  static func inspectInformation(
    shellProcessIdentifier: Int32?
  ) async -> WorkspaceInformationSnapshot {
    guard let shellProcessIdentifier, shellProcessIdentifier > 0 else {
      return WorkspaceInformationSnapshot(
        processes: [],
        listeningPorts: [],
        state: .unavailable("此 Pane 没有终端进程。")
      )
    }
    return await detachedValue {
      let processRun = runResult(
        executable: "/bin/ps",
        arguments: ["-axo", "pid=,ppid=,etime=,comm="],
        timeout: 2,
        maximumBytes: 4 * 1_024 * 1_024
      )
      guard processRun.failure == nil else {
        return WorkspaceInformationSnapshot(
          processes: [], listeningPorts: [], state: .failed("无法读取当前终端进程。"))
      }
      let processes = WorkspaceProcessParser.processTree(
        from: processRun.output, rootProcessIdentifier: shellProcessIdentifier)
      guard !currentTaskIsCancelled() else {
        return WorkspaceInformationSnapshot(
          processes: [], listeningPorts: [], state: .unavailable("检查已取消。"))
      }
      guard !processes.isEmpty else {
        return WorkspaceInformationSnapshot(
          processes: [],
          listeningPorts: [],
          state: .failed("无法读取当前终端进程。")
        )
      }
      let inspectedPIDs = processes.map(\.processIdentifier)
      let portRun = runResult(
        executable: "/usr/sbin/lsof",
        arguments: [
          "-nP", "-a", "-p", inspectedPIDs.map(String.init).joined(separator: ","),
          "-iTCP", "-sTCP:LISTEN", "-Fpcn",
        ],
        timeout: 2,
        maximumBytes: 2 * 1_024 * 1_024,
        acceptedTerminationStatuses: [0, 1]
      )
      guard portRun.failure == nil else {
        return WorkspaceInformationSnapshot(
          processes: processes,
          listeningPorts: [],
          state: .failed("无法读取监听端口。")
        )
      }
      return WorkspaceInformationSnapshot(
        processes: processes,
        listeningPorts: ListeningPortParser.parse(portRun.output)
      )
    }
  }

  /// Git 页只读取当前目录状态与 diff 汇总，不启动 ps/lsof。status 确认仓库存在后才
  /// 执行 shortstat；任何阶段取消都会让当前子进程快速结束并跳过后续命令。
  static func inspectGit(directory: String) async -> GitStatusSummary {
    await detachedValue {
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
      guard !currentTaskIsCancelled() else { return GitStatusSummary() }
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
      return git
    }
  }

  /// 单个文件的 diff 预览。仍然只走只读 git：`--cached` 读暂存区，未跟踪文件没有可比
  /// 对象，改用 `--no-index` 与 `/dev/null` 比较（git 对该模式以退出码 1 返回内容，
  /// 这里只取标准输出）。路径经 `--` 隔开，不会被当成选项或 revision。
  static func inspectDiff(directory: String, path: String, staged: Bool) async -> String {
    guard !path.isEmpty, !path.hasPrefix("-") else { return "" }
    return await detachedValue {
      let common = ["-c", "core.fsmonitor=false", "-C", directory, "diff"]
      let tracked = run(
        executable: "/usr/bin/git",
        arguments: common + (staged ? ["--cached"] : []) + ["--", path],
        timeout: 3,
        maximumBytes: 512 * 1_024
      )
      guard tracked.isEmpty, !staged, !currentTaskIsCancelled() else { return tracked }
      return run(
        executable: "/usr/bin/git",
        arguments: common + ["--no-index", "--", "/dev/null", path],
        timeout: 3,
        maximumBytes: 512 * 1_024
      )
    }
  }

  /// Files 页只依赖目录枚举，不应排在可能触发秒级超时的 ps/lsof/Git 检查之后。
  /// 独立 user-initiated 任务让面板先得到有界文件树，顶部页签切换也不会阻塞主线程；外层
  /// 刷新取消时必须同步取消扫描，否则快速 cd 或关闭面板会积累已经无用的目录遍历。
  static func inspectFiles(directory: String, includeHidden: Bool = false) async -> [WorkspaceFileNode] {
    let scan = Task.detached(priority: .userInitiated) {
      WorkspaceFileTree.enumerate(
        root: URL(fileURLWithPath: directory), includeHidden: includeHidden)
    }
    return await withTaskCancellationHandler {
      await scan.value
    } onCancel: {
      scan.cancel()
    }
  }

  /// `Task.detached` 不会自动继承等待方后续收到的取消。统一包装后，控制器取消当前页
  /// 任务会同步取消真正执行阻塞 POSIX/Process 工作的 detached task。
  private static func detachedValue<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
  ) async -> Value {
    let task = Task.detached(priority: .utility, operation: operation)
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func currentTaskIsCancelled() -> Bool {
    withUnsafeCurrentTask { $0?.isCancelled == true }
  }

  /// `Process` 的输出读取必须与子进程并行，否则大输出会填满 pipe 并与 wait 互锁。
  /// 超时或超限后先 terminate，再以 SIGKILL 保底；返回已收集的有界文本供解析器使用。
  private static func run(
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    maximumBytes: Int
  ) -> String {
    runResult(
      executable: executable,
      arguments: arguments,
      timeout: timeout,
      maximumBytes: maximumBytes
    ).output
  }

  private static func runResult(
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    maximumBytes: Int,
    acceptedTerminationStatuses: Set<Int32> = [0]
  ) -> CommandRunResult {
    final class OutputBox: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
      var exceededLimit = false
    }

    guard !currentTaskIsCancelled() else {
      return .init(output: "", failure: .cancelled)
    }
    guard FileManager.default.isExecutableFile(atPath: executable), maximumBytes > 0 else {
      return .init(output: "", failure: .unavailable)
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
      return .init(output: "", failure: .launch)
    }
    // `DispatchSemaphore.wait` 本身不响应 Swift Task cancellation。用短周期轮询同时观察
    // deadline 与取消标记；取消和超时共享同一终止流程，避免快速 cd/收起面板后仍留下
    // 最长数秒的 ps/lsof/git 子进程。
    let deadline = Date().addingTimeInterval(max(0.1, timeout))
    var failure: Failure?
    while finished.wait(timeout: .now() + 0.025) == .timedOut {
      if currentTaskIsCancelled() {
        failure = .cancelled
        break
      }
      if Date() >= deadline {
        failure = .timedOut
        break
      }
    }
    output.lock.lock()
    let exceededLimit = output.exceededLimit
    output.lock.unlock()
    if failure != nil || exceededLimit {
      if exceededLimit { failure = .exceededLimit }
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
    let text = String(data: data, encoding: .utf8) ?? ""
    if failure == nil, !acceptedTerminationStatuses.contains(process.terminationStatus) {
      failure = .unexpectedExit
    }
    return .init(output: text, failure: failure)
  }
}
