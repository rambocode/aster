import AsterCore
import AsterMemory
import Foundation

/// TerminalSession 向记录层暴露的窄接口。Session 只做参数拷贝与转发，
/// 记录层的任何故障都不得回流到终端（写入类方法全部无返回值、不抛错）。
@MainActor
protocol TerminalEventRecording: AnyObject {
  func sessionStarted(id: UUID, projectPath: String, shell: String?)
  func commandStarted(id: UUID, command: String?, workingDirectory: String)
  /// 命令文本必须一并上报：排除策略按可执行名判定，输出正文的取舍依赖这条决定。
  func commandFinished(id: UUID, command: String?, exitStatus: Int?)
  func agentChanged(id: UUID, provider: String?, agentSessionID: String?)
  func receivePTYOutput(id: UUID, bytes: ArraySlice<UInt8>)
  func sessionEnded(id: UUID, exitCode: Int32?)

  /// 当前 Session 的记录状态。UI 只读，不驱动任何重建。
  func recordingMode(for id: UUID) -> RecordingMode
  /// 该 Session 此刻是否真的在落盘（策略允许 + 管线已建立）。
  func isRecording(id: UUID) -> Bool
  /// Per-pane 临时隐身：只在本 Session 生命周期内生效，不写全局设置。
  func setIncognito(_ incognito: Bool, for id: UUID)
}

/// 记录管线的输入。命令事件与 PTY 字节走**同一条**流，是排除判定正确性的前提：
/// 两条独立通道无法保证「命令被排除」这个决定先于它的输出到达（见 `resolveOutput`）。
enum SessionPipelineInput: Sendable {
  case output([UInt8])
  case commandStarted(command: String?, workingDirectory: String)
  case commandFinished(command: String?, exitStatus: Int?)
  case agentChanged(provider: String?, agentSessionID: String?)
  case ended(exitCode: Int?)
}

