import AsterCore
import Combine
import Foundation

/// 机器侧栏的一行（P4.3）。
///
/// Local 与远端配置共用同一行模型，但 Local 永远排在最上且不可禁用/移除：它是
/// 「本机」这一事实，不是一份可以删掉的配置。
struct MachineFleetRow: Equatable, Identifiable {
  var id: UUID
  var label: String
  /// 该配置绑定的命名会话名。侧栏必须显示它，否则用户无法区分同一主机的两个配置。
  var sessionName: String
  /// 原始 SSH target；Local 为 nil。
  var sshTarget: String?
  var isLocal: Bool
  var enabled: Bool
  var state: SessionConnectionState
  var lastUpdatedAt: Date?
  var lastError: String?
  /// 远端探测到的已安装 Agent CLI；nil 表示尚未探测（Local 恒为 nil，本机 Agent 走设置页）。
  var agents: [RemoteAgentCatalogEntry]? = nil

  /// 侧栏副标题：会话名 +（远端时）target。不显示 PID 或 hostname 作为身份。
  var subtitle: String {
    guard let sshTarget else { return sessionName }
    return "\(sshTarget) · \(sessionName)"
  }
}

/// 添加机器时需要用户显式确认的内容（§4.1 第 2 条）。
///
/// 「需要安装」和「运行中服务不兼容」都会影响远端进程，必须先把**目标、版本与
/// 进程影响**摆出来再让用户点确认；取消什么都不留下。
struct MachineSetupConfirmation: Equatable {
  enum Kind: Equatable {
    /// 远端没有兼容二进制，需要安装。
    case installation
    /// 运行中服务协议主版本不兼容，需要显式替换。
    case incompatibleServer
    /// 使用 `ASTER_REMOTE_BINARY` 指定的开发产物，必须显式接受。
    case developmentArtifact
    /// 用户主动更新远端服务：停止运行中的服务、安装新版本并重启。
    case serviceReplacement
  }

  var kind: Kind
  /// 目标机器（原始 target 文本）。
  var target: String
  /// 目标平台，例如 `linux/x86_64`。
  var platform: String
  /// 将要安装或已在运行的版本描述。
  var version: String
  /// 进程影响说明。必须明确写出「会不会停止正在运行的任务」。
  var processImpact: String
  /// 详细原因（来自设置事务）。
  var reason: String
}

/// 添加 / 更新机器的结果。
enum MachineSetupResult: Equatable {
  case added(MachineProfile)
  /// 远端服务已替换为新版本，配置里的运行时路径已更新。
  case updated(MachineProfile)
  /// 远端已经是本机产物的同一份二进制，什么也没动。
  case upToDate(String)
  /// 用户在确认对话框里取消：不保存任何配置。
  case cancelled
  case failed(String)
}

/// 一台机器上注册表动作所需的客户端与端点。
///
/// 之所以把两者绑在一起返回：`ManagedSessionClient` 的注册表扩展要求端点与客户端
/// 来自同一条传输（本机 / SSH），拆开传很容易配错组合。
struct MachineRegistryAccess: Sendable {
  var client: any ManagedSessionClient
  var endpoint: ManagedRegistryEndpoint
}

/// 机器编排的服务依赖。真实实现走 SSH，测试注入替身，避免在单测里连网络。
///
/// `runSetup` 是 `async` 且**不绑定 MainActor**：它是一串网络往返，放在主线程同步
/// 等待会让整个界面随远端延迟卡住，与 §4.1 第 1 条直接冲突。
protocol MachineFleetServices: Sendable {
  /// 执行完整的远端设置事务（P3 已交付的 `RemoteMachineSetup.run`）。
  func runSetup(rawTarget: String, label: String, sessionName: String, profileID: UUID) async throws
    -> RemoteSetupOutcome
  /// 为一台机器构造命名会话注册表的访问入口。
  func registry(for profile: MachineProfile) throws -> MachineRegistryAccess
  /// 本机可安装到该平台的服务产物；没有返回 nil，有但不可用（平台不符、清单坏）抛错。
  func serviceArtifact(for platform: RemotePlatform) throws -> RemoteServiceArtifact?
  /// 把产物安装到远端私有目录（P3.4）。不停止任何运行中的服务。
  func installService(
    rawTarget: String, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
    acceptDevelopmentArtifact: Bool
  ) async throws -> RemoteInstallOutcome
  /// 显式替换运行中的服务（§7）：列出影响 → 停止 → 安装 → 用新二进制重启同一命名会话。
  func replaceService(
    profile: MachineProfile, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
    acceptDevelopmentArtifact: Bool
  ) async throws -> RemoteReplacementOutcome
  /// 远端某个文件的 SHA256（小写 hex），用于判断是否已是同一份二进制；拿不到返回 nil。
  func remoteBinaryDigest(rawTarget: String, path: String) async throws -> String?
  /// 远端 Agent 集成：`install` 为 nil 只探测；否则上传 hook 脚本并为这些 provider 合并配置。
  func agentIntegration(for profile: MachineProfile, install: [AgentProvider]?) async throws
    -> RemoteAgentIntegrationReport
  /// 远端已安装的 Agent CLI 清单（一次 SSH 往返）。「新建远端 Agent」的选择列表来源。
  func remoteAgentCatalog(for profile: MachineProfile) async throws -> RemoteAgentProbeResult
}

/// 「新建远端 Agent」列表里的一项。
struct RemoteAgentCatalogEntry: Equatable, Sendable {
  var provider: AgentProvider
  var version: String?
}

/// 安装/替换的默认实现：不提供产物、不执行任何远端写动作。
/// 只关心连接与注册表的测试替身不必逐个实现这些方法。
extension MachineFleetServices {
  func serviceArtifact(for platform: RemotePlatform) throws -> RemoteServiceArtifact? { nil }
  func installService(
    rawTarget: String, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
    acceptDevelopmentArtifact: Bool
  ) async throws -> RemoteInstallOutcome {
    throw ManagedSessionError.runtimeUnavailable(L("本服务实现不支持远端安装。"))
  }
  func replaceService(
    profile: MachineProfile, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
    acceptDevelopmentArtifact: Bool
  ) async throws -> RemoteReplacementOutcome {
    throw ManagedSessionError.runtimeUnavailable(L("本服务实现不支持远端服务替换。"))
  }
  func remoteBinaryDigest(rawTarget: String, path: String) async throws -> String? { nil }
  func agentIntegration(for profile: MachineProfile, install: [AgentProvider]?) async throws
    -> RemoteAgentIntegrationReport
  {
    throw ManagedSessionError.runtimeUnavailable(L("本服务实现不支持远端 Agent 集成。"))
  }
  func remoteAgentCatalog(for profile: MachineProfile) async throws -> RemoteAgentProbeResult {
    throw ManagedSessionError.runtimeUnavailable(L("本服务实现不支持远端 Agent 探测。"))
  }
}

