import Foundation
import Testing

@testable import AsterCore

/// P4 的 OrbStack 真实验收（A13/A14/A15）。
///
/// 这些用例**只在显式开启时运行**（`ASTER_P4_ORB=1`），因为它们会真的通过 SSH 连接
/// OrbStack、启动命名会话服务、创建真实进程，并且会起一个本轮专用的本地 TCP 中继
/// 制造真实断连。默认关闭，避免普通测试运行触碰远端机器。
///
/// 证据规则（`docs/developer/remote-work-acceptance.md` §1）：每轮唯一 runID，全部远端
/// 资源放在 `${HOME}/.local/state/aster-test/<runID>` 下；停止与清理只限定本轮 runID 内
/// 记录的**具体 PID 与 socket 路径**，禁止按进程名结束进程（不用 pkill/pgrep）。
/// 存活证据一律用真实 PID（`kill -0`）与真实文件增长，不用「标题相同」冒充。
///
/// 环境变量：
/// - `ASTER_P4_ORB=1`：总开关。
/// - `ASTER_P4_TARGET`：主 SSH target 文本，默认 `root@ubuntu@orb`。
/// - `ASTER_P4_RUN_ID`：本轮 runID，缺省按时间戳生成。
/// - `ASTER_P4_LOCAL_BINARY`：本机 macOS 产物（Local 侧真实建会话用）。
/// - `ASTER_P4_REMOTE_BINARY_PATH`：远端已安装的 `aster-session` 绝对路径。
/// - `ASTER_P4_RELAY_SCRIPT`：中继脚本，默认 `scripts/remote-work-p4-relay.py`。
/// - `ASTER_P4_RELAY_PORT`：中继监听端口，默认 0（临时端口，起来后回读实际端口）。

// MARK: - 运行参数与日志

/// 验收运行参数。全部来自环境变量，默认值只用于本地手动执行。
private struct P4AcceptanceSettings {
  var rawTarget: String
  var runID: String
  var localBinary: String
  var remoteBinaryPath: String
  var relayScript: String
  var relayPort: Int
  var orbBackendHost: String
  var orbBackendPort: Int
  var orbIdentityFile: String
  var orbUser: String

  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["ASTER_P4_ORB"] == "1"
  }

  /// 仓库根目录。用 `#filePath` 反推，避免依赖测试进程的工作目录。
  static var repositoryRoot: String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/AsterCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // <repo>
      .path
  }

  static func fromEnvironment() -> P4AcceptanceSettings {
    let environment = ProcessInfo.processInfo.environment
    let relay = environment["ASTER_P4_RELAY_SCRIPT"] ?? "scripts/remote-work-p4-relay.py"
    let relayPath =
      relay.hasPrefix("/") ? relay : "\(repositoryRoot)/\(relay)"
    return P4AcceptanceSettings(
      rawTarget: environment["ASTER_P4_TARGET"] ?? "root@ubuntu@orb",
      runID: environment["ASTER_P4_RUN_ID"] ?? "p4-\(Int(Date().timeIntervalSince1970))",
      localBinary: environment["ASTER_P4_LOCAL_BINARY"] ?? "",
      remoteBinaryPath: environment["ASTER_P4_REMOTE_BINARY_PATH"] ?? "",
      relayScript: relayPath,
      relayPort: Int(environment["ASTER_P4_RELAY_PORT"] ?? "") ?? 0,
      // OrbStack 的真实后端。alias 场景与中继场景都直连它，保证「不同 target 文本
      // 解析到同一台真实主机」是真的同一后端，而不是两台恰好同名的机器。
      orbBackendHost: environment["ASTER_P4_ORB_HOST"] ?? "127.0.0.1",
      orbBackendPort: Int(environment["ASTER_P4_ORB_PORT"] ?? "") ?? 32222,
      orbIdentityFile: environment["ASTER_P4_ORB_IDENTITY"]
        ?? "\(NSHomeDirectory())/.orbstack/ssh/id_ed25519",
      orbUser: environment["ASTER_P4_ORB_USER"] ?? "root@ubuntu"
    )
  }
}

/// 验收过程中的结构化日志。写到 stdout，由外层脚本重定向到证据日志文件。
private func p4Note(_ text: String) {
  print("[P4] \(text)")
}

// MARK: - 本机与远端命令辅助

/// 本机执行一条 shell 命令并返回退出码与 stdout+stderr。用于控制中继、核对本机 PID。
@discardableResult
private func p4LocalShell(_ script: String, timeout: TimeInterval = 60) -> (
  status: Int32, output: String
) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", script]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  process.standardInput = FileHandle.nullDevice
  do { try process.run() } catch { return (-1, "launch failed: \(error)") }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 直接执行一条远端 shell 命令。用于建目录、读计数文件、按具体 PID 核实存活。
private func p4RemoteShell(
  _ transport: RemoteSessionTransport,
  _ script: String,
  timeout: TimeInterval = 30
) throws -> RemoteSSHResult {
  try RemoteSSHProcessRunner().run(
    arguments: transport.sshArguments(remoteCommand: ["/bin/sh", "-c", script]),
    timeout: timeout)
}

/// 远端文件行数。计数任务每秒追加一行，行数增长即为「任务真的还在产出」的证据。
private func p4RemoteLineCount(_ transport: RemoteSessionTransport, _ path: String) throws -> Int {
  let result = try p4RemoteShell(
    transport, "wc -l < \(RemoteSSHInvocation.quote(path)) 2>/dev/null || echo 0")
  let text = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  return Int(text) ?? 0
}

/// 按**具体 PID** 判定远端进程存活。禁止按进程名匹配（验收规格 §1）。
private func p4RemotePIDAlive(_ transport: RemoteSessionTransport, _ pid: Int32) throws -> Bool {
  let result = try p4RemoteShell(transport, "kill -0 \(pid) 2>/dev/null && echo ALIVE || echo GONE")
  return result.standardOutput.contains("ALIVE")
}

/// 每秒追加「序号 时间戳」的计数脚本。用它证明服务端持续排空 PTY、任务持续产出。
private func p4CounterScript(markerFile: String) -> [String] {
  [
    "/bin/sh", "-c",
    "i=0; while :; do i=$((i+1)); echo \"$i $(date +%s)\" >> \(RemoteSSHInvocation.quote(markerFile)); sleep 1; done",
  ]
}

/// 长时间不退出的占位进程 argv。
///
/// 为什么必须是长 sleep：会话 revision 由整个会话共享，终端退出也会推进它；
/// 并发同 revision 提交期间任何终端退出都会污染冲突判定。
private func p4IdleArgv() -> [String] { ["/bin/sh", "-c", "sleep 3600"] }

// MARK: - 私有临时 SSH 配置

/// 私有临时 SSH 配置里的一个 alias 定义。
///
/// 用它构造「原始 target 文本不同、后端却是同一台真实主机」的第二份机器配置，
/// 以及 A14 走本地中继端口的机器配置。
private struct P4SSHAlias {
  var alias: String
  var hostName: String
  var port: Int
  var user: String
  var identityFile: String
}

