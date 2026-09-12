import Foundation
import Testing

@testable import AsterCore

/// P3 的 OrbStack 真实验收补充：A10.1/A10.2/A10.4 的 SSH 配置形态与 A11.4 的自定义开发二进制。
///
/// 与 `RemoteWorkP3AcceptanceTests` 同一套开关（`ASTER_P3_ORB=1`）与证据规则：每轮唯一
/// runID，远端资源全部放在 `${HOME}/.local/state/aster-test/<runID>-cfg` 下，清理只限定该
/// 目录；不按进程名结束任何进程。本文件自造的 SSH 配置写在 `/tmp` 下的 0700 私有目录里，
/// 用完即删，绝不改动用户的 `~/.ssh/config`。

/// 验收运行参数。与已有验收文件共用同一批环境变量，runID 加 `-cfg` 后缀避免撞车。
private struct P3ConfigSettings {
  var rawTarget: String
  var runID: String
  var localLinuxBinary: String

  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["ASTER_P3_ORB"] == "1"
  }

  static func fromEnvironment() -> P3ConfigSettings {
    let environment = ProcessInfo.processInfo.environment
    let base = environment["ASTER_P3_RUN_ID"] ?? "p3-\(Int(Date().timeIntervalSince1970))"
    return P3ConfigSettings(
      rawTarget: environment["ASTER_P3_TARGET"] ?? "root@ubuntu@orb",
      runID: "\(base)-cfg",
      localLinuxBinary: environment["ASTER_P3_LOCAL_BINARY"] ?? ""
    )
  }
}

/// 验收过程中的结构化日志。写到 stdout，由外层脚本重定向到证据日志文件。
private func cfgNote(_ text: String) {
  print("[P3CFG] \(text)")
}

/// 直接执行一条远端 shell 命令并返回结果。用于建目录、读版本、判断 socket 等辅助动作。
private func cfgRemoteShell(
  _ transport: RemoteSessionTransport,
  _ script: String,
  timeout: TimeInterval = 30
) throws -> RemoteSSHResult {
  try RemoteSSHProcessRunner().run(
    arguments: transport.sshArguments(remoteCommand: ["/bin/sh", "-c", script]),
    timeout: timeout)
}

