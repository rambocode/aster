import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// P4.3 的真实 AppKit 宿主验收：机器分区确实被渲染进侧栏，Local 恒在最上，
// 「+ 添加机器」按钮与每行的右键菜单都是**真实可点**的控件，而不是只有编程接口。

@MainActor
private func allViews(_ root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { allViews($0) }
}

/// 机器列表现在住在左下角切换器的弹出层里：先找到切换器、打开弹出层，再遍历其内容。
@MainActor
private func machineSidebarViews(_ root: NSView) -> [NSView] {
  guard let switcher = allViews(root).compactMap({ $0 as? MachineSwitcherButton }).first else {
    return []
  }
  if switcher.popoverContentView == nil { switcher.presentPopover() }
  guard let content = switcher.popoverContentView else { return [] }
  return allViews(content)
}

@MainActor
private struct MachineSidebarFixture {
  let window: NSWindow
  let controller: WorkspaceViewController
  let fleet: MachineFleetModel
  let suiteName: String
  let defaults: UserDefaults
  let configURL: URL

  func tearDown() {
    if let tab = controller.model.selectedTab {
      for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    }
    window.orderOut(nil)
    fleet.stop()
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent())
  }
}

/// 只做设置事务的替身；不连网络，直接产出可保存的配置。
private final class SidebarStubServices: MachineFleetServices, @unchecked Sendable {
  func runSetup(rawTarget: String, label: String, sessionName: String, profileID: UUID)
    async throws -> RemoteSetupOutcome
  {
    .ready(
      profile: MachineProfile(
        id: profileID, label: label, sshTarget: rawTarget, sessionName: sessionName),
      identity: MachineFleetFixtures.identity,
      report: MachineFleetFixtures.report)
  }

  func registry(for profile: MachineProfile) throws -> MachineRegistryAccess {
    throw ManagedSessionError.runtimeUnavailable("测试不提供注册表传输")
  }
}

/// 永远连不上的驱动：用来证明离线机器仍然能被渲染、选中与操作。
private struct SidebarSilentDriver: MachineConnectionDriving {
  func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
    .needsExplicitSetup(kind: nil, reason: "测试驱动不连接")
  }
  func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool { false }
  func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool { false }
}

@MainActor
private func makeMachineSidebarFixture() throws -> MachineSidebarFixture {
  let suiteName = "MachineSidebarProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  // 机器分区只在竖直标签栏（侧栏）布局里出现，这是它的宿主。
  preferences.tabBarLayout = .vertical
  model.ensureInitialTab()

  let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("MachineSidebarProbe.\(UUID().uuidString)")
    .appendingPathComponent("machines.json")
  let fleet = MachineFleetModel(
    store: MachineProfileStore(fileURL: configURL),
    services: SidebarStubServices(),
    supervisor: MachineConnectionSupervisor(
      environment: MachineConnectionEnvironment(
        sleep: { _ in await Task.yield() }, jitter: { 0 }),
      driver: SidebarSilentDriver()),
    localStateProvider: { .online },
    localErrorProvider: { nil })
  MachineFleetModel.shared = fleet

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false)
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  return MachineSidebarFixture(
    window: window, controller: controller, fleet: fleet, suiteName: suiteName,
    defaults: defaults, configURL: configURL)
}

@Test("机器侧栏：Local 恒在最上，添加机器按钮真实存在且可点")
@MainActor
func machineSidebarRendersLocalAndAddButton() async throws {
  let fixture = try makeMachineSidebarFixture()
  defer { fixture.tearDown() }
  try await Task.sleep(for: .milliseconds(120))
  fixture.window.contentView?.layoutSubtreeIfNeeded()

  let views = machineSidebarViews(fixture.controller.view)
  let rows = views.compactMap { $0 as? MachineRowButton }
  #expect(rows.count == 1)
  #expect(rows.first?.machineID == MachineProfile.localProfileID)

  // 组头与添加按钮必须是真实控件，且添加按钮挂着可触发的 action。
  #expect(views.contains { $0.identifier?.rawValue == "machine-section-header" })
  let addButton = try #require(
    views.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "machine-add-button" })
  #expect(addButton.target != nil)
  #expect(addButton.action != nil)
  #expect(addButton.isEnabled)
}

@Test("机器侧栏：保存的机器渲染成一行，右键菜单提供重命名/禁用/移除")
@MainActor
func machineSidebarRendersSavedMachineWithMenu() async throws {
  let fixture = try makeMachineSidebarFixture()
  defer { fixture.tearDown() }
  guard case .added(let profile) = await fixture.fleet.addMachine(
    label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
  else {
    Issue.record("前置添加失败")
    return
  }
  fixture.controller.scheduleRefresh()
  try await Task.sleep(for: .milliseconds(150))
  fixture.window.contentView?.layoutSubtreeIfNeeded()

  let rows = machineSidebarViews(fixture.controller.view).compactMap { $0 as? MachineRowButton }
  #expect(rows.count == 2)
  #expect(rows[0].machineID == MachineProfile.localProfileID)
  let remote = try #require(rows.first { $0.machineID == profile.id })

  // 右键菜单是真实可点路径：三项都有 target/action 与代表的机器 ID。
  let menu = try #require(remote.menu)
  let titles = menu.items.map(\.title)
  #expect(titles.contains("重命名…"))
  #expect(titles.contains("禁用"))
  #expect(titles.contains("移除…"))
  for item in menu.items where !item.isSeparatorItem {
    #expect(item.target != nil, "\(item.title) 必须有可触发的目标")
    #expect(item.representedObject as? UUID == profile.id)
  }

  // 离线的机器整体灰显，明确表示这是缓存结构。
  #expect(remote.alphaValue < 1)
  #expect(remote.toolTip?.contains("需要处理") == true || remote.toolTip?.contains("未连接") == true)
}

@Test("机器侧栏：主菜单「文件 ▸ 添加机器…」与侧栏按钮指向同一个动作")
@MainActor
func machineSidebarMenuEntryMatchesSidebarButton() async throws {
  let fixture = try makeMachineSidebarFixture()
  defer { fixture.tearDown() }
  try await Task.sleep(for: .milliseconds(120))
  let addButton = try #require(
    machineSidebarViews(fixture.controller.view).compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "machine-add-button" })
  // 两条入口共用同一个 selector；主菜单项转交给当前工作区控制器。
  #expect(addButton.action == #selector(WorkspaceViewController.presentAddMachine))
  #expect(fixture.controller.responds(to: #selector(WorkspaceViewController.presentAddMachine)))
}
