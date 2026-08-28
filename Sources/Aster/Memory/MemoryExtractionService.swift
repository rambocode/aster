import AsterCore
import Darwin
import Foundation

/// CLI Agent 增强提炼服务：把 Session 事件流交给本机已安装的 Coding Agent CLI
/// （`claude -p` / `codex exec`）做叙述性提炼，失败时回落到纯本地的规则式提炼。
///
/// 本文件承担全部「危险」职责——授权判定、进程启动、超时与回落——纯函数部分
/// （摘要、prompt、响应解析）全在 `AsterCore/SessionMemoryExtraction.swift`。
///
/// 三条不可让步的纪律：
/// 1. **未授权零外发**：`enabled && acknowledged` 缺一不可，否则连 prompt 都不构造。
/// 2. **主线程不阻塞**：子进程等待走 `terminationHandler` + 信号量，且整段在 detached
///    task 上执行（`docs/developer/engineering-pitfalls.md`：主线程禁止泵 runloop 的等待）。
/// 3. **失败必回落**：未安装、超时、非零退出、解析失败一律返回规则式结果，绝不抛错、
///    绝不返回 nil——事件早已落库，提炼只是增强（PRD §76）。

// MARK: - 授权与执行 seam

/// 提炼授权状态的快照。
struct MemoryExtractionAuthorization: Sendable {
  let isEnabled: Bool
  let providerIdentifier: String?
  let isAcknowledged: Bool

  init(isEnabled: Bool, providerIdentifier: String?, isAcknowledged: Bool) {
    self.isEnabled = isEnabled
    self.providerIdentifier = providerIdentifier
    self.isAcknowledged = isAcknowledged
  }

  /// 是否允许把会话摘要发给外部 Agent。开关与确认必须同时为真（PRD §73）。
  var allowsOutbound: Bool { isEnabled && isAcknowledged }
}

/// 一次提炼子进程的执行结果。
struct MemoryExtractionProcessResult: Sendable {
  let standardOutput: String
  let terminationStatus: Int32
  let didTimeOut: Bool

  init(standardOutput: String, terminationStatus: Int32, didTimeOut: Bool = false) {
    self.standardOutput = standardOutput
    self.terminationStatus = terminationStatus
    self.didTimeOut = didTimeOut
  }

  /// 只有正常退出且非超时才算可用输出。
  var isUsable: Bool { !didTimeOut && terminationStatus == 0 }
}

/// 进程执行的可注入 seam。测试注入假实现，从而完全不起真实进程也能验证回落链。
struct MemoryExtractionProcessExecutor: Sendable {
  /// 把命令名解析成绝对路径；返回 nil 表示本机没装该 CLI。
  let resolveExecutable: @Sendable (_ command: String) -> String?
  /// 运行一次提炼命令。实现必须自带超时与输出上限，且**绝不能在主线程调用**。
  let run:
    @Sendable (
      _ executable: String,
      _ arguments: [String],
      _ workingDirectory: String?,
      _ timeout: TimeInterval
    ) -> MemoryExtractionProcessResult?

  /// 生产实现：PATH 查找 + 有界子进程。
  static let live = MemoryExtractionProcessExecutor(
    resolveExecutable: MemoryExtractionProcess.resolve(command:),
    run: MemoryExtractionProcess.run(executable:arguments:workingDirectory:timeout:)
  )
}

/// 并发闸门：同一时刻只允许一次 CLI 提炼在跑。
///
/// 抢不到闸门时**不排队**而是立即回落规则式：一次调用约 13 秒 / $0.09（Phase 0 实测），
/// 关闭多个窗口时排队会同时拖长退出流程并放大账单，宁可让后几个 session 拿规则式结果。
actor MemoryExtractionGate {
  private var isBusy = false

  /// 尝试占用闸门；返回 false 表示已有提炼在跑。
  func acquire() -> Bool {
    guard !isBusy else { return false }
    isBusy = true
    return true
  }

  func release() {
    isBusy = false
  }
}

// MARK: - 规则式提炼（结构化完整版）