/// 生成本轮专用的私有 SSH 配置目录与文件。
///
/// 为什么自定义的 alias 块放在 `Include 用户配置` **之前**：OpenSSH 对同一关键字取
/// 首次出现的值，alias 的 HostName/Port/IdentityFile/主机密钥策略必须由我们自己确定，
/// 不能被用户 `Host *` 段覆盖；而用户对 `orb` 这类具体主机的定义仍然通过 Include 生效。
/// control socket 放在短前缀私有目录下，保证路径短于 `sockaddr_un` 的 104 字节上限。
private func p4MakePrivateConfiguration(
  aliases: [P4SSHAlias],
  policy: RemoteSSHPolicy = RemoteSSHPolicy()
) throws -> RemoteSSHManagedConfiguration {
  let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
  let directory = "/tmp/aster-p4-\(suffix)"
  try FileManager.default.createDirectory(
    atPath: directory, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let controlPath = "\(directory)/c-%C"
  let knownHosts = "\(directory)/known_hosts"
  let configurationPath = "\(directory)/config"

  var lines: [String] = ["# Aster P4 验收私有临时 SSH 配置。只服务本轮，结束即删除。"]
  for alias in aliases {
    lines += [
      "",
      "Host \(alias.alias)",
      "  HostName \(alias.hostName)",
      "  Port \(alias.port)",
      "  User \(alias.user)",
      "  IdentityFile \(alias.identityFile)",
      "  IdentitiesOnly yes",
      // 私有 known_hosts：只记录本轮的中继/回环主机键，绝不写用户自己的 known_hosts。
      "  UserKnownHostsFile \(knownHosts)",
      "  StrictHostKeyChecking accept-new",
    ]
  }
  lines += [
    "",
    "Host *",
    "  ServerAliveInterval \(policy.keepAliveInterval)",
    "  ServerAliveCountMax \(policy.keepAliveCountMax)",
    "  ControlMaster auto",
    "  ControlPath \(controlPath)",
    "  ControlPersist 60",
    "",
  ]
  if let userConfiguration = RemoteSSHConfigurationManager.defaultUserConfigurationPath() {
    lines += ["Include \(userConfiguration)", ""]
  }

  guard
    FileManager.default.createFile(
      atPath: configurationPath,
      contents: Data(lines.joined(separator: "\n").utf8),
      attributes: [.posixPermissions: 0o600])
  else {
    try? FileManager.default.removeItem(atPath: directory)
    throw RemoteSSHError(kind: .transportFailure, target: "", detail: "无法写入私有 SSH 配置")
  }
  return RemoteSSHManagedConfiguration(
    directoryPath: directory, configurationPath: configurationPath, controlPath: controlPath)
}

/// 清理私有 SSH 配置：先让每个 target 的 ControlMaster 退出，再删除私有目录。
///
/// 逐 target `-O exit` 而不是直接删目录：只回收本次生成的复用连接，不触碰用户自己的。
/// 清理失败必须显式报告，不静默吞掉（验收规格 §1）。
private func p4CleanUpPrivateConfiguration(
  _ configuration: RemoteSSHManagedConfiguration,
  targets: [RemoteSSHTarget]
) {
  for target in targets {
    let invocation = RemoteSSHInvocation(
      target: target,
      configurationFile: configuration.configurationPath,
      options: [],
      remoteCommand: [],
      connectTimeout: 5)
    _ = try? RemoteSSHProcessRunner().run(
      arguments: ["-O", "exit"] + invocation.arguments(), timeout: 5)
  }
  do {
    try FileManager.default.removeItem(atPath: configuration.directoryPath)
    p4Note("私有 SSH 配置已清理：\(configuration.directoryPath)")
  } catch {
    p4Note("清理失败（私有 SSH 配置 \(configuration.directoryPath)）：\(error)")
  }
}

// MARK: - 远端上下文

/// 一轮验收共用的远端上下文：已解析 target、平台信息、本轮目录与二进制事实。
private struct P4RemoteContext {
  var target: RemoteSSHTarget
  var transport: RemoteSessionTransport
  var platform: RemotePlatform
  var runRoot: String
  var stateParent: String
  var binaryPath: String

  /// 本轮 runID 目录下的注册表端点。全部命名会话都建在它下面。
  var registryEndpoint: ManagedRegistryEndpoint {
    ManagedRegistryEndpoint(
      machineProfileID: MachineProfile.localProfileID,
      binaryPath: binaryPath,
      stateParentPath: stateParent)
  }

  func endpoint(profileID: UUID, sessionName: String) -> ManagedSessionEndpoint {
    ManagedSessionEndpoint(
      machineProfileID: profileID, binaryPath: binaryPath,
      stateParentPath: stateParent, sessionName: sessionName)
  }
}

/// 探测远端平台、建立本轮目录，并把环境事实写进日志（验收规格 §1 要求测试前记录）。
private func p4PrepareRemote(
  settings: P4AcceptanceSettings,
  target: RemoteSSHTarget,
  transport: RemoteSessionTransport,
  scope: String
) throws -> P4RemoteContext {
  let probe = try RemoteSSHProcessRunner().run(
    arguments: transport.sshArguments(
      remoteCommand: RemoteHostProbe.probeCommand(explicitPath: settings.remoteBinaryPath)),
    timeout: 30)
  guard probe.exitStatus == 0,
    let report = RemoteHostProbe.parse(
      probe.standardOutput, explicitPath: settings.remoteBinaryPath)
  else {
    throw RemoteSSHError(
      kind: .transportFailure, target: target.rawText, detail: "远端探测失败或输出不可识别")
  }
  p4Note(
    "[\(scope)] 远端平台 os=\(report.platform.os) arch=\(report.platform.architecture) home=\(report.platform.homeDirectory)"
  )
  for candidate in report.candidates {
    p4Note(
      "[\(scope)] 候选 path=\(candidate.path) version=\(candidate.releaseVersion ?? "-") protocol=\(candidate.protocolMajor.map(String.init) ?? "-").\(candidate.protocolMinor.map(String.init) ?? "-")"
    )
  }

  let runRoot = "\(report.platform.homeDirectory)/.local/state/aster-test/\(settings.runID)"
  let stateParent = "\(runRoot)/state"
  _ = try p4RemoteShell(
    transport,
    "umask 077; mkdir -p \(RemoteSSHInvocation.quote(runRoot)) \(RemoteSSHInvocation.quote(stateParent))"
  )

  // 二进制摘要属于必须记录的环境事实；Linux 用 sha256sum，其它平台回落 shasum。
  let digest = try p4RemoteShell(
    transport,
    "sha256sum \(RemoteSSHInvocation.quote(settings.remoteBinaryPath)) 2>/dev/null || shasum -a 256 \(RemoteSSHInvocation.quote(settings.remoteBinaryPath))"
  )
  p4Note(
    "[\(scope)] 远端二进制 \(settings.remoteBinaryPath) sha256=\(digest.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
  )
  p4Note("[\(scope)] 本轮目录 runRoot=\(runRoot) stateParent=\(stateParent)")

  return P4RemoteContext(
    target: target,
    transport: transport,
    platform: report.platform,
    runRoot: runRoot,
    stateParent: stateParent,
    binaryPath: settings.remoteBinaryPath)
}

/// 打印一次握手身份与能力（serverID/epoch/sessionID/capabilities/version）。
private func p4LogIdentity(_ scope: String, _ identity: SessionServerIdentity) {
  p4Note(
    "[\(scope)] 握手 serverID=\(identity.reference.serverID) epoch=\(identity.serverEpoch) sessionID=\(identity.reference.sessionID)"
  )
  p4Note("[\(scope)] capabilities=\(identity.capabilities.sorted()) version=\(identity.version)")
}

/// 停止并删除本轮某个命名会话；失败显式报告，不静默吞掉。
private func p4TearDownSession(
  _ client: any ManagedSessionClient,
  _ registry: ManagedRegistryEndpoint,
  _ name: String
) {
  // 用例可能已经在场景里删掉了该会话；先确认它还在，避免把「本来就不存在」报成清理失败。
  do {
    _ = try client.attachSession(registry, selector: .name(name))
  } catch let error as ManagedSessionError where error.isSessionNotFound {
    p4Note("清理：会话 \(name) 已不存在，无需处理")
    return
  } catch {
    p4Note("清理：会话 \(name) 状态查询失败（继续尝试停止）：\(error)")
  }
  do {
    let stopped = try client.stopSession(registry, selector: .name(name))
    p4Note("清理：会话 \(name) 停止后 state=\(stopped.state.rawValue)")
  } catch {
    p4Note("清理失败（停止会话 \(name)）：\(error)")
  }
  do {
    let deleted = try client.deleteSession(registry, selector: .name(name))
    p4Note("清理：会话 \(name) 删除结果=\(deleted)")
  } catch {
    p4Note("清理失败（删除会话 \(name)）：\(error)")
  }
}

// MARK: - 本地中继（A14 真实断连）

/// `scripts/remote-work-p4-relay.py` 的进程包装。
///
/// 断连方式必须可控且只影响本轮：停中继让已建立的 SSH 连接真实断开、新连接被拒；
/// 重启中继即恢复。中继只按状态文件里记录的**单个 PID** 收发信号，不按进程名匹配。
private final class P4Relay {
  let scriptPath: String
  let stateFile: String
  private(set) var port: Int
  private(set) var pid: Int32 = 0
  private var process: Process?

  init(scriptPath: String, stateFile: String, port: Int) {
    self.scriptPath = scriptPath
    self.stateFile = stateFile
    self.port = port
  }

  /// 启动中继并等待状态文件出现；回读实际监听端口与 PID。
  func start(targetHost: String, targetPort: Int) throws {
    try? FileManager.default.removeItem(atPath: stateFile)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "python3", scriptPath, "serve",
      "--listen-port", String(port),
      "--target-host", targetHost,
      "--target-port", String(targetPort),
      "--state-file", stateFile,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    self.process = process

    // 状态文件先写后进 accept 循环，所以它出现即表示中继已就绪。
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if let data = FileManager.default.contents(atPath: stateFile),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let listenPort = (object["listenPort"] as? NSNumber)?.intValue,
        let relayPID = (object["pid"] as? NSNumber)?.int32Value
      {
        port = listenPort
        pid = relayPID
        p4Note("中继就绪 pid=\(pid) 127.0.0.1:\(port) -> \(targetHost):\(targetPort)")
        return
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    throw RemoteSSHError(kind: .timeout, target: "", detail: "中继未在 15 秒内就绪")
  }

  /// 停止中继：只向状态文件里的那一个 PID 发 SIGTERM，绝不按进程名匹配。
  @discardableResult
  func stop() -> Bool {
    guard pid != 0 else { return false }
    let result = p4LocalShell(
      "/usr/bin/env python3 \(RemoteSSHInvocation.quote(scriptPath)) stop --state-file \(RemoteSSHInvocation.quote(stateFile))"
    )
    p4Note("中继停止请求 exit=\(result.status) out=\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if p4LocalShell("kill -0 \(pid) 2>/dev/null").status != 0 {
        process?.waitUntilExit()
        process = nil
        p4Note("中继 PID \(pid) 已退出")
        return true
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    p4Note("清理失败（中继 PID \(pid) 未在 10 秒内退出）")
    return false
  }
}

// MARK: - 连接编排器的可注入替身

/// 虚拟时钟：只推进逻辑时间并记录每次等待的秒数，不真正阻塞。
private final class P4VirtualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_700_000_000)
  private var recorded: [TimeInterval] = []

  /// 已发生的等待序列，用于断言退避表与心跳间隔。
  var sleeps: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  /// 读当前逻辑时间。写成同步方法：异步上下文里不能直接调用 `NSLock.lock()`。
  private func currentTime() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  /// 记录一次等待并推进逻辑时间。
  private func advance(_ seconds: TimeInterval) {
    lock.lock()
    recorded.append(seconds)
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }

  func environment(jitter: Double) -> MachineConnectionEnvironment {
    MachineConnectionEnvironment(
      now: { [self] in currentTime() },
      sleep: { [self] seconds in
        advance(seconds)
        // 让出一次调度点，保证 actor 的其它请求（状态查询）仍能穿插进来。
        await Task.yield()
      },
      jitter: { jitter })
  }
}

/// 按脚本返回结果的连接驱动替身。用它在虚拟时钟下驱动真实的 `MachineConnectionSupervisor`。
private final class P4ScriptedConnectionDriver: MachineConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var connectQueue: [MachineConnectionOutcome]
  private var heartbeatQueue: [Bool]
  private var connects = 0
  private var heartbeats = 0
  private let snapshotConfirmed: Bool

  init(
    connectOutcomes: [MachineConnectionOutcome],
    heartbeatResults: [Bool] = [],
    snapshotConfirmed: Bool = true
  ) {
    self.connectQueue = connectOutcomes
    self.heartbeatQueue = heartbeatResults
    self.snapshotConfirmed = snapshotConfirmed
  }

  var connectCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return connects
  }

  var heartbeatCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return heartbeats
  }

  /// 取下一个连接结果。写成同步方法：异步上下文里不能直接调用 `NSLock.lock()`。
  ///
  /// 队列耗尽后固定返回 attention：连接循环因此终止，虚拟时钟不会空转。
  private func nextConnect() -> MachineConnectionOutcome {
    lock.lock()
    defer { lock.unlock() }
    connects += 1
    guard !connectQueue.isEmpty else {
      return .needsExplicitSetup(kind: nil, reason: "scripted end")
    }
    return connectQueue.removeFirst()
  }

  /// 取下一个心跳结果；队列耗尽按未响应处理。
  private func nextHeartbeat() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    heartbeats += 1
    guard !heartbeatQueue.isEmpty else { return false }
    return heartbeatQueue.removeFirst()
  }

  func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
    nextConnect()
  }

  func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool {
    nextHeartbeat()
  }

  func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool {
    snapshotConfirmed
  }
}

