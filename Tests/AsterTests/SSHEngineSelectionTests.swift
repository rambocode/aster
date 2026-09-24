import AsterCore
import Foundation
import Testing

@testable import Aster

// 引擎选择与 aster-ssh 定位：环境变量优先、缺二进制回退 OpenSSH、开发构建的候选路径。

@MainActor
@Test("引擎选择：找不到二进制回退 openssh 并记诊断；环境变量 openssh 时不拉起 broker")
func sshBrokerSupervisorFallsBackToOpenSSH() throws {
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let routing = SSHEngineRouting()
  let missing = SSHBrokerSupervisor(
    routing: routing, hostDirectory: { directory }, environment: [:], locateExecutable: { nil })
  missing.start(preferredEngine: .native)
  #expect(missing.engine == .openssh)
  #expect(routing.nativeEndpoint == nil)
  #expect(missing.diagnostics.contains { $0 == "ssh.engine.fallback: executable missing" })
  #expect(throws: SSHBrokerError.engineDisabled) { try missing.nativeEndpoint() }

  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  let overridden = makeFakeBrokerSupervisor(
    broker, directory: directory, routing: routing,
    environment: [SSHEngine.environmentKey: "openssh"])
  overridden.start(preferredEngine: .native)
  #expect(overridden.engine == .openssh)
  #expect(overridden.launchCount == 0)
  #expect(routing.nativeEndpoint == nil)
}

@Test("引擎选择：环境变量优先于设置，非法取值忽略并报告")
func sshBrokerSupervisorRequestedEngine() {
  #expect(SSHBrokerSupervisor.requestedEngine(environment: [:], preferred: .native) == (.native, nil))
  #expect(
    SSHBrokerSupervisor.requestedEngine(
      environment: ["ASTER_SSH_ENGINE": "OpenSSH"], preferred: .native) == (.openssh, nil))
  #expect(
    SSHBrokerSupervisor.requestedEngine(
      environment: ["ASTER_SSH_ENGINE": "native"], preferred: .openssh) == (.native, nil))
  let invalid = SSHBrokerSupervisor.requestedEngine(
    environment: ["ASTER_SSH_ENGINE": "putty"], preferred: .openssh)
  #expect(invalid.engine == .openssh)
  #expect(invalid.problem != nil)
}

@Test("定位 aster-ssh：环境变量 → App 包 → 主程序同目录 → 开发构建 cargo 产物")
func sshBrokerSupervisorLocatesExecutable() throws {
  let fileManager = FileManager.default
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AsterLocateSSH.\(UUID().uuidString)")
  defer { try? fileManager.removeItem(at: root) }
  func makeExecutable(_ relative: String) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.standardizedFileURL
  }
  let devMain = root.appendingPathComponent(".build/debug/Aster")
  let appBundle = root.appendingPathComponent("Aster.app")

  // 什么都没有。
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == nil)
  // 只有 cargo 产物：由 .build 反推仓库根。
  let cargo = try makeExecutable("SshRuntime/target/debug/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == cargo)
  // 主程序同目录优先于 cargo 产物。
  let sibling = try makeExecutable(".build/debug/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == sibling)
  // App 包内优先于开发产物。
  let bundled = try makeExecutable("Aster.app/Contents/MacOS/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == bundled)
  // 环境变量最优先；指向不可执行文件时忽略。
  let override = try makeExecutable("custom/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: ["ASTER_SSH_BINARY": override.path], bundleURL: appBundle,
      mainExecutableURL: devMain, fileManager: fileManager) == override)
  #expect(
    SSHBrokerSupervisor.locate(
      environment: ["ASTER_SSH_BINARY": "/nonexistent/aster-ssh"], bundleURL: appBundle,
      mainExecutableURL: devMain, fileManager: fileManager) == bundled)
}

@MainActor
@Test("传输工厂：有原生端点时走 aster-ssh 并带 hostID，不建私有 OpenSSH 配置；否则与原来一致")
func machineHostBindingTransportFollowsRouting() throws {
  let endpoint = NativeSSHEndpoint(executablePath: "/tmp/aster-ssh", brokerSocketPath: "/tmp/x/b.sock")
  let routing = SSHEngineRouting()
  let environment = [RemoteSSHPolicy.manageSSHConfigEnvironmentKey: "0"]
  let services = RemoteMachineFleetServices(environment: environment, routing: routing)
  let hostID = UUID()

  let openssh = try services.makeTransport("root@orb", hostID: hostID)
  #expect(openssh.native == nil)
  #expect(openssh.executablePath == "/usr/bin/ssh")

  routing.publish(endpoint)
  let native = try services.makeTransport("root@orb", hostID: hostID)
  #expect(native.native == endpoint)
  #expect(native.hostID == hostID)
  #expect(native.managedConfiguration == nil)
  #expect(native.sshArguments(remoteCommand: ["true"]).contains(hostID.uuidString))

  // 受管终端协调器（Pane 桥与场景 B 旁路通道的来源）同样按路由选择。
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.remoteTargetEnvironmentKey: "root@orb",
      RemoteSSHPolicy.manageSSHConfigEnvironmentKey: "0",
    ],
    machineProfileID: UUID(), hostID: hostID, routing: routing)
  #expect(coordinator.remoteTransport?.native == endpoint)
  #expect(coordinator.remoteTransport?.hostID == hostID)
  let legacy = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.remoteTargetEnvironmentKey: "root@orb",
      RemoteSSHPolicy.manageSSHConfigEnvironmentKey: "0",
    ],
    machineProfileID: UUID(), routing: SSHEngineRouting())
  #expect(legacy.remoteTransport?.native == nil)
  #expect(legacy.remoteTransport?.executablePath == "/usr/bin/ssh")
}