/// 远端 Agent 集成动作的结果。
enum AgentIntegrationResult: Equatable {
  /// 已安装（或全部早已就位）；报告里有每个 provider 的最终状态与失败原因。
  case installed(RemoteAgentIntegrationReport)
  /// 远端没有任何可集成的 Agent CLI；文案说明发现了什么。
  case nothingToInstall(String)
  case cancelled
  case failed(String)
}

/// 机器与 Local 的统一编排（P4.3 / P4.4 / P4.5 / P4.7）。
///
/// 它是 AsterCore 的 `MachineProfileStore` + `MachineConnectionSupervisor` 之上的
/// **MainActor 门面**：领域规则（原子写、整份校验、差异、退避、代次、活动机器解析）
/// 全部由 Core 提供，这里只负责把它们接到 AppKit 侧栏与控制协议上。
///
/// 关键时序（§4.1 第 1 条）：`start()` 立即把 Local 放进列表并让界面可用，
/// enabled 的远端机器由编排器在各自独立的 Task 里连接，任何一台失联都不阻塞其它机器。
@MainActor
final class MachineFleetModel: ObservableObject {
  /// 侧栏行。Local 恒在第一位。
  @Published private(set) var rows: [MachineFleetRow] = []
  /// 当前活动机器。被禁用/移除时回到 Local。
  @Published private(set) var activeMachineID: UUID = MachineProfile.localProfileID
  /// 配置文件损坏时的可恢复错误；非 nil 时界面显示它，但保留最后一份有效配置。
  @Published private(set) var configurationError: String?
  /// Local 不可用时的明确错误态。当前活动机器回落到 Local 后必须展示它，
  /// 而不是自动跳到别的远端（§4.1 第 7 条）。
  @Published private(set) var localFailureReason: String?

  /// 进程级共享实例。机器配置是客户端级事实，所有工作区窗口看到同一份列表与连接状态。
  /// 测试替换它以使用私有配置文件，绝不写用户真实配置。
  static var shared: MachineFleetModel = MachineFleetModel(
    store: MachineProfileStore(),
    services: RemoteMachineFleetServices(),
    supervisor: MachineConnectionSupervisor(driver: RemoteMachineConnectionDriver()))

  private let store: MachineProfileStore
  private let services: any MachineFleetServices
  private let supervisor: MachineConnectionSupervisor
  private let localStateProvider: () -> SessionConnectionState
  private let localErrorProvider: () -> String?

  private(set) var profiles: [MachineProfile] = []
  /// 编排器状态的本地缓存；`refreshStatuses()` 从 actor 拉过来后重建行。
  private(set) var statuses: [UUID: MachineConnectionStatus] = [:]
  /// 远端 Agent 清单缓存与已探测过的连接代次：每次连上（新代次）只探一次，不随状态轮询反复 SSH。
  private var agentCatalogs: [UUID: [RemoteAgentCatalogEntry]] = [:]
  private var agentCatalogGenerations: [UUID: UInt64] = [:]
  private var agentCatalogTasks: [UUID: Task<Void, Never>] = [:]
  private var watcher: FileSystemDirectoryWatcher?
  private var statusPollTask: Task<Void, Never>?
  private var hasStarted = false
  /// Local 行的最后更新时间。只在 Local 状态真正变化时推进——每次重建都取当前时间
  /// 会让行内容永远“不相等”，于是每一轮状态轮询都触发一次侧栏整树重建。
  private var localStateStamp = (state: SessionConnectionState.disconnected, at: Date())

  /// 状态轮询间隔。编排器是 actor，界面只能异步取状态；测试把它调小以缩短用例。
  var statusPollInterval: Duration = .milliseconds(400)

  init(
    store: MachineProfileStore,
    services: any MachineFleetServices,
    supervisor: MachineConnectionSupervisor,
    localStateProvider: @escaping () -> SessionConnectionState = {
      ManagedTerminalCoordinatorRegistry.coordinator(forMachine: MachineProfile.localProfileID)
        .connectionState
    },
    localErrorProvider: @escaping () -> String? = {
      ManagedTerminalCoordinatorRegistry.coordinator(forMachine: MachineProfile.localProfileID)
        .lastError
    }
  ) {
    self.store = store
    self.services = services
    self.supervisor = supervisor
    self.localStateProvider = localStateProvider
    self.localErrorProvider = localErrorProvider
    rebuildRows()
  }

  deinit { statusPollTask?.cancel() }

  // MARK: - 生命周期

  /// 启动：先读配置并立即出图，再交给编排器为每台 enabled 机器起独立连接任务。
  ///
  /// 读配置是本地文件 IO（毫秒级），远端连接才是网络往返；两者顺序不能颠倒，
  /// 否则「启动立即展示 Local 和持久化布局」这条会被一台黑洞地址的机器拖垮。
  func start() {
    // 多个工作区窗口共享同一实例；重复调用不能重复建立连接任务。
    guard !hasStarted else { return }
    hasStarted = true
    reloadProfiles()
    startWatching()
    startStatusPolling()
    let launched = profiles
    Task { [supervisor] in
      for profile in launched where profile.enabled { await supervisor.start(profile: profile) }
    }
  }

  /// 停止全部连接任务与监听。禁用/移除单台机器不要用它。
  func stop() {
    statusPollTask?.cancel()
    statusPollTask = nil
    watcher?.stop()
    watcher = nil
    hasStarted = false
    let ids = profiles.map(\.id)
    Task { [supervisor] in
      for id in ids { await supervisor.remove(profileID: id) }
    }
  }

  // MARK: - 配置

  /// 重新读取配置文件，并按 Core 的差异结论决定连接动作。
  ///
  /// 三条分支对应 §4.1 第 7、8 条：损坏保留旧配置与现存连接；重命名只更新显示；
  /// 只有连接相关字段变化才重连。
  func reloadProfiles() {
    do {
      switch try store.load() {
      case .loaded(let loaded):
        if configurationError != nil { configurationError = nil }
        applyProfiles(loaded)
      case .absent:
        // 文件不存在是合法的首次启动状态，不是损坏。
        if configurationError != nil { configurationError = nil }
        applyProfiles([])
      }
    } catch {
      // 保留 `profiles` 与全部现存连接，不做任何断开动作。
      let message = Self.describe(error)
      if configurationError != message { configurationError = message }
      rebuildRows()
    }
  }