/// 等待某台机器进入期望状态（虚拟时钟下连接循环是异步的，必须有界轮询）。
private func p4WaitForState(
  _ supervisor: MachineConnectionSupervisor,
  profileID: UUID,
  state: SessionConnectionState
) async -> MachineConnectionStatus? {
  for _ in 0..<400 {
    if let status = await supervisor.status(profileID: profileID), status.state == state {
      return status
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return await supervisor.status(profileID: profileID)
}

/// 固定的样例服务身份，用于向编排器投递旧代结果。
private func p4SampleIdentity(profileID: UUID) -> SessionServerIdentity {
  SessionServerIdentity(
    reference: SessionServerReference(
      machineProfileID: profileID,
      serverID: "00000000-0000-4000-8000-0000000000aa",
      sessionID: "00000000-0000-4000-8000-0000000000bb"),
    serverEpoch: "00000000-0000-4000-8000-0000000000cc",
    capabilities: ["session_snapshot"],
    version: "0.0.0-stale")
}

// MARK: - A15 并发提交结果

/// 一次并发布局提交的结果。跨 `Task` 传递，必须是 `Sendable`，所以不直接搬运 `any Error`。
private enum P4SplitAttempt: Sendable {
  case ok(WorkspaceTransactionResult<RemotePaneSplitResult>)
  case conflict(currentRevision: UInt64?)
  case other(String)
}

/// 提交一次真实 `pane.split` 并把结果归一成可跨 Task 传递的形态。
private func p4AttemptSplit(
  client: WorkspaceTransactionClient,
  paneID: String,
  direction: SplitDirection,
  expectedRevision: UInt64,
  terminal: RemoteTerminalSpec
) -> P4SplitAttempt {
  do {
    return .ok(
      try client.splitPane(
        paneID: paneID, direction: direction,
        expectedRevision: expectedRevision, terminal: terminal))
  } catch WorkspaceTransactionError.revisionConflict(let current) {
    return .conflict(currentRevision: current)
  } catch {
    return .other(String(describing: error))
  }
}

/// 取快照里第一个工作区第一个标签的第一个窗格。布局操作都以它为起点。
private func p4FirstPane(_ snapshot: RemoteSessionSnapshot) -> RemotePane? {
  snapshot.workspaces.first?.tabs.first?.layout.allPanes.first
}

// MARK: - 用例

@Suite(.serialized)
struct RemoteWorkP4AcceptanceTests {

  // MARK: A13

  /// A13：多机器与命名会话（R04/R05）。
  ///
  /// 七个场景必须在**同一轮**里按顺序执行：重命名不重连、移除只分离、停止限定本会话
  /// 这三条都要跨场景比较同一个 serverEpoch 与同一个真实 PID，拆开就失去了证据。
  @Test(.enabled(if: P4AcceptanceSettings.isEnabled))
  func multiMachineAndNamedSessionsAcceptance() throws {
    let settings = P4AcceptanceSettings.fromEnvironment()
    p4Note("=== A13 runID=\(settings.runID) target=\(settings.rawTarget) ===")
    #expect(!settings.remoteBinaryPath.isEmpty, "必须提供 ASTER_P4_REMOTE_BINARY_PATH")

    // ---------- 两份配置：不同原始 target 文本，同一台真实主机 ----------
    let aliasName = "aster-p4-\(settings.runID.replacingOccurrences(of: "_", with: "-"))-alias"
    let configuration = try p4MakePrivateConfiguration(aliases: [
      P4SSHAlias(
        alias: aliasName, hostName: settings.orbBackendHost, port: settings.orbBackendPort,
        user: settings.orbUser, identityFile: settings.orbIdentityFile)
    ])
    let orbTarget = try RemoteSSHTarget.parse(settings.rawTarget)
    let aliasTarget = try RemoteSSHTarget.parse(aliasName)
    defer { p4CleanUpPrivateConfiguration(configuration, targets: [orbTarget, aliasTarget]) }
    p4Note(
      "target A 解析：raw=\(orbTarget.rawText) user=\(orbTarget.user ?? "-") host=\(orbTarget.host)")
    p4Note(
      "target B 解析：raw=\(aliasTarget.rawText) user=\(aliasTarget.user ?? "-") host=\(aliasTarget.host)"
    )
    #expect(orbTarget.rawText != aliasTarget.rawText, "两份配置必须保留各自的原始 target 文本")

    let policy = RemoteSSHPolicy()
    let transportA = RemoteSessionTransport(
      target: orbTarget, policy: policy, managedConfiguration: configuration)
    let transportB = RemoteSessionTransport(
      target: aliasTarget, policy: policy, managedConfiguration: configuration)

    let context = try p4PrepareRemote(
      settings: settings, target: orbTarget, transport: transportA, scope: "A13")
    let registry = context.registryEndpoint
    let sessionA = "a13-one"
    let sessionB = "a13-two"

    // ---------- 场景 1：两个保存配置 + 两个命名会话，含同 hostname ----------
    p4Note("--- A13.1 两个配置 + 两个命名会话 ---")
    let profileIDA = UUID()
    let profileIDB = UUID()
    func runSetup(
      transport: RemoteSessionTransport, rawTarget: String, label: String,
      sessionName: String, profileID: UUID
    ) throws -> (MachineProfile, SessionServerIdentity) {
      let executor = RemoteSSHSetupExecutor(
        transport: transport,
        endpointTemplate: ManagedSessionEndpoint(
          machineProfileID: profileID, binaryPath: context.binaryPath,
          stateParentPath: context.stateParent, sessionName: sessionName))
      let outcome = try RemoteMachineSetup(
        executor: executor, explicitRemoteBinaryPath: context.binaryPath
      ).run(
        rawTarget: rawTarget, label: label, sessionName: sessionName, profileID: profileID)
      guard case .ready(let profile, let identity, _) = outcome else {
        throw ManagedSessionError.runtimeUnavailable("设置未 ready：\(outcome)")
      }
      return (profile, identity)
    }

    let (profileA, identityA) = try runSetup(
      transport: transportA, rawTarget: settings.rawTarget, label: "orb-a",
      sessionName: sessionA, profileID: profileIDA)
    let (profileB, identityB) = try runSetup(
      transport: transportB, rawTarget: aliasName, label: "orb-b",
      sessionName: sessionB, profileID: profileIDB)
    p4LogIdentity("A13/会话A", identityA)
    p4LogIdentity("A13/会话B", identityB)

    #expect(profileA.id != profileB.id, "两份配置的身份必须不同")
    #expect(profileA.sshTarget == settings.rawTarget, "配置 A 必须保留原始 target 文本")
    #expect(profileB.sshTarget == aliasName, "配置 B 必须保留原始 target 文本")
    #expect(
      identityA.reference.serverID != identityB.reference.serverID,
      "两个命名会话各有独立服务实例，serverID 必须不同")

    // 同 hostname 证据：用**配置 B 的 target 文本**去握手**会话 A**。
    // 两个 target 文本不同，但只要它们指向同一台真实主机与同一个命名会话，
    // 服务身份（serverID/epoch/sessionID）必须逐字相同——这就是「按真实服务身份共享
    // 资源，同时保留两份配置」的真实断言，而不是靠比较主机名字符串。
    let crossIdentity = try RemoteManagedSessionClient(transport: transportB).serverStatus(
      context.endpoint(profileID: profileIDB, sessionName: sessionA))
    p4LogIdentity("A13/同主机交叉握手", crossIdentity)
    #expect(
      crossIdentity.reference.serverID == identityA.reference.serverID,
      "不同 target 文本解析到同一主机时必须拿到相同的真实 serverID")
    #expect(crossIdentity.reference.sessionID == identityA.reference.sessionID)
    #expect(crossIdentity.serverEpoch == identityA.serverEpoch, "交叉握手不得重启服务")

    let clientA = RemoteManagedSessionClient(transport: transportA)
    let clientB = RemoteManagedSessionClient(transport: transportB)
    let endpointA = context.endpoint(profileID: profileIDA, sessionName: sessionA)
    let endpointB = context.endpoint(profileID: profileIDB, sessionName: sessionB)
    defer {
      p4TearDownSession(clientA, registry, sessionA)
      p4TearDownSession(clientA, registry, sessionB)
    }

    let listed = try clientA.listSessions(registry)
    p4Note(
      "A13.1 注册表：\(listed.map { "\($0.name)/\($0.state.rawValue)/\($0.sessionID)" }.joined(separator: " "))"
    )
    #expect(listed.contains { $0.name == sessionA && $0.state == .running })
    #expect(listed.contains { $0.name == sessionB && $0.state == .running })

    // 各会话建一个持续输出的计数任务，作为后续所有「不受影响」断言的锚点。
    let markerA = "\(context.runRoot)/counter-a.txt"
    let markerB = "\(context.runRoot)/counter-b.txt"
    let taskA = try clientA.createTerminal(
      endpointA, workingDirectory: context.runRoot, argv: p4CounterScript(markerFile: markerA))
    let taskB = try clientB.createTerminal(
      endpointB, workingDirectory: context.runRoot, argv: p4CounterScript(markerFile: markerB))
    guard let pidA = taskA.pid, let pidB = taskB.pid else {
      Issue.record("计数任务未返回 PID：A=\(String(describing: taskA.pid)) B=\(String(describing: taskB.pid))")
      return
    }
    p4Note("A13 计数任务 A terminalID=\(taskA.reference.terminalID) pid=\(pidA)")
    p4Note("A13 计数任务 B terminalID=\(taskB.reference.terminalID) pid=\(pidB)")

    // ---------- 场景 2：分别修改各会话布局，互不影响 ----------
    p4Note("--- A13.2 分别修改布局 ---")
    let transactionA = WorkspaceTransactionClient(client: clientA, endpoint: endpointA)
    let transactionB = WorkspaceTransactionClient(client: clientB, endpoint: endpointB)
    let baseRevisionA = try transactionA.snapshot().revision
    let baseRevisionB = try transactionB.snapshot().revision
    p4Note("A13.2 起始 revision A=\(baseRevisionA) B=\(baseRevisionB)")

    let spec = RemoteTerminalSpec(cwd: context.runRoot, argv: p4IdleArgv())
    let workspaceA = try transactionA.createWorkspace(
      expectedRevision: baseRevisionA, title: "a13-a", terminal: spec)
    let revisionBDuringA = try transactionB.snapshot().revision
    #expect(revisionBDuringA == baseRevisionB, "会话 A 的布局事务不得推进会话 B 的 revision")

    guard let paneA = workspaceA.value.tabs.first?.layout.allPanes.first else {
      Issue.record("会话 A 的 workspace.create 未返回窗格")
      return
    }
    let splitA = try transactionA.splitPane(
      paneID: paneA.paneID, direction: .right,
      expectedRevision: workspaceA.revision, terminal: spec)
    p4Note(
      "A13.2 会话A workspaceID=\(workspaceA.value.workspaceID) revision \(baseRevisionA)→\(workspaceA.revision)→\(splitA.revision) 新 paneID=\(splitA.value.pane.paneID) terminalID=\(splitA.value.terminal.reference.terminalID) pid=\(splitA.value.terminal.pid.map(String.init) ?? "-")"
    )
    #expect(splitA.value.terminal.pid != nil, "拆分产生的终端必须有真实 PID")

    let workspaceB = try transactionB.createWorkspace(
      expectedRevision: baseRevisionB, title: "a13-b", terminal: spec)
    p4Note(
      "A13.2 会话B workspaceID=\(workspaceB.value.workspaceID) revision \(baseRevisionB)→\(workspaceB.revision)"
    )
    let finalSnapshotA = try transactionA.snapshot()
    let finalSnapshotB = try transactionB.snapshot()
    #expect(finalSnapshotA.revision == splitA.revision, "会话 B 的事务不得推进会话 A 的 revision")
    #expect(
      finalSnapshotA.workspaces.contains { $0.workspaceID == workspaceA.value.workspaceID })
    #expect(
      finalSnapshotB.workspaces.contains { $0.workspaceID == workspaceB.value.workspaceID })
    #expect(
      !finalSnapshotB.workspaces.contains { $0.workspaceID == workspaceA.value.workspaceID },
      "两个命名会话的结构必须互相隔离")

    // ---------- 场景 3：重命名配置不触发重连 ----------
    p4Note("--- A13.3 重命名不重连 ---")
    let epochBeforeRename = try clientA.serverStatus(endpointA).serverEpoch
    var renamed = profileA
    renamed.label = "orb-a-renamed"
    let reconnectIDs = MachineProfileStore.reconnectRequiredProfileIDs(
      old: [profileA, profileB], new: [renamed, profileB])
    p4Note("A13.3 只改 label 的重连集合=\(reconnectIDs)")
    #expect(reconnectIDs.isEmpty, "重命名只改标签，不得触发重连")
    let epochAfterRename = try clientA.serverStatus(endpointA).serverEpoch
    let pidAfterRename = try clientA.listTerminals(endpointA).first {
      $0.reference.terminalID == taskA.reference.terminalID
    }?.pid
    p4Note("A13.3 epoch \(epochBeforeRename)→\(epochAfterRename) pid=\(pidAfterRename.map(String.init) ?? "-")")
    #expect(epochAfterRename == epochBeforeRename, "重命名前后 serverEpoch 必须不变")
    #expect(pidAfterRename == pidA, "重命名前后任务 PID 必须不变")

    // ---------- 场景 4：禁用/移除只分离 ----------
    p4Note("--- A13.4 移除只分离 ---")
    let afterRemove = MachineActivationPolicy.afterDisableOrRemove(
      activeProfileID: profileIDB, affectedProfileID: profileIDB)
    #expect(afterRemove.activeProfileID == MachineProfile.localProfileID, "移除当前机器必须回 Local")
    let remaining = MachineProfileStore.diff(old: [profileA, profileB], new: [profileA])
    #expect(remaining == [.removed(profileIDB)], "移除只产生 removed 变更")
    let taskAfterRemove = try clientB.listTerminals(endpointB).first {
      $0.reference.terminalID == taskB.reference.terminalID
    }
    p4Note(
      "A13.4 移除配置后：state=\(taskAfterRemove?.state.rawValue ?? "-") pid=\(taskAfterRemove?.pid.map(String.init) ?? "-")"
    )
    #expect(taskAfterRemove?.state == .running, "移除配置只断开客户端，远端会话必须仍在运行")
    #expect(taskAfterRemove?.pid == pidB, "移除配置不得改变远端任务 PID")
    #expect(try p4RemotePIDAlive(transportA, pidB), "远端任务进程必须仍然存活")

    // ---------- 场景 5：停止限定本会话 ----------
    p4Note("--- A13.5 停止限定本会话 ---")
    let epochBBeforeStopA = try clientB.serverStatus(endpointB).serverEpoch
    let countBBeforeStopA = try p4RemoteLineCount(transportA, markerB)
    let stoppedA = try clientA.stopSession(registry, selector: .name(sessionA))
    p4Note("A13.5 停止会话 A：state=\(stoppedA.state.rawValue) sessionID=\(stoppedA.sessionID)")
    #expect(stoppedA.state == .stopped)
    #expect(try p4RemotePIDAlive(transportA, pidA) == false, "停止会话必须回收本会话进程")

    Thread.sleep(forTimeInterval: 3)
    let epochBAfterStopA = try clientB.serverStatus(endpointB).serverEpoch
    let taskBAfterStopA = try clientB.listTerminals(endpointB).first {
      $0.reference.terminalID == taskB.reference.terminalID
    }
    let countBAfterStopA = try p4RemoteLineCount(transportA, markerB)
    p4Note(
      "A13.5 会话B epoch \(epochBBeforeStopA)→\(epochBAfterStopA) pid=\(taskBAfterStopA?.pid.map(String.init) ?? "-") 计数 \(countBBeforeStopA)→\(countBAfterStopA)"
    )
    #expect(epochBAfterStopA == epochBBeforeStopA, "停止会话 A 不得影响会话 B 的服务实例")
    #expect(taskBAfterStopA?.pid == pidB, "停止会话 A 不得影响会话 B 的任务 PID")
    #expect(countBAfterStopA > countBBeforeStopA, "会话 B 的任务输出必须继续增长")

    // ---------- 场景 6：活动会话删除被拒 ----------
    p4Note("--- A13.6 活动会话删除被拒 ---")
    var deleteError: ManagedSessionError?
    do {
      _ = try clientB.deleteSession(registry, selector: .name(sessionB))
      Issue.record("运行中的会话不应删除成功")
    } catch let error as ManagedSessionError {
      deleteError = error
    }
    p4Note("A13.6 删除运行中会话的错误：\(String(describing: deleteError))")
    #expect(deleteError?.isSessionRunning == true, "活动会话删除必须原样返回 session_running")
    #expect(try p4RemotePIDAlive(transportA, pidB), "被拒绝的删除不得影响运行中的任务")

    // ---------- 场景 7：停止后删除成功且不影响其它会话 ----------
    p4Note("--- A13.7 停止后删除 ---")
    let deletedA = try clientA.deleteSession(registry, selector: .name(sessionA))
    #expect(deletedA, "已停止的会话必须可以删除")
    let afterDelete = try clientA.listSessions(registry)
    p4Note(
      "A13.7 删除后注册表：\(afterDelete.map { "\($0.name)/\($0.state.rawValue)" }.joined(separator: " "))")
    #expect(!afterDelete.contains { $0.name == sessionA }, "删除后该会话不得再出现在注册表")
    #expect(
      afterDelete.contains { $0.name == sessionB && $0.state == .running },
      "删除一个会话不得影响其它会话")
    let taskBAfterDelete = try clientB.listTerminals(endpointB).first {
      $0.reference.terminalID == taskB.reference.terminalID
    }
    #expect(taskBAfterDelete?.pid == pidB, "删除其它会话不得改变本会话任务 PID")
    p4Note("A13 全部场景结束（清理在 defer 中执行，只限定 runID \(settings.runID)）")
  }

  // MARK: A14（快速部分）

  /// A14：连接状态与配置恢复（R06）中的黑洞地址、虚拟时钟、旧代回调与坏配置恢复。
  ///
  /// ≥60 秒的真实断连拆成独立用例（见 `realDisconnectRecoveryAcceptance`），
  /// 这样这一条可以单独快速重跑。
  @Test(.enabled(if: P4AcceptanceSettings.isEnabled))
  func connectionStateAndProfileRecoveryAcceptance() async throws {
    let settings = P4AcceptanceSettings.fromEnvironment()
    p4Note("=== A14 runID=\(settings.runID) ===")
    #expect(!settings.remoteBinaryPath.isEmpty, "必须提供 ASTER_P4_REMOTE_BINARY_PATH")
    #expect(!settings.localBinary.isEmpty, "必须提供 ASTER_P4_LOCAL_BINARY")

    let policy = RemoteSSHPolicy()
    let configuration = try p4MakePrivateConfiguration(aliases: [])
    let goodTarget = try RemoteSSHTarget.parse(settings.rawTarget)
    // 192.0.2.1 属于 RFC 5737 TEST-NET-1，保证不可路由，SYN 必被丢弃。
    let blackholeTarget = try RemoteSSHTarget.parse("192.0.2.1")
    defer { p4CleanUpPrivateConfiguration(configuration, targets: [goodTarget, blackholeTarget]) }

    let goodTransport = RemoteSessionTransport(
      target: goodTarget, policy: policy, managedConfiguration: configuration)
    let context = try p4PrepareRemote(
      settings: settings, target: goodTarget, transport: goodTransport, scope: "A14")
    let registry = context.registryEndpoint
    let sessionName = "a14-good"
    let goodProfileID = UUID()
    let goodClient = RemoteManagedSessionClient(transport: goodTransport)
    let goodEndpoint = context.endpoint(profileID: goodProfileID, sessionName: sessionName)
    let goodIdentity = try {
      let executor = RemoteSSHSetupExecutor(
        transport: goodTransport, endpointTemplate: goodEndpoint)
      let outcome = try RemoteMachineSetup(
        executor: executor, explicitRemoteBinaryPath: context.binaryPath
      ).run(
        rawTarget: settings.rawTarget, label: "orb-good", sessionName: sessionName,
        profileID: goodProfileID)
      guard case .ready(_, let identity, _) = outcome else {
        throw ManagedSessionError.runtimeUnavailable("正常配置未 ready：\(outcome)")
      }
      return identity
    }()
    p4LogIdentity("A14/正常配置", goodIdentity)
    defer { p4TearDownSession(goodClient, registry, sessionName) }

    // ---------- A14.1 黑洞地址不阻塞 Local 与正常配置 ----------
    p4Note("--- A14.1 黑洞地址 ---")
    let blackholeTransport = RemoteSessionTransport(
      target: blackholeTarget, policy: policy, managedConfiguration: configuration)
    let blackholeExecutor = RemoteSSHSetupExecutor(
      transport: blackholeTransport,
      endpointTemplate: ManagedSessionEndpoint(
        machineProfileID: UUID(), binaryPath: context.binaryPath,
        stateParentPath: context.stateParent, sessionName: "a14-blackhole"))

    // 黑洞连接放到后台线程，前台同时做 Local 与正常远端的真实操作：
    // 「Local 不等待远端」必须用两条时间线的实测耗时证明，不能只看最终都成功。
    let blackholeStart = Date()
    let remoteBinaryPath = settings.remoteBinaryPath
    let blackholeTask = Task.detached { () -> P4SetupAttempt in
      do {
        let outcome = try RemoteMachineSetup(
          executor: blackholeExecutor, explicitRemoteBinaryPath: remoteBinaryPath
        ).run(rawTarget: "192.0.2.1", label: "blackhole", sessionName: "a14-blackhole")
        return .unexpected("黑洞地址不应成功：\(outcome)")
      } catch let failure as RemoteSetupFailure {
        return .failed(
          stage: failure.stage.rawValue, kind: failure.sshKind, message: failure.message,
          requiresExplicitSetup: failure.requiresExplicitSetup)
      } catch {
        return .unexpected(String(describing: error))
      }
    }

    // Local：用本机 macOS 产物真实建一个命名会话并创建终端。
    let localRoot = NSTemporaryDirectory() + "aster-p4-local-\(settings.runID)"
    try FileManager.default.createDirectory(
      atPath: localRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let localClient = LocalManagedSessionClient()
    let localRegistry = ManagedRegistryEndpoint(
      binaryPath: settings.localBinary, stateParentPath: localRoot)
    let localEndpoint = localRegistry.sessionEndpoint(name: "a14-local")
    let localStart = Date()
    let localSession = try localClient.createSession(localRegistry, name: "a14-local")
    let localTerminal = try localClient.createTerminal(
      localEndpoint, workingDirectory: localRoot, argv: p4IdleArgv())
    let localElapsed = Date().timeIntervalSince(localStart)
    p4Note(
      "A14.1 Local 会话 sessionID=\(localSession.sessionID) terminalID=\(localTerminal.reference.terminalID) pid=\(localTerminal.pid.map(String.init) ?? "-") 用时 \(String(format: "%.2f", localElapsed))s"
    )
    #expect(localTerminal.state == .running, "Local 必须在远端黑洞期间照常创建终端")
    if let localPID = localTerminal.pid {
      #expect(p4LocalShell("kill -0 \(localPID)").status == 0, "Local 终端进程必须真实存活")
    } else {
      Issue.record("Local 终端未返回 PID")
    }

    // 正常远端配置在黑洞期间同样可用。
    let goodDuringBlackhole = try goodClient.serverStatus(goodEndpoint)
    #expect(goodDuringBlackhole.serverEpoch == goodIdentity.serverEpoch, "黑洞配置不得影响正常配置")
    p4Note("A14.1 黑洞期间正常配置仍可用：epoch=\(goodDuringBlackhole.serverEpoch)")

    let blackholeResult = await blackholeTask.value
    let blackholeElapsed = Date().timeIntervalSince(blackholeStart)
    p4Note(
      "A14.1 黑洞失败：\(blackholeResult.description) 用时 \(String(format: "%.2f", blackholeElapsed))s（连接超时 \(policy.connectTimeout)s）"
    )
    #expect(blackholeElapsed < 40, "黑洞地址必须在连接超时内失败，不得无限挂起")
    #expect(localElapsed < blackholeElapsed, "Local 不得等待远端黑洞连接")
    if case .failed(_, let kind, _, let requiresExplicitSetup) = blackholeResult {
      #expect(kind == .timeout || kind == .hostUnreachable, "黑洞地址必须归类为超时/不可达")
      #expect(requiresExplicitSetup == false, "黑洞地址属于可自动重试的失败，不进 attention")
    } else {
      Issue.record("黑洞地址未产生 RemoteSetupFailure：\(blackholeResult.description)")
    }

    // Local 清理（远端与本机资源都只限定本轮 runID）。
    _ = try? localClient.terminateTerminal(
      localEndpoint, terminalID: localTerminal.reference.terminalID)
    p4TearDownSession(localClient, localRegistry, "a14-local")
    do { try FileManager.default.removeItem(atPath: localRoot) } catch {
      p4Note("清理失败（本机 Local 目录 \(localRoot)）：\(error)")
    }

    // ---------- A14.2 虚拟时钟验证退避与心跳 ----------
    p4Note("--- A14.2 虚拟时钟 ---")
    let connectionPolicy = MachineConnectionPolicy()
    #expect(connectionPolicy.connectTimeout == 10, "连接超时必须是 10 秒")
    #expect(connectionPolicy.handshakeTimeout == 5, "握手超时必须是 5 秒")
    #expect(connectionPolicy.backoffSchedule == [1, 2, 4, 8, 16, 30], "退避表必须是 1/2/4/8/16/30")
    #expect(connectionPolicy.heartbeatInterval == 15, "心跳间隔必须是 15 秒")
    #expect(connectionPolicy.heartbeatMissTolerance == 3, "连续 3 次未响应转 reconnecting")
    // ±20% 抖动边界：归一化抖动 ±1 对应 ±20%，超出 ±1 必须被夹紧。
    #expect(connectionPolicy.backoffDelay(attempt: 5, jitter: 1) == 36)
    #expect(connectionPolicy.backoffDelay(attempt: 5, jitter: -1) == 24)
    #expect(connectionPolicy.backoffDelay(attempt: 5, jitter: 4) == 36)
    #expect(connectionPolicy.backoffDelay(attempt: 99, jitter: 0) == 30, "超出退避表后固定 30 秒")

    let backoffProfile = MachineProfile(label: "backoff", sshTarget: "example.invalid")
    let backoffClock = P4VirtualClock()
    let backoffDriver = P4ScriptedConnectionDriver(
      connectOutcomes: Array(repeating: .transient(reason: "unreachable"), count: 7))
    let backoffSupervisor = MachineConnectionSupervisor(
      policy: connectionPolicy, environment: backoffClock.environment(jitter: 0),
      driver: backoffDriver)
    await backoffSupervisor.start(profile: backoffProfile)
    _ = await p4WaitForState(
      backoffSupervisor, profileID: backoffProfile.id, state: .attention)
    p4Note("A14.2 退避序列（jitter=0）=\(backoffClock.sleeps)")
    #expect(backoffClock.sleeps == [1, 2, 4, 8, 16, 30, 30], "退避必须按 1/2/4/8/16/30 并封顶")

    let heartbeatProfile = MachineProfile(label: "heartbeat", sshTarget: "example.invalid")
    let heartbeatClock = P4VirtualClock()
    let heartbeatDriver = P4ScriptedConnectionDriver(
      connectOutcomes: [.connected(p4SampleIdentity(profileID: heartbeatProfile.id))],
      heartbeatResults: [false, false, false])
    let heartbeatSupervisor = MachineConnectionSupervisor(
      policy: connectionPolicy, environment: heartbeatClock.environment(jitter: 0),
      driver: heartbeatDriver)
    await heartbeatSupervisor.start(profile: heartbeatProfile)
    _ = await p4WaitForState(
      heartbeatSupervisor, profileID: heartbeatProfile.id, state: .attention)
    p4Note(
      "A14.2 心跳序列=\(heartbeatClock.sleeps) 心跳调用=\(heartbeatDriver.heartbeatCount) 连接调用=\(heartbeatDriver.connectCount)"
    )
    #expect(heartbeatDriver.heartbeatCount == 3, "连续 3 次未响应即转重连，不多试")
    // 三次 15 秒心跳等待之后立刻出现退避表第一档 1 秒，就是「转入 reconnecting」的证据。
    #expect(heartbeatClock.sleeps.prefix(4) == [15, 15, 15, 1])

    // ---------- A14.4 连接中切换配置 + 注入旧代回调 ----------
    p4Note("--- A14.4 旧代回调 ---")
    var switchProfile = MachineProfile(label: "switch", sshTarget: "host-one.invalid")
    let switchClock = P4VirtualClock()
    let switchDriver = P4ScriptedConnectionDriver(connectOutcomes: [])
    let switchSupervisor = MachineConnectionSupervisor(
      policy: connectionPolicy, environment: switchClock.environment(jitter: 0),
      driver: switchDriver)
    await switchSupervisor.start(profile: switchProfile)
    _ = await p4WaitForState(switchSupervisor, profileID: switchProfile.id, state: .attention)
    let staleGeneration = await switchSupervisor.currentGeneration(profileID: switchProfile.id)
    switchProfile.sshTarget = "host-two.invalid"
    await switchSupervisor.start(profile: switchProfile)
    _ = await p4WaitForState(switchSupervisor, profileID: switchProfile.id, state: .attention)
    let freshGeneration = await switchSupervisor.currentGeneration(profileID: switchProfile.id)
    #expect(freshGeneration > staleGeneration, "切换连接相关字段必须递增代次")

    let droppedBefore = await switchSupervisor.droppedStaleResults
    let applied = await switchSupervisor.deliver(
      profileID: switchProfile.id, generation: staleGeneration,
      outcome: .connected(p4SampleIdentity(profileID: switchProfile.id)))
    let droppedAfter = await switchSupervisor.droppedStaleResults
    let statusAfterStale = await switchSupervisor.status(profileID: switchProfile.id)
    p4Note(
      "A14.4 旧代 \(staleGeneration) → 当前 \(freshGeneration)；applied=\(applied) dropped \(droppedBefore)→\(droppedAfter) state=\(statusAfterStale?.state.rawValue ?? "-")"
    )
    #expect(applied == false, "旧代结果必须被丢弃")
    #expect(droppedAfter == droppedBefore + 1, "丢弃计数必须增加")
    #expect(statusAfterStale?.state == .attention, "旧代结果不得改写当前状态")
    #expect(statusAfterStale?.identity == nil, "旧代身份不得被写入")
    #expect(statusAfterStale?.inputAllowed == false)
    let staleInput = await switchSupervisor.submitInput(
      profileID: switchProfile.id, generation: staleGeneration)
    let currentInput = await switchSupervisor.submitInput(
      profileID: switchProfile.id, generation: freshGeneration)
    #expect(staleInput == .deliveryUnknown, "旧代输入结果未知且不自动重放")
    #expect(currentInput == .rejected, "attention 状态不得投递输入")

    // ---------- A14.5 破坏机器配置文件后修复 ----------
    p4Note("--- A14.5 坏配置恢复 ---")
    let storeRoot = NSTemporaryDirectory() + "aster-p4-profiles-\(settings.runID)"
    let storeURL = URL(fileURLWithPath: storeRoot).appendingPathComponent("machines.json")
    defer {
      do { try FileManager.default.removeItem(atPath: storeRoot) } catch {
        p4Note("清理失败（机器配置目录 \(storeRoot)）：\(error)")
      }
    }
    let store = MachineProfileStore(fileURL: storeURL)
    let saved = [
      MachineProfile(label: "orb-good", sshTarget: settings.rawTarget, sessionName: sessionName),
      MachineProfile(label: "orb-other", sshTarget: "example.invalid", sessionName: "other"),
    ]
    try store.save(saved)
    #expect(store.effectiveProfiles == saved)

    try Data("{ this is not json".utf8).write(to: storeURL)
    var corruptedError: MachineProfileStoreError?
    do {
      _ = try store.load()
      Issue.record("损坏配置不应加载成功")
    } catch let error as MachineProfileStoreError {
      corruptedError = error
    }
    if case .corrupted(let detail) = corruptedError {
      p4Note("A14.5 损坏配置：corrupted(\(detail))")
    } else {
      Issue.record("损坏配置必须报 corrupted，实际 \(String(describing: corruptedError))")
    }
    #expect(store.effectiveProfiles == saved, "损坏配置必须保留最后有效快照与现存连接")

    try FileManager.default.removeItem(at: storeURL)
    let absent = try store.load()
    p4Note("A14.5 文件删除后的加载结果=\(absent)")
    #expect(absent == .absent, "文件删除与内容损坏必须是两种不同结果")
    #expect(store.effectiveProfiles == saved, "文件缺失同样不得清空最后有效快照")

    try MachineProfileStore.encode(saved).write(to: storeURL)
    let repaired = try store.load()
    #expect(repaired == .loaded(saved), "写回合法内容后必须一次性应用成功")
    p4Note("A14.5 修复后有效配置数=\(store.effectiveProfiles.count)")
  }

  // MARK: A14.3（≥60 秒真实断连）

  /// A14.3：真实断连 ≥60 秒后恢复。
  ///
  /// 单独一个用例，因为它至少要等 60 秒；断连手段是停掉本轮专用的本地 TCP 中继，
  /// 只对状态文件里记录的那一个 PID 发信号，不触碰 OrbStack 本身、也不按进程名匹配。
  @Test(.enabled(if: P4AcceptanceSettings.isEnabled))
  func realDisconnectRecoveryAcceptance() async throws {
    let settings = P4AcceptanceSettings.fromEnvironment()
    p4Note("=== A14.3 runID=\(settings.runID) ===")
    #expect(!settings.remoteBinaryPath.isEmpty, "必须提供 ASTER_P4_REMOTE_BINARY_PATH")
    guard FileManager.default.isReadableFile(atPath: settings.relayScript) else {
      Issue.record("中继脚本不可读：\(settings.relayScript)")
      return
    }

    let relayStateFile = NSTemporaryDirectory() + "aster-p4-relay-\(settings.runID).json"
    let relay = P4Relay(
      scriptPath: settings.relayScript, stateFile: relayStateFile, port: settings.relayPort)
    try relay.start(targetHost: settings.orbBackendHost, targetPort: settings.orbBackendPort)
    defer {
      _ = relay.stop()
      do { try FileManager.default.removeItem(atPath: relayStateFile) } catch {
        p4Note("清理失败（中继状态文件 \(relayStateFile)）：\(error)")
      }
    }

    let aliasName = "aster-p4-relay-\(settings.runID.replacingOccurrences(of: "_", with: "-"))"
    let configuration = try p4MakePrivateConfiguration(aliases: [
      P4SSHAlias(
        alias: aliasName, hostName: "127.0.0.1", port: relay.port,
        user: settings.orbUser, identityFile: settings.orbIdentityFile)
    ])
    let relayTarget = try RemoteSSHTarget.parse(aliasName)
    defer { p4CleanUpPrivateConfiguration(configuration, targets: [relayTarget]) }
    p4Note("A14.3 中继 target 解析：raw=\(relayTarget.rawText) host=\(relayTarget.host)")

    let transport = RemoteSessionTransport(
      target: relayTarget, policy: RemoteSSHPolicy(), managedConfiguration: configuration)
    let context = try p4PrepareRemote(
      settings: settings, target: relayTarget, transport: transport, scope: "A14.3")
    let registry = context.registryEndpoint
    let sessionName = "a14-relay"
    let profileID = UUID()
    let endpoint = context.endpoint(profileID: profileID, sessionName: sessionName)
    let client = RemoteManagedSessionClient(transport: transport)
    let executor = RemoteSSHSetupExecutor(transport: transport, endpointTemplate: endpoint)
    let outcome = try RemoteMachineSetup(
      executor: executor, explicitRemoteBinaryPath: context.binaryPath
    ).run(
      rawTarget: aliasName, label: "orb-relay", sessionName: sessionName, profileID: profileID)
    guard case .ready(let profile, let identity, _) = outcome else {
      Issue.record("经中继的设置未 ready：\(outcome)")
      return
    }
    p4LogIdentity("A14.3", identity)
    #expect(profile.sshTarget == aliasName, "配置必须保留原始 target 文本")
    defer { p4TearDownSession(client, registry, sessionName) }

    let markerFile = "\(context.runRoot)/counter-relay.txt"
    let task = try client.createTerminal(
      endpoint, workingDirectory: context.runRoot, argv: p4CounterScript(markerFile: markerFile))
    guard let taskPID = task.pid else {
      Issue.record("计数任务未返回 PID")
      return
    }
    p4Note("A14.3 计数任务 terminalID=\(task.reference.terminalID) pid=\(taskPID)")
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let countBefore = try p4RemoteLineCount(transport, markerFile)
    let epochBefore = identity.serverEpoch
    p4Note("A14.3 断连前 epoch=\(epochBefore) 计数=\(countBefore)")

    // ---------- 断连 ----------
    #expect(relay.stop(), "中继必须按记录的 PID 停止")
    let failStart = Date()
    var offlineError: (any Error)?
    do {
      _ = try client.listTerminals(endpoint)
      Issue.record("断连期间的客户端操作不应成功")
    } catch { offlineError = error }
    let failElapsed = Date().timeIntervalSince(failStart)
    p4Note(
      "A14.3 断连期间操作失败：\(String(describing: offlineError)) 用时 \(String(format: "%.2f", failElapsed))s"
    )
    #expect(offlineError != nil, "断连期间必须明确失败，不得挂起")
    #expect(failElapsed < 40, "断连期间的失败必须有界，不得无限等待")

    // 缓存必须明确 stale：断线状态既不允许输入也不允许导航。
    let offlineStatus = MachineConnectionStatus(
      profileID: profileID, state: .reconnecting, generation: 1, failureCount: 1,
      identity: identity, inputAllowed: false, lastUpdatedAt: Date(), reason: "relay down")
    let presentation = MachineOfflinePresentation.from(offlineStatus)
    p4Note(
      "A14.3 离线呈现 stale=\(presentation.isStale) dimmed=\(presentation.isDimmed) input=\(presentation.allowsInput) navigation=\(presentation.allowsNavigation)"
    )
    #expect(presentation.isStale, "断线时缓存必须明确标为 stale")
    #expect(presentation.allowsInput == false, "断线期间不得发送输入")
    #expect(presentation.allowsNavigation == false, "断线期间不得操作窗格与标签")

    // 断线期间的输入不投递：用真实编排器状态判定，不靠界面自觉。
    let clock = P4VirtualClock()
    let driver = P4ScriptedConnectionDriver(
      connectOutcomes: [.transient(reason: "relay down"), .needsExplicitSetup(kind: nil, reason: "stop")])
    let supervisor = MachineConnectionSupervisor(
      environment: clock.environment(jitter: 0), driver: driver)
    let offlineProfile = MachineProfile(
      id: profileID, label: "orb-relay", sshTarget: aliasName, sessionName: sessionName)
    await supervisor.start(profile: offlineProfile)
    _ = await p4WaitForState(supervisor, profileID: profileID, state: .attention)
    let generation = await supervisor.currentGeneration(profileID: profileID)
    let delivery = await supervisor.submitInput(profileID: profileID, generation: generation)
    #expect(delivery == .rejected, "不在线时输入必须被拒绝且不缓存")

    // ---------- 等待 ≥60 秒 ----------
    p4Note("A14.3 保持断连 65 秒…")
    try await Task.sleep(nanoseconds: 65_000_000_000)

    // ---------- 恢复 ----------
    try relay.start(targetHost: settings.orbBackendHost, targetPort: settings.orbBackendPort)
    var recovered = false
    let recoverDeadline = Date().addingTimeInterval(60)
    while Date() < recoverDeadline {
      if (try? p4RemoteShell(transport, "true", timeout: 15)) != nil {
        recovered = true
        break
      }
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    #expect(recovered, "重启中继后必须能重新连接")

    let statusAfter = try client.serverStatus(endpoint)
    let taskAfter = try client.listTerminals(endpoint).first {
      $0.reference.terminalID == task.reference.terminalID
    }
    let countAfter = try p4RemoteLineCount(transport, markerFile)
    p4Note(
      "A14.3 恢复后 epoch \(epochBefore)→\(statusAfter.serverEpoch) pid=\(taskAfter?.pid.map(String.init) ?? "-") 计数 \(countBefore)→\(countAfter)"
    )
    #expect(statusAfter.serverEpoch == epochBefore, "断连恢复不得重启服务（epoch 必须不变）")
    #expect(taskAfter?.state == .running, "任务必须仍在运行")
    #expect(taskAfter?.pid == taskPID, "断连恢复不得改变任务 PID")
    #expect(countAfter > countBefore + 50, "任务必须在断连期间持续产出（每秒一行，断连 ≥60 秒）")
    #expect(try p4RemotePIDAlive(transport, taskPID), "任务进程必须真实存活")

    // 重连不抢焦点：活动机器与焦点窗格必须逐字保持。
    let focusedPane = UUID()
    let afterReconnect = MachineActivationPolicy.afterReconnect(
      activeProfileID: profileID, focusedPaneID: focusedPane)
    #expect(afterReconnect.activeProfileID == profileID, "重连不得改变活动机器")
    #expect(afterReconnect.focusedPaneID == focusedPane, "重连不得改变焦点窗格")
    p4Note("A14.3 重连不抢焦点：activeProfileID=\(afterReconnect.activeProfileID) focusedPaneID=\(focusedPane)")

    _ = try? client.terminateTerminal(endpoint, terminalID: task.reference.terminalID)
  }

  // MARK: A15

  /// A15：共享结构、焦点与画面兴趣（R07）。
  ///
  /// 两个客户端是两份**独立的生产客户端实例**（各自的 SSH 传输、各自的
  /// `WorkspaceTransactionClient` 与 `ClientSurfaceInterest`），因此「结构共享、焦点独立」
  /// 是被真实连接证明的，而不是同一个对象自己和自己比。
  @Test(.enabled(if: P4AcceptanceSettings.isEnabled))
  func sharedStructureFocusAndSurfaceInterestAcceptance() async throws {
    let settings = P4AcceptanceSettings.fromEnvironment()
    p4Note("=== A15 runID=\(settings.runID) ===")
    #expect(!settings.remoteBinaryPath.isEmpty, "必须提供 ASTER_P4_REMOTE_BINARY_PATH")

    let target = try RemoteSSHTarget.parse(settings.rawTarget)
    // 两个客户端各用一份私有 SSH 配置与各自的 control socket：这才是两条真实连接。
    let configurationOne = try p4MakePrivateConfiguration(aliases: [])
    let configurationTwo = try p4MakePrivateConfiguration(aliases: [])
    defer {
      p4CleanUpPrivateConfiguration(configurationOne, targets: [target])
      p4CleanUpPrivateConfiguration(configurationTwo, targets: [target])
    }
    let transportOne = RemoteSessionTransport(
      target: target, policy: RemoteSSHPolicy(), managedConfiguration: configurationOne)
    let transportTwo = RemoteSessionTransport(
      target: target, policy: RemoteSSHPolicy(), managedConfiguration: configurationTwo)

    let context = try p4PrepareRemote(
      settings: settings, target: target, transport: transportOne, scope: "A15")
    let registry = context.registryEndpoint
    let sessionName = "a15"
    let profileOne = UUID()
    let profileTwo = UUID()
    let endpointOne = context.endpoint(profileID: profileOne, sessionName: sessionName)
    let endpointTwo = context.endpoint(profileID: profileTwo, sessionName: sessionName)
    let sessionClientOne = RemoteManagedSessionClient(transport: transportOne)
    let sessionClientTwo = RemoteManagedSessionClient(transport: transportTwo)

    let identityOne = try {
      let executor = RemoteSSHSetupExecutor(
        transport: transportOne, endpointTemplate: endpointOne)
      let outcome = try RemoteMachineSetup(
        executor: executor, explicitRemoteBinaryPath: context.binaryPath
      ).run(
        rawTarget: settings.rawTarget, label: "a15-one", sessionName: sessionName,
        profileID: profileOne)
      guard case .ready(_, let identity, _) = outcome else {
        throw ManagedSessionError.runtimeUnavailable("A15 设置未 ready：\(outcome)")
      }
      return identity
    }()
    let identityTwo = try sessionClientTwo.serverStatus(endpointTwo)
    p4LogIdentity("A15/客户端1", identityOne)
    p4LogIdentity("A15/客户端2", identityTwo)
    #expect(
      identityTwo.reference.serverID == identityOne.reference.serverID,
      "两个客户端必须连到同一个真实服务实例")
    #expect(identityTwo.serverEpoch == identityOne.serverEpoch)
    defer { p4TearDownSession(sessionClientOne, registry, sessionName) }

    let clientOne = WorkspaceTransactionClient(client: sessionClientOne, endpoint: endpointOne)
    let clientTwo = WorkspaceTransactionClient(client: sessionClientTwo, endpoint: endpointTwo)
    var interestOne = ClientSurfaceInterest(clientID: "a15-client-one")
    var interestTwo = ClientSurfaceInterest(clientID: "a15-client-two")

    // ---------- A15.1 相同结构、独立焦点 ----------
    p4Note("--- A15.1 相同结构、独立焦点 ---")
    let idleSpec = RemoteTerminalSpec(cwd: context.runRoot, argv: p4IdleArgv())
    let baseRevision = try clientOne.snapshot().revision
    let workspace = try clientOne.createWorkspace(
      expectedRevision: baseRevision, title: "a15-shared", terminal: idleSpec)
    let secondTab = try clientOne.createTab(
      workspaceID: workspace.value.workspaceID, expectedRevision: workspace.revision,
      title: "a15-tab-two", terminal: idleSpec)
    p4Note(
      "A15.1 workspaceID=\(workspace.value.workspaceID) tab1=\(workspace.value.tabs.first?.tabID ?? "-") tab2=\(secondTab.value.tabID) revision \(baseRevision)→\(workspace.revision)→\(secondTab.revision)"
    )

    let snapshotOne = try clientOne.snapshot()
    let snapshotTwo = try clientTwo.snapshot()
    #expect(snapshotOne.workspaces == snapshotTwo.workspaces, "两个客户端必须看到相同的共享结构")
    #expect(snapshotOne.revision == snapshotTwo.revision)

    // 两端「查看不同标签」：各自维护自己的可见集合与焦点，互不影响。
    guard let sharedWorkspace = snapshotOne.workspaces.first(where: {
      $0.workspaceID == workspace.value.workspaceID
    }),
      sharedWorkspace.tabs.count >= 2,
      let paneInTabOne = sharedWorkspace.tabs[0].layout.allPanes.first,
      let paneInTabTwo = sharedWorkspace.tabs[1].layout.allPanes.first,
      let paneUUIDOne = UUID(uuidString: paneInTabOne.paneID),
      let paneUUIDTwo = UUID(uuidString: paneInTabTwo.paneID)
    else {
      Issue.record("共享结构里缺少两个标签或窗格")
      return
    }
    interestOne.focus(paneID: paneUUIDOne)
    _ = interestOne.becameVisible(terminalID: paneInTabOne.terminalID)
    interestTwo.focus(paneID: paneUUIDTwo)
    _ = interestTwo.becameVisible(terminalID: paneInTabTwo.terminalID)
    #expect(interestOne.focusedPaneID == paneUUIDOne)
    #expect(interestTwo.focusedPaneID == paneUUIDTwo)
    interestTwo.focus(paneID: nil)
    #expect(interestOne.focusedPaneID == paneUUIDOne, "一端换焦点不得影响另一端")
    #expect(interestOne.visibleSurfaces != interestTwo.visibleSurfaces, "可见集合必须互相独立")
    p4Note(
      "A15.1 焦点独立：客户端1 pane=\(paneInTabOne.paneID) 客户端2 pane=\(paneInTabTwo.paneID)")

    // 在客户端 1 上真实创建、拆分、改标题、关闭；客户端 2 重新取快照后结构一致。
    let split = try clientOne.splitPane(
      paneID: paneInTabOne.paneID, direction: .down,
      expectedRevision: secondTab.revision, terminal: idleSpec)
    let retitled = try clientOne.updatePane(
      paneID: split.value.pane.paneID, expectedRevision: split.revision, title: "a15-renamed")
    let closed = try clientOne.closeTab(
      tabID: sharedWorkspace.tabs[1].tabID, expectedRevision: retitled.revision)
    p4Note(
      "A15.1 结构变更：split pane=\(split.value.pane.paneID) terminal=\(split.value.terminal.reference.terminalID) pid=\(split.value.terminal.pid.map(String.init) ?? "-")；改标题 revision=\(retitled.revision)；关闭标签 closed=\(closed.value) revision=\(closed.revision)"
    )
    #expect(split.value.terminal.pid != nil, "拆分产生的终端必须有真实 PID")
    #expect(closed.value, "关闭标签必须成功")
    let afterChangesOne = try clientOne.snapshot()
    let afterChangesTwo = try clientTwo.snapshot()
    #expect(afterChangesOne.workspaces == afterChangesTwo.workspaces, "结构变更后两端必须仍然一致")
    #expect(afterChangesTwo.revision == closed.revision)
    #expect(
      afterChangesTwo.workspaces.flatMap(\.tabs).allSatisfy {
        $0.tabID != sharedWorkspace.tabs[1].tabID
      }, "被关闭的标签不得出现在另一客户端的快照里")

    // ---------- A15.2 同 revision 并发（继承 A06） ----------
    p4Note("--- A15.2 同 revision 并发 ---")
    // 并发前先取一次快照：会话 revision 是共享的，必须用实测值而不是推算值。
    let preConcurrency = try clientOne.snapshot()
    guard let concurrencyPane = p4FirstPane(preConcurrency) else {
      Issue.record("并发前快照里没有可用窗格")
      return
    }
    let preRevision = preConcurrency.revision
    p4Note("A15.2 并发前 revision=\(preRevision) paneID=\(concurrencyPane.paneID)")

    let firstTask = Task.detached { () -> P4SplitAttempt in
      p4AttemptSplit(
        client: clientOne, paneID: concurrencyPane.paneID, direction: .right,
        expectedRevision: preRevision, terminal: idleSpec)
    }
    let secondTask = Task.detached { () -> P4SplitAttempt in
      p4AttemptSplit(
        client: clientTwo, paneID: concurrencyPane.paneID, direction: .down,
        expectedRevision: preRevision, terminal: idleSpec)
    }
    let attempts = [await firstTask.value, await secondTask.value]
    var winner: WorkspaceTransactionResult<RemotePaneSplitResult>?
    var conflictRevision: UInt64??
    for attempt in attempts {
      switch attempt {
      case .ok(let result): winner = result
      case .conflict(let current): conflictRevision = .some(current)
      case .other(let text): Issue.record("并发提交出现非预期错误：\(text)")
      }
    }
    guard let winner else {
      Issue.record("并发提交必须恰好有一个成功：\(attempts)")
      return
    }
    guard let conflictRevision else {
      Issue.record("并发提交必须恰好有一个收到 revision_conflict：\(attempts)")
      return
    }
    p4Note(
      "A15.2 pre-revision=\(preRevision) 成功方 revision=\(winner.revision) 冲突方 currentRevision=\(conflictRevision.map(String.init) ?? "nil")"
    )
    p4Note(
      "A15.2 成功方新终端 terminalID=\(winner.value.terminal.reference.terminalID) pid=\(winner.value.terminal.pid.map(String.init) ?? "-") paneID=\(winner.value.pane.paneID)"
    )
    #expect(winner.revision > preRevision, "成功方必须推进 revision")
    #expect(winner.value.terminal.pid != nil, "成功方新终端必须有真实 PID")
    if let winnerPID = winner.value.terminal.pid {
      #expect(try p4RemotePIDAlive(transportOne, winnerPID), "成功方新终端进程必须真实存活")
    }
    if let current = conflictRevision {
      #expect(current >= winner.revision, "服务端带回的 currentRevision 不得比成功方旧")
    }

    // 冲突方拿新快照重试必须成功。
    let retried = try clientTwo.retryWithFreshSnapshot { revision in
      try clientTwo.splitPane(
        paneID: concurrencyPane.paneID, direction: .down,
        expectedRevision: revision, terminal: idleSpec)
    }
    p4Note(
      "A15.2 冲突方重试成功：revision=\(retried.revision) terminalID=\(retried.value.terminal.reference.terminalID) pid=\(retried.value.terminal.pid.map(String.init) ?? "-")"
    )
    #expect(retried.revision > winner.revision, "重试必须基于新 revision 提交成功")

    // ---------- A15.3 隐藏终端持续输出，再切回取得写权 ----------
    p4Note("--- A15.3 隐藏仍产出，重新可见先快照后交互 ---")
    let hiddenMarker = "\(context.runRoot)/counter-a15.txt"
    let hiddenSplit = try clientOne.splitPane(
      paneID: concurrencyPane.paneID, direction: .right,
      expectedRevision: retried.revision,
      terminal: RemoteTerminalSpec(
        cwd: context.runRoot, argv: p4CounterScript(markerFile: hiddenMarker)))
    let hiddenTerminalID = hiddenSplit.value.terminal.reference.terminalID
    guard let hiddenPID = hiddenSplit.value.terminal.pid else {
      Issue.record("隐藏输出终端未返回 PID")
      return
    }
    p4Note("A15.3 隐藏输出终端 terminalID=\(hiddenTerminalID) pid=\(hiddenPID)")

    _ = interestOne.becameVisible(terminalID: hiddenTerminalID)
    interestOne.confirmSnapshot(terminalID: hiddenTerminalID)
    interestOne.acquireWriteLease(terminalID: hiddenTerminalID)
    #expect(interestOne.resizeDecision(terminalID: hiddenTerminalID) == .allowed)

    try await Task.sleep(nanoseconds: 3_000_000_000)
    let countBeforeHide = try p4RemoteLineCount(transportOne, hiddenMarker)
    let hideIntents = interestOne.becameHidden(terminalID: hiddenTerminalID)
    p4Note("A15.3 隐藏意图=\(hideIntents)")
    #expect(hideIntents == [.unsubscribe(terminalID: hiddenTerminalID)], "隐藏必须产生取消画面订阅意图")
    #expect(interestOne.gate(terminalID: hiddenTerminalID) == .closed)
    #expect(
      interestOne.resizeDecision(terminalID: hiddenTerminalID) == .rejected(.notVisible),
      "不可见的控制器不得改尺寸")

    try await Task.sleep(nanoseconds: 6_000_000_000)
    let countAfterHide = try p4RemoteLineCount(transportOne, hiddenMarker)
    p4Note("A15.3 隐藏期间计数 \(countBeforeHide)→\(countAfterHide)")
    #expect(countAfterHide > countBeforeHide, "隐藏画面后服务端必须继续排空 PTY，任务持续产出")
    #expect(try p4RemotePIDAlive(transportOne, hiddenPID), "隐藏期间任务进程必须存活")

    let visibleIntents = interestOne.becameVisible(terminalID: hiddenTerminalID)
    p4Note("A15.3 重新可见意图=\(visibleIntents)")
    #expect(
      visibleIntents == [
        .subscribe(terminalID: hiddenTerminalID), .requestSnapshot(terminalID: hiddenTerminalID),
      ], "重新可见必须先订阅并请求完整快照")
    #expect(interestOne.gate(terminalID: hiddenTerminalID) == .awaitingSnapshot)
    #expect(interestOne.allowsInteraction(terminalID: hiddenTerminalID) == false)
    #expect(
      interestOne.resizeDecision(terminalID: hiddenTerminalID) == .rejected(.gateNotOpen),
      "快照确认之前不得放行交互与尺寸更新")
    interestOne.confirmSnapshot(terminalID: hiddenTerminalID)
    #expect(interestOne.gate(terminalID: hiddenTerminalID) == .open)
    #expect(interestOne.resizeDecision(terminalID: hiddenTerminalID) == .allowed)

    // 只有「持有写租约且可见」的控制器才能 resize：客户端 2 可见但无租约。
    _ = interestTwo.becameVisible(terminalID: hiddenTerminalID)
    interestTwo.confirmSnapshot(terminalID: hiddenTerminalID)
    #expect(
      interestTwo.resizeDecision(terminalID: hiddenTerminalID) == .rejected(.noWriteLease),
      "没有写租约的客户端不得改尺寸")

    // ---------- A15.4 混合布局本地资源隔离 ----------
    p4Note("--- A15.4 混合布局本地资源隔离 ---")
    let snapshotForProjection = try clientOne.snapshot()
    let projected = try RemoteWorkspaceProjection.project(
      snapshot: snapshotForProjection, server: identityOne.reference)
    guard let projectedTab = projected.workspaces.first?.tabs.first else {
      Issue.record("投影结果里没有标签")
      return
    }
    let localSecretPath = "\(NSTemporaryDirectory())aster-p4-local-secret-\(settings.runID).txt"
    let localDirectory = "\(NSTemporaryDirectory())aster-p4-local-\(settings.runID)"
    guard let managedPane = projectedTab.layout.allPanes.first else {
      Issue.record("投影结果里没有窗格")
      return
    }
    // 来源客户端的混合布局：受管终端 + 本地文件 Pane，并给受管窗格挂一个本地关联。
    var annotatedManagedPane = managedPane
    annotatedManagedPane.resourcePath = localSecretPath
    annotatedManagedPane.workingDirectory = localDirectory
    let localFilePane = PaneDescriptor(
      kind: .fileBrowser, workingDirectory: localDirectory, resourcePath: localSecretPath)
    let mixedLayout = PaneLayout.split(
      axis: .horizontal,
      first: .leaf(annotatedManagedPane),
      second: .leaf(localFilePane),
      ratio: 0.5)

    let submission = ManagedSubtreeMapping.submission(for: mixedLayout)
    let submissionJSON = String(
      decoding: try JSONEncoder().encode(submission.layout), as: UTF8.self)
    p4Note("A15.4 提交载荷=\(submissionJSON)")
    p4Note("A15.4 保留在本地的 Pane=\(submission.retainedLocalPaneIDs)")
    #expect(
      !submissionJSON.contains(localSecretPath), "提交载荷不得包含任何本地 resourcePath")
    #expect(!submissionJSON.contains(localDirectory), "提交载荷不得包含本地目录")
    #expect(
      !submissionJSON.contains(localFilePane.id.uuidString.lowercased()),
      "提交载荷不得包含本地文件 Pane")
    #expect(
      submission.retainedLocalPaneIDs.contains(localFilePane.id), "本地文件 Pane 必须留在来源客户端")
    #expect(submission.layout?.allPanes.count == 1, "共享子树只保留受管终端")

    // 第二客户端从服务端快照投影：只有受管终端，没有来源客户端的本地资源。
    let projectedForTwo = try RemoteWorkspaceProjection.project(
      snapshot: try clientTwo.snapshot(), server: identityTwo.reference)
    let panesForTwo = projectedForTwo.workspaces.flatMap { $0.tabs }.flatMap { $0.layout.allPanes }
    #expect(panesForTwo.allSatisfy { $0.kind == .terminal }, "第二客户端只应看到受管终端")
    #expect(panesForTwo.allSatisfy { $0.resourcePath == nil }, "第二客户端不得拿到本地资源路径")
    #expect(panesForTwo.allSatisfy { $0.managedTerminal != nil })
    #expect(
      !panesForTwo.contains { $0.id == localFilePane.id }, "第二客户端不得看到来源客户端的本地 Pane")
    p4Note("A15.4 第二客户端窗格数=\(panesForTwo.count)（全部受管终端、无本地资源）")

    // 来源客户端 merge 回去：本地关联按 paneID 正确恢复。
    let associations = ManagedSubtreeMapping.captureLocalAssociations(in: mixedLayout)
    let mergedForSource = ManagedSubtreeMapping.merge(
      shared: projectedTab.layout, localAssociations: associations)
    let restored = mergedForSource.allPanes.first { $0.id == managedPane.id }
    p4Note("A15.4 来源客户端恢复后 resourcePath=\(restored?.resourcePath ?? "-")")
    #expect(restored?.resourcePath == localSecretPath, "来源客户端的本地关联必须正确恢复")
    #expect(restored?.workingDirectory == localDirectory)
    let mergedForOther = ManagedSubtreeMapping.merge(
      shared: projectedTab.layout, localAssociations: [:])
    #expect(
      mergedForOther.allPanes.allSatisfy { $0.resourcePath == nil },
      "其它客户端 merge 后仍然拿不到本地资源")

    p4Note("A15 全部场景结束（清理在 defer 中执行，只限定 runID \(settings.runID)）")
  }
}

// MARK: - 后台设置尝试的结果

/// 一次在后台执行的机器设置尝试结果。跨 `Task` 传递，必须是 `Sendable`，
/// 所以只搬运已脱敏的分类与文本，不搬运 `any Error`。
private enum P4SetupAttempt: Sendable {
  case unexpected(String)
  case failed(
    stage: String, kind: RemoteSSHFailureKind?, message: String, requiresExplicitSetup: Bool)

  var description: String {
    switch self {
    case .unexpected(let text): text
    case .failed(let stage, let kind, let message, _):
      "stage=\(stage) kind=\(kind?.rawValue ?? "-") message=\(message)"
    }
  }
}