/// 单个 Session 的事件管线：统一分配序号、脱敏、落 artifact 并转投 EventWriter。
/// actor 隔离让输出解析（可能高吞吐）完全离开主线程。
actor SessionEventPipeline {
  private let sessionID: UUID
  private let shell: String?
  private let startedAt: Date
  private let startDirectory: String
  private let writer: EventWriter
  private let artifacts: TranscriptArtifactStore
  /// 本 Session 生效的策略快照。中途改设置不影响已建立的管线——
  /// 关闭记录由服务层直接拆管线，语义比「管线自查」更确定。
  private let policy: RecordingPolicy
  private let resolveProject: @Sendable (String) async -> ProjectIdentity?
  private let inspectGit: @Sendable (String) async -> GitStatusSummary

  private var sequence = 0
  /// 自持实例，与 Autocomplete 的 capture 互不影响。
  private var outputCapture = ShellCommandOutputCapture()
  private var lastKnownDirectory: String
  private var projectPath: String
  /// 已闭合但还不知道归属命令的输出（D 标记字节先于主线程的 commandFinished 到达）。
  private var pendingCapturedOutput: ShellCapturedCommandOutput?
  /// 已知的命令排除判定，等待它的输出闭合（主线程事件先到）。
  private var pendingCommandExcluded: Bool?
  /// 失败命令后的 git 快照限频闸门（PRD Phase 1：最短间隔 5 秒）。
  private var gitThrottle = RecordingThrottle(minimumInterval: 5)
  private var quotaTracker = ArtifactQuotaTracker()
  /// Agent 归属，由 `.agentChanged` 更新。Session 结束后的 transcript 补录需要它来
  /// 定位 provider 自己的记录文件；终端侧无法从输出里可靠还原工具调用。
  private var agentProvider: AgentProvider?
  private var agentSessionIdentifier: String?
  /// 会话是否已在库里物化。空会话（没有命令、没有 Agent 关联）**永不落库**：
  /// 开个 pane 又关掉不该在 History 里留下「zsh · 0 条命令」的噪音行。
  private var materialized = false
  /// 物化前缓存的前置事件（sessionStarted 等）。有意义事件走物化后的直写路径，
  /// 这里只会有个位数条目；上限纯属防御。
  private var bufferedEvents: [RecordedEvent] = []
  /// bootstrap 解析出的项目身份，物化时才写 projects 表。
  private var pendingProject: ProjectIdentity?

  init(
    sessionID: UUID,
    shell: String?,
    startedAt: Date,
    startDirectory: String,
    policy: RecordingPolicy,
    writer: EventWriter,
    artifacts: TranscriptArtifactStore,
    resolveProject: @escaping @Sendable (String) async -> ProjectIdentity?,
    inspectGit: @escaping @Sendable (String) async -> GitStatusSummary
  ) {
    self.sessionID = sessionID
    self.shell = shell
    self.startedAt = startedAt
    self.startDirectory = startDirectory
    self.policy = policy
    self.writer = writer
    self.artifacts = artifacts
    self.resolveProject = resolveProject
    self.inspectGit = inspectGit
    lastKnownDirectory = startDirectory
    projectPath = startDirectory
  }

  /// 解析项目归属并缓存开场事件；**不写库**。落库推迟到首条有意义事件
  ///（`materializeIfNeeded`），空 pane 开了就关不会留下任何行。
  /// 首次 git 快照也一并推迟：不为随手开关的 pane fork git 子进程。
  func bootstrap() async {
    if let identity = await resolveProject(startDirectory) {
      projectPath = identity.path
      pendingProject = identity
    }
    await emit(kind: .sessionStarted, workingDirectory: startDirectory, source: .terminal)
  }

  /// 首条有意义事件（命令、Agent 关联）触发的真正落库：先写 projects/sessions 行，
  /// 再按原始顺序补写缓存事件——events.session_id 是外键且 `foreign_keys=ON`，
  /// 顺序颠倒会让整批写入回滚。
  private func materializeIfNeeded() async {
    guard !materialized else { return }
    materialized = true
    if let pendingProject {
      await writer.record(.upsertProject(pendingProject, openedAt: startedAt))
      self.pendingProject = nil
    }
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID,
          projectPath: projectPath,
          shell: shell,
          startedAt: startedAt
        )))
    for event in bufferedEvents {
      await writer.record(.appendEvent(event))
    }
    bufferedEvents = []
    scheduleGitSnapshot(force: true)
  }

  /// 消费一条管线输入。整个方法是 Session 内事件顺序的唯一权威。
  func handle(_ input: SessionPipelineInput) async {
    switch input {
    case .output(let bytes):
      for completed in outputCapture.consume(bytes[...]) {
        await resolveOutput(completed)
      }
    case .commandStarted(let command, let workingDirectory):
      // 新的命令周期开始：上一轮悬而未决的配对一律作废（保守丢弃，宁可少记）。
      pendingCapturedOutput = nil
      pendingCommandExcluded = nil
      if !workingDirectory.isEmpty { lastKnownDirectory = workingDirectory }
      guard policy.shouldRecord(command: command, workingDirectory: lastKnownDirectory) else {
        return
      }
      await materializeIfNeeded()
      await emit(
        kind: .shellCommand,
        command: command,
        workingDirectory: lastKnownDirectory,
        source: .shellIntegration
      )
    case .commandFinished(let command, let exitStatus):
      let excluded = !policy.shouldRecord(
        command: command, workingDirectory: lastKnownDirectory)
      // persistOutput 会直写事件与 artifact，必须先保证 sessions 行已存在。
      if !excluded { await materializeIfNeeded() }
      if let buffered = pendingCapturedOutput {
        pendingCapturedOutput = nil
        if !excluded { await persistOutput(buffered) }
      } else {
        pendingCommandExcluded = excluded
      }
      guard !excluded else { return }
      await emit(
        kind: .commandFinished,
        workingDirectory: lastKnownDirectory,
        exitStatus: exitStatus,
        source: .shellIntegration
      )
      // 失败命令后的仓库状态是排障时最有价值的上下文；限频保证连续失败不会刷屏。
      if (exitStatus ?? 0) != 0 { scheduleGitSnapshot(force: false) }
    case .agentChanged(let provider, let agentSessionID):
      guard policy.shouldRecord(workingDirectory: lastKnownDirectory) else { return }
      // 记住最近一次归属；provider 可能在同一 Session 内换人，补录以最后一次为准。
      if let provider, let parsed = AgentProvider(rawValue: provider) { agentProvider = parsed }
      if let agentSessionID, !agentSessionID.isEmpty { agentSessionIdentifier = agentSessionID }
      // Agent 关联本身就是有意义活动：即便零 shell 命令也值得留下这个 Session。
      await materializeIfNeeded()
      await emit(
        kind: .agentStateChanged,
        command: provider,
        workingDirectory: lastKnownDirectory,
        source: .agentHook
      )
      await writer.record(
        .updateSessionAgent(
          sessionID: sessionID, provider: provider, agentSessionID: agentSessionID))
    case .ended(let exitCode):
      // 未配对的输出没有可靠的命令归属，无法判定是否被排除——直接丢弃。
      pendingCapturedOutput = nil
      pendingCommandExcluded = nil
      // 从未物化 = 空会话：缓存的开场事件连同描述符一起丢弃，库里零痕迹。
      guard materialized else {
        bufferedEvents = []
        return
      }
      await emit(
        kind: .sessionEnded,
        workingDirectory: lastKnownDirectory,
        exitStatus: exitCode,
        source: .terminal
      )
      await writer.record(
        .endSession(sessionID: sessionID, exitCode: exitCode, endedAt: Date()))
    }
  }

  /// 记录一条事件；命令文本入库前脱敏。
  ///
  /// 刻意不在这里更新 `lastKnownDirectory`：git 快照是异步回来的，它携带的目录是
  /// 采集**当时**的 cwd，落后于终端现况，写回去会把后续事件的归属带偏。
  /// cwd 只由 `.commandStarted` 这类有明确时序的输入推进。
  private func emit(
    kind: MemoryEventKind,
    command: String? = nil,
    workingDirectory: String,
    exitStatus: Int? = nil,
    outputExcerpt: String? = nil,
    source: MemoryEventSource,
    payload: String? = nil
  ) async {
    sequence += 1
    let redactedCommand = command.map { AgentContextRedactor.redact($0).value }
    let event = RecordedEvent(
      sessionID: sessionID,
      sequence: sequence,
      timestamp: Date(),
      kind: kind,
      command: redactedCommand,
      workingDirectory: workingDirectory,
      exitStatus: exitStatus,
      outputExcerpt: outputExcerpt,
      source: source,
      payload: payload
    )
    if materialized {
      await writer.record(.appendEvent(event))
    } else if bufferedEvents.count < 32 {
      // 物化前只缓存不落库；空会话结束时这些缓存被整体丢弃。
      bufferedEvents.append(event)
    }
  }

  /// 会话是否真的落过库。空会话必须在这里拦住收尾链：提炼会经 writer 读事件，
  /// 惰性开库会为一个不存在的会话创建数据库文件，破坏「零痕迹」。
  func didMaterialize() -> Bool { materialized }

  /// Session 结束后做 transcript 补录所需的参数。没有确认的 Agent 归属时返回 nil，
  /// 补录一律跳过——绝不靠猜测去读 provider 的本地记录文件。
  func transcriptIngestionContext()
    -> (provider: AgentProvider, agentSessionID: String, projectPath: String)?
  {
    guard let agentProvider, let agentSessionIdentifier, !agentSessionIdentifier.isEmpty else {
      return nil
    }
    return (agentProvider, agentSessionIdentifier, projectPath)
  }

  /// 把一段闭合输出与它的命令排除判定配对。
  ///
  /// D 标记既在 PTY 字节里（触发 capture 闭合）也触发主线程的 commandFinished，
  /// 两者到达顺序不确定；谁先到就等谁，配上了才决定写不写。
  private func resolveOutput(_ captured: ShellCapturedCommandOutput) async {
    if let excluded = pendingCommandExcluded {
      pendingCommandExcluded = nil
      if !excluded { await persistOutput(captured) }
    } else {
      pendingCapturedOutput = captured
    }
  }

  /// 输出正文落 artifact 文件，events 表只留有界摘录供 FTS。
  private func persistOutput(_ captured: ShellCapturedCommandOutput) async {
    let visible = ANSICleaner.visibleText(from: captured.text)
    let redacted = AgentContextRedactor.redact(visible).value
    guard let excerpt = MemoryOutputExcerpt.tail(of: redacted) else { return }
    sequence += 1
    let seq = sequence
    let artifact = artifacts.write(sessionID: sessionID, sequence: seq, text: redacted)
    await writer.record(
      .appendEvent(
        RecordedEvent(
          sessionID: sessionID,
          sequence: seq,
          timestamp: Date(),
          kind: .commandOutput,
          workingDirectory: lastKnownDirectory,
          exitStatus: captured.exitStatus,
          outputExcerpt: excerpt,
          source: .shellIntegration,
          payload: artifact.map { "{\"artifact\":\"\($0.relativePath)\"}" }
        )))
    guard let artifact else { return }
    await writer.record(.appendArtifact(artifact))
    // 配额裁剪要遍历全表并删文件，按累计字节限频，不是每条输出都扫。
    if quotaTracker.shouldSweep(afterWriting: artifact.byteCount) {
      await writer.enforceArtifactQuota(maximumBytes: ArtifactQuotaTracker.defaultQuotaBytes)
    }
  }

  /// 触发一次 git 状态采集。子进程调用放在 detached task 上：在管线 actor 内 await
  /// 子进程会让后续 PTY 分片排在数秒的 git 之后（actor 重入下还会打乱事件顺序）。
  private func scheduleGitSnapshot(force: Bool) {
    let directory = lastKnownDirectory
    guard policy.shouldRecord(workingDirectory: directory) else { return }
    if force {
      _ = gitThrottle.allow()
    } else {
      guard gitThrottle.allow() else { return }
    }
    let inspect = inspectGit
    Task.detached(priority: .utility) { [self] in
      let summary = await inspect(directory)
      await commitGitSnapshot(summary, directory: directory)
    }
  }

  /// 把采集结果写成 `.gitStateSnapshot` 事件并同步到 sessions 行。
  private func commitGitSnapshot(_ summary: GitStatusSummary, directory: String) async {
    let payload = GitSnapshotPayload(
      branch: summary.branch,
      commit: summary.objectID,
      dirtyFileCount: summary.changes.count
    )
    guard payload.isMeaningful else { return }
    await emit(
      kind: .gitStateSnapshot,
      workingDirectory: directory,
      source: .git,
      payload: payload.jsonString()
    )
    // 快照只会由物化或失败命令触发，此处 materialized 恒真；守卫是防御——
    // 未物化时 sessions 行不存在，UPDATE 是无意义空转。
    guard materialized else { return }
    // commitBefore 由 SQL 的 coalesce 保护：只有首次快照会写入，后续只更新 after。
    await writer.record(
      .updateSessionGit(
        sessionID: sessionID,
        branch: payload.branch,
        commitBefore: payload.commit,
        commitAfter: payload.commit
      ))
  }
}

