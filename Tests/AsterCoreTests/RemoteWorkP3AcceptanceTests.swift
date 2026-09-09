import Foundation
import Testing

@testable import AsterCore

/// P3 的 OrbStack 真实验收（A10/A11/A12）。
///
/// 这些用例**只在显式开启时运行**（`ASTER_P3_ORB=1`），因为它们会真的通过 SSH
/// 连接 OrbStack、上传二进制、启动后台服务并创建真实进程。默认关闭，避免普通
/// 测试运行触碰远端机器。
///
/// 证据规则（`docs/developer/remote-work-acceptance.md` §1）：每轮唯一 runID，
/// 全部远端资源放在 `${HOME}/.local/state/aster-test/<runID>` 下，停止与清理只
/// 限定该 runID；不按进程名结束任何进程。

/// 验收运行参数。全部来自环境变量，默认值只用于本地手动执行。
private struct P3AcceptanceSettings {
  var rawTarget: String
  var runID: String
  var localLinuxBinary: String

  static var isEnabled: Bool {
    ProcessInfo.processInfo.environment["ASTER_P3_ORB"] == "1"
  }

  static func fromEnvironment() -> P3AcceptanceSettings {
    let environment = ProcessInfo.processInfo.environment
    return P3AcceptanceSettings(
      rawTarget: environment["ASTER_P3_TARGET"] ?? "root@ubuntu@orb",
      runID: environment["ASTER_P3_RUN_ID"] ?? "p3-\(Int(Date().timeIntervalSince1970))",
      localLinuxBinary: environment["ASTER_P3_LOCAL_BINARY"] ?? ""
    )
  }
}

/// 验收过程中的结构化日志。写到 stdout，由外层脚本重定向到证据日志文件。
private func note(_ text: String) {
  print("[P3] \(text)")
}

/// 直接执行一条远端 shell 命令并返回结果。用于建目录、读计数文件等辅助动作。
private func remoteShell(
  _ transport: RemoteSessionTransport,
  _ script: String,
  timeout: TimeInterval = 30
) throws -> RemoteSSHResult {
  try RemoteSSHProcessRunner().run(
    arguments: transport.sshArguments(remoteCommand: ["/bin/sh", "-c", script]),
    timeout: timeout)
}

/// 本地文件的 sha256（小写 hex）。清单摘要与远端复核用同一算法。
private func localDigest(_ path: String) throws -> String {
  try RemoteInstallTransaction.fileDigest(at: path)
}

@Suite(.serialized)
struct RemoteWorkP3AcceptanceTests {