/// 去掉首尾空白，日志与断言统一用它，避免换行干扰比较。
private func cfgTrim(_ text: String) -> String {
  text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 读取 OpenSSH 对某个 target 的最终解析结果（`ssh -G`）。
///
/// 为什么按“首次出现”取值：`ssh -G` 对 `identityfile` 之类可重复的关键字会打印多行，
/// 而 OpenSSH 自身的语义就是首次出现优先，这里保持一致，避免取到后面的默认候选。
private func cfgResolvedConfiguration(
  _ rawTarget: String, configurationFile: String? = nil
) throws -> [String: String] {
  // 自造的 aster-p3-* alias 只存在于私有配置里，解析它必须带上 `-F`，否则 OpenSSH
  // 找不到 Host 段，会把别名本身当主机名、端口当成默认 22。
  var argv: [String] = ["-G"]
  if let configurationFile { argv += ["-F", configurationFile] }
  argv += ["--", rawTarget]
  let result = try RemoteSSHProcessRunner().run(arguments: argv, timeout: 20)
  var map: [String: String] = [:]
  for line in result.standardOutput.split(separator: "\n") {
    let parts = line.split(separator: " ", maxSplits: 1)
    guard let key = parts.first, map[String(key)] == nil else { continue }
    map[String(key)] = parts.count > 1 ? String(parts[1]) : ""
  }
  return map
}

/// 一轮验收共用的环境：自造的私有 SSH 配置、由被测代码生成的私有配置、传输与远端路径。
///
/// 之所以把手写配置再交给 `RemoteSSHConfigurationManager.makePrivateConfiguration` 去
/// `Include`，是因为要验的是**产品代码生成的私有配置**在真实 alias / ProxyJump 场景下也能
/// 工作；直接把手写文件当 `-F` 会绕过被测代码，验不到 ControlMaster 与保活的注入。
private struct P3ConfigEnvironment {
  var settings: P3ConfigSettings
  var target: RemoteSSHTarget
  var policy: RemoteSSHPolicy
  /// `/tmp` 下的 0700 私有目录，存放手写配置；测试结束删除。
  var scratchDirectory: String
  /// 手写的 alias / ProxyJump / 端口 / IPv6 配置（0600）。
  var aliasConfigurationPath: String
  /// 被测代码生成的私有配置（`Include` 了上面那份）。
  var managed: RemoteSSHManagedConfiguration
  var transport: RemoteSessionTransport
  var platformOS: String
  var architecture: String
  var home: String
  var runRoot: String

  /// OrbStack 的容器内部没有任何监听中的 TCP 端口（也没有 sshd），
  /// 唯一能构成真实两跳的路径是让容器通过这个名字回连 Mac 上的 OrbStack SSH 代理。
  static let jumpDestinationHost = "host.orb.internal"

  static func make() throws -> P3ConfigEnvironment {
    let settings = P3ConfigSettings.fromEnvironment()
    let target = try RemoteSSHTarget.parse(settings.rawTarget)
    let policy = RemoteSSHPolicy()

    let resolved = try cfgResolvedConfiguration(settings.rawTarget)
    let hostName = resolved["hostname"] ?? target.host
    let port = resolved["port"] ?? "22"
    let user = resolved["user"] ?? (target.user ?? "root")
    let identityFile = resolved["identityfile"] ?? ""
    let proxyCommand = resolved["proxycommand"] ?? "none"
    cfgNote("ssh -G \(settings.rawTarget)：user=\(user) hostname=\(hostName) port=\(port)")
    cfgNote("ssh -G identityfile=\(identityFile) proxycommand=\(proxyCommand.isEmpty ? "-" : "有")")

    let scratch = try makeScratchDirectory(prefix: "aster-p3cfg")
    let aliasPath = scratch + "/alias-config"
    let text = aliasConfigurationText(
      userConfigurationPath: RemoteSSHConfigurationManager.defaultUserConfigurationPath(),
      hostName: hostName, port: port, user: user, identityFile: identityFile,
      proxyCommand: proxyCommand)
    try writePrivateFile(text, to: aliasPath)

    let managed = try RemoteSSHConfigurationManager.makePrivateConfiguration(
      userConfigurationPath: aliasPath, policy: policy)
    let transport = RemoteSessionTransport(
      target: target, policy: policy, managedConfiguration: managed)

    // 平台与家目录必须来自真实探测，不能写死：远端路径全部由它派生。
    let probe = try RemoteSSHProcessRunner().run(
      arguments: transport.sshArguments(
        remoteCommand: RemoteHostProbe.probeCommand(explicitPath: nil)),
      timeout: 30)
    guard probe.exitStatus == 0,
      let report = RemoteHostProbe.parse(probe.standardOutput, explicitPath: nil)
    else {
      throw RemoteSSHError(
        kind: .transportFailure, target: settings.rawTarget, detail: "远端探测失败")
    }
    let home = report.platform.homeDirectory
    let runRoot = "\(home)/.local/state/aster-test/\(settings.runID)"
    cfgNote(
      "远端平台 os=\(report.platform.os) arch=\(report.platform.architecture) home=\(home)")
    cfgNote("runRoot=\(runRoot)")

    let environment = P3ConfigEnvironment(
      settings: settings, target: target, policy: policy, scratchDirectory: scratch,
      aliasConfigurationPath: aliasPath, managed: managed, transport: transport,
      platformOS: report.platform.os, architecture: report.platform.architecture,
      home: home, runRoot: runRoot)
    _ = try cfgRemoteShell(
      transport, "umask 077; mkdir -p \(RemoteSSHInvocation.quote(runRoot))")
    return environment
  }

  /// 用给定 target 文本建一个走同一份私有配置的传输。
  func transport(forRawTarget raw: String) throws -> RemoteSessionTransport {
    RemoteSessionTransport(
      target: try RemoteSSHTarget.parse(raw), policy: policy, managedConfiguration: managed)
  }

  /// 清理本次生成的全部本地临时资源；远端目录由各用例自己按 runID 清理。
  func cleanUp() {
    RemoteSSHConfigurationManager.cleanUp(managed, target: target)
    try? FileManager.default.removeItem(atPath: scratchDirectory)
    cfgNote("本地临时 SSH 配置已清理：\(scratchDirectory)")
  }

  /// 0700 私有目录。放 `/tmp` 而不是 `NSTemporaryDirectory()`：control socket 路径有
  /// `sockaddr_un` 104 字节上限，沙盒临时目录太长会直接超限。
  static func makeScratchDirectory(prefix: String) throws -> String {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    let directory = "/tmp/\(prefix)-\(suffix)"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return directory
  }

  /// 以 0600 写入一个私有文件。OpenSSH 对配置文件权限敏感，必须显式收紧。
  static func writePrivateFile(_ text: String, to path: String) throws {
    guard
      FileManager.default.createFile(
        atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    else {
      throw RemoteSSHError(kind: .transportFailure, target: "", detail: "无法写入 \(path)")
    }
  }

  /// 生成手写的验收专用 SSH 配置文本。
  ///
  /// 关键取舍：
  /// 1. `Include` 用户配置放在最前，保证 `root@ubuntu@orb` 这类用户自有 alias 仍能解析；
  ///    本文件不改动用户配置，只在自己的临时文件里追加 aster-p3-* 这些自造 alias。
  /// 2. `ProxyCommand` 原样抄 `ssh -G` 的输出（其中的单引号是 OrbStack 可执行文件路径
  ///    带空格所致，`ProxyCommand` 本来就交给 `/bin/sh -c`，保持原样才正确）。
  /// 3. `aster-p3-jump` 的 `HostName` 不能指回 127.0.0.1：那是 Mac 上的回环地址，跳板
  ///    机（容器）内部并没有监听它，必须用容器可达的 `host.orb.internal` 回连 Mac 代理，
  ///    这样才是真正的两跳 ProxyJump 而不是伪装。
  /// 4. `aster-p3-port` 不带 ProxyCommand，直接 TCP 连端口，用来单独验证自定义端口生效。
  static func aliasConfigurationText(
    userConfigurationPath: String?,
    hostName: String,
    port: String,
    user: String,
    identityFile: String,
    proxyCommand: String
  ) -> String {
    var lines: [String] = [
      "# Aster P3 配置验收专用临时 SSH 配置（测试结束删除，不影响用户配置）。"
    ]
    if let userConfigurationPath, !userConfigurationPath.isEmpty {
      lines.append("Include \(userConfigurationPath)")
    }
    let hasProxyCommand = !proxyCommand.isEmpty && proxyCommand != "none"

    lines += ["", "Host aster-p3-alias", "  HostName \(hostName)", "  Port \(port)", "  User \(user)"]
    if !identityFile.isEmpty { lines.append("  IdentityFile \(identityFile)") }
    if hasProxyCommand { lines.append("  ProxyCommand \(proxyCommand)") }
    lines += ["  StrictHostKeyChecking no", "  UserKnownHostsFile /dev/null"]

    lines += [
      "", "Host aster-p3-jump", "  HostName \(jumpDestinationHost)", "  Port \(port)",
      "  User \(user)",
    ]
    if !identityFile.isEmpty { lines.append("  IdentityFile \(identityFile)") }
    lines += [
      "  ProxyJump aster-p3-alias", "  StrictHostKeyChecking no",
      "  UserKnownHostsFile /dev/null",
    ]

    lines += ["", "Host aster-p3-port", "  HostName \(hostName)", "  Port \(port)", "  User \(user)"]
    if !identityFile.isEmpty { lines.append("  IdentityFile \(identityFile)") }
    lines += ["  StrictHostKeyChecking no", "  UserKnownHostsFile /dev/null"]

    // URI 形式自带 user/host/port，只缺密钥与主机密钥策略，用主机名段补上。
    lines += ["", "Host \(hostName)"]
    if !identityFile.isEmpty { lines.append("  IdentityFile \(identityFile)") }
    lines += ["  StrictHostKeyChecking no", "  UserKnownHostsFile /dev/null"]

    // IPv6 字面量：OrbStack 的 SSH 代理同时监听 [::1]:<port>。
    lines += ["", "Host ::1", "  Port \(port)", "  User \(user)"]
    if !identityFile.isEmpty { lines.append("  IdentityFile \(identityFile)") }
    lines += ["  StrictHostKeyChecking no", "  UserKnownHostsFile /dev/null", ""]

    return lines.joined(separator: "\n")
  }
}

/// 用给定 target 真实连一次并返回 `uname -m`；连接失败时返回 nil 并记录原因。
private func cfgArchitecture(
  _ environment: P3ConfigEnvironment, rawTarget: String
) throws -> (arch: String?, detail: String) {
  let transport = try environment.transport(forRawTarget: rawTarget)
  let result = try cfgRemoteShell(transport, "uname -m", timeout: 40)
  guard result.exitStatus == 0 else {
    return (nil, "exit=\(result.exitStatus) stderr=\(cfgTrim(result.standardError))")
  }
  return (cfgTrim(result.standardOutput), "exit=0")
}

/// 把本地 Linux 产物安装到指定 installRoot，返回安装结果。供多个用例复用。
private func cfgInstall(
  _ environment: P3ConfigEnvironment,
  installRoot: String,
  version: String,
  artifactKind: RemoteArtifactKind,
  acceptDevelopmentArtifact: Bool
) throws -> RemoteInstallOutcome {
  let path = environment.settings.localLinuxBinary
  let digest = try RemoteInstallTransaction.fileDigest(at: path)
  let size = try RemoteInstallTransaction.fileSize(at: path)
  let manifest = RemoteReleaseManifest(
    version: version, platform: environment.platformOS,
    architecture: environment.architecture, sha256: digest, sizeBytes: size,
    signature: nil, artifactKind: artifactKind)
  let plan = RemoteInstallPlan(
    targetDescription: environment.target.rawText, homeDirectory: environment.home,
    installRoot: installRoot, manifest: manifest, existingVersion: nil)
  let transaction = RemoteInstallTransaction(
    executor: RemoteSSHInstallExecutor(transport: environment.transport),
    remotePlatform: environment.platformOS,
    remoteArchitecture: environment.architecture,
    acceptDevelopmentArtifact: acceptDevelopmentArtifact)
  return try transaction.install(
    plan: plan, manifest: manifest, localPath: path, localDigest: digest, localSize: size)
}

/// 从安装事务的错误里取出清单校验原因，兼容裸 `RemoteInstallValidationError` 与被
/// `RemoteInstallError.validation(_:)` 包装两种形态。
private func cfgValidationReason(_ error: (any Error)?) -> RemoteInstallValidationError? {
  if let error = error as? RemoteInstallValidationError { return error }
  if let error = error as? RemoteInstallError, case .validation(let reason) = error { return reason }
  return nil
}

@Suite(.serialized)
struct RemoteWorkP3ConfigAcceptanceTests {

  /// A10.1：alias、ProxyJump、自定义端口、URI 与 IPv6 五种 target 形态的真实连接。
  @Test(.enabled(if: P3ConfigSettings.isEnabled))
  func a10AliasProxyJumpPortAndIPv6() throws {
    let environment = try P3ConfigEnvironment.make()
    defer { environment.cleanUp() }
    let baseline = try cfgArchitecture(environment, rawTarget: environment.settings.rawTarget)
    guard let expectedArch = baseline.arch, !expectedArch.isEmpty else {
      Issue.record("基线 target 无法连接：\(baseline.detail)")
      return
    }
    cfgNote("基线 \(environment.settings.rawTarget) 架构=\(expectedArch)")

    // 1. alias：Host 段里带 HostName/Port/User/ProxyCommand，target 只有一个别名。
    let alias = try RemoteSSHTarget.parse("aster-p3-alias")
    #expect(alias.host == "aster-p3-alias")
    #expect(alias.user == nil, "alias 形式不应解析出用户名，用户名由 SSH 配置决定")
    let aliasResult = try cfgArchitecture(environment, rawTarget: "aster-p3-alias")
    cfgNote("alias aster-p3-alias：arch=\(aliasResult.arch ?? "-") \(aliasResult.detail)")
    #expect(aliasResult.arch == expectedArch, "alias target 必须能真正连上")

    // 2. ProxyJump：两跳，先落到容器，再由容器回连 Mac 上的 OrbStack SSH 代理。
    let jumpResult = try cfgArchitecture(environment, rawTarget: "aster-p3-jump")
    cfgNote("ProxyJump aster-p3-jump：arch=\(jumpResult.arch ?? "-") \(jumpResult.detail)")
    #expect(jumpResult.arch == expectedArch, "ProxyJump target 必须能真正连上")

    // 3. URI + 自定义端口：`%40` 是 URI 里对 `root@ubuntu` 中间那个 `@` 的转义，
    //    OpenSSH 会自行解码；不转义的 `ssh://root@ubuntu@host:port` 被 OpenSSH 判为非法。
    let resolved = try cfgResolvedConfiguration(environment.settings.rawTarget)
    let hostName = resolved["hostname"] ?? environment.target.host
    let portText = resolved["port"] ?? "22"
    let encodedUser =
      (resolved["user"] ?? "root").replacingOccurrences(of: "@", with: "%40")
    let uriText = "ssh://\(encodedUser)@\(hostName):\(portText)"
    let uri = try RemoteSSHTarget.parse(uriText)
    #expect(uri.isURI)
    #expect(uri.host == hostName)
    #expect(uri.port == Int(portText), "URI 必须解析出自定义端口 \(portText)")
    let uriResult = try cfgArchitecture(environment, rawTarget: uriText)
    cfgNote("URI \(uriText)：port=\(uri.port.map(String.init) ?? "-") arch=\(uriResult.arch ?? "-") \(uriResult.detail)")
    #expect(uriResult.arch == expectedArch, "URI 形式（含自定义端口）必须能真正连上")

    // 4. 只靠 Port 生效的 alias：没有 ProxyCommand，端口不对就连不上，是端口生效的独立证据。
    let portResult = try cfgArchitecture(environment, rawTarget: "aster-p3-port")
    cfgNote("自定义端口 alias aster-p3-port（Port \(portText)）：arch=\(portResult.arch ?? "-") \(portResult.detail)")
    #expect(portResult.arch == expectedArch, "自定义端口必须生效")

    // 5. IPv6。
    //    5a. URI 形式只做解析验证：本机 OpenSSH（10.3p1）不接受 `ssh://` URI 里的 IPv6
    //        字面量，`ssh -- 'ssh://user@[::1]:port'` 直接打印 usage 退出，与是否监听无关。
    let ipv6URI = try RemoteSSHTarget.parse("ssh://[::1]:\(portText)")
    #expect(ipv6URI.host == "::1", "IPv6 URI 必须解析出去掉方括号的主机段")
    #expect(ipv6URI.port == Int(portText), "IPv6 URI 必须解析出端口")
    cfgNote("IPv6 URI ssh://[::1]:\(portText)：仅解析验证（host=\(ipv6URI.host) port=\(ipv6URI.port.map(String.init) ?? "-")），未连通——OpenSSH 不接受 URI 中的 IPv6 字面量")
    //    5b. 非 URI 形式做真实连通：OrbStack 的代理同时监听 [::1]:<port>。
    let ipv6Raw = "\(resolved["user"] ?? "root")@::1"
    let ipv6Target = try RemoteSSHTarget.parse(ipv6Raw)
    #expect(ipv6Target.host == "::1")
    let ipv6Result = try cfgArchitecture(environment, rawTarget: ipv6Raw)
    cfgNote("IPv6 直连 \(ipv6Raw)：arch=\(ipv6Result.arch ?? "-") \(ipv6Result.detail)")
    #expect(ipv6Result.arch == expectedArch, "IPv6 字面量 target 必须能真正连上")
  }

  /// A10.2：两个解析到同一 hostname 的 target 各自保留原始配置，服务身份仍然共享。
  @Test(.enabled(if: P3ConfigSettings.isEnabled))
  func a10SameHostDifferentTargetsKeepOwnProfiles() throws {
    let environment = try P3ConfigEnvironment.make()
    defer { environment.cleanUp() }

    let caseRoot = "\(environment.runRoot)/a10-2"
    let installRoot = "\(caseRoot)/install"
    let stateParent = "\(caseRoot)/state"
    let sessionName = "p3cfg"
    _ = try cfgRemoteShell(
      environment.transport,
      "umask 077; mkdir -p \(RemoteSSHInvocation.quote(stateParent))")
    defer {
      _ = try? cfgRemoteShell(
        environment.transport, "rm -rf \(RemoteSSHInvocation.quote(caseRoot))", timeout: 60)
      cfgNote("A10.2 远端目录已清理：\(caseRoot)")
    }

    guard !environment.settings.localLinuxBinary.isEmpty else {
      Issue.record("必须提供 ASTER_P3_LOCAL_BINARY")
      return
    }
    let outcome = try cfgInstall(
      environment, installRoot: installRoot, version: "0.1.0-a10-2",
      artifactKind: .testArtifact, acceptDevelopmentArtifact: false)
    let activePath = outcome.installedPath
    cfgNote("A10.2 安装完成：\(activePath)")

    // 两个 target 文本不同但 `ssh -G` 解析到同一 hostname/port，因此指向同一台真实机器。
    let aliasRaw = "aster-p3-alias"
    let directRaw = environment.settings.rawTarget
    let aliasResolved = try cfgResolvedConfiguration(
      aliasRaw, configurationFile: environment.managed.configurationPath)
    let directResolved = try cfgResolvedConfiguration(
      directRaw, configurationFile: environment.managed.configurationPath)
    cfgNote(
      "解析对照：\(aliasRaw) -> \(aliasResolved["hostname"] ?? "-"):\(aliasResolved["port"] ?? "-")；\(directRaw) -> \(directResolved["hostname"] ?? "-"):\(directResolved["port"] ?? "-")"
    )
    #expect(aliasResolved["hostname"] == directResolved["hostname"], "两个 target 必须解析到同一 hostname")
    #expect(aliasResolved["port"] == directResolved["port"], "两个 target 必须解析到同一端口")

    let aliasID = UUID()
    let directID = UUID()
    func runSetup(_ raw: String, label: String, profileID: UUID) throws -> RemoteSetupOutcome {
      let transport = try environment.transport(forRawTarget: raw)
      let executor = RemoteSSHSetupExecutor(
        transport: transport,
        endpointTemplate: ManagedSessionEndpoint(
          machineProfileID: profileID, binaryPath: activePath, stateParentPath: stateParent,
          sessionName: sessionName))
      return try RemoteMachineSetup(executor: executor, explicitRemoteBinaryPath: activePath)
        .run(rawTarget: raw, label: label, sessionName: sessionName, profileID: profileID)
    }

    guard case .ready(let aliasProfile, let aliasIdentity, _) = try runSetup(
      aliasRaw, label: "orb-alias", profileID: aliasID)
    else {
      Issue.record("alias target 设置未返回 ready")
      return
    }
    guard case .ready(let directProfile, let directIdentity, _) = try runSetup(
      directRaw, label: "orb-direct", profileID: directID)
    else {
      Issue.record("原始 target 设置未返回 ready")
      return
    }
    defer {
      _ = try? cfgRemoteShell(
        environment.transport,
        "\(RemoteSSHInvocation.quote(activePath)) server stop \(RemoteSSHInvocation.quote(stateParent)) \(RemoteSSHInvocation.quote(sessionName))",
        timeout: 30)
    }

    cfgNote("alias 配置：id=\(aliasProfile.id) target=\(aliasProfile.sshTarget ?? "-")")
    cfgNote("direct 配置：id=\(directProfile.id) target=\(directProfile.sshTarget ?? "-")")
    #expect(aliasProfile.id == aliasID)
    #expect(directProfile.id == directID)
    #expect(aliasProfile.id != directProfile.id, "两份配置必须是不同的机器配置")
    #expect(aliasProfile.sshTarget == aliasRaw, "配置必须保存 alias 原始文本，不得归一化")
    #expect(directProfile.sshTarget == directRaw, "配置必须保存原始 target 文本，不得归一化")

    cfgNote(
      "服务身份：alias serverID=\(aliasIdentity.reference.serverID) sessionID=\(aliasIdentity.reference.sessionID) epoch=\(aliasIdentity.serverEpoch)"
    )
    cfgNote(
      "服务身份：direct serverID=\(directIdentity.reference.serverID) sessionID=\(directIdentity.reference.sessionID) epoch=\(directIdentity.serverEpoch)"
    )
    #expect(
      aliasIdentity.reference.serverID == directIdentity.reference.serverID,
      "同一台机器上的同一命名会话必须返回同一个 serverID")
    #expect(
      aliasIdentity.reference.sessionID == directIdentity.reference.sessionID,
      "同一台机器上的同一命名会话必须返回同一个 sessionID")
    #expect(
      aliasIdentity.serverEpoch == directIdentity.serverEpoch, "第二次设置不得重启已运行的服务")
    // machineProfileID 是客户端侧字段，必须各自保留，不能被服务身份共享带跑。
    #expect(aliasIdentity.reference.machineProfileID == aliasID)
    #expect(directIdentity.reference.machineProfileID == directID)
  }

  /// A10.4：SSH 配置管理开启/关闭的差异——用户保活优先、私有 control socket 清理、用户复用不受影响。
  @Test(.enabled(if: P3ConfigSettings.isEnabled))
  func a10ManagedSSHConfigurationOnAndOff() throws {
    let environment = try P3ConfigEnvironment.make()
    defer { environment.cleanUp() }
    let rawTarget = environment.settings.rawTarget

    // 1. 用户配置优先：显式写 ServerAliveInterval 99，私有配置补的 15 不得覆盖它。
    //    这份“用户配置”自己再 Include 真实用户配置，保证 orb alias 仍能解析。
    let userScratch = try P3ConfigEnvironment.makeScratchDirectory(prefix: "aster-p3usr")
    defer { try? FileManager.default.removeItem(atPath: userScratch) }
    let userConfigPath = userScratch + "/user-config"
    var userLines = ["# 验收用“用户配置”：显式设置保活间隔，用来验证用户设置优先。", "Host *", "  ServerAliveInterval 99"]
    if let real = RemoteSSHConfigurationManager.defaultUserConfigurationPath() {
      userLines.append("Include \(real)")
    }
    try P3ConfigEnvironment.writePrivateFile(userLines.joined(separator: "\n") + "\n", to: userConfigPath)

    let userFirst = try RemoteSSHConfigurationManager.makePrivateConfiguration(
      userConfigurationPath: userConfigPath, policy: environment.policy)
    defer { RemoteSSHConfigurationManager.cleanUp(userFirst, target: environment.target) }
    let resolvedText = try RemoteSSHProcessRunner().run(
      arguments: ["-G", "-F", userFirst.configurationPath, "--", rawTarget], timeout: 20)
    let keepAliveLine =
      resolvedText.standardOutput.split(separator: "\n")
      .first { $0.hasPrefix("serveraliveinterval ") }.map(String.init) ?? "-"
    cfgNote("私有配置解析出的保活：\(keepAliveLine)（策略默认值 \(environment.policy.keepAliveInterval)）")
    #expect(keepAliveLine == "serveraliveinterval 99", "用户配置里的保活设置必须优先于私有配置补的默认值")

    // 2. 私有 control socket：ControlMaster auto 会在私有目录里建 socket；cleanUp 后目录整体消失。
    let socketManaged = try RemoteSSHConfigurationManager.makePrivateConfiguration(
      userConfigurationPath: environment.aliasConfigurationPath, policy: environment.policy)
    let socketTransport = RemoteSessionTransport(
      target: environment.target, policy: environment.policy, managedConfiguration: socketManaged)
    #expect(socketManaged.controlPath.count < 104, "control socket 路径必须短于 sockaddr_un 上限")
    let firstConnect = try cfgRemoteShell(socketTransport, "true", timeout: 40)
    #expect(firstConnect.exitStatus == 0, "私有配置下必须能连上")
    let socketNames =
      (try? FileManager.default.contentsOfDirectory(atPath: socketManaged.directoryPath)) ?? []
    let sockets = socketNames.filter { $0.hasPrefix("c-") }
    cfgNote("私有目录内容：\(socketNames)；control socket=\(sockets)")
    #expect(!sockets.isEmpty, "ControlMaster 必须在私有目录里建立 control socket")

    RemoteSSHConfigurationManager.cleanUp(socketManaged, target: environment.target)
    #expect(
      !FileManager.default.fileExists(atPath: socketManaged.directoryPath),
      "cleanUp 必须删除整个私有目录")
    cfgNote("cleanUp 后私有目录已删除：\(socketManaged.directoryPath)")

    // 3. 关闭配置管理：argv 里不得出现 -F，且仍能靠用户自己的 OpenSSH 配置连上。
    var offPolicy = environment.policy
    offPolicy.manageSSHConfig = false
    let offTransport = RemoteSessionTransport(
      target: environment.target, policy: offPolicy, managedConfiguration: socketManaged)
    let offArguments = offTransport.sshArguments(remoteCommand: ["/bin/sh", "-c", "true"])
    cfgNote("manageSSHConfig=false 的 argv：\(offArguments.joined(separator: " "))")
    #expect(!offArguments.contains("-F"), "关闭配置管理后不得注入 -F")
    let offResult = try cfgRemoteShell(offTransport, "uname -m", timeout: 40)
    cfgNote("manageSSHConfig=false 连接：exit=\(offResult.exitStatus) out=\(cfgTrim(offResult.standardOutput))")
    #expect(offResult.exitStatus == 0, "关闭配置管理后必须仍能用用户配置连上")

    // 4. 用户自己的复用连接不受影响：cleanUp 之后不带 -F 的普通连接仍然成功。
    let plain = try RemoteSSHProcessRunner().run(
      arguments: ["-o", "BatchMode=yes", "--", rawTarget, "true"], timeout: 40)
    cfgNote("cleanUp 后的用户侧普通连接：exit=\(plain.exitStatus) stderr=\(cfgTrim(plain.standardError))")
    #expect(plain.exitStatus == 0, "cleanUp 不得影响用户自己的连接与复用")
  }

  /// A11.4：自定义开发二进制的拒绝/接受路径，以及停止服务后后台只读探测不重启服务。
  @Test(.enabled(if: P3ConfigSettings.isEnabled))
  func a11DevelopmentBinaryAndNoBackgroundRestart() throws {
    let environment = try P3ConfigEnvironment.make()
    defer { environment.cleanUp() }
    guard !environment.settings.localLinuxBinary.isEmpty,
      FileManager.default.isExecutableFile(atPath: environment.settings.localLinuxBinary)
    else {
      Issue.record("本地 Linux 产物不可执行：\(environment.settings.localLinuxBinary)")
      return
    }

    let caseRoot = "\(environment.runRoot)/a11-4"
    let installRoot = "\(caseRoot)/install"
    let stateParent = "\(caseRoot)/state"
    let sessionName = "p3cfg-a11"
    _ = try cfgRemoteShell(
      environment.transport,
      "umask 077; mkdir -p \(RemoteSSHInvocation.quote(stateParent))")
    defer {
      _ = try? cfgRemoteShell(
        environment.transport, "rm -rf \(RemoteSSHInvocation.quote(caseRoot))", timeout: 60)
      cfgNote("A11.4 远端目录已清理：\(caseRoot)")
    }

    let localPath = environment.settings.localLinuxBinary
    let digest = try RemoteInstallTransaction.fileDigest(at: localPath)
    let size = try RemoteInstallTransaction.fileSize(at: localPath)
    let devManifest = RemoteReleaseManifest(
      version: "0.1.0-dev", platform: environment.platformOS,
      architecture: environment.architecture, sha256: digest, sizeBytes: size,
      signature: nil, artifactKind: .developmentBuild)
    cfgNote("开发产物清单：\(devManifest.displaySummary)")
    #expect(devManifest.isOfficialRelease == false, "开发产物不得标成正式发行")

    let executor = RemoteSSHInstallExecutor(transport: environment.transport)
    let plan = RemoteInstallPlan(
      targetDescription: environment.target.rawText, homeDirectory: environment.home,
      installRoot: installRoot, manifest: devManifest, existingVersion: nil)
    let activePath = plan.activePath

    // 1. 未显式接受：必须在任何远端写动作之前拒绝，远端不得出现活动二进制。
    let strict = RemoteInstallTransaction(
      executor: executor, remotePlatform: environment.platformOS,
      remoteArchitecture: environment.architecture, acceptDevelopmentArtifact: false)
    var notAcceptedError: (any Error)?
    do {
      _ = try strict.install(
        plan: plan, manifest: devManifest, localPath: localPath, localDigest: digest,
        localSize: size)
      Issue.record("未显式接受的开发产物不应安装成功")
    } catch { notAcceptedError = error }
    cfgNote("未接受开发产物错误：\(notAcceptedError.map { String(describing: $0) } ?? "-")")
    #expect(
      cfgValidationReason(notAcceptedError) == .developmentArtifactNotAccepted,
      "必须以 developmentArtifactNotAccepted 拒绝")
    let noActive = try cfgRemoteShell(
      environment.transport,
      "test -e \(RemoteSSHInvocation.quote(activePath)) && echo EXISTS || echo ABSENT")
    #expect(cfgTrim(noActive.standardOutput) == "ABSENT", "拒绝后远端不得出现活动二进制")

    // 2. 错误平台：即使已显式接受开发产物，也必须在上传前拒绝，staging 目录不得产生内容。
    var wrongPlatform = devManifest
    wrongPlatform.platform = environment.platformOS == "linux" ? "macos" : "linux"
    wrongPlatform.version = "0.1.0-dev-wrongplatform"
    let wrongPlan = RemoteInstallPlan(
      targetDescription: environment.target.rawText, homeDirectory: environment.home,
      installRoot: installRoot, manifest: wrongPlatform, existingVersion: nil)
    let permissive = RemoteInstallTransaction(
      executor: executor, remotePlatform: environment.platformOS,
      remoteArchitecture: environment.architecture, acceptDevelopmentArtifact: true)
    var wrongPlatformError: (any Error)?
    do {
      _ = try permissive.install(
        plan: wrongPlan, manifest: wrongPlatform, localPath: localPath, localDigest: digest,
        localSize: size)
      Issue.record("错误平台的开发产物不应安装成功")
    } catch { wrongPlatformError = error }
    cfgNote("错误平台错误：\(wrongPlatformError.map { String(describing: $0) } ?? "-")")
    #expect(
      cfgValidationReason(wrongPlatformError)
        == .platformMismatch(expected: wrongPlatform.platform, actual: environment.platformOS),
      "必须以 platformMismatch 拒绝")
    let stagingState = try cfgRemoteShell(
      environment.transport,
      "d=\(RemoteSSHInvocation.quote(wrongPlan.stagingDirectory)); if [ -d \"$d\" ]; then ls -A \"$d\" | wc -l; else echo NODIR; fi"
    )
    let stagingText = cfgTrim(stagingState.standardOutput)
    cfgNote("错误平台后 staging 状态：\(stagingText)")
    #expect(stagingText == "NODIR" || stagingText == "0", "错误平台不得发生任何上传")

    // 3. 显式接受：安装成功，远端活动二进制可运行。
    let outcome = try permissive.install(
      plan: plan, manifest: devManifest, localPath: localPath, localDigest: digest,
      localSize: size)
    cfgNote("显式接受后安装完成：\(outcome.installedPath) -> \(outcome.versionedPath)")
    #expect(outcome.artifactKind == .developmentBuild)
    let version = try cfgRemoteShell(
      environment.transport, "\(RemoteSSHInvocation.quote(activePath)) --version")
    cfgNote("远端 --version：\(cfgTrim(version.standardOutput))")
    #expect(version.exitStatus == 0, "显式接受安装的开发产物必须可运行")

    // 4. 启动命名会话服务并创建持续输出的测试任务。
    let profileID = UUID()
    let template = ManagedSessionEndpoint(
      machineProfileID: profileID, binaryPath: activePath, stateParentPath: stateParent,
      sessionName: sessionName)
    let setup = RemoteMachineSetup(
      executor: RemoteSSHSetupExecutor(transport: environment.transport, endpointTemplate: template),
      explicitRemoteBinaryPath: activePath)
    guard case .ready(let profile, let identity, _) = try setup.run(
      rawTarget: environment.settings.rawTarget, label: "orb-a11-4", sessionName: sessionName,
      profileID: profileID)
    else {
      Issue.record("显式设置未返回 ready")
      return
    }
    cfgNote("首次设置：serverID=\(identity.reference.serverID) epoch=\(identity.serverEpoch)")

    let endpoint = ManagedSessionEndpoint(
      machineProfileID: profile.id, binaryPath: activePath, stateParentPath: stateParent,
      sessionName: sessionName)
    let client = RemoteManagedSessionClient(transport: environment.transport)
    let markerFile = "\(caseRoot)/counter.txt"
    let counterScript =
      "i=0; while :; do i=$((i+1)); echo \"$i\" >> \(RemoteSSHInvocation.quote(markerFile)); sleep 1; done"
    let taskA = try client.createTerminal(
      endpoint, workingDirectory: caseRoot, argv: ["/bin/sh", "-c", counterScript])
    guard let pidA = taskA.pid else {
      Issue.record("测试任务未返回 PID")
      return
    }
    cfgNote("测试任务 A：terminalID=\(taskA.reference.terminalID) pid=\(pidA)")

    let stopCommand =
      "\(RemoteSSHInvocation.quote(activePath)) server stop \(RemoteSSHInvocation.quote(stateParent)) \(RemoteSSHInvocation.quote(sessionName))"

    // 5. 显式停止服务。
    let firstStop = try cfgRemoteShell(environment.transport, stopCommand)
    cfgNote("第一次 server stop：exit=\(firstStop.exitStatus) out=\(cfgTrim(firstStop.standardOutput))")
    #expect(firstStop.exitStatus == 0)

    // 6. 显式设置入口允许重新准备会话：再跑一次 setup.run 必须重新起服务（epoch 变化）。
    guard case .ready(_, let identity2, _) = try setup.run(
      rawTarget: environment.settings.rawTarget, label: "orb-a11-4", sessionName: sessionName,
      profileID: profileID)
    else {
      Issue.record("停止服务后的显式设置未返回 ready")
      return
    }
    cfgNote("重新设置：serverID=\(identity2.reference.serverID) epoch=\(identity2.serverEpoch)")
    #expect(identity2.serverEpoch != identity.serverEpoch, "显式设置必须重新准备会话，产生新的 epoch")
    let taskAState = try cfgRemoteShell(
      environment.transport, "kill -0 \(pidA) 2>/dev/null && echo ALIVE || echo GONE")
    cfgNote("停止服务后测试任务 A（pid \(pidA)）：\(cfgTrim(taskAState.standardOutput))")
    #expect(cfgTrim(taskAState.standardOutput) == "GONE", "显式停止服务必须回收它创建的任务进程")

    // 7. 再建一个任务并显式结束，验证结束路径本身可用。
    let taskB = try client.createTerminal(
      endpoint, workingDirectory: caseRoot, argv: ["/bin/sh", "-c", counterScript])
    guard let pidB = taskB.pid else {
      Issue.record("第二个测试任务未返回 PID")
      return
    }
    cfgNote("测试任务 B：terminalID=\(taskB.reference.terminalID) pid=\(pidB)")
    Thread.sleep(forTimeInterval: 2)
    let terminated = try client.terminateTerminal(
      endpoint, terminalID: taskB.reference.terminalID)
    cfgNote("测试任务 B 结束：state=\(terminated.state.rawValue) exitCode=\(terminated.exitCode.map(String.init) ?? "-")")
    #expect(terminated.state == .exited)

    // 8. 停止服务后，后台只读探测不得把服务拉起来。
    //    `serverStatus` 是只读查询：服务不存在时必须抛错，并且不能因此产生新的服务实例。
    let secondStop = try cfgRemoteShell(environment.transport, stopCommand)
    cfgNote("第二次 server stop：exit=\(secondStop.exitStatus) out=\(cfgTrim(secondStop.standardOutput))")
    var statusError: (any Error)?
    do {
      let status = try client.serverStatus(endpoint)
      Issue.record("服务已停止时 serverStatus 不应成功，实际 epoch=\(status.serverEpoch)")
    } catch { statusError = error }
    cfgNote("停止后 serverStatus 错误：\(statusError.map { String(describing: $0) } ?? "-")")
    #expect(statusError != nil, "服务不存在时只读查询必须失败，不得隐式启动服务")

    // 残留判定按 socket 文件本身，不按进程名匹配（验收规格禁止模糊进程名匹配）。
    let socketState = try cfgRemoteShell(
      environment.transport,
      "found=NO_SOCKET; for s in \(RemoteSSHInvocation.quote(stateParent))/*/control.sock; do [ -S \"$s\" ] && found=\"$s\"; done; echo \"$found\""
    )
    cfgNote("只读探测后服务 socket 状态：\(cfgTrim(socketState.standardOutput))")
    #expect(
      cfgTrim(socketState.standardOutput) == "NO_SOCKET", "后台只读探测不得启动新的服务实例")

    // 9. 清理断言：两个测试任务的 PID 必须都已回收。
    for pid in [pidA, pidB] {
      let alive = try cfgRemoteShell(
        environment.transport, "kill -0 \(pid) 2>/dev/null && echo ALIVE || echo GONE")
      cfgNote("清理后 pid \(pid)：\(cfgTrim(alive.standardOutput))")
      #expect(cfgTrim(alive.standardOutput) == "GONE", "测试任务进程必须已回收")
    }
  }
}