/// Session Recording 的装配与路由中心：进程内单例，持有唯一 EventWriter，
/// 按 Session 维护事件管线。所有公开方法都在 MainActor 上快速返回。
@MainActor
final class SessionRecordingService: TerminalEventRecording {
  /// 进程级单例：所有窗口/Pane 共享同一 EventWriter（单写者约定）。
  static let shared = SessionRecordingService()

  /// 一个活跃 Session 的运行态。descriptor 不在这里保存——提炼阶段从库里回读，
  /// 那份才带得上 agent provider 与 git 分支。
  private struct SessionState {
    let continuation: AsyncStream<SessionPipelineInput>.Continuation
    /// 临时隐身期间管线保持存活但不接收任何输入——零落盘发生在入队之前，
    /// 而不是靠管线内部丢弃。管线不重建，恢复后事件序号才能接着往下走。
    var isSuspended = false
  }

  /// Session 启动参数。Session 若在隐身状态下启动就没有管线，退出隐身时要靠这份
  /// 记录补建；surface 重启复用同一 UUID 时也靠它保住原始启动时间。
  private struct StartInfo {
    let projectPath: String
    let shell: String?
    let startedAt: Date
  }

  private let writer: EventWriter
  private let artifacts: TranscriptArtifactStore
  private let defaults: UserDefaults
  private let resolveProject: @Sendable (String) async -> ProjectIdentity?
  private let inspectGit: @Sendable (String) async -> GitStatusSummary
  private var states: [UUID: SessionState] = [:]
  private var startInfo: [UUID: StartInfo] = [:]
  /// Per-pane 临时隐身集合。只活在内存里：隐身状态本身不应留下痕迹。
  private var incognitoSessions: Set<UUID> = []
  /// 管线消费任务。测试用它等待排空；任务自行完成后从表里摘除，不会无界增长。
  /// 带 generation 是为了让摘除只命中自己那一代——同一 Session 可能重建过管线。
  private var pipelineTasks: [UUID: (generation: Int, task: Task<Void, Never>)] = [:]
  private var pipelineGeneration = 0
  /// transcript 补录前的等待时长。
  ///
  /// provider 把自己的记录刷盘可能比 PTY 退出晚几百毫秒到一两秒，立刻补录会漏掉
  /// 最后几条工具调用。补录是幂等的（已有 transcript 事件就整体跳过），所以
  /// **不能**靠「先补一次、几秒后再补一次」兜底——第一次写了部分内容之后，
  /// 第二次会直接返回，尾部就永久丢了。只能等够再补一次。
  /// Session 已经结束，没有人在等这条路径，用完整性换延迟是划算的。
  private let transcriptIngestionDelay: Duration