  /// 把一份已校验的配置整体应用进来。
  private func applyProfiles(_ loaded: [MachineProfile]) {
    let changes = MachineProfileStore.diff(old: profiles, new: loaded)
    let previous = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    profiles = loaded
    let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })

    // 重命名（只有 label 变化）不在 `changes` 里，因此这里不会触发任何重连动作，
    // 只把新标签同步给编排器用于诊断输出。
    for profile in loaded where previous[profile.id] != nil && previous[profile.id]?.label != profile.label {
      Task { [supervisor] in await supervisor.rename(profileID: profile.id, label: profile.label) }
    }

    for change in changes {
      switch change {
      case .removed(let id):
        Task { [supervisor] in await supervisor.remove(profileID: id) }
        statuses.removeValue(forKey: id)
        resolveActiveMachine(after: id)
      case .added(let id), .connectionChanged(let id), .enabledChanged(let id):
        guard let profile = byID[id] else { continue }
        if profile.enabled {
          Task { [supervisor] in await supervisor.start(profile: profile) }
        } else {
          Task { [supervisor] in await supervisor.disable(profileID: id) }
          resolveActiveMachine(after: id)
        }
      }
    }
    if !loaded.contains(where: { $0.id == activeMachineID }) {
      activeMachineID = MachineProfile.localProfileID
    }
    rebuildRows()
  }

  /// 监听配置文件所在目录的外部变更（P4.5）。
  ///
  /// 监听目录而不是文件：原子写会 rename 掉旧 inode，盯着文件的监听源在第一次保存后
  /// 就失效了。事件只表示「可能变化」，一律整份重读。
  private func startWatching() {
    guard watcher == nil else { return }
    let directory = store.fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let watcher = FileSystemDirectoryWatcher(directory: directory)
    try? watcher.start { [weak self] in self?.reloadProfiles() }
    self.watcher = watcher
  }

  /// 轮询编排器状态。编排器是 actor，界面只能异步取值。
  private func startStatusPolling() {
    statusPollTask?.cancel()
    statusPollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshStatuses()
        guard let interval = self?.statusPollInterval else { return }
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// 从编排器取一次全部状态并重建行。
  func refreshStatuses() async {
    let all = await supervisor.allStatuses()
    statuses = Dictionary(uniqueKeysWithValues: all.map { ($0.profileID, $0) })
    rebuildRows()
    // 机器刚连上（新代次）时探一次远端 Agent 清单，侧栏行才能直接显示"这台机器有哪些 Agent"。
    for status in all where status.state == .online {
      guard agentCatalogGenerations[status.profileID] != status.generation,
        agentCatalogTasks[status.profileID] == nil
      else { continue }
      agentCatalogGenerations[status.profileID] = status.generation
      scheduleAgentCatalogRefresh(status.profileID)
    }
  }

  /// 后台探测一台机器的 Agent 清单并写回行模型。失败只清掉本次探测记录，下次连上再试。
  private func scheduleAgentCatalogRefresh(_ id: UUID) {
    agentCatalogTasks[id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.agentCatalogTasks[id] = nil }
      do {
        _ = try await self.remoteAgentCatalog(id)
      } catch {
        self.agentCatalogGenerations.removeValue(forKey: id)
      }
    }
  }

  /// 手动重新探测一台机器的 Agent 清单（右键菜单）。
  func refreshAgentCatalog(_ id: UUID) async throws -> [RemoteAgentCatalogEntry] {
    try await remoteAgentCatalog(id)
  }

  // MARK: - 动作

  /// 添加机器（P4.3 / §4.1 第 2 条）。
  ///
  /// 顺序固定：输入解析 → SSH 验证 → 平台/二进制探测 → 服务握手 → 命名会话启动。
  /// 只有 `RemoteMachineSetup` 返回 `.ready` 才写配置文件；需要安装或需要接受开发
  /// 产物时先经 `confirm` 让用户看到目标、版本与进程影响，取消即什么都不保存。
  func addMachine(
    label: String,
    sshTarget: String,
    sessionName: String,
    confirm: (MachineSetupConfirmation) -> Bool
  ) async -> MachineSetupResult {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSession = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLabel.isEmpty else { return .failed(L("机器标签不能为空。")) }
    guard !trimmedSession.isEmpty else { return .failed(L("必须指定要绑定的命名会话。")) }

    let profileID = UUID()
    let outcome: RemoteSetupOutcome
    switch await setupOutcome(
      rawTarget: sshTarget, label: trimmedLabel, sessionName: trimmedSession, profileID: profileID)
    {
    case .success(let value): outcome = value
    case .failure(let failure): return .failed(failure.message)
    }

    switch outcome {
    case .ready(let profile, _, _):
      return await saveNewProfile(profile)

    case .installationRequired(let report, let reason):
      // 安装只写入新文件、不碰运行中的进程；装完再走一遍完整设置事务，配置仍然只在
      // `.ready` 时产出。用户取消时磁盘上什么也没写。
      let artifact: RemoteServiceArtifact
      switch locateArtifact(for: report.platform) {
      case .found(let found): artifact = found
      case .unavailable(let message): return .failed(message)
      }
      let accepted = confirm(
        MachineSetupConfirmation(
          kind: artifact.manifest.artifactKind == .developmentBuild
            ? .developmentArtifact : .installation,
          target: sshTarget,
          platform: "\(report.platform.os)/\(report.platform.architecture)",
          version: artifact.manifest.displaySummary,
          processImpact: L("安装只写入新的二进制文件，不会停止远端正在运行的任何进程。"),
          reason: reason))
      guard accepted else { return .cancelled }
      do {
        _ = try await services.installService(
          rawTarget: sshTarget, report: report, artifact: artifact,
          acceptDevelopmentArtifact: accepted)
      } catch {
        return .failed(L("安装失败：\(RemoteSetupDescription.text(for: error))"))
      }
      return await completeSetup(
        rawTarget: sshTarget, label: trimmedLabel, sessionName: trimmedSession,
        profileID: profileID)

    case .incompatibleServerRunning(let report, let reason):
      // 运行中服务主版本不兼容：只能显式替换。替换后重新走设置事务拿到新服务的身份。
      let artifact: RemoteServiceArtifact
      switch locateArtifact(for: report.platform) {
      case .found(let found): artifact = found
      case .unavailable(let message): return .failed(message)
      }
      let accepted = confirm(
        MachineSetupConfirmation(
          kind: .incompatibleServer,
          target: sshTarget,
          platform: "\(report.platform.os)/\(report.platform.architecture)",
          version: report.runningServer?.version ?? report.candidates.first?.releaseVersion ?? L("未知"),
          processImpact: L("替换会停止运行中的服务实例及其全部受管进程。Aster 不会在后台执行它。"),
          reason: reason + "\n" + L("将安装：\(artifact.manifest.displaySummary)")))
      guard accepted else { return .cancelled }
      // 尚未保存的机器没有 profile；用本次设置的 ID、标签与会话名临时构造一份端点信息，
      // 运行时路径取不兼容的那个候选（它就是正在运行的服务）。
      let pending = MachineProfile(
        id: profileID, label: trimmedLabel, sshTarget: sshTarget, sessionName: trimmedSession,
        remoteBinaryPath: report.candidates.first { $0.protocolMajor != nil }?.path)
      do {
        _ = try await services.replaceService(
          profile: pending, report: report, artifact: artifact,
          acceptDevelopmentArtifact: accepted)
      } catch {
        return .failed(L("服务替换失败：\(RemoteSetupDescription.text(for: error))"))
      }
      return await completeSetup(
        rawTarget: sshTarget, label: trimmedLabel, sessionName: trimmedSession,
        profileID: profileID)
    }
  }

  /// 更新一台已保存机器的远端服务：探测 → 找本机产物 → 与远端比对 → 确认 → 替换 → 更新配置。
  ///
  /// 远端已经是同一份二进制（摘要相同）时什么也不做。替换会停止该命名会话里的全部
  /// 受管进程，所以确认文案必须写出受影响的终端数。
  func updateService(
    _ id: UUID, confirm: (MachineSetupConfirmation) -> Bool
  ) async -> MachineSetupResult {
    guard id != MachineProfile.localProfileID else { return .failed(L("Local 的服务随 App 更新。")) }
    guard let profile = profiles.first(where: { $0.id == id }), let target = profile.sshTarget
    else { return .failed(L("机器不存在。")) }

    // 复用设置事务做探测与握手：拿到平台、候选与运行中服务身份。
    let outcome: RemoteSetupOutcome
    switch await setupOutcome(
      rawTarget: target, label: profile.label, sessionName: profile.sessionName,
      profileID: profile.id)
    {
    case .success(let value): outcome = value
    case .failure(let failure): return .failed(failure.message)
    }
    let report: RemoteProbeReport
    let runningBinaryPath: String?
    switch outcome {
    case .ready(let fresh, _, let freshReport):
      report = freshReport
      // 已保存的运行时路径优先：探测按 PATH → 私有安装目录的顺序挑候选，机器上若还留着
      // 旧的 /usr/local/bin/aster-session，新探测会一直指回它，"已是最新"就永远判不出来。
      runningBinaryPath = profile.remoteBinaryPath ?? fresh.remoteBinaryPath
    case .incompatibleServerRunning(let freshReport, _):
      report = freshReport
      runningBinaryPath = freshReport.candidates.first { $0.protocolMajor != nil }?.path
    case .installationRequired(let freshReport, _):
      report = freshReport
      runningBinaryPath = nil
    }

    let artifact: RemoteServiceArtifact
    switch locateArtifact(for: report.platform) {
    case .found(let found): artifact = found
    case .unavailable(let message): return .failed(message)
    }

    // 远端已经在跑同一份二进制：不停服务、不上传。
    if let runningBinaryPath,
      let digest = try? await services.remoteBinaryDigest(rawTarget: target, path: runningBinaryPath),
      digest == artifact.manifest.sha256
    {
      return .upToDate(L("远端服务已是本机的这一份（\(artifact.manifest.displaySummary)），无需更新。"))
    }

    let serviceRunning = report.runningServer != nil
    let affected = serviceRunning ? ((try? await runningTerminalCount(profile)) ?? 0) : 0
    let current = report.candidates.first { $0.path == runningBinaryPath }
    let accepted = confirm(
      MachineSetupConfirmation(
        kind: artifact.manifest.artifactKind == .developmentBuild
          ? .developmentArtifact : .serviceReplacement,
        target: target,
        platform: "\(report.platform.os)/\(report.platform.architecture)",
        version: artifact.manifest.displaySummary,
        processImpact: serviceRunning
          ? L("会停止命名会话「\(profile.sessionName)」的服务及其中 \(String(affected)) 个受管终端，重启后按冷恢复恢复布局。")
          : L("远端当前没有运行中的服务，安装后直接启动。"),
        reason: L("远端当前：\(current?.releaseVersion ?? L("无可用服务")) \(runningBinaryPath ?? "")")))
    guard accepted else { return .cancelled }

    var updated = profile
    do {
      if serviceRunning {
        let replacement = try await services.replaceService(
          profile: profile, report: report, artifact: artifact,
          acceptDevelopmentArtifact: accepted)
        updated.remoteBinaryPath = replacement.installOutcome.installedPath
      } else {
        let install = try await services.installService(
          rawTarget: target, report: report, artifact: artifact,
          acceptDevelopmentArtifact: accepted)
        updated.remoteBinaryPath = install.installedPath
      }
    } catch {
      return .failed(L("服务更新失败：\(RemoteSetupDescription.text(for: error))"))
    }

    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return .failed(L("机器不存在。")) }
    var next = profiles
    next[index] = updated
    do { try store.save(next) } catch { return .failed(L("配置保存失败：\(Self.describe(error))")) }
    profiles = next
    rebuildRows()
    // 新服务是新的 serverID/epoch：丢掉按旧二进制路径缓存的协调器，重新建立连接。
    ManagedTerminalCoordinatorRegistry.reset(machineProfileID: id)
    await supervisor.remove(profileID: id)
    if updated.enabled { await supervisor.start(profile: updated) }
    await refreshStatuses()
    return .updated(updated)
  }

  /// 远端 Agent 集成：探测 → 确认（列出会改动的远端配置）→ 上传 hook 并合并配置。
  ///
  /// 只对远端已装且有受管集成的 provider 动手；只有屏幕检测的 CLI 原样运行不伪造状态。
  /// 已全部就位时不弹确认直接返回，供添加机器后的自动调用静默通过。
  func configureAgentIntegration(
    _ id: UUID, confirm: (RemoteAgentIntegrationReport) -> Bool
  ) async -> AgentIntegrationResult {
    guard id != MachineProfile.localProfileID else {
      return .failed(L("本机 Agent 集成请在「设置 ▸ 智能体」里安装。"))
    }
    guard let profile = profiles.first(where: { $0.id == id }) else { return .failed(L("机器不存在。")) }
    let report: RemoteAgentIntegrationReport
    do { report = try await services.agentIntegration(for: profile, install: nil) } catch {
      return .failed(L("远端 Agent 探测失败：\(RemoteSetupDescription.text(for: error))"))
    }
    guard !report.candidates.isEmpty else {
      let screenOnly = report.screenOnly.map { $0.provider.displayName }
      let detail = screenOnly.isEmpty
        ? L("远端 PATH 上没有发现任何已知 Agent CLI。")
        : L("远端只发现 \(screenOnly.joined(separator: "、"))，它们没有 Aster 受管集成，将按普通终端运行并依赖屏幕检测。")
      return .nothingToInstall(detail)
    }
    guard !report.pending.isEmpty else { return .installed(report) }
    guard confirm(report) else { return .cancelled }
    do {
      let installed = try await services.agentIntegration(
        for: profile, install: report.pending.map(\.provider))
      return .installed(installed)
    } catch {
      return .failed(L("远端 Agent 集成安装失败：\(RemoteSetupDescription.text(for: error))"))
    }
  }

  /// 远端已安装的 Agent CLI，按 `AgentProvider.allCases` 顺序。空数组表示远端 PATH 上一个都没有。
  func remoteAgentCatalog(_ id: UUID) async throws -> [RemoteAgentCatalogEntry] {
    guard let profile = profiles.first(where: { $0.id == id }), profile.sshTarget != nil else {
      throw MachineFleetError.machineNotFound
    }
    let probe = try await services.remoteAgentCatalog(for: profile)
    let catalog = AgentProvider.allCases.compactMap { provider -> RemoteAgentCatalogEntry? in
      guard let entry = probe.entries[provider], entry.installed else { return nil }
      return RemoteAgentCatalogEntry(provider: provider, version: entry.version)
    }
    agentCatalogs[id] = catalog
    rebuildRows()
    return catalog
  }

  /// 跑一次设置事务并把两类错误统一成 `RemoteSetupFailure`。
  private func setupOutcome(
    rawTarget: String, label: String, sessionName: String, profileID: UUID
  ) async -> Result<RemoteSetupOutcome, RemoteSetupFailure> {
    do {
      return .success(
        try await services.runSetup(
          rawTarget: rawTarget, label: label, sessionName: sessionName, profileID: profileID))
    } catch let failure as RemoteSetupFailure {
      return .failure(failure)
    } catch {
      return .failure(
        RemoteSetupFailure(
          stage: .sessionPreparation, requiresExplicitSetup: true,
          message: RemoteSetupDescription.text(for: error)))
    }
  }

  /// 安装/替换之后的收尾：再跑一遍完整设置事务，只有 `.ready` 才保存配置。
  /// 到这里还需要安装或替换，说明刚装的二进制没被探测到或仍不兼容，直接报失败，
  /// 不再弹第二次确认。
  private func completeSetup(
    rawTarget: String, label: String, sessionName: String, profileID: UUID
  ) async -> MachineSetupResult {
    switch await setupOutcome(
      rawTarget: rawTarget, label: label, sessionName: sessionName, profileID: profileID)
    {
    case .failure(let failure): return .failed(failure.message)
    case .success(.ready(let profile, _, _)): return await saveNewProfile(profile)
    case .success(.installationRequired(_, let reason)):
      return .failed(L("安装完成后远端仍未发现可用的 aster-session：\(reason)"))
    case .success(.incompatibleServerRunning(_, let reason)):
      return .failed(L("替换完成后远端服务仍不兼容：\(reason)"))
    }
  }

  /// `.ready` 的唯一落盘入口：写配置、进列表、起连接。
  private func saveNewProfile(_ profile: MachineProfile) async -> MachineSetupResult {
    do { try store.save(profiles + [profile]) } catch {
      return .failed(L("配置保存失败：\(Self.describe(error))"))
    }
    profiles.append(profile)
    rebuildRows()
    await supervisor.start(profile: profile)
    await refreshStatuses()
    return .added(profile)
  }

  private enum ArtifactLookup {
    case found(RemoteServiceArtifact)
    case unavailable(String)
  }

  /// 找本机产物；找不到或不可用都转成可直接展示的失败文案。
  private func locateArtifact(for platform: RemotePlatform) -> ArtifactLookup {
    do {
      guard let artifact = try services.serviceArtifact(for: platform) else {
        return .unavailable(
          L("本机没有适用于 \(platform.os)/\(platform.architecture) 的 aster-session 产物。")
            + L("可用 \(RemoteEnvironmentKeys.remoteBinary) 指定自定义构建，或使用内含远端服务产物的正式版 App。"))
      }
      return .found(artifact)
    } catch let error as RemoteServiceArtifactError {
      return .unavailable(error.text)
    } catch {
      return .unavailable(RemoteSetupDescription.text(for: error))
    }
  }

  /// 替换前统计会被停止的受管终端数，只用于确认文案。
  private func runningTerminalCount(_ profile: MachineProfile) async throws -> Int {
    let access = try services.registry(for: profile)
    let endpoint = ManagedSessionEndpoint(
      machineProfileID: profile.id, binaryPath: access.endpoint.binaryPath,
      stateParentPath: access.endpoint.stateParentPath, sessionName: profile.sessionName)
    return try await Task.detached(priority: .userInitiated) {
      try access.client.listTerminals(endpoint).filter { $0.state == .running }.count
    }.value
  }

  /// 重命名（§4.1 第 7 条）：只改标签，不触发重连。
  @discardableResult
  func rename(_ id: UUID, to label: String) -> String? {
    guard id != MachineProfile.localProfileID else { return L("Local 不能重命名。") }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return L("标签不能为空。") }
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return L("机器不存在。") }
    var updated = profiles
    updated[index].label = trimmed
    do { try store.save(updated) } catch { return L("配置保存失败：\(Self.describe(error))") }
    profiles = updated
    // 编排器只更新标签，代次、任务与连接状态全部保持不变。
    Task { [supervisor] in await supervisor.rename(profileID: id, label: trimmed) }
    rebuildRows()
    return nil
  }

  /// 启用/禁用（§4.1 第 7 条）：即使离线也可操作，只断开该配置，不停止远端服务。
  @discardableResult
  func setEnabled(_ id: UUID, _ enabled: Bool) -> String? {
    guard id != MachineProfile.localProfileID else { return L("Local 不能禁用。") }
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return L("机器不存在。") }
    guard profiles[index].enabled != enabled else { return nil }
    var updated = profiles
    updated[index].enabled = enabled
    do { try store.save(updated) } catch { return L("配置保存失败：\(Self.describe(error))") }
    profiles = updated
    let profile = updated[index]
    if enabled {
      Task { [supervisor] in await supervisor.start(profile: profile) }
    } else {
      Task { [supervisor] in await supervisor.disable(profileID: id) }
      statuses[id] = MachineConnectionStatus(
        profileID: id, state: .disabled, generation: statuses[id]?.generation ?? 0,
        lastUpdatedAt: Date())
      resolveActiveMachine(after: id)
    }
    rebuildRows()
    return nil
  }

  /// 移除（§4.1 第 7 条）：离线也能移除；只删配置与本地连接，远端资源全部保留。
  @discardableResult
  func remove(_ id: UUID) -> String? {
    guard id != MachineProfile.localProfileID else { return L("Local 不能移除。") }
    guard profiles.contains(where: { $0.id == id }) else { return L("机器不存在。") }
    let updated = profiles.filter { $0.id != id }
    do { try store.save(updated) } catch { return L("配置删除失败：\(Self.describe(error))") }
    profiles = updated
    statuses.removeValue(forKey: id)
    agentCatalogs.removeValue(forKey: id)
    agentCatalogGenerations.removeValue(forKey: id)
    Task { [supervisor] in await supervisor.remove(profileID: id) }
    resolveActiveMachine(after: id)
    rebuildRows()
    return nil
  }

  /// 切换活动机器。
  ///
  /// 离线机器仍可选中查看缓存结构；输入与导航由 `MachineOfflinePresentation` 禁用。
  /// 已禁用的机器不能成为活动机器：它连结构缓存都不再更新。
  @discardableResult
  func selectMachine(_ id: UUID) -> String? {
    if id == MachineProfile.localProfileID {
      activeMachineID = id
      return nil
    }
    guard let profile = profiles.first(where: { $0.id == id }) else { return L("机器不存在。") }
    guard profile.enabled else { return L("该机器已禁用。") }
    activeMachineID = id
    return nil
  }

  /// 当前活动机器的离线展示模型（P4.7）。
  func presentation(for id: UUID) -> MachineOfflinePresentation {
    if id == MachineProfile.localProfileID {
      // Local 的连接状态由受管协调器提供；它在线即可交互，故障时保留明确错误态。
      let state = localStateProvider()
      return MachineOfflinePresentation.from(
        MachineConnectionStatus(
          profileID: id,
          state: state,
          generation: 0,
          inputAllowed: state == .online,
          lastUpdatedAt: Date(),
          reason: localErrorProvider()))
    }
    guard let status = statuses[id] else {
      return MachineOfflinePresentation.from(
        MachineConnectionStatus(
          profileID: id, state: .disconnected, generation: 0, inputAllowed: false,
          lastUpdatedAt: Date(), reason: L("尚未建立连接。")))
    }
    return MachineOfflinePresentation.from(status)
  }

  /// 禁用或移除一台机器之后重新解析活动机器（P4.7）。
  ///
  /// 规则由 `MachineActivationPolicy` 提供：只有被影响的正是当前活动机器时才回 Local，
  /// 而且**绝不**自动挑另一台远端；Local 自身故障时保留它的明确错误态。
  private func resolveActiveMachine(after affected: UUID) {
    let resolution = MachineActivationPolicy.afterDisableOrRemove(
      activeProfileID: activeMachineID,
      affectedProfileID: affected,
      localFailureReason: localErrorProvider())
    activeMachineID = resolution.activeProfileID
    localFailureReason = resolution.localFailureReason
  }

  /// 为一台机器构造命名会话注册表访问入口。
  func registry(for id: UUID) throws -> MachineRegistryAccess {
    let profile: MachineProfile
    if id == MachineProfile.localProfileID {
      profile = MachineProfile.local()
    } else {
      guard let match = profiles.first(where: { $0.id == id }) else {
        throw MachineFleetError.machineNotFound
      }
      profile = match
    }
    return try services.registry(for: profile)
  }

  /// 列出某台机器上的命名会话。侧栏与 CLI 共用。
  ///
  /// 列表只用于展示与运维；配置本身仍然只绑定一个命名会话，不会隐式汇总全部会话。
  func sessions(onMachine id: UUID) async throws -> [NamedSessionDescriptor] {
    let access = try registry(for: id)
    return try await Task.detached(priority: .userInitiated) {
      try access.client.listSessions(access.endpoint)
    }.value
  }

  /// 按 ID 或标签定位机器。CLI 允许两种写法，但**必须显式给出**，不用「当前选中项」补全。
  func resolve(idOrLabel: String) -> MachineProfile? {
    if idOrLabel.caseInsensitiveCompare("local") == .orderedSame {
      return MachineProfile.local()
    }
    if let uuid = UUID(uuidString: idOrLabel) {
      if uuid == MachineProfile.localProfileID { return MachineProfile.local() }
      return profiles.first { $0.id == uuid }
    }
    let matches = profiles.filter { $0.label == idOrLabel }
    // 标签不保证唯一：多于一个匹配时拒绝，避免写到错误的机器上。
    return matches.count == 1 ? matches[0] : nil
  }

  // MARK: - 行投影

  /// 重建侧栏行。Local 恒在最上，其余按标签排序，保证刷新时不跳动。
  private func rebuildRows() {
    let localState = localStateProvider()
    if localStateStamp.state != localState {
      localStateStamp = (localState, Date())
    }
    var result: [MachineFleetRow] = [
      MachineFleetRow(
        id: MachineProfile.localProfileID,
        label: "Local",
        sessionName: ManagedTerminalCoordinatorRegistry
          .coordinator(forMachine: MachineProfile.localProfileID).endpoint?.sessionName ?? "default",
        sshTarget: nil,
        isLocal: true,
        enabled: true,
        state: localState,
        lastUpdatedAt: localStateStamp.at,
        lastError: localErrorProvider())
    ]
    let sorted = profiles.sorted {
      $0.label.localizedStandardCompare($1.label) == .orderedAscending
    }
    for profile in sorted {
      let status = statuses[profile.id]
      result.append(
        MachineFleetRow(
          id: profile.id,
          label: profile.label,
          sessionName: profile.sessionName,
          sshTarget: profile.sshTarget,
          isLocal: false,
          enabled: profile.enabled,
          state: profile.enabled ? (status?.state ?? .disconnected) : .disabled,
          lastUpdatedAt: status?.lastUpdatedAt,
          lastError: status?.reason,
          agents: agentCatalogs[profile.id]))
    }
    // 内容没变就不写回：`rows` 是 @Published，每次赋值都会让工作区整树刷新，
    // 而状态轮询是高频调用。没有这道判断，侧栏会被每一轮空轮询重建一次，
    // 标签行实例随之被替换（AppKitMigrationTests 的行实例稳定性会因此失败）。
    guard result != rows else { return }
    rows = result
  }

  /// 配置存储错误的展示文案。删除与损坏必须能被分辨。
  static func describe(_ error: any Error) -> String {
    guard let storeError = error as? MachineProfileStoreError else {
      return RemoteSetupDescription.text(for: error)
    }
    switch storeError {
    case .fileMissing(let path): return L("机器配置文件不存在：\(path)")
    case .corrupted(let detail): return L("机器配置文件内容损坏：\(detail)")
    case .invalidProfiles(let reasons): return L("机器配置非法：\(reasons.joined(separator: "；"))")
    case .ioFailure(let detail): return L("机器配置读写失败：\(detail)")
    }
  }
}

