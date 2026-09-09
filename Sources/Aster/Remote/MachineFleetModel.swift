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

/// 添加机器的结果。
enum MachineSetupResult: Equatable {
  case added(MachineProfile)
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
    guard !trimmedLabel.isEmpty else { return .failed("机器标签不能为空。") }
    guard !trimmedSession.isEmpty else { return .failed("必须指定要绑定的命名会话。") }

    let profileID = UUID()
    let outcome: RemoteSetupOutcome
    do {
      outcome = try await services.runSetup(
        rawTarget: sshTarget, label: trimmedLabel, sessionName: trimmedSession,
        profileID: profileID)
    } catch let failure as RemoteSetupFailure {
      return .failed(failure.message)
    } catch {
      return .failed(RemoteSetupDescription.text(for: error))
    }

    switch outcome {
    case .ready(let profile, _, _):
      do { try store.save(profiles + [profile]) } catch {
        return .failed("配置保存失败：\(Self.describe(error))")
      }
      profiles.append(profile)
      rebuildRows()
      await supervisor.start(profile: profile)
      await refreshStatuses()
      return .added(profile)

    case .installationRequired(let report, let reason):
      let accepted = confirm(
        MachineSetupConfirmation(
          kind: .installation,
          target: sshTarget,
          platform: "\(report.platform.os)/\(report.platform.architecture)",
          version: report.candidates.first?.releaseVersion ?? "（远端尚无 aster-session）",
          processImpact: "安装只写入新的二进制文件，不会停止远端正在运行的任何进程。",
          reason: reason))
      // 用户取消：配置从未产出，磁盘上什么也没写。
      return accepted ? .failed("安装事务尚未在本入口开放，请使用显式安装设置。") : .cancelled

    case .incompatibleServerRunning(let report, let reason):
      let accepted = confirm(
        MachineSetupConfirmation(
          kind: .incompatibleServer,
          target: sshTarget,
          platform: "\(report.platform.os)/\(report.platform.architecture)",
          version: report.runningServer?.version ?? report.candidates.first?.releaseVersion ?? "未知",
          processImpact: "替换会停止运行中的服务实例及其全部受管进程。Aster 不会在后台执行它。",
          reason: reason))
      return accepted ? .failed("服务替换属于显式更新事务，本入口不执行。") : .cancelled
    }
  }

  /// 重命名（§4.1 第 7 条）：只改标签，不触发重连。
  @discardableResult
  func rename(_ id: UUID, to label: String) -> String? {
    guard id != MachineProfile.localProfileID else { return "Local 不能重命名。" }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "标签不能为空。" }
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return "机器不存在。" }
    var updated = profiles
    updated[index].label = trimmed
    do { try store.save(updated) } catch { return "配置保存失败：\(Self.describe(error))" }
    profiles = updated
    // 编排器只更新标签，代次、任务与连接状态全部保持不变。
    Task { [supervisor] in await supervisor.rename(profileID: id, label: trimmed) }
    rebuildRows()
    return nil
  }

  /// 启用/禁用（§4.1 第 7 条）：即使离线也可操作，只断开该配置，不停止远端服务。
  @discardableResult
  func setEnabled(_ id: UUID, _ enabled: Bool) -> String? {
    guard id != MachineProfile.localProfileID else { return "Local 不能禁用。" }
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return "机器不存在。" }
    guard profiles[index].enabled != enabled else { return nil }
    var updated = profiles
    updated[index].enabled = enabled
    do { try store.save(updated) } catch { return "配置保存失败：\(Self.describe(error))" }
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
    guard id != MachineProfile.localProfileID else { return "Local 不能移除。" }
    guard profiles.contains(where: { $0.id == id }) else { return "机器不存在。" }
    let updated = profiles.filter { $0.id != id }
    do { try store.save(updated) } catch { return "配置删除失败：\(Self.describe(error))" }
    profiles = updated
    statuses.removeValue(forKey: id)
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
    guard let profile = profiles.first(where: { $0.id == id }) else { return "机器不存在。" }
    guard profile.enabled else { return "该机器已禁用。" }
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
          lastUpdatedAt: Date(), reason: "尚未建立连接。"))
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
          lastError: status?.reason))
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
    case .fileMissing(let path): return "机器配置文件不存在：\(path)"
    case .corrupted(let detail): return "机器配置文件内容损坏：\(detail)"
    case .invalidProfiles(let reasons): return "机器配置非法：\(reasons.joined(separator: "；"))"
    case .ioFailure(let detail): return "机器配置读写失败：\(detail)"
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
    guard let stateParent else {
      throw RemoteSetupFailure(
        stage: .sessionPreparation, requiresExplicitSetup: true,
        message: "未配置远端状态目录（\(RemoteEnvironmentKeys.stateDirectory)），无法准备命名会话。")
    }
    let setup = RemoteMachineSetup(
      executor: RemoteSSHSetupExecutor(
        transport: transport,
        endpointTemplate: ManagedSessionEndpoint(
          machineProfileID: profileID,
          binaryPath: explicitBinary ?? "aster-session",
          stateParentPath: stateParent,
          sessionName: sessionName)),
      explicitRemoteBinaryPath: explicitBinary)
    return try setup.run(
      rawTarget: rawTarget, label: label, sessionName: sessionName, profileID: profileID)
  }

  func registry(for profile: MachineProfile) throws -> MachineRegistryAccess {
    guard let stateParent, !stateParent.isEmpty else {
      throw ManagedSessionError.runtimeUnavailable(
        "未配置 \(RemoteEnvironmentKeys.stateDirectory)，无法访问命名会话注册表。")
    }
    guard let rawTarget = profile.sshTarget else {
      guard let binary = localBinary, !binary.isEmpty else {
        throw ManagedSessionError.runtimeUnavailable(
          "未配置 \(RemoteEnvironmentKeys.binary)，无法访问本机命名会话注册表。")
      }
      return MachineRegistryAccess(
        client: LocalManagedSessionClient(),
        endpoint: ManagedRegistryEndpoint(
          machineProfileID: profile.id, binaryPath: binary, stateParentPath: stateParent))
    }
    guard let binary = explicitBinary, !binary.isEmpty else {
      throw ManagedSessionError.runtimeUnavailable(
        "未配置 \(RemoteEnvironmentKeys.remoteBinary)，无法访问远端命名会话注册表。")
    }
    return MachineRegistryAccess(
      client: RemoteManagedSessionClient(transport: try makeTransport(rawTarget)),
      endpoint: ManagedRegistryEndpoint(
        machineProfileID: profile.id, binaryPath: binary, stateParentPath: stateParent))
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
    guard let stateParent = environment[RemoteEnvironmentKeys.stateDirectory],
      let binary = environment[RemoteEnvironmentKeys.remoteBinary]
    else {
      throw RemoteSetupFailure(
        stage: .sessionPreparation, requiresExplicitSetup: true,
        message: "远端受管模式未配置运行时二进制或状态目录。")
    }
    let client = RemoteManagedSessionClient(transport: try services.makeTransport(rawTarget))
    return try client.serverStatus(
      ManagedSessionEndpoint(
        machineProfileID: profile.id, binaryPath: binary, stateParentPath: stateParent,
        sessionName: profile.sessionName))
  }
}
