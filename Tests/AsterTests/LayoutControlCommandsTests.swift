import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 结构方法的分发：pane.close / pane.split / tab.new / tab.close / tab.focus / tab.rename。
@Suite(.serialized)
@MainActor
struct LayoutControlCommandsTests {
  private final class PolicyBox {
    var policy = AsterControlDispatcher.Policy(
      allowSendKeys: true, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
  }

  @MainActor
  private struct Fixture {
    let workspace: ControlTestWorkspace
    let dispatcher: AsterControlDispatcher
    let client = ControlFakeClient()
    let box: PolicyBox

    var model: AppModel { workspace.model }

    func call(_ method: String, _ params: JSONValue? = nil) async -> AsterControlResponse {
      await dispatcher.handle(controlRequest(method, params), client: client)
    }
  }

  private func makeFixture() throws -> Fixture {
    let workspace = try ControlTestWorkspace()
    let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
    bridge.activeModelProvider = { [weak model = workspace.model] in model }
    bridge.attach(model: workspace.model)
    let box = PolicyBox()
    let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") { box.policy }
    return Fixture(workspace: workspace, dispatcher: dispatcher, box: box)
  }

  @Test("pane.split 在目标 Pane 旁拆出新 Pane 并返回它的短 ID；pane.close 把它关掉")
  func splitThenClosePane() async throws {
    let fixture = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let tab = try #require(fixture.model.selectedTab)

    let split = await fixture.call("pane.split", ["pane": "w1:p1", "direction": "down"])
    let created = try #require(split.result).decoded(as: LayoutActionResult.self)
    #expect(created.paneID == "w1:p2")
    #expect(created.windowID == "w1")
    #expect(tab.layout.allPanes.count == 2)

    let closed = await fixture.call("pane.close", ["pane": "w1:p2"])
    let outcome = try #require(closed.result).decoded(as: LayoutActionResult.self)
    #expect(outcome.paneID == "w1:p2")
    #expect(outcome.closedTab == false)
    #expect(outcome.tabID == nil)
    #expect(tab.layout.allPanes.count == 1)
    #expect(await fixture.call("pane.close", ["pane": "w1:p2"]).error?.code == .notFound)
  }

  @Test("pane.close 关的是标签里最后一个 Pane 时连标签一起关")
  func closingLastPaneClosesTab() async throws {
    let fixture = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let created = try #require(await fixture.call("tab.new", ["cwd": "/tmp"]).result)
      .decoded(as: LayoutActionResult.self)
    let paneID = try #require(created.paneID)
    #expect(created.tabID == "w1:t2")
    #expect(fixture.model.tabs.count == 2)

    let outcome = try #require(await fixture.call("pane.close", ["pane": .string(paneID)]).result)
      .decoded(as: LayoutActionResult.self)
    #expect(outcome.closedTab == true)
    #expect(outcome.tabID == "w1:t2")
    #expect(fixture.model.tabs.count == 1)
  }

  @Test("tab.new 选中新标签并带回 ID；tab.focus 切回旧标签；tab.close 接受标签里的 Pane 做目标")
  func tabLifecycle() async throws {
    let fixture = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let first = try #require(fixture.model.selectedTab)

    let created = try #require(await fixture.call("tab.new").result)
      .decoded(as: LayoutActionResult.self)
    let newPane = try #require(created.paneID)
    #expect(fixture.model.tabs.count == 2)
    #expect(fixture.model.selectedTab?.id != first.id)

    #expect(await fixture.call("tab.focus", ["tab": "w1:t1"]).error == nil)
    #expect(fixture.model.selectedTab?.id == first.id)

    let closed = try #require(await fixture.call("tab.close", ["tab": .string(newPane)]).result)
      .decoded(as: LayoutActionResult.self)
    #expect(closed.tabID == created.tabID)
    #expect(fixture.model.tabs.map(\.id) == [first.id])
    #expect(await fixture.call("tab.close", ["tab": "w1:t9"]).error?.code == .notFound)
    #expect(
      await fixture.call("tab.new", ["cwd": "/nonexistent/aster-layout-test"]).error?.code
        == .invalidParams)
  }

  @Test("tab.rename 固定标签名，title 为空时恢复自动标题")
  func renameTab() async throws {
    let fixture = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let tab = try #require(fixture.model.selectedTab)

    #expect(await fixture.call("tab.rename", ["tab": "w1:t1", "title": "构建"]).error == nil)
    #expect(tab.tabTitleOverride == .name("构建"))
    #expect(await fixture.call("tab.rename", ["tab": "w1:p1"]).error == nil)
    #expect(tab.tabTitleOverride == .automatic)
  }

  @Test("写门禁关闭时拒绝关闭 / 拆分 / 新建，但 focus 与 rename 仍可用")
  func writeGate() async throws {
    let fixture = try makeFixture()
    defer { fixture.workspace.tearDown() }
    fixture.box.policy.allowSendKeys = false

    #expect(await fixture.call("pane.split", ["pane": "w1:p1"]).error?.code == .writeNotAllowed)
    #expect(await fixture.call("pane.close", ["pane": "w1:p1"]).error?.code == .writeNotAllowed)
    #expect(await fixture.call("tab.new").error?.code == .writeNotAllowed)
    #expect(await fixture.call("tab.close", ["tab": "w1:t1"]).error?.code == .writeNotAllowed)
    #expect(fixture.model.tabs.count == 1)
    #expect(fixture.model.selectedTab?.layout.allPanes.count == 1)

    #expect(await fixture.call("tab.focus", ["tab": "w1:t1"]).error == nil)
    #expect(await fixture.call("tab.rename", ["tab": "w1:t1", "title": "x"]).error == nil)
  }
}