  /// A10/A11/A12 的完整链路。
  ///
  /// 五个场景按顺序在**同一台真实机器**上执行，因为「已安装再次连接不重启运行中的
  /// 测试任务」必须跨场景比较同一个 PID；拆成独立用例就失去了这条证据。
  @Test(.enabled(if: P3AcceptanceSettings.isEnabled))
  func orbStackRemoteWorkAcceptance() throws {
    let settings = P3AcceptanceSettings.fromEnvironment()
    note("runID=\(settings.runID) target=\(settings.rawTarget)")
    #expect(!settings.localLinuxBinary.isEmpty, "必须提供 ASTER_P3_LOCAL_BINARY")
    guard FileManager.default.isExecutableFile(atPath: settings.localLinuxBinary) else {
      Issue.record("本地 Linux 产物不可执行：\(settings.localLinuxBinary)")
      return
    }

    // ---------- 前置：target 解析与私有 SSH 配置 ----------
    let target = try RemoteSSHTarget.parse(settings.rawTarget)
    note("target 解析：raw=\(target.rawText) user=\(target.user ?? "-") host=\(target.host)")
    let policy = RemoteSSHPolicy()
    let managed = try RemoteSSHConfigurationManager.makePrivateConfiguration(policy: policy)
    note("私有 SSH 配置：\(managed.configurationPath)（controlPath 长度 \(managed.controlPath.count)）")
    #expect(managed.controlPath.count < 104, "control socket 路径必须短于 sockaddr_un 上限")
    let transport = RemoteSessionTransport(
      target: target, policy: policy, managedConfiguration: managed)
    defer {
      RemoteSSHConfigurationManager.cleanUp(managed, target: target)
      note("私有 SSH 配置与 control socket 已清理")
    }

    // ---------- 环境记录（验收规格 §1 要求测试前记录） ----------
    let probeOutput = try RemoteSSHProcessRunner().run(
      arguments: transport.sshArguments(
        remoteCommand: RemoteHostProbe.probeCommand(explicitPath: nil)),
      timeout: 30)
    #expect(probeOutput.exitStatus == 0)
    guard let baseline = RemoteHostProbe.parse(probeOutput.standardOutput, explicitPath: nil) else {
      Issue.record("探测输出不可识别")
      return
    }
    note("远端平台 os=\(baseline.platform.os) arch=\(baseline.platform.architecture) home=\(baseline.platform.homeDirectory)")
    note("基线候选二进制：\(baseline.candidates.map(\.path))")

    let home = baseline.platform.homeDirectory
    #expect(!home.isEmpty)
    let runRoot = "\(home)/.local/state/aster-test/\(settings.runID)"
    let installRoot = "\(runRoot)/install"
    let stateParent = "\(runRoot)/state"
    let activePath = "\(installRoot)/bin/aster-session"
    let sessionName = "p3"
    let markerFile = "\(runRoot)/counter.txt"

    _ = try remoteShell(
      transport,
      "umask 077; mkdir -p \(RemoteSSHInvocation.quote(runRoot)) \(RemoteSSHInvocation.quote(stateParent))")

    // ================= 场景 1：首次安装 =================
    note("=== 场景 1：首次安装 ===")
    let executor = RemoteSSHSetupExecutor(
      transport: transport,
      endpointTemplate: ManagedSessionEndpoint(
        machineProfileID: UUID(), binaryPath: activePath, stateParentPath: stateParent,
        sessionName: sessionName))
    let setup = RemoteMachineSetup(executor: executor, explicitRemoteBinaryPath: activePath)

    // 1a. 安装之前：必须返回 installationRequired，且不产出配置。
    let beforeInstall = try setup.run(
      rawTarget: settings.rawTarget, label: "orb-p3", sessionName: sessionName)
    if case .installationRequired(_, let reason) = beforeInstall {
      note("场景 1a 通过：\(reason)")
    } else {
      Issue.record("安装前应返回 installationRequired，实际 \(beforeInstall)")
    }

    // 1b. 取消安装：不执行任何安装动作，远端不应出现活动二进制，也不产生配置。
    let cancelled = try remoteShell(
      transport, "test -e \(RemoteSSHInvocation.quote(activePath)) && echo EXISTS || echo ABSENT")
    #expect(cancelled.standardOutput.contains("ABSENT"), "取消安装不得留下二进制")
    note("场景 1b 通过：取消安装后远端无二进制、无机器配置")

    // 1c. 完成安装（隔离测试 manifest，明确 test 标识，不伪装正式发行）。
    let digest = try localDigest(settings.localLinuxBinary)
    let size = try RemoteInstallTransaction.fileSize(at: settings.localLinuxBinary)
    let manifest = RemoteReleaseManifest(
      version: "0.1.0-dev",
      platform: baseline.platform.os,
      architecture: baseline.platform.architecture,
      sha256: digest,
      sizeBytes: size,
      signature: nil,
      artifactKind: .testArtifact)
    note("测试清单：\(manifest.displaySummary)")
    #expect(manifest.isOfficialRelease == false, "测试产物不得标成正式发行")

    let installExecutor = RemoteSSHInstallExecutor(transport: transport)
    let transaction = RemoteInstallTransaction(
      executor: installExecutor,
      remotePlatform: baseline.platform.os,
      remoteArchitecture: baseline.platform.architecture)
    let plan = RemoteInstallPlan(
      targetDescription: target.rawText,
      homeDirectory: home,
      installRoot: installRoot,
      manifest: manifest,
      existingVersion: nil)
    note("安装影响说明：\n\(plan.impactSummary)")
    let outcome = try transaction.install(
      plan: plan, manifest: manifest, localPath: settings.localLinuxBinary,
      localDigest: digest, localSize: size)
    note("安装完成：\(outcome.installedPath) -> \(outcome.versionedPath)")

    let installedVersion = try remoteShell(
      transport, "\(RemoteSSHInvocation.quote(activePath)) --version")
    note("远端 --version：\(installedVersion.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect(installedVersion.exitStatus == 0)

    // 1d. 安装后再设置：必须一路成功并产出配置。
    let ready = try setup.run(
      rawTarget: settings.rawTarget, label: "orb-p3", sessionName: sessionName)
    guard case .ready(let profile, let identity, let report) = ready else {
      Issue.record("安装后应返回 ready，实际 \(ready)")
      return
    }
    note("握手：serverID=\(identity.reference.serverID) epoch=\(identity.serverEpoch) sessionID=\(identity.reference.sessionID)")
    note("capabilities=\(identity.capabilities) version=\(identity.version)")
    note("配置：label=\(profile.label) target=\(profile.sshTarget ?? "-") session=\(profile.sessionName)")
    #expect(profile.sshTarget == settings.rawTarget, "配置必须保存原始 target 文本")
    #expect(report.runningServer != nil)

    // 1e. 创建持续输出的测试任务，记录 PID 与序号。
    let endpoint = ManagedSessionEndpoint(
      machineProfileID: profile.id, binaryPath: activePath, stateParentPath: stateParent,
      sessionName: sessionName)
    let client = RemoteManagedSessionClient(transport: transport)
    let counterScript =
      "i=0; while :; do i=$((i+1)); echo \"$i $(date +%s)\" >> \(RemoteSSHInvocation.quote(markerFile)); sleep 1; done"
    let created = try client.createTerminal(
      endpoint, workingDirectory: runRoot, argv: ["/bin/sh", "-c", counterScript])
    guard let taskPID = created.pid else {
      Issue.record("测试任务未返回 PID")
      return
    }
    note("测试任务：terminalID=\(created.reference.terminalID) pid=\(taskPID) cwd=\(created.cwd ?? "-")")
    Thread.sleep(forTimeInterval: 3)
    let firstCount = try remoteShell(
      transport, "wc -l < \(RemoteSSHInvocation.quote(markerFile))")
      .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    note("场景 1 结束时计数=\(firstCount)")

    // ================= 场景 2：已安装再次连接 =================
    note("=== 场景 2：已安装再次连接 ===")
    let again = try setup.run(
      rawTarget: settings.rawTarget, label: "orb-p3", sessionName: sessionName)
    guard case .ready(_, let identity2, _) = again else {
      Issue.record("再次连接应返回 ready，实际 \(again)")
      return
    }
    #expect(identity2.reference.serverID == identity.reference.serverID, "serverID 必须不变")
    #expect(identity2.serverEpoch == identity.serverEpoch, "再次连接不得重启服务（epoch 必须不变）")
    let listed = try client.listTerminals(endpoint)
    let same = listed.first { $0.reference.terminalID == created.reference.terminalID }
    #expect(same?.state == .running, "测试任务必须仍在运行")
    #expect(same?.pid == taskPID, "再次连接不得重启运行中的测试任务（PID 必须不变）")
    Thread.sleep(forTimeInterval: 2)
    let secondCount = try remoteShell(
      transport, "wc -l < \(RemoteSSHInvocation.quote(markerFile))")
      .standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    note("场景 2：epoch=\(identity2.serverEpoch) pid=\(same?.pid.map(String.init) ?? "-") 计数 \(firstCount)→\(secondCount)")
    #expect((Int(secondCount) ?? 0) > (Int(firstCount) ?? 0), "任务输出必须继续增长")

    // ================= 场景 3：版本不同但协议兼容 =================
    note("=== 场景 3：版本不同但兼容 ===")
    // 用一个转发脚本模拟“另一个发行版本、同一协议主版本”的产物：只改 --version 输出，
    // 其余全部转调已安装的真实二进制，这样兼容判定走的是真实握手而不是伪造回复。
    let wrapperVersion = "0.1.1-p3test"
    let realVersionedPath = outcome.versionedPath
    let wrapperLocal = NSTemporaryDirectory() + "aster-session-\(settings.runID)-wrapper"
    let wrapperText = """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo 'aster-session \(wrapperVersion) protocol=1.0'
        exit 0
      fi
      exec \(RemoteSSHInvocation.quote(realVersionedPath)) "$@"
      """
    try wrapperText.write(toFile: wrapperLocal, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: wrapperLocal) }
    let wrapperDigest = try localDigest(wrapperLocal)
    let wrapperSize = try RemoteInstallTransaction.fileSize(at: wrapperLocal)
    let wrapperManifest = RemoteReleaseManifest(
      version: wrapperVersion,
      platform: baseline.platform.os,
      architecture: baseline.platform.architecture,
      sha256: wrapperDigest,
      sizeBytes: wrapperSize,
      signature: nil,
      artifactKind: .testArtifact)
    let wrapperPlan = RemoteInstallPlan(
      targetDescription: target.rawText,
      homeDirectory: home,
      installRoot: installRoot,
      manifest: wrapperManifest,
      existingVersion: manifest.version)
    let wrapperOutcome = try transaction.install(
      plan: wrapperPlan, manifest: wrapperManifest, localPath: wrapperLocal,
      localDigest: wrapperDigest, localSize: wrapperSize)
    note("切换到版本 \(wrapperOutcome.version)，保留旧版本 \(wrapperOutcome.previousVersion ?? "-")")

    let oldKept = try remoteShell(
      transport,
      "test -x \(RemoteSSHInvocation.quote(realVersionedPath)) && echo KEPT || echo GONE")
    #expect(oldKept.standardOutput.contains("KEPT"), "旧版本必须保留以便回退")

    let newVersionProbe = try RemoteSSHProcessRunner().run(
      arguments: transport.sshArguments(
        remoteCommand: RemoteHostProbe.probeCommand(explicitPath: activePath)),
      timeout: 30)
    let newReport = RemoteHostProbe.parse(newVersionProbe.standardOutput, explicitPath: activePath)
    let newCandidate = newReport?.candidates.first { $0.path == activePath }
    note("新候选：version=\(newCandidate?.releaseVersion ?? "-") protocol=\(newCandidate?.protocolMajor.map(String.init) ?? "-").\(newCandidate?.protocolMinor.map(String.init) ?? "-")")
    #expect(newCandidate?.releaseVersion == wrapperVersion, "发行版本必须与安装版本一致")
    #expect(newCandidate?.protocolMajor == RemoteProtocolContract.clientProtocolMajor)

    let compatible = try setup.run(
      rawTarget: settings.rawTarget, label: "orb-p3", sessionName: sessionName)
    guard case .ready(_, let identity3, _) = compatible else {
      Issue.record("版本不同但兼容应返回 ready，实际 \(compatible)")
      return
    }
    #expect(identity3.serverEpoch == identity.serverEpoch, "兼容连接不得重启运行中的服务")
    let listed3 = try client.listTerminals(endpoint)
    let same3 = listed3.first { $0.reference.terminalID == created.reference.terminalID }
    #expect(same3?.pid == taskPID, "版本不同但兼容时测试任务 PID 必须不变")
    note("场景 3：epoch=\(identity3.serverEpoch) pid=\(same3?.pid.map(String.init) ?? "-")")

    // ================= 场景 4：认证失败与非法 target =================
    note("=== 场景 4：认证失败 ===")
    // 4a. 非法 target 在连接前拒绝：替身不需要，直接看解析层。
    for bad in ["-oProxyCommand=id", "orb;id", "orb host", "orb$(id)", "orb|id"] {
      #expect(throws: RemoteSSHTargetError.self) { _ = try RemoteSSHTarget.parse(bad) }
    }
    note("场景 4a 通过：以选项开头与含元字符的 target 在连接前拒绝")

    // 4b. 真实认证拒绝：关闭公钥认证后 OpenSSH 必然返回 Permission denied。
    let denyTransport = RemoteSessionTransport(
      target: target, policy: policy, managedConfiguration: nil,
      extraOptions: ["PubkeyAuthentication=no", "PreferredAuthentications=password"])
    let denyExecutor = RemoteSSHSetupExecutor(
      transport: denyTransport,
      endpointTemplate: ManagedSessionEndpoint(
        machineProfileID: UUID(), binaryPath: activePath, stateParentPath: stateParent,
        sessionName: sessionName))
    var denyFailure: RemoteSetupFailure?
    do {
      _ = try RemoteMachineSetup(executor: denyExecutor, explicitRemoteBinaryPath: activePath)
        .run(rawTarget: settings.rawTarget, label: "orb-p3-deny", sessionName: sessionName)
      Issue.record("认证失败场景不应成功")
    } catch let failure as RemoteSetupFailure {
      denyFailure = failure
    }
    #expect(denyFailure?.stage == .authentication)
    #expect(denyFailure?.sshKind == .authenticationRequired)
    #expect(denyFailure?.requiresExplicitSetup == true, "认证失败必须进入 attention 而不是自动重连")
    note("场景 4b：stage=\(denyFailure?.stage.rawValue ?? "-") kind=\(denyFailure?.sshKind?.rawValue ?? "-") message=\(denyFailure?.message ?? "-")")

    // 4c. 未知主机密钥：不自动接受，直接失败。
    let unknownHostTransport = RemoteSessionTransport(
      target: target, policy: policy, managedConfiguration: nil,
      extraOptions: [
        "UserKnownHostsFile=/dev/null", "StrictHostKeyChecking=yes", "ControlPath=none",
      ])
    let unknownExecutor = RemoteSSHSetupExecutor(
      transport: unknownHostTransport,
      endpointTemplate: ManagedSessionEndpoint(
        machineProfileID: UUID(), binaryPath: activePath, stateParentPath: stateParent,
        sessionName: sessionName))
    var hostKeyFailure: RemoteSetupFailure?
    do {
      _ = try RemoteMachineSetup(executor: unknownExecutor, explicitRemoteBinaryPath: activePath)
        .run(rawTarget: settings.rawTarget, label: "orb-p3-hostkey", sessionName: sessionName)
      Issue.record("未知主机密钥场景不应成功")
    } catch let failure as RemoteSetupFailure {
      hostKeyFailure = failure
    }
    #expect(hostKeyFailure?.sshKind == .hostKeyUnknown, "未知主机密钥必须被识别且不自动接受")
    note("场景 4c：kind=\(hostKeyFailure?.sshKind?.rawValue ?? "-") message=\(hostKeyFailure?.message ?? "-")")

    // 认证失败后运行中的任务必须完全不受影响。
    let afterDeny = try client.listTerminals(endpoint)
    #expect(
      afterDeny.first { $0.reference.terminalID == created.reference.terminalID }?.pid == taskPID,
      "认证失败不得影响已运行任务")

