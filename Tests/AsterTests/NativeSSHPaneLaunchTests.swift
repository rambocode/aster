import AsterCore
import Foundation
import Testing

@testable import Aster

// 原生 SSH 标签：启动 argv、OpenSSH 回退、新标签的 Pane 描述符与「保存为主机」的纯转换。
// 端点用假的，使用频率写独立 UserDefaults suite，不碰用户真实配置与 broker。

private let fakeEndpoint = NativeSSHEndpoint(
  executablePath: "/opt/aster/aster-ssh", brokerSocketPath: "/tmp/aster-sshb-test/b.sock")

@Test("原生 Pane 的启动 argv：client + broker + 目标 + --tty，不带 --no-prompt 与远端命令")
func nativeSSHLaunchUsesClientArguments() throws {
  let hostID = UUID()
  let host = SSHHostProfile(id: hostID, name: "prod", host: "10.0.0.5", user: "deploy")
  let plan = NativeSSHPaneLaunch.plan(
    for: .host(hostID), endpoint: .success(fakeEndpoint), hosts: [.emptyDefaults(), host])
  #expect(
    plan
      == .native(
        executable: "/opt/aster/aster-ssh",
        arguments: [
          "client", "--broker", "/tmp/aster-sshb-test/b.sock", "--host-id", hostID.uuidString, "--tty",
        ]))

  let textPlan = NativeSSHPaneLaunch.plan(
    for: try #require(NativeSSHPaneSpec.target("ssh://me@box:2222")), endpoint: .success(fakeEndpoint),
    hosts: [])
  #expect(
    textPlan
      == .native(
        executable: "/opt/aster/aster-ssh",
        arguments: ["client", "--broker", "/tmp/aster-sshb-test/b.sock", "--target", "ssh://me@box:2222", "--tty"]))
}

@Test("引擎不是 native 时回退到 OpenSSH：主机按规范 target，文本原样")
func nativeSSHLaunchFallsBackToOpenSSH() throws {
  let hostID = UUID()
  let host = SSHHostProfile(id: hostID, name: "prod", host: "10.0.0.5", port: 2222, user: "deploy")
  let failure = Result<NativeSSHEndpoint, any Error>.failure(SSHBrokerError.engineDisabled)
  let plan = NativeSSHPaneLaunch.plan(for: .host(hostID), endpoint: failure, hosts: [host])
  guard case .openssh(let target, let reason) = plan else {
    Issue.record("应回退到 OpenSSH：\(plan)")
    return
  }
  #expect(target == "ssh://deploy@10.0.0.5:2222")
  #expect(!reason.isEmpty)
  #expect(
    NativeSSHPaneLaunch.plan(for: try #require(NativeSSHPaneSpec.target("orb")), endpoint: failure, hosts: [])
      == .openssh(target: "orb", reason: NativeSSHPaneLaunch.fallbackReason(SSHBrokerError.engineDisabled)))
}

@Test("主机已删除时不启动也不回退，只给原因")
func nativeSSHLaunchReportsMissingHost() {
  let plan = NativeSSHPaneLaunch.plan(for: .host(UUID()), endpoint: .success(fakeEndpoint), hosts: [])
  guard case .unavailable = plan else {
    Issue.record("应不可用：\(plan)")
    return
  }
}

@Test("回退命令：安全目标原样，含特殊字符时单引号转义")
func nativeSSHTypedCommandQuotes() {
  #expect(NativeSSHPaneLaunch.typedSSHCommand(target: "ssh://me@[::1]:2222") == "ssh ssh://me@[::1]:2222")
  #expect(NativeSSHPaneLaunch.typedSSHCommand(target: "we'ird") == #"ssh 'we'\''ird'"#)
}

@Test("默认标题：主机名称优先，文本目标取主机部分")
func nativeSSHDefaultTitle() throws {
  let host = SSHHostProfile(name: "prod", host: "10.0.0.5")
  #expect(NativeSSHPaneLaunch.defaultTitle(for: .host(host.id), hosts: [host]) == "prod")
  #expect(
    NativeSSHPaneLaunch.defaultTitle(for: try #require(NativeSSHPaneSpec.target("me@box:2222")), hosts: [])
      == "box")
}