/// 机器编排的错误。
enum MachineFleetError: Error, Equatable {
  case machineNotFound
  case localNotRemovable
}

/// 生产环境的服务实现：SSH 传输 + P3 的设置事务。
///
/// 这里只做「把配置翻译成传输参数」这一件事；解析、探测、安装判定全部复用
/// `RemoteMachineSetup`，不在 App 侧复制服务端领域逻辑。
struct RemoteMachineFleetServices: MachineFleetServices {
  private let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  /// 受管运行时的远端二进制路径来源。缺失时设置事务会走探测流程。
  private var explicitBinary: String? { environment[RemoteEnvironmentKeys.remoteBinary] }
  private var localBinary: String? { environment[RemoteEnvironmentKeys.binary] }
  private var stateParent: String? { environment[RemoteEnvironmentKeys.stateDirectory] }

  func runSetup(rawTarget: String, label: String, sessionName: String, profileID: UUID) async throws
    -> RemoteSetupOutcome
  {
    let transport = try makeTransport(rawTarget)
    // 状态目录不再是前置条件：环境变量只作覆盖，缺省由设置事务按远端 $HOME 推导并创建。
    // 模板里的路径只是占位，`ensureSession` 会用最终确定的目录覆盖它。
    let setup = RemoteMachineSetup(
      executor: RemoteSSHSetupExecutor(
        transport: transport,
        endpointTemplate: ManagedSessionEndpoint(
          machineProfileID: profileID,
          binaryPath: explicitBinary ?? "aster-session",
          stateParentPath: stateParent ?? "",
          sessionName: sessionName)),
      explicitRemoteBinaryPath: explicitBinary,
      explicitStateParentPath: stateParent)
    return try setup.run(
      rawTarget: rawTarget, label: label, sessionName: sessionName, profileID: profileID)
  }