/// 结构化规则式提炼器：`StructuredSessionSummaryBuilder` 的 Memory 包装。
///
/// 与 seam 里 spike 版的 `RuleBasedMemoryExtractor` 并存但更完整（时长、git、文件改动、
/// 工具调用统计），CLI 路径的每一次回落也都落到这里，保证「有 CLI 和没 CLI」拿到的
/// 事实部分完全一致。
struct StructuredRuleBasedMemoryExtractor: SessionMemoryExtracting {
  func extract(
    session: RecordedSessionDescriptor,
    events: [RecordedEvent]
  ) async -> ExtractedMemory? {
    guard let digest = SessionEventDigest.make(session: session, events: events) else { return nil }
    return MemoryExtractionAssembler.ruleBased(digest: digest, session: session)
  }
}

/// digest / 提炼结果 → `ExtractedMemory` 的组装规则。两条路径共用，保证回链一致。
enum MemoryExtractionAssembler {
  /// 规则式结果。内容全部来自本机事件，因此 confidence 取满值。
  static func ruleBased(
    digest: SessionEventDigest,
    session: RecordedSessionDescriptor
  ) -> ExtractedMemory {
    let draft = StructuredSessionSummaryBuilder.build(digest: digest)
    let memory = MemoryRecord(
      // Memory id 沿用 session id：同一 session 重复提炼是幂等替换，不会堆积副本。
      id: session.id,
      projectPath: draft.projectPath,
      sessionID: session.id,
      taskID: session.taskID,
      type: .session,
      title: draft.title,
      content: draft.content,
      summary: draft.title,
      confidence: 1.0,
      extractor: .ruleBased
    )
    return ExtractedMemory(memory: memory, sources: sources(digest: digest, session: session))
  }

  /// CLI Agent 结果。正文是「叙述 + 事实记录」两段：叙述来自模型（可能有偏差），
  /// 事实记录仍是本机 digest，让用户随时能对照原始命令核验模型的说法。
  static func cliAgent(
    summary: AgentSessionSummary,
    provider: AgentProvider,
    digest: SessionEventDigest,
    session: RecordedSessionDescriptor
  ) -> ExtractedMemory {
    let facts = SessionDigestRenderer.markdown(for: digest)
    let content = summary.markdown() + "\n\n---\n\n" + facts
    let memory = MemoryRecord(
      id: session.id,
      projectPath: digest.projectPath,
      sessionID: session.id,
      taskID: session.taskID,
      type: .session,
      title: title(summary: summary, digest: digest),
      content: content,
      summary: summary.summaryLine() ?? StructuredSessionSummaryBuilder.title(for: digest),
      // 模型叙述是推断而非观测，可信度刻意低于规则式，展示层据此提示不确定性。
      confidence: 0.7,
      extractor: .cliAgent(provider.rawValue)
    )
    return ExtractedMemory(memory: memory, sources: sources(digest: digest, session: session))
  }

  /// 回链：session 必给，task 与 git commit 有则补（PRD §31）。
  private static func sources(
    digest: SessionEventDigest,
    session: RecordedSessionDescriptor
  ) -> [MemorySourceRef] {
    var refs: [MemorySourceRef] = [.init(kind: .session, identifier: session.id.uuidString)]
    if let taskID = session.taskID {
      refs.append(.init(kind: .task, identifier: taskID.uuidString))
    }
    if let commit = digest.gitCommit, !commit.isEmpty {
      refs.append(.init(kind: .gitCommit, identifier: commit))
    }
    return refs
  }

  /// 标题优先用模型给的 goal（信息量最高），缺失时回落结构化计数标题。
  private static func title(summary: AgentSessionSummary, digest: SessionEventDigest) -> String {
    guard let goal = summary.goal?.split(whereSeparator: \.isNewline).first.map(String.init),
      !goal.trimmingCharacters(in: .whitespaces).isEmpty
    else { return StructuredSessionSummaryBuilder.title(for: digest) }
    let bounded = goal.count > 120 ? String(goal.prefix(120)) + "…" : goal
    return "\(digest.projectName) · \(bounded)"
  }
}

// MARK: - CLI Agent 提炼器

/// 调用本机 Coding Agent CLI 做提炼；任何一步不满足都回落规则式。
struct CLIAgentMemoryExtractor: SessionMemoryExtracting {
  /// 单次提炼的墙钟上限。Phase 0 实测 `claude -p` 约 13 秒；120 秒留足网络抖动余量，
  /// 超时后强杀，绝不让退出流程被一个卡住的 CLI 拖住。
  static let defaultTimeout: TimeInterval = 120

