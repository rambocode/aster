// 新建工作区表单的纯逻辑：主机下拉的分组与去重、提交分派与名称校验。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 一台绑定了已保存主机的在线机器、一台已禁用的机器，以及三条主机（含默认项）。
@MainActor
private struct FormFixture {
  let boundHost = SSHHostProfile(name: "prod", host: "prod.example.com")
  let freeHost = SSHHostProfile(name: "staging", host: "staging.example.com")
  let online: NewWorkspaceMachine
  let disabled = NewWorkspaceMachine(
    id: UUID(), label: "retired", hostID: nil, sshTarget: "old-box", enabled: false, state: .disabled)

  init() {
    online = NewWorkspaceMachine(
      id: UUID(), label: "prod-box", hostID: boundHost.id, sshTarget: "orb", enabled: true,
      state: .online)
  }

  var hosts: [SSHHostProfile] { [SSHHostProfile.emptyDefaults(), boundHost, freeHost] }
}

@MainActor
@Test("新建表单：已添加成机器的主机与别名不重复出现，禁用机器与默认项不列出")
func newWorkspaceFormDedupesBoundHostsAndAliases() {
  let fixture = FormFixture()
  let entries = NewWorkspaceForm.menuEntries(
    machines: [fixture.online, fixture.disabled], hosts: fixture.hosts,
    aliases: ["orb", "staging", "old-box", "dev", "dev", ""])
  #expect(
    entries == [
      .choice(.local, title: L("本机")),
      .separator, .header(L("机器")),
      .choice(
        .machine(fixture.online.id), title: "prod-box（\(MachineRowButton.stateText(.online))）"),
      .separator, .header(L("主机")),
      .choice(.savedHost(id: fixture.freeHost.id, name: "staging"), title: "staging"),
      .separator, .header(L("SSH 别名")),
      .choice(.sshAlias("dev"), title: "dev"),
      .separator, .choice(.addHost, title: L("添加主机…")),
    ])
}

@MainActor
@Test("新建表单：拿不到 ssh 别名时整组不显示，没有机器和主机时只剩本机与添加主机")
func newWorkspaceFormOmitsUnavailableGroups() {
  let entries = NewWorkspaceForm.menuEntries(
    machines: [], hosts: [SSHHostProfile.emptyDefaults()], aliases: nil)
  #expect(
    entries == [
      .choice(.local, title: L("本机")), .separator, .choice(.addHost, title: L("添加主机…")),
    ])
}

@MainActor
@Test("新建表单：提交按所选主机分派，名称去空白；未添加的主机与别名先走添加机器")
func newWorkspaceFormDispatchesSubmission() throws {
  let hostID = UUID()
  let machineID = UUID()
  #expect(
    try NewWorkspaceForm.submission(choice: .local, name: "  notes ", openInNewWindow: true)
      == .createLocal(name: "notes"))
  #expect(
    try NewWorkspaceForm.submission(choice: .machine(machineID), name: "api", openInNewWindow: false)
      == .createRemote(machineID: machineID, name: "api", inNewWindow: false))
  #expect(
    try NewWorkspaceForm.submission(
      choice: .savedHost(id: hostID, name: "staging"), name: "api", openInNewWindow: true)
      == .addMachineThenCreate(
        prefill: .init(label: "staging", hostID: hostID), name: "api", inNewWindow: true))
  #expect(
    try NewWorkspaceForm.submission(choice: .sshAlias("dev"), name: "api", openInNewWindow: false)
      == .addMachineThenCreate(
        prefill: .init(label: "dev", sshTarget: "dev"), name: "api", inNewWindow: false))
  // 「添加主机…」是跳转，不校验名称。
  #expect(
    try NewWorkspaceForm.submission(choice: .addHost, name: "", openInNewWindow: false)
      == .openHostSettings)
}

@MainActor
@Test("新建表单：名称为空或过长时拒绝提交")
func newWorkspaceFormRejectsInvalidNames() {
  #expect(throws: NamedWorkspaceRegistryError.emptyName) {
    try NewWorkspaceForm.submission(choice: .machine(UUID()), name: "   ", openInNewWindow: false)
  }
  let long = String(repeating: "x", count: NamedWorkspaceRegistry.maximumNameLength + 1)
  #expect(throws: NamedWorkspaceRegistryError.nameTooLong) {
    try NewWorkspaceForm.submission(choice: .local, name: long, openInNewWindow: false)
  }
}

@MainActor
@Test("新建表单：只有远端目标才允许「在新窗口中打开」")
func newWorkspaceFormRemoteChoices() {
  #expect(NewWorkspaceHostChoice.machine(UUID()).isRemote)
  #expect(NewWorkspaceHostChoice.savedHost(id: UUID(), name: "a").isRemote)
  #expect(NewWorkspaceHostChoice.sshAlias("a").isRemote)
  #expect(!NewWorkspaceHostChoice.local.isRemote)
  #expect(!NewWorkspaceHostChoice.addHost.isRemote)
}