  func registry(for profile: MachineProfile) throws -> MachineRegistryAccess {
    guard let rawTarget = profile.sshTarget else {
      guard let stateParent, !stateParent.isEmpty else {
        throw ManagedSessionError.runtimeUnavailable(
          L("未配置 \(RemoteEnvironmentKeys.stateDirectory)，无法访问命名会话注册表。"))
      }
      guard let binary = localBinary, !binary.isEmpty else {
        throw ManagedSessionError.runtimeUnavailable(
          L("未配置 \(RemoteEnvironmentKeys.binary)，无法访问本机命名会话注册表。"))
      }
      return MachineRegistryAccess(
        client: LocalManagedSessionClient(),
        endpoint: ManagedRegistryEndpoint(
          machineProfileID: profile.id, binaryPath: binary, stateParentPath: stateParent))
    }
    let runtime = try RemoteRuntimeLocation.resolve(profile: profile, environment: environment)
    return MachineRegistryAccess(
      client: RemoteManagedSessionClient(transport: try makeTransport(rawTarget)),
      endpoint: ManagedRegistryEndpoint(
        machineProfileID: profile.id, binaryPath: runtime.binaryPath,
        stateParentPath: runtime.stateParentPath))
  }

  /// 产物目录：`ASTER_REMOTE_BINARY` 覆盖优先，否则读 App 包内 `Resources/remote-service/`。
  private var artifactCatalog: RemoteServiceArtifactCatalog {
    RemoteServiceArtifactCatalog(
      bundledDirectory: Bundle.main.resourceURL?.appendingPathComponent(
        RemoteServiceArtifactCatalog.bundledDirectoryName, isDirectory: true),
      environment: environment)
  }