  /// 授权读取。做成异步闭包是因为 `AppPreferences` 是 `@MainActor` 类型，
  /// 而提炼发生在后台；这里只做一次极短的主线程读取，不涉及任何 IO。
  let readAuthorization: @Sendable () async -> MemoryExtractionAuthorization
  let executor: MemoryExtractionProcessExecutor
  let timeout: TimeInterval
  let gate: MemoryExtractionGate

  init(
    readAuthorization: @escaping @Sendable () async -> MemoryExtractionAuthorization,
    executor: MemoryExtractionProcessExecutor = .live,
    timeout: TimeInterval = defaultTimeout,
    gate: MemoryExtractionGate = MemoryExtractionGate()
  ) {
    self.readAuthorization = readAuthorization
    self.executor = executor
    self.timeout = timeout
    self.gate = gate
  }

  /// 从 `UserDefaults` 读取授权的便捷构造。
  init(
    defaults: UserDefaults,
    executor: MemoryExtractionProcessExecutor = .live,
    timeout: TimeInterval = defaultTimeout
  ) {
    // `UserDefaults` 内部线程安全但未标注 Sendable；这里只在闭包里读三个标量，
    // 用 `nonisolated(unsafe)` 显式承担该跨隔离域捕获。
    nonisolated(unsafe) let storage = defaults
    self.init(
      readAuthorization: {
        let settings = await MainActor.run {
          AppPreferences.memoryExtractionSettings(from: storage)
        }
        return MemoryExtractionAuthorization(
          isEnabled: settings.enabled,
          providerIdentifier: settings.provider,
          isAcknowledged: settings.acknowledged
        )
      },
      executor: executor,
      timeout: timeout
    )
  }

  func extract(
    session: RecordedSessionDescriptor,
    events: [RecordedEvent]
  ) async -> ExtractedMemory? {
    // 摘要先算：事件不足以形成 Memory 时直接返回 nil，连授权都不必判定，更不外发。
    guard let digest = SessionEventDigest.make(session: session, events: events) else { return nil }
    let fallback = MemoryExtractionAssembler.ruleBased(digest: digest, session: session)

    let authorization = await readAuthorization()
    guard authorization.allowsOutbound else { return fallback }
    guard let provider = Self.provider(from: authorization.providerIdentifier) else {
      return fallback
    }
    guard let executable = executor.resolveExecutable(provider.commandName) else { return fallback }

    let prompt = AgentSummaryPromptBuilder.prompt(digest: digest)
    guard let arguments = Self.arguments(for: provider, prompt: prompt) else { return fallback }

    // 闸门抢不到就直接回落，不排队（见 `MemoryExtractionGate` 的说明）。
    guard await gate.acquire() else { return fallback }
    let result = await Self.detached { [executor, timeout] in
      executor.run(executable, arguments, digest.projectPath, timeout)
    }
    await gate.release()

    guard let result, result.isUsable else { return fallback }
    guard let summary = AgentSummaryResponseParser.parse(result.standardOutput), !summary.isEmpty
    else { return fallback }
    return MemoryExtractionAssembler.cliAgent(
      summary: summary, provider: provider, digest: digest, session: session)
  }

  // MARK: 装配入口

  /// 按当前设置安装全局提炼器。授权齐备时装 CLI 增强实现，否则装结构化规则式实现。
  ///
  /// 装配层（`AppModel` / `AsterAppDelegate`）在启动时和用户改动提炼设置后调用；
  /// 本类型自己从不调用它，避免服务层反向依赖装配顺序。
  @MainActor
  static func installIfEnabled(
    defaults: UserDefaults = .standard,
    executor: MemoryExtractionProcessExecutor = .live
  ) {
    let settings = AppPreferences.memoryExtractionSettings(from: defaults)
    guard settings.enabled, settings.acknowledged else {
      MemoryExtraction.provider = StructuredRuleBasedMemoryExtractor()
      return
    }
    MemoryExtraction.provider = CLIAgentMemoryExtractor(defaults: defaults, executor: executor)
  }

  /// 设置页「查看将要发送的内容」的数据源（PRD §73）。返回的文本与真正外发的 prompt
  /// 逐字节一致；没有可提炼事件时返回一句说明而不是空串。
  static func previewPayload(
    session: RecordedSessionDescriptor,
    events: [RecordedEvent]
  ) -> String {
    AgentSummaryPromptBuilder.previewText(session: session, events: events)
  }