  /// 默认取 `MemoryStoreAccess` 的进程级单写者。**不要**在这里新建 `EventWriter`：
  /// Memory 管理 UI 与 Task 编辑也写同一个库，第二个写连接会造成锁竞争与写丢失。
  /// `writer` 与 `location` 可注入只为测试隔离，生产装配一律用默认值。
  init(
    location: MemoryStoreLocation = MemoryStoreAccess.location,
    writer: EventWriter = MemoryStoreAccess.writer,
    defaults: UserDefaults = .standard,
    resolveProject: @escaping @Sendable (String) async -> ProjectIdentity? = {
      await ProjectResolutionService.shared.project(for: $0)
    },
    inspectGit: @escaping @Sendable (String) async -> GitStatusSummary = {
      await WorkspaceInspectionService.inspectGit(directory: $0)
    },
    transcriptIngestionDelay: Duration = .seconds(2)
  ) {
    self.writer = writer
    artifacts = TranscriptArtifactStore(location: location)
    self.defaults = defaults
    self.transcriptIngestionDelay = transcriptIngestionDelay
    self.resolveProject = resolveProject
    self.inspectGit = inspectGit
  }

  // MARK: - 记录状态

  /// 全局策略叠加本 Session 的临时隐身。off / incognito 都是零落盘。
  private func effectivePolicy(for id: UUID) -> RecordingPolicy {
    AppPreferences.memoryRecordingPolicy(from: defaults)
      .overriddenByIncognito(incognitoSessions.contains(id))
  }