  func serviceArtifact(for platform: RemotePlatform) throws -> RemoteServiceArtifact? {
    try artifactCatalog.artifact(forPlatform: platform.os, architecture: platform.architecture)
  }

  /// 受管发布的签名验证。
  ///
  /// 目前没有正式的发布签名基础设施：`RemoteInstallSignature` 里只有测试密钥对，用它
  /// 给 `managedRelease` 放行等于把测试签名当正式签名。因此这里一律拒绝，打包脚本产出的
  /// 清单也标为 `developmentBuild`，由用户在确认框里显式接受。接入真实发布密钥后替换此处。
  private static let releaseSignatureVerifier: @Sendable (RemoteReleaseManifest) -> Bool = {
    _ in false
  }

  func installService(
    rawTarget: String, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
    acceptDevelopmentArtifact: Bool
  ) async throws -> RemoteInstallOutcome {
    let transport = try makeTransport(rawTarget)
    let executor = RemoteSSHInstallExecutor(transport: transport)
    let plan = RemoteInstallPlan(
      targetDescription: rawTarget,
      homeDirectory: report.platform.homeDirectory,
      manifest: artifact.manifest,
      existingVersion: try await Self.activeInstalledVersion(
        executor: executor, homeDirectory: report.platform.homeDirectory))
    let transaction = RemoteInstallTransaction(
      executor: executor,
      remotePlatform: report.platform.os,
      remoteArchitecture: report.platform.architecture,
      acceptDevelopmentArtifact: acceptDevelopmentArtifact,
      signatureVerifier: Self.releaseSignatureVerifier)
    // 上传与远端复核是阻塞的 SSH 往返，必须离开主线程。
    return try await Task.detached(priority: .userInitiated) {
      try transaction.install(
        plan: plan, manifest: artifact.manifest, localPath: artifact.localPath)
    }.value
  }