  /// 用合成事件渲染的样例 payload，供「还没有任何已记录 session」时展示。
  ///
  /// 刻意走与真实路径**完全相同**的 prompt 构造器而不是手写一段说明文字：用户看到的
  /// 结构、边界说明与字段清单必须与真正外发的内容一致，否则预览就成了营销文案。
  /// 合成事件里的路径与命令都是虚构的，不读取用户机器上的任何数据。
  static func samplePreviewPayload() -> String {
    let sampleID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let start = Date(timeIntervalSince1970: 0)
    let descriptor = RecordedSessionDescriptor(
      id: sampleID,
      projectPath: "/Users/example/source/sample-project",
      shell: "/bin/zsh",
      agentProvider: AgentProvider.claudeCode.rawValue,
      startedAt: start,
      gitBranch: "feature/sample"
    )
    func sample(
      _ sequence: Int, _ kind: MemoryEventKind, command: String? = nil, exitStatus: Int? = nil,
      excerpt: String? = nil, payload: String? = nil
    ) -> RecordedEvent {
      RecordedEvent(
        sessionID: sampleID, sequence: sequence,
        timestamp: start.addingTimeInterval(Double(sequence) * 12),
        kind: kind, command: command,
        workingDirectory: "/Users/example/source/sample-project",
        exitStatus: exitStatus, outputExcerpt: excerpt, source: nil, payload: payload)
    }
    let events: [RecordedEvent] = [
      sample(1, .shellCommand, command: "swift test --filter Reconnect"),
      sample(2, .commandOutput, excerpt: "Test Case 'reconnect' failed\nerror: connection reset"),
      sample(3, .commandFinished, exitStatus: 1),
      sample(4, .agentToolCall, payload: #"{"tool":"Edit"}"#),
      sample(5, .fileModified, payload: #"{"path":"Sources/Networking/Reconnect.swift"}"#),
      sample(6, .shellCommand, command: "swift test --filter Reconnect"),
      sample(7, .commandFinished, exitStatus: 0),
      sample(
        8, .gitStateSnapshot,
        payload: GitSnapshotPayload(
          branch: "feature/sample", commit: "0123abc", dirtyFileCount: 1
        ).jsonString()),
      sample(9, .sessionEnded),
    ]
    return previewPayload(session: descriptor, events: events)
  }

  // MARK: 命令规划

  /// 设置里的 provider 标识 → `AgentProvider`。空值取默认 claudeCode；
  /// 无法识别的字符串说明配置漂移，返回 nil 让调用方回落，不擅自换一个 Agent 外发。
  static func provider(from identifier: String?) -> AgentProvider? {
    guard let identifier, !identifier.isEmpty else { return .claudeCode }
    return AgentProvider(rawValue: identifier)
  }

  /// provider 的非交互（单轮、无 TUI）调用参数。未验证过非交互模式的 provider 返回 nil，
  /// 宁可回落规则式，也不用猜出来的参数在用户机器上启动一个交互式 Agent。
  static func arguments(for provider: AgentProvider, prompt: String) -> [String]? {
    switch provider {
    case .claudeCode: ["-p", prompt, "--output-format", "json"]
    case .codex: ["exec", prompt]
    case .openCode, .cursorCLI, .kimiCode, .pi, .omp, .grokBuild,
      .gemini, .githubCopilot, .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      nil
    }
  }

  /// 把阻塞式子进程调用挪到 detached task，保证调用方（可能是主线程）不被信号量卡住。
  private static func detached<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
  ) async -> Value {
    let task = Task.detached(priority: .utility, operation: operation)
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

// MARK: - 生产进程实现

/// 提炼专用的子进程执行器。
///
/// 与 `MemoryProcessRunner`（git 探测用）刻意分开：提炼进程需要继承用户环境
/// （CLI Agent 的凭据、配置在 `HOME` 下）、需要更长超时与更大输出上限，
/// 把这些放宽到共享 runner 上会一并放宽只读探测的攻击面。
enum MemoryExtractionProcess {
  /// stdout 上限。JSON 摘要通常几 KiB；256 KiB 已足够容纳异常啰嗦的输出。
  static let maximumOutputBytes = 256 * 1_024

  /// GUI 进程的 PATH 往往只有 `/usr/bin:/bin`，用户装在 Homebrew 或 `~/.local/bin`
  /// 的 Agent CLI 因此查不到。这里在环境 PATH 之外补上常见安装位置。
  static let additionalSearchPaths = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
  ]

  /// 把命令名解析成绝对路径。只接受可执行的普通文件，找不到返回 nil。
  static func resolve(command: String) -> String? {
    guard !command.isEmpty, !command.contains("/") else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let environmentPaths =
      (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map(String.init)
    let candidates =
      environmentPaths + additionalSearchPaths
      + ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.bun/bin", "\(home)/bin"]
    for directory in candidates where !directory.isEmpty {
      let path = (directory as NSString).appendingPathComponent(command)
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
  }

  /// 运行提炼命令并返回有界 stdout。
  ///
  /// 读端必须与子进程并行消费，否则大输出填满 pipe 会与等待互锁；stdin 接 null
  /// 设备，避免 CLI 误以为有交互输入而永久挂起。
  static func run(
    executable: String,
    arguments: [String],
    workingDirectory: String?,
    timeout: TimeInterval
  ) -> MemoryExtractionProcessResult? {
    /// 读端缓冲：`readabilityHandler` 在专用队列回调，必须加锁与主体隔离。
    final class OutputBox: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
      var exceededLimit = false
    }

    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // 继承用户环境：CLI Agent 需要 HOME 下的凭据与配置才能工作。只补 PATH，
    // 不做裁剪——裁剪会让 Agent 在用户机器上表现得与手动执行不一致，难以排查。
    var environment = ProcessInfo.processInfo.environment
    let existingPath = environment["PATH"] ?? ""
    environment["PATH"] = ([existingPath] + additionalSearchPaths)
      .filter { !$0.isEmpty }
      .joined(separator: ":")
    process.environment = environment
    if let workingDirectory, FileManager.default.fileExists(atPath: workingDirectory) {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let output = OutputBox()
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      output.lock.lock()
      if output.data.count + chunk.count > maximumOutputBytes { output.exceededLimit = true }
      if output.data.count < maximumOutputBytes {
        output.data.append(chunk.prefix(maximumOutputBytes - output.data.count))
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
      return nil
    }

    // `DispatchSemaphore.wait` 不响应 Swift Task 取消，短周期轮询同时观察 deadline 与
    // 取消标记；两者共用同一条终止流程，保证不留下超时后仍在跑的 Agent 进程。
    let deadline = Date().addingTimeInterval(max(1, timeout))
    var didTimeOut = false
    var wasCancelled = false
    while finished.wait(timeout: .now() + 0.05) == .timedOut {
      if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
        wasCancelled = true
        break
      }
      if Date() >= deadline {
        didTimeOut = true
        break
      }
    }
    if didTimeOut || wasCancelled {
      terminate(process, finished: finished)
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    output.lock.lock()
    if output.data.count < maximumOutputBytes {
      output.data.append(tail.prefix(maximumOutputBytes - output.data.count))
    }
    let data = output.data
    let exceeded = output.exceededLimit
    output.lock.unlock()
    guard !wasCancelled else { return nil }
    return MemoryExtractionProcessResult(
      standardOutput: String(data: data, encoding: .utf8) ?? "",
      terminationStatus: didTimeOut ? -1 : process.terminationStatus,
      didTimeOut: didTimeOut || exceeded
    )
  }

  /// 分级终止：SIGTERM → SIGKILL(pid) → SIGKILL(进程组)。
  ///
  /// Agent CLI 通常会拉起 node/python 子进程，只杀父进程会留下孤儿；`kill(-pid)` 只在
  /// 子进程自己调用过 setpgid（成为组长）时命中，命不中时返回 ESRCH，对本进程无害。
  private static func terminate(_ process: Process, finished: DispatchSemaphore) {
    process.terminate()
    guard finished.wait(timeout: .now() + 0.5) == .timedOut else { return }
    let pid = process.processIdentifier
    guard pid > 0 else { return }
    _ = Darwin.kill(pid, SIGKILL)
    _ = Darwin.kill(-pid, SIGKILL)
    _ = finished.wait(timeout: .now() + 0.5)
  }
}