  func recordingMode(for id: UUID) -> RecordingMode {
    effectivePolicy(for: id).mode
  }

  func isRecording(id: UUID) -> Bool {
    guard let state = states[id] else { return false }
    return !state.isSuspended
  }

  /// 切换本 Session 的临时隐身。
  ///
  /// 开启后所有回调在 MainActor 上直接返回，连字节都不入队（零落盘发生在源头）。
  /// 关闭后同一条管线继续工作，事件序号接着往下走；若隐身期间根本没建过管线
  /// （Session 一开始就在隐身里启动），这时才用记住的启动参数补建。
  func setIncognito(_ incognito: Bool, for id: UUID) {
    let changed =
      incognito ? incognitoSessions.insert(id).inserted : incognitoSessions.remove(id) != nil
    guard changed else { return }
    if states[id] != nil {
      states[id]?.isSuspended = incognito
    } else if !incognito, let info = startInfo[id] {
      start(id: id, info: info)
    }
  }

  // MARK: - TerminalEventRecording

  func sessionStarted(id: UUID, projectPath: String, shell: String?) {
    // surface 重启会复用同一 Session UUID 再次回调；启动时间保留首次值。
    let info = startInfo[id]
      ?? StartInfo(projectPath: projectPath, shell: shell, startedAt: Date())
    startInfo[id] = info
    guard states[id] == nil else { return }
    start(id: id, info: info)
  }

  func commandStarted(id: UUID, command: String?, workingDirectory: String) {
    activeContinuation(for: id)?.yield(
      .commandStarted(command: command, workingDirectory: workingDirectory))
  }

  func commandFinished(id: UUID, command: String?, exitStatus: Int?) {
    activeContinuation(for: id)?.yield(
      .commandFinished(command: command, exitStatus: exitStatus))
  }

  func agentChanged(id: UUID, provider: String?, agentSessionID: String?) {
    activeContinuation(for: id)?.yield(
      .agentChanged(provider: provider, agentSessionID: agentSessionID))
  }

  func receivePTYOutput(id: UUID, bytes: ArraySlice<UInt8>) {
    // 主线程在这里只做一次字节拷贝 + 入队，解析与脱敏都在管线 actor 上。
    activeContinuation(for: id)?.yield(.output(Array(bytes)))
  }

  func sessionEnded(id: UUID, exitCode: Int32?) {
    startInfo[id] = nil
    incognitoSessions.remove(id)
    guard let state = states.removeValue(forKey: id) else { return }
    // 结束事件即便在隐身中也要投递：已物化的 Session 需要它闭合状态，否则行会
    // 永远停在 'active'；未物化的空会话由管线自行丢弃，这条事件不含任何新内容。
    state.continuation.yield(.ended(exitCode: exitCode.map(Int.init)))
    state.continuation.finish()
  }