  func replaceService(
    profile: MachineProfile, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
    acceptDevelopmentArtifact: Bool
  ) async throws -> RemoteReplacementOutcome {
    guard let rawTarget = profile.sshTarget else { throw MachineFleetError.machineNotFound }
    let transport = try makeTransport(rawTarget)
    // 停止/重启走当前运行中的服务端点；二进制路径优先取配置里的实测值。
    let stateParent = Self.nonEmpty(environment[RemoteEnvironmentKeys.stateDirectory])
      ?? Self.nonEmpty(profile.stateParentPath)
      ?? RemoteHostProbe.privateStateParentPath(homeDirectory: report.platform.homeDirectory)
    guard let stateParent else {
      throw ManagedSessionError.runtimeUnavailable(L("无法确定远端状态目录，无法替换服务。"))
    }
    let currentBinary = Self.nonEmpty(environment[RemoteEnvironmentKeys.remoteBinary])
      ?? Self.nonEmpty(profile.remoteBinaryPath)
      ?? report.candidates.first?.path
      ?? RemoteHostProbe.privateInstallPath(homeDirectory: report.platform.homeDirectory)
    let endpoint = ManagedSessionEndpoint(
      machineProfileID: profile.id, binaryPath: currentBinary,
      stateParentPath: stateParent, sessionName: profile.sessionName)
    let installExecutor = RemoteSSHInstallExecutor(transport: transport)
    let plan = RemoteInstallPlan(
      targetDescription: rawTarget,
      homeDirectory: report.platform.homeDirectory,
      manifest: artifact.manifest,
      existingVersion: try await Self.activeInstalledVersion(
        executor: installExecutor, homeDirectory: report.platform.homeDirectory))
    let transaction = RemoteReplacementTransaction(
      executor: RemoteSSHReplacementExecutor(
        client: RemoteManagedSessionClient(transport: transport), endpoint: endpoint),
      installTransaction: RemoteInstallTransaction(
        executor: installExecutor,
        remotePlatform: report.platform.os,
        remoteArchitecture: report.platform.architecture,
        acceptDevelopmentArtifact: acceptDevelopmentArtifact,
        signatureVerifier: Self.releaseSignatureVerifier))
    return try await Task.detached(priority: .userInitiated) {
      try transaction.replace(
        plan: plan, manifest: artifact.manifest, localPath: artifact.localPath)
    }.value
  }

  func agentIntegration(for profile: MachineProfile, install: [AgentProvider]?) async throws
    -> RemoteAgentIntegrationReport
  {
    guard let rawTarget = profile.sshTarget else { throw MachineFleetError.machineNotFound }
    guard
      let script = AsterResourceLocations.resourcesDirectory(bundle: .main, fileManager: .default)?
        .appendingPathComponent("agent-integration/aster-agent-hook.sh"),
      FileManager.default.isReadableFile(atPath: script.path)
    else { throw AgentSetupServiceError.integrationResourceUnavailable }
    let installer = RemoteAgentIntegrationInstaller(
      transport: try makeTransport(rawTarget), localHookScriptURL: script)
    // 探测与安装都是多次阻塞的 SSH 往返，必须离开主线程。
    return try await Task.detached(priority: .userInitiated) {
      if let install { return try installer.install(providers: install) }
      return try installer.inspect()
    }.value
  }