    // ================= 场景 5：上传失败 =================
    note("=== 场景 5：上传失败 ===")
    // 5a. 摘要不匹配：在任何远端写动作之前就拒绝。
    var badDigestManifest = manifest
    badDigestManifest.sha256 = String(repeating: "0", count: 64)
    badDigestManifest.version = "0.9.9-baddigest"
    let badDigestPlan = RemoteInstallPlan(
      targetDescription: target.rawText, homeDirectory: home, installRoot: installRoot,
      manifest: badDigestManifest, existingVersion: wrapperVersion)
    #expect(throws: (any Error).self) {
      try transaction.install(
        plan: badDigestPlan, manifest: badDigestManifest, localPath: settings.localLinuxBinary,
        localDigest: digest, localSize: size)
    }
    note("场景 5a 通过：摘要不匹配在上传前拒绝")

    // 5b. 错误平台：不匹配平台的本地二进制不得复制到远端。
    var wrongPlatform = manifest
    wrongPlatform.platform = baseline.platform.os == "linux" ? "macos" : "linux"
    wrongPlatform.version = "0.9.8-wrongplatform"
    let wrongPlan = RemoteInstallPlan(
      targetDescription: target.rawText, homeDirectory: home, installRoot: installRoot,
      manifest: wrongPlatform, existingVersion: wrapperVersion)
    #expect(throws: (any Error).self) {
      try transaction.install(
        plan: wrongPlan, manifest: wrongPlatform, localPath: settings.localLinuxBinary,
        localDigest: digest, localSize: size)
    }
    note("场景 5b 通过：错误平台产物被拒绝")

    // 5c. 真实上传失败：在 staging 路径上先建一个目录，`cat > <目录>` 必然失败。
    //
    // 为什么不用 chmod：验收在 root 下运行，root 绕过权限位，chmod 注入不出失败。
    // 目录占位对任何用户都失败，是这台机器上唯一确定的注入方式。
    var interrupted = manifest
    interrupted.version = "0.9.7-uploadfail"
    let blockedStagingID = "p3-upload-block"
    let interruptedPlan = RemoteInstallPlan(
      targetDescription: target.rawText, homeDirectory: home, installRoot: installRoot,
      manifest: interrupted, existingVersion: wrapperVersion, stagingID: blockedStagingID)
    _ = try remoteShell(
      transport, "mkdir -p \(RemoteSSHInvocation.quote(interruptedPlan.stagingPath))")
    var uploadError: (any Error)?
    do {
      _ = try transaction.install(
        plan: interruptedPlan, manifest: interrupted, localPath: settings.localLinuxBinary,
        localDigest: digest, localSize: size)
      Issue.record("上传失败场景不应成功")
    } catch { uploadError = error }
    note("场景 5c 错误：\(uploadError.map { String(describing: $0) } ?? "-")")
    _ = try remoteShell(
      transport, "rm -rf \(RemoteSSHInvocation.quote(interruptedPlan.stagingPath))")

    // 失败必须回滚且保留可用旧版本：活动路径仍指向场景 3 安装的版本。
    let afterFailure = try remoteShell(
      transport, "\(RemoteSSHInvocation.quote(activePath)) --version")
    note("上传失败后活动版本：\(afterFailure.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect(afterFailure.exitStatus == 0, "上传失败后旧版本必须仍可用")
    #expect(
      afterFailure.standardOutput.contains(wrapperVersion), "上传失败不得替换掉可用二进制")
    let failedVersionDir = try remoteShell(
      transport,
      "test -e \(RemoteSSHInvocation.quote(installRoot + "/versions/0.9.7-uploadfail")) && echo EXISTS || echo ABSENT"
    )
    #expect(failedVersionDir.standardOutput.contains("ABSENT"), "失败版本目录必须被回滚清理")

    // 上传失败后运行中的任务与服务实例必须不受影响。
    let afterUploadFailure = try client.serverStatus(endpoint)
    #expect(afterUploadFailure.serverEpoch == identity.serverEpoch, "安装失败不得重启服务")
    let finalList = try client.listTerminals(endpoint)
    let finalTask = finalList.first { $0.reference.terminalID == created.reference.terminalID }
    #expect(finalTask?.pid == taskPID, "安装失败不得影响运行中的任务")
    note("场景 5 结束：epoch=\(afterUploadFailure.serverEpoch) pid=\(finalTask?.pid.map(String.init) ?? "-")")

    // ================= A12：远端目录与本地边界 =================
    note("=== A12：远端目录与本地边界 ===")
    // 本地与远端建同名目录，内容不同；远端终端必须只看到远端内容。
    let sharedPath = "\(runRoot)/samedir"
    _ = try remoteShell(
      transport,
      "mkdir -p \(RemoteSSHInvocation.quote(sharedPath)); echo REMOTE_SIDE > \(RemoteSSHInvocation.quote(sharedPath + "/marker"))"
    )
    let localSame = URL(fileURLWithPath: sharedPath)
    try? FileManager.default.createDirectory(
      at: localSame, withIntermediateDirectories: true)
    try? "LOCAL_SIDE".write(
      to: localSame.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: localSame) }

    let cwdProbeFile = "\(runRoot)/cwd-probe.txt"
    let cwdTerminal = try client.createTerminal(
      endpoint, workingDirectory: sharedPath,
      argv: [
        "/bin/sh", "-c",
        "{ pwd; cat marker; } > \(RemoteSSHInvocation.quote(cwdProbeFile)) 2>&1",
      ])
    note("A12 终端：terminalID=\(cwdTerminal.reference.terminalID) cwd=\(cwdTerminal.cwd ?? "-")")
    Thread.sleep(forTimeInterval: 2)
    let cwdProbe = try remoteShell(
      transport, "cat \(RemoteSSHInvocation.quote(cwdProbeFile))")
    note("A12 pwd/marker：\(cwdProbe.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect(cwdProbe.standardOutput.contains("REMOTE_SIDE"), "远端终端必须读到远端同名目录内容")
    #expect(!cwdProbe.standardOutput.contains("LOCAL_SIDE"), "远端终端不得读到本机同名路径")

    // 不存在的目录：服务端拒绝，且不回落到本机目录。
    var missingError: (any Error)?
    do {
      _ = try client.createTerminal(
        endpoint, workingDirectory: "\(runRoot)/definitely-missing",
        argv: ["/bin/sh", "-c", "true"])
      Issue.record("不存在的远端目录不应创建成功")
    } catch { missingError = error }
    if case .some(ManagedSessionError.serviceError(let code, _)) = missingError as? ManagedSessionError
    {
      #expect(code == "cwd_unavailable", "不存在的目录必须由服务端按 cwd_unavailable 拒绝")
      note("A12 不存在目录：code=\(code)")
    } else {
      Issue.record("不存在目录的错误未按服务端错误码返回：\(String(describing: missingError))")
    }

    // 本机文件类动作在远端 Pane 上全部禁用，并有明确原因。
    for action in RemoteWorkspaceBoundary.LocalAction.allCases {
      #expect(RemoteWorkspaceBoundary.isAllowedOnRemotePane(action) == false)
      let reason = RemoteWorkspaceBoundary.disabledReason(action, machineLabel: "orb-p3")
      #expect(!reason.isEmpty)
    }
    note("A12 通过：远端 Pane 的本机文件动作全部禁用并给出原因")

    // ---------- 清理：只限定本次 runID ----------
    note("=== 清理（只限定 runID \(settings.runID)） ===")
    _ = try? client.terminateTerminal(endpoint, terminalID: cwdTerminal.reference.terminalID)
    let terminated = try client.terminateTerminal(
      endpoint, terminalID: created.reference.terminalID)
    note("测试任务结束：state=\(terminated.state.rawValue) exitCode=\(terminated.exitCode.map(String.init) ?? "-")")
    #expect(terminated.state == .exited)
    let stopResult = try remoteShell(
      transport,
      "\(RemoteSSHInvocation.quote(activePath)) server stop \(RemoteSSHInvocation.quote(stateParent)) \(RemoteSSHInvocation.quote(sessionName))"
    )
    note("server stop exit=\(stopResult.exitStatus) out=\(stopResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    // 残留检查按**具体 PID**判定，不按进程名匹配：验收规格禁止用模糊进程名
    // 结束或统计其他会话，而且 pgrep 的命令行本身就含 runID，会自我匹配。
    let taskAlive = try remoteShell(
      transport, "kill -0 \(taskPID) 2>/dev/null && echo ALIVE || echo GONE")
    note("测试任务 PID \(taskPID) 清理后状态：\(taskAlive.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect(taskAlive.standardOutput.contains("GONE"), "测试任务进程必须已回收")
    let socketGone = try remoteShell(
      transport,
      "ls \(RemoteSSHInvocation.quote(stateParent))/*/control.sock 2>/dev/null || echo NO_SOCKET")
    note("服务 socket 清理：\(socketGone.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect(socketGone.standardOutput.contains("NO_SOCKET"), "服务停止后必须删除自己的 socket")
  }
}
