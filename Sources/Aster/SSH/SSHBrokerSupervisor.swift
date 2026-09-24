import AsterCore
import Combine
import Foundation

// aster-ssh broker 的生命周期：定位二进制、选引擎、拉起与崩溃重启、分发 broker 事件、
// 推送主机规格。协议见 SshRuntime/PROTOCOL.md；进程与管道细节在 SSHBrokerControlChannel。
// 本类型从不处理秘密：认证请求原样交给 `authCoordinator`，回答原样写回 broker，不记录、不保存。

/// broker 不可用的原因。
enum SSHBrokerError: Error, Equatable {
  /// 找不到 aster-ssh 可执行文件。
  case executableMissing
  /// broker 启动失败或未在超时内报告 ready。
  case startFailed(String)
  /// 当前引擎不是 native（被设置、环境变量选择，或回退）。
  case engineDisabled
  /// 控制通道已关闭（broker 已退出或正在关闭）。
  case channelClosed
  /// `aster-ssh config` 子命令失败；`detail` 只含退出码与脱敏摘要。
  case configFailed(String)
}

/// aster-ssh broker 监管者。每个 App 实例一个。
@MainActor
final class SSHBrokerSupervisor {
  /// 可调参数。测试把超时与退避调小。
  struct Tuning {
    /// 等待 `ready` 的上限；超时视为启动失败，结束进程并按退避重启。
    var readyTimeout: Duration = .seconds(5)
    /// 崩溃后第 n 次重启前的等待秒数，超出取最后一档。
    var restartDelays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]
    /// 一次运行超过这么久才算稳定，退出后退避从第一档重新开始。
    var stableUptime: TimeInterval = 30
    /// `config list` 的超时秒数。
    var configTimeout: TimeInterval = 10
  }

  static let shared = SSHBrokerSupervisor(
    routing: .shared,
    hostDirectory: { SSHHostDirectory.shared },
    linkStateHandler: { MachineFleetModel.shared.handleLinkState($0) })

  /// 当前生效引擎：native 表示 broker 已拉起、传输走 aster-ssh；openssh 是改造前的路径。
  /// `start` 之前恒为 openssh，保证未经 App 启动流程的调用方（测试、CLI）行为不变。
  private(set) var engine: SSHEngine = .openssh
  /// broker 是否已报告 ready。
  private(set) var isReady = false
  /// broker 进程累计启动次数（含重启）。
  private(set) var launchCount = 0
  /// 最近的诊断（事件码与脱敏说明），只保留最后 20 条，供排障与测试断言。
  private(set) var diagnostics: [String] = []

  /// 回答认证与主机密钥请求。为 nil 时一律回答取消 / 拒绝。
  var authCoordinator: (any SSHAuthCoordinating)?
  /// `link.state` 事件的接收者（机器连接状态）。
  var linkStateHandler: ((SSHLinkStateEvent) -> Void)?

  private let routing: SSHEngineRouting?
  private let hostDirectory: () -> SSHHostDirectory
  private let tuning: Tuning
  private let environment: [String: String]
  private let locateExecutable: () -> URL?

  private var executable: URL?
  private var socketDirectory: URL?
  private var endpoint: NativeSSHEndpoint?
  private var channel: SSHBrokerControlChannel?
  /// 每次拉起 broker 递增。事件、退出回调与异步回答都带着它，旧实例的一律丢弃。
  private var channelGeneration: UInt64 = 0
  private var launchedAt: Date?
  private var restartAttempt = 0
  private var restartTask: Task<Void, Never>?
  private var readyTimeoutTask: Task<Void, Never>?
  private var hostsSubscription: AnyCancellable?
  /// 最近一次成功推给当前 broker 的规格；相同内容不重复发送。
  private var lastSyncedSpecs: [UUID: SSHResolvedSpec]?
  private var isShuttingDown = false

  /// - Parameters:
  ///   - routing: 发布原生端点的位置；测试传独立实例或 nil，避免影响全局传输选择。
  ///   - hostDirectory: 主机目录（profiles.sync 的来源），首次需要时才取。
  ///   - linkStateHandler: `link.state` 的接收者。
  ///   - environment: 读取 `ASTER_SSH_ENGINE`、`ASTER_SSH_BINARY`，并作为 broker 的环境。
  ///   - locateExecutable: 定位 aster-ssh；缺省按 `executableURL(environment:bundle:)`。
  init(
    routing: SSHEngineRouting?,
    hostDirectory: @escaping () -> SSHHostDirectory,
    linkStateHandler: ((SSHLinkStateEvent) -> Void)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    tuning: Tuning = Tuning(),
    locateExecutable: (() -> URL?)? = nil
  ) {
    self.routing = routing
    self.hostDirectory = hostDirectory
    self.linkStateHandler = linkStateHandler
    self.environment = environment
    self.tuning = tuning
    self.locateExecutable = locateExecutable ?? { Self.executableURL(environment: environment) }
  }

  // MARK: - 定位与引擎选择

  /// 可执行文件名。
  nonisolated static let executableName = "aster-ssh"

  /// 定位 aster-ssh：`ASTER_SSH_BINARY` → App 包 `Contents/MacOS/aster-ssh` →
  /// 与主程序同目录 → 开发构建 `SshRuntime/target/{release,debug}/aster-ssh`。
  nonisolated static func executableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
  ) -> URL? {
    locate(
      environment: environment, bundleURL: bundle.bundleURL, mainExecutableURL: bundle.executableURL,
      fileManager: .default)
  }

  /// `executableURL` 的可注入版本。
  ///
  /// aster-session 在开发构建里只能靠环境变量指定；aster-ssh 多给两个开发候选：
  /// SwiftPM 调试产物在 `<仓库>/.build/<配置>/Aster`，与之同目录的 aster-ssh 覆盖手工复制的情况；
  /// 由 `.build` 反推出仓库根后再找 cargo 产物，覆盖「只跑了 cargo build」的常见情况。
  nonisolated static func locate(
    environment: [String: String],
    bundleURL: URL,
    mainExecutableURL: URL?,
    fileManager: FileManager
  ) -> URL? {
    var candidates: [URL] = []
    if let override = environment["ASTER_SSH_BINARY"], !override.isEmpty {
      candidates.append(URL(fileURLWithPath: override))
    }
    candidates.append(bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)"))
    if let mainExecutableURL {
      let directory = mainExecutableURL.deletingLastPathComponent()
      candidates.append(directory.appendingPathComponent(executableName))
      let components = directory.standardizedFileURL.pathComponents
      if let buildIndex = components.lastIndex(of: ".build"), buildIndex > 0 {
        let root = NSString.path(withComponents: Array(components[..<buildIndex]))
        for configuration in ["release", "debug"] {
          candidates.append(
            URL(fileURLWithPath: root)
              .appendingPathComponent("SshRuntime/target/\(configuration)/\(executableName)"))
        }
      }
    }
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }?.standardizedFileURL
  }

  /// 用户要求的引擎：环境变量 `ASTER_SSH_ENGINE` 优先，其次设置项。
  /// 环境变量取值非法时忽略它并返回说明，由调用方记诊断。
  nonisolated static func requestedEngine(
    environment: [String: String], preferred: SSHEngine
  ) -> (engine: SSHEngine, problem: String?) {
    guard let raw = environment[SSHEngine.environmentKey]?.trimmingCharacters(in: .whitespaces),
      !raw.isEmpty
    else { return (preferred, nil) }
    guard let engine = SSHEngine(rawValue: raw.lowercased()) else {
      return (preferred, "invalid \(SSHEngine.environmentKey)=\(raw)")
    }
    return (engine, nil)
  }

  // MARK: - 生命周期

  /// App 启动时调用一次：决定引擎，native 时拉起 broker 并发布端点。
  ///
  /// 引擎只在启动时决定：运行中切换会让已经连着 broker 的受管终端与 Pane 桥全部失效，
  /// 因此设置里的切换在下次启动生效。选 native 但找不到二进制或拉不起来时回退 openssh。
  func start(preferredEngine: SSHEngine) {
    guard channel == nil, endpoint == nil else { return }
    isShuttingDown = false
    let (requested, problem) = Self.requestedEngine(
      environment: environment, preferred: preferredEngine)
    if let problem { note("ssh.engine.invalid_override", problem, level: .warning) }
    guard requested == .native else {
      engine = .openssh
      note("ssh.engine.selected", "openssh", level: .info)
      return
    }
    guard let executable = locateExecutable() else {
      fallBack("executable missing")
      return
    }
    do {
      let directory = try Self.makeSocketDirectory()
      self.executable = executable
      socketDirectory = directory
      endpoint = NativeSSHEndpoint(
        executablePath: executable.path,
        brokerSocketPath: directory.appendingPathComponent("b.sock").path)
      try launch()
    } catch {
      removeSocketDirectory()
      endpoint = nil
      fallBack("launch failed: \(error)")
      return
    }
    engine = .native
    routing?.publish(endpoint)
    note("ssh.engine.selected", "native", level: .info)
    subscribeToHosts()
  }

  /// 回退到 openssh 并记诊断。
  private func fallBack(_ reason: String) {
    engine = .openssh
    routing?.publish(nil)
    note("ssh.engine.fallback", reason, level: .warning)
  }

  /// App 退出时调用：发 `shutdown`、关闭 stdin，撤销端点并删除私有目录。
  ///
  /// 不等待 broker 退出：stdin EOF 本身就是退出信号，App 退出不应被它拖住。
  func shutdown() {
    isShuttingDown = true
    restartTask?.cancel()
    restartTask = nil
    readyTimeoutTask?.cancel()
    readyTimeoutTask = nil
    hostsSubscription = nil
    if let channel {
      do { try channel.send(.shutdown) } catch {
        note("ssh.broker.shutdown_failed", String(describing: error), level: .warning)
      }
      channel.closeInput()
    }
    channel = nil
    isReady = false
    routing?.publish(nil)
    endpoint = nil
    removeSocketDirectory()
    engine = .openssh
  }

  /// 返回可用的原生端点。引擎不是 native 时抛 `engineDisabled`，调用方应走 OpenSSH。
  ///
  /// broker 暂时不在（崩溃后退避中）也返回端点：socket 路径不变，client 连不上时按
  /// 传输失败归类并由上层重试，重启后自然恢复。
  func nativeEndpoint() throws -> NativeSSHEndpoint {
    guard engine == .native, let endpoint else { throw SSHBrokerError.engineDisabled }
    return endpoint
  }

  /// 等到 broker 报告 ready。超过 `readyTimeout` 抛 `startFailed`。
  func waitUntilReady() async throws {
    let deadline = ContinuousClock.now + tuning.readyTimeout
    while !isReady {
      guard engine == .native, !isShuttingDown else { throw SSHBrokerError.engineDisabled }
      guard ContinuousClock.now < deadline else {
        throw SSHBrokerError.startFailed("broker not ready")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// 拉起一个 broker 实例。
  private func launch() throws {
    guard let executable, let endpoint else { throw SSHBrokerError.executableMissing }
    try removeStaleSocket(endpoint.brokerSocketPath)
    channelGeneration &+= 1
    let generation = channelGeneration
    let channel = try SSHBrokerControlChannel(
      executableURL: executable,
      arguments: ["broker", "--socket", endpoint.brokerSocketPath],
      environment: environment,
      onLine: { [weak self] line in self?.receive(line: line, generation: generation) },
      onFramingError: { [weak self] problem in
        self?.note("ssh.broker.framing_error", problem, level: .warning)
      },
      onExit: { [weak self] status in self?.handleExit(status: status, generation: generation) },
      onWriteFailure: { code in Self.recordGlobal("ssh.broker.write_failed", "errno=\(code)") })
    self.channel = channel
    isReady = false
    lastSyncedSpecs = nil
    launchedAt = Date()
    launchCount += 1
    scheduleReadyTimeout(generation: generation)
  }

  /// ready 超时看门狗：到点仍未 ready 就结束进程，退出回调负责按退避重启。
  private func scheduleReadyTimeout(generation: UInt64) {
    readyTimeoutTask?.cancel()
    let timeout = tuning.readyTimeout
    readyTimeoutTask = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      guard let self, generation == self.channelGeneration, !self.isReady else { return }
      self.note("ssh.broker.ready_timeout", "no ready within \(timeout)", level: .error)
      self.channel?.terminate()
    }
  }

  /// broker 退出：非主动关闭时按退避重启。
  private func handleExit(status: Int32, generation: UInt64) {
    guard generation == channelGeneration else { return }
    channel = nil
    isReady = false
    readyTimeoutTask?.cancel()
    readyTimeoutTask = nil
    guard !isShuttingDown, engine == .native else { return }
    if let launchedAt, Date().timeIntervalSince(launchedAt) >= tuning.stableUptime {
      restartAttempt = 0
    }
    let delays = tuning.restartDelays
    let delay = delays.isEmpty ? 1 : delays[min(restartAttempt, delays.count - 1)]
    restartAttempt += 1
    note("ssh.broker.exited", "status=\(status) restart_in=\(delay)s", level: .warning)
    restartTask?.cancel()
    restartTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(Int(delay * 1000))) } catch { return }
      guard let self, !self.isShuttingDown, self.channel == nil else { return }
      do { try self.launch() } catch {
        // 拉起本身失败（例如二进制被删）：记下并继续按退避重试，不回退引擎——
        // 已经写进 Pane 命令行的端点仍指向这里。
        self.note("ssh.broker.relaunch_failed", String(describing: error), level: .error)
        self.handleExit(status: -1, generation: self.channelGeneration)
      }
    }
  }

  // MARK: - 事件分发

  /// 解码一行并分发。旧实例的行直接丢弃。
  private func receive(line: Data, generation: UInt64) {
    guard generation == channelGeneration else { return }
    let event: SSHBrokerEvent
    do { event = try SSHBrokerEvent.decode(line: line) } catch {
      // 只记长度，不记内容：坏行里可能混着任何东西。
      note("ssh.broker.malformed_line", "bytes=\(line.count)", level: .warning)
      return
    }
    dispatch(event, generation: generation)
  }

  /// 按类型处理一条 broker 事件。
  private func dispatch(_ event: SSHBrokerEvent, generation: UInt64) {
    switch event {
    case .ready(_, let version):
      isReady = true
      readyTimeoutTask?.cancel()
      readyTimeoutTask = nil
      note("ssh.broker.ready", "version=\(version)", level: .info)
      syncProfiles()
    case .authRequest(let request):
      handleAuthRequest(request, generation: generation)
    case .authResult(let id, let accepted):
      authCoordinator?.handleResult(id: id, accepted: accepted)
    case .hostKeyConfirm(let request):
      handleHostKey(request, generation: generation)
    case .linkState(let state):
      linkStateHandler?(state)
    case .log(let level, let message):
      note("ssh.broker.log", "\(level): \(message)", level: .debug)
    case .unknown:
      // 协议要求忽略未知类型（向前兼容）。
      break
    }
  }

  /// 凭证请求：交给协调者，回答原样写回；没有协调者或回答不配套时回答取消。
  private func handleAuthRequest(_ request: SSHAuthRequest, generation: UInt64) {
    let cancel = SSHBrokerCommand.authAnswer(id: request.id, secret: nil, responses: nil)
    guard let coordinator = authCoordinator else {
      send(cancel, generation: generation)
      return
    }
    Task { [weak self] in
      let answer = await coordinator.answer(request)
      guard case .authAnswer(let id, _, _) = answer, id == request.id else {
        self?.note("ssh.broker.auth_answer_mismatch", "id=\(request.id)", level: .warning)
        self?.send(cancel, generation: generation)
        return
      }
      self?.send(answer, generation: generation)
    }
  }

  /// 主机密钥确认：交给协调者；没有协调者或回答不配套时拒绝。
  private func handleHostKey(_ request: SSHHostKeyRequest, generation: UInt64) {
    let reject = SSHBrokerCommand.hostKeyAnswer(id: request.id, accept: false)
    guard let coordinator = authCoordinator else {
      send(reject, generation: generation)
      return
    }
    Task { [weak self] in
      let answer = await coordinator.confirmHostKey(request)
      guard case .hostKeyAnswer(let id, _) = answer, id == request.id else {
        self?.note("ssh.broker.hostkey_answer_mismatch", "id=\(request.id)", level: .warning)
        self?.send(reject, generation: generation)
        return
      }
      self?.send(answer, generation: generation)
    }
  }

  /// 写一条命令给指定实例。实例已换代（重启过）时丢弃：请求来自旧 broker，新实例不认识它。
  private func send(_ command: SSHBrokerCommand, generation: UInt64) {
    guard generation == channelGeneration, let channel else { return }
    do { try channel.send(command) } catch {
      // 错误里不含命令内容；auth.answer 的秘密不会进日志。
      note("ssh.broker.send_failed", String(describing: error), level: .warning)
    }
  }

  // MARK: - 主机规格同步

  /// 把最新主机规格推给 broker（`profiles.sync`）。broker 未就绪时忽略，ready 后会自动补发。
  func syncProfiles() {
    guard isReady else { return }
    sync(hosts: hostDirectory().hosts)
  }

  /// 订阅主机目录变化。`@Published` 在赋值前发出新值，所以直接用发出的值，不回读属性。
  private func subscribeToHosts() {
    hostsSubscription = hostDirectory().$hosts
      .dropFirst()
      .sink { [weak self] hosts in
        MainActor.assumeIsolated { self?.sync(hosts: hosts) }
      }
  }

  /// 解析并发送；与上次发给同一实例的内容相同则跳过。
  private func sync(hosts: [SSHHostProfile]) {
    guard isReady, let channel else { return }
    let resolved = SSHHostResolver.resolveAll(hosts)
    if !resolved.failures.isEmpty {
      note("ssh.hosts.unresolved", "count=\(resolved.failures.count)", level: .warning)
    }
    guard resolved.specs != lastSyncedSpecs else { return }
    do {
      try channel.send(.profilesSync(resolved.specs))
      lastSyncedSpecs = resolved.specs
    } catch {
      note("ssh.broker.sync_failed", String(describing: error), level: .warning)
    }
  }

  // MARK: - config 子命令

  /// 读取 `~/.ssh/config` 解析结果（`aster-ssh config list --json`），在后台执行。
  ///
  /// 不依赖 broker，也不受引擎选择影响：openssh 引擎下设置页的导入同样需要它。
  func configListing() async throws -> SSHConfigListing {
    guard let executable = executable ?? locateExecutable() else {
      throw SSHBrokerError.executableMissing
    }
    let timeout = tuning.configTimeout
    return try await Task.detached(priority: .userInitiated) {
      let runner = RemoteSSHProcessRunner(executablePath: executable.path)
      let result: RemoteSSHResult
      do {
        result = try runner.run(arguments: ["config", "list", "--json"], timeout: timeout)
      } catch let error as RemoteSSHError {
        throw SSHBrokerError.configFailed(error.detail)
      }
      guard result.exitStatus == 0 else {
        throw SSHBrokerError.configFailed("exit \(result.exitStatus)")
      }
      do {
        return try JSONDecoder().decode(SSHConfigListing.self, from: Data(result.standardOutput.utf8))
      } catch {
        throw SSHBrokerError.configFailed("malformed output")
      }
    }.value
  }

  // MARK: - 私有目录

  /// 在 `/tmp` 下建 0700 私有目录放 broker socket。
  ///
  /// 不用 `NSTemporaryDirectory()`：它在 `/var/folders/…` 下，路径已占去一半 `sockaddr_un`
  /// 的 104 字节上限；`/tmp/aster-sshb-<10 位>/b.sock` 只有 30 字节左右。
  nonisolated static func makeSocketDirectory(fileManager: FileManager = .default) throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
    let path = "/tmp/aster-sshb-\(suffix)"
    try fileManager.createDirectory(
      atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// 删除上一实例留下的 socket 文件；broker 重启复用同一路径时 bind 才不会失败。
  private func removeStaleSocket(_ path: String) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path) else { return }
    try fileManager.removeItem(atPath: path)
  }

  /// 删除私有目录（含 socket）。失败只记诊断：/tmp 会被系统定期清理。
  private func removeSocketDirectory() {
    guard let socketDirectory else { return }
    self.socketDirectory = nil
    do { try FileManager.default.removeItem(at: socketDirectory) } catch {
      note("ssh.broker.cleanup_failed", String(describing: (error as NSError).code), level: .info)
    }
  }

  // MARK: - 诊断

  /// 记一条诊断：进内存环形缓冲，同时写诊断中心。说明文本必须已脱敏。
  private func note(_ code: String, _ detail: String, level: DiagnosticLevel) {
    diagnostics.append("\(code): \(detail)")
    if diagnostics.count > 20 { diagnostics.removeFirst(diagnostics.count - 20) }
    Self.recordGlobal(code, detail, level: level)
  }

  /// 写诊断中心。诊断中心自带锁，可在任意线程调用。
  nonisolated private static func recordGlobal(
    _ code: String, _ detail: String, level: DiagnosticLevel = .warning
  ) {
    DiagnosticsCenter.shared.record(
      code, level: level, category: .integration, attributes: ["detail": detail])
  }
}