  /// 测试用：等待某个 Session 的管线（含提炼）跑完。生产路径不调用。
  func waitForCompletion(id: UUID) async {
    await pipelineTasks[id]?.task.value
  }

  /// 取得可写入的入队口。隐身中的 Session 在这里就返回 nil，调用点不做任何拷贝。
  private func activeContinuation(for id: UUID)
    -> AsyncStream<SessionPipelineInput>.Continuation?
  {
    guard let state = states[id], !state.isSuspended else { return nil }
    return state.continuation
  }

  // MARK: - 管线生命周期

  /// 建立一条 Session 管线。策略不允许落盘时直接返回，连 AsyncStream 都不创建。
  private func start(id: UUID, info: StartInfo) {
    let policy = effectivePolicy(for: id)
    guard policy.writesToDisk,
      policy.shouldRecord(workingDirectory: info.projectPath)
    else { return }

    let pipeline = SessionEventPipeline(
      sessionID: id,
      shell: info.shell,
      startedAt: info.startedAt,
      startDirectory: info.projectPath,
      policy: policy,
      writer: writer,
      artifacts: artifacts,
      resolveProject: resolveProject,
      inspectGit: inspectGit
    )
    // bufferingNewest 让洪峰时丢最旧分片——输出摘录允许缺损，终端延迟不允许。
    var continuation: AsyncStream<SessionPipelineInput>.Continuation!
    let stream = AsyncStream<SessionPipelineInput>(bufferingPolicy: .bufferingNewest(256)) {
      continuation = $0
    }
    let writer = writer
    let delay = transcriptIngestionDelay
    let task = Task.detached(priority: .utility) {
      // bootstrap 期间到达的字节留在流缓冲里，不会因为建表还没完成而丢失。
      await pipeline.bootstrap()
      var completed = false
      for await input in stream {
        if case .ended = input { completed = true }
        await pipeline.handle(input)
      }
      // 只有真正结束**且落过库**的 Session 才走收尾链；因切换隐身而拆管线
      // 不产生半截 Memory，空会话不触发任何读写（惰性开库也算痕迹）。
      guard completed, await pipeline.didMaterialize() else { return }
      // transcript 补录必须排在提炼**之前**：补录进来的工具调用与文件读写
      // 是 Session Memory 的一部分，晚一步就进不了草稿。补录自身幂等且静默降级。
      if let context = await pipeline.transcriptIngestionContext() {
        try? await Task.sleep(for: delay)
        await AgentTranscriptIngestion.ingest(
          sessionID: id,
          provider: context.provider,
          agentSessionID: context.agentSessionID,
          projectPath: context.projectPath,
          writer: writer
        )
      }
      await Self.extractMemory(sessionID: id, writer: writer)
    }
    pipelineGeneration += 1
    let generation = pipelineGeneration
    states[id] = SessionState(continuation: continuation)
    pipelineTasks[id] = (generation, task)
    // 任务完成后自行摘除，避免长时间运行的进程无界累积已结束的 Task 句柄。
    Task { [weak self] in
      await task.value
      guard let self, self.pipelineTasks[id]?.generation == generation else { return }
      self.pipelineTasks[id] = nil
    }
  }

  /// Session 结束后的 Memory 提炼。走 `MemoryExtraction.provider` seam，
  /// 装配层可以换成 CLI Agent 增强实现；失败只是没有 Memory，Raw Event 已经落库。
  private static func extractMemory(sessionID: UUID, writer: EventWriter) async {
    let events = await writer.recordedEvents(sessionID: sessionID)
    guard !events.isEmpty else { return }
    guard let descriptor = await writer.sessionDescriptor(sessionID: sessionID) else { return }
    guard
      let extracted = await MemoryExtraction.provider.extract(
        session: descriptor, events: events)
    else { return }
    await writer.record(
      .insertMemoryRecord(extracted.memory, sources: extracted.sources))
    await writer.flush()
    // Session 收尾是保留策略的天然时机：低频（每次会话一次）、已在后台、
    // 且刚写完新数据正是裁旧数据的时候。Raw events 超龄裁剪，memories 长存。
    await writer.enforceEventRetention()
  }
}