/// 用假端点与独立使用频率 suite 跑一段 AppModel 代码，结束后还原全局注入点。
@MainActor
private func withNativeSSHTestEnvironment(
  endpoint: @escaping () throws -> NativeSSHEndpoint, _ body: (AppModel, UserDefaults) throws -> Void
) rethrows {
  let suite = "NativeSSHPaneLaunchTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  let previousProvider = NativeSSHPaneLaunch.endpointProvider
  let previousDefaults = HostUsageTracking.defaults
  NativeSSHPaneLaunch.endpointProvider = endpoint
  HostUsageTracking.defaults = defaults
  defer {
    NativeSSHPaneLaunch.endpointProvider = previousProvider
    HostUsageTracking.defaults = previousDefaults
    defaults.removePersistentDomain(forName: suite)
  }
  try body(AppModel(defaults: defaults), defaults)
}

@Test("打开原生 SSH 目标：新本地标签的 Pane 记下 nativeSSH，标题用主机名，并记一次使用")
@MainActor
func openNativeSSHCreatesTaggedTab() throws {
  try withNativeSSHTestEnvironment(endpoint: { fakeEndpoint }) { model, defaults in
    model.ensureInitialTab()
    let before = model.tabs.count
    model.openNativeSSH(target: "ssh://deploy@box:2222")
    #expect(model.tabs.count == before + 1)
    let tab = try #require(model.selectedTab)
    let pane = try #require(tab.layout.allPanes.first)
    #expect(pane.nativeSSH == NativeSSHPaneSpec.target("ssh://deploy@box:2222"))
    #expect(tab.title == "box")
    #expect(tab.activeSession?.nativeSSH == pane.nativeSSH)
    #expect(tab.activeSession?.isManagedTerminal == false)
    let ledger = try HostUsageLedger.load(from: defaults)
    #expect(ledger.entries[.target("ssh://deploy@box:2222")]?.count == 1)
  }
}

@Test("引擎不可用时不建原生 Pane，改开普通标签并提示原因")
@MainActor
func openNativeSSHFallsBackWhenEngineDisabled() throws {
  try withNativeSSHTestEnvironment(endpoint: { throw SSHBrokerError.engineDisabled }) { model, _ in
    model.ensureInitialTab()
    let before = model.tabs.count
    model.openNativeSSH(target: "orb")
    #expect(model.tabs.count == before + 1)
    #expect(model.selectedTab?.layout.allPanes.first?.nativeSSH == nil)
    #expect(model.notice == NativeSSHPaneLaunch.fallbackReason(SSHBrokerError.engineDisabled))
  }
}

@Test("无效目标不建标签")
@MainActor
func openNativeSSHRejectsInvalidTarget() throws {
  try withNativeSSHTestEnvironment(endpoint: { fakeEndpoint }) { model, _ in
    model.ensureInitialTab()
    let before = model.tabs.count
    model.openNativeSSH(target: "-oProxyCommand=evil")
    #expect(model.tabs.count == before)
    #expect(model.notice != nil)
  }
}

@Test("保存为主机：表单内容变成主机配置，名称与分组可留空")
@MainActor
func saveHostSheetMakesProfile() throws {
  let profile = try SaveSSHHostSheet.makeProfile(
    .init(name: "  ", group: " web ", target: "deploy@10.0.0.5:2222", connectNow: false))
  #expect(profile.name == "10.0.0.5")
  #expect(profile.group == "web")
  #expect(profile.host == "10.0.0.5")
  #expect(profile.user == "deploy")
  #expect(profile.port == 2222)

  let bare = try SaveSSHHostSheet.makeProfile(.init(name: "box", group: "", target: "box", connectNow: true))
  #expect(bare.group == nil)
  #expect(bare.port == nil)
  #expect(bare.user == "")

  #expect(throws: SaveSSHHostSheet.SaveError.self) {
    try SaveSSHHostSheet.makeProfile(.init(name: "x", group: "", target: "java:99999", connectNow: false))
  }
}

@Test("手敲 alias 时用 ssh -G 解析出的真实地址预填，名称保留 alias")
@MainActor
func saveHostPrefillUsesResolvedEndpointForAlias() throws {
  let invocation = try #require(SSHCommandInvocation.parse("ssh -p 2200 prod"))
  guard case .target(let target) = QuickConnectTarget.derive(from: invocation) else {
    Issue.record("应能反推")
    return
  }
  let resolved = SSHResolvedEndpoint(hostName: "10.0.0.5", user: "deploy", port: 22)
  let prefill = SaveSSHHostSheet.Prefill.derived(target: target, invocation: invocation, resolved: resolved)
  #expect(prefill.name == "prod")
  #expect(prefill.target == QuickConnectTarget(user: "deploy", host: "10.0.0.5", port: 2200))

  let direct = SaveSSHHostSheet.Prefill.derived(
    target: target, invocation: invocation, resolved: SSHResolvedEndpoint(hostName: "prod"))
  #expect(direct.target == target)
}