  func remoteAgentCatalog(for profile: MachineProfile) async throws -> RemoteAgentProbeResult {
    guard let rawTarget = profile.sshTarget else { throw MachineFleetError.machineNotFound }
    let transport = try makeTransport(rawTarget)
    return try await Task.detached(priority: .userInitiated) {
      let result = try RemoteSSHProcessRunner().run(
        arguments: transport.sshArguments(remoteCommand: RemoteAgentProbe.probeCommand()),
        timeout: 30)
      guard let probe = RemoteAgentProbe.parse(result.standardOutput) else {
        throw ManagedSessionError.malformedReply(L("Agent 探测输出缺少标记"))
      }
      return probe
    }.value
  }

  func remoteBinaryDigest(rawTarget: String, path: String) async throws -> String? {
    let transport = try makeTransport(rawTarget)
    let quoted = RemoteSSHInvocation.quote(path)
    let script =
      "command -v sha256sum >/dev/null 2>&1 && sha256sum \(quoted) || shasum -a 256 \(quoted)"
    let result = try await Task.detached(priority: .userInitiated) {
      try RemoteSSHProcessRunner().run(
        arguments: transport.sshArguments(remoteCommand: ["/bin/sh", "-c", script]),
        timeout: TimeInterval(transport.policy.connectTimeout + 20))
    }.value
    guard result.exitStatus == 0 else { return nil }
    let digest = result.standardOutput.split(whereSeparator: { $0 == " " || $0 == "\n" }).first
      .map(String.init)?.lowercased()
    guard let digest, RemoteInstallValidation.isLowercaseHexDigest(digest) else { return nil }
    return digest
  }

  /// 私有安装目录当前活动 symlink 指向的版本名（`versions/<v>/aster-session` 里的 `<v>`）。
  /// 只有由安装事务写入的版本化目录才能作为回滚目标；`/usr/local/bin` 之类的外部路径不算。
  private static func activeInstalledVersion(
    executor: RemoteSSHInstallExecutor, homeDirectory: String
  ) async throws -> String? {
    let active = RemoteInstallPlan.defaultInstallRoot(homeDirectory: homeDirectory)
      + "/bin/" + RemoteInstallPlan.binaryName
    let result = try await Task.detached(priority: .userInitiated) {
      try executor.runRemote(["readlink", active])
    }.value
    guard result.exitStatus == 0 else { return nil }
    let components = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "/").map(String.init)
    // …/versions/<v>/aster-session
    guard components.count >= 3, components[components.count - 3] == "versions" else {
      return nil
    }
    return components[components.count - 2]
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  /// 构造 SSH 传输。私有临时配置只在 `manage_ssh_config` 开启时创建。
  func makeTransport(_ rawTarget: String) throws -> RemoteSessionTransport {
    let target: RemoteSSHTarget
    do { target = try RemoteSSHTarget.parse(rawTarget) } catch let error as RemoteSSHTargetError {
      throw RemoteSetupFailure(
        stage: .targetValidation, requiresExplicitSetup: true,
        message: RemoteSetupDescription.targetText(error))
    }
    let policy = RemoteSSHPolicy.fromEnvironment(environment)
    let managed =
      policy.manageSSHConfig
      ? try? RemoteSSHConfigurationManager.makePrivateConfiguration(policy: policy) : nil
    return RemoteSessionTransport(
      target: target, policy: policy, managedConfiguration: managed)
  }
}

/// 生产环境的连接驱动：一次 SSH 往返完成握手，之后按策略做心跳与快照确认。
///
/// 后台连接**只连接现存兼容服务**：这里调用的是 `serverStatus`（只读查询），
/// 绝不调用 `ensureServer`。服务不存在、需要安装或替换时进入 attention（§4.1 最后一段）。
struct RemoteMachineConnectionDriver: MachineConnectionDriving {
  private let services: RemoteMachineFleetServices
  private let environment: [String: String]

  init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
    self.services = RemoteMachineFleetServices(environment: environment)
  }

  func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
    do {
      return .connected(try identity(for: profile))
    } catch let error as RemoteSetupFailure {
      return error.requiresExplicitSetup
        ? .needsExplicitSetup(kind: error.sshKind, reason: error.message)
        : .transient(reason: error.message)
    } catch let error as RemoteSSHError {
      return MachineConnectionOutcome.from(
        sshKind: error.kind, detail: RemoteSSHDiagnostics.redact(error.detail))
    } catch {
      return .transient(reason: RemoteSetupDescription.text(for: error))
    }
  }

  func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool {
    (try? identity(for: profile)) != nil
  }

  /// 重连后的快照确认。
  ///
  /// 只有服务身份仍可查询到才放行输入；查询失败时返回 false，编排器据此继续重连，
  /// 不会在没有确认快照的情况下把输入投进去。
  func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool {
    (try? identity(for: profile)) != nil
  }

  private func identity(for profile: MachineProfile) throws -> SessionServerIdentity {
    guard let rawTarget = profile.sshTarget else { throw MachineFleetError.machineNotFound }
    let runtime: RemoteRuntimeLocation
    do { runtime = try RemoteRuntimeLocation.resolve(profile: profile, environment: environment) }
    catch {
      throw RemoteSetupFailure(
        stage: .sessionPreparation, requiresExplicitSetup: true,
        message: RemoteSetupDescription.text(for: error))
    }
    let client = RemoteManagedSessionClient(transport: try services.makeTransport(rawTarget))
    return try client.serverStatus(
      ManagedSessionEndpoint(
        machineProfileID: profile.id, binaryPath: runtime.binaryPath,
        stateParentPath: runtime.stateParentPath, sessionName: profile.sessionName))
  }
}

/// 一台远端机器的受管运行时位置（二进制 + 状态父目录）。
///
/// 来源优先级固定：环境变量（开发/测试覆盖）→ 设置事务写进配置的实测值。两者都没有
/// 只可能是 P8 之前保存的旧配置，此时提示用户重新添加机器，而不是要求设置环境变量。
struct RemoteRuntimeLocation: Equatable, Sendable {
  var binaryPath: String
  var stateParentPath: String

  static func resolve(profile: MachineProfile, environment: [String: String]) throws
    -> RemoteRuntimeLocation
  {
    let binary = Self.nonEmpty(environment[RemoteEnvironmentKeys.remoteBinary])
      ?? Self.nonEmpty(profile.remoteBinaryPath)
    let stateParent = Self.nonEmpty(environment[RemoteEnvironmentKeys.stateDirectory])
      ?? Self.nonEmpty(profile.stateParentPath)
    guard let binary, let stateParent else {
      throw ManagedSessionError.runtimeUnavailable(
        L("机器「\(profile.label)」缺少远端运行时位置（旧版本保存的配置）。请移除后重新添加该机器。"))
    }
    return RemoteRuntimeLocation(binaryPath: binary, stateParentPath: stateParent)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
