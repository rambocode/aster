// `workspace.open` / `workspace.new` 的定向测试：名称解析、歧义、打开上限与远端错误映射。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("workspace.open：本地按名称或 ID 打开，远端按 机器/工作区 选中")
@MainActor
func workspaceControlOpenResolvesLocalAndRemote() async throws {
  let fixture = WorkspaceControlFixture()
  fixture.otherWindow.cache[fixture.orb.id] = [controlTestSummary("ws-1", "build")]
  let dev = try #require(fixture.directory.workspaces.first { $0.name == "dev" })

  let byName = try #require(await fixture.call("workspace.open", ["workspace": "dev"]).result)
    .decoded(as: WorkspaceActionResult.self)
  #expect(byName == WorkspaceActionResult(kind: "local", workspaceID: dev.id.uuidString, name: "dev"))
  _ = await fixture.call("workspace.open", .object(["workspace": .string(dev.id.uuidString)]))
  #expect(fixture.directory.opened == [dev.id, dev.id])

  // 缓存来自另一个窗口，写操作仍落在 key window 的协调器上。
  let remote = try #require(await fixture.call("workspace.open", ["workspace": "orb/build"]).result)
    .decoded(as: WorkspaceActionResult.self)
  #expect(remote.kind == "remote")
  #expect(remote.workspaceID == "ws-1")
  #expect(remote.machineLabel == "orb")
  let byID = await fixture.call(
    "workspace.open", .object(["workspace": .string("\(fixture.orb.id.uuidString)/ws-1")]))
  #expect(byID.error == nil)
  #expect(fixture.keyWindow.selected == Array(repeating: "\(fixture.orb.id.uuidString)/ws-1", count: 2))
  #expect(fixture.otherWindow.selected.isEmpty)
}

@Test("workspace.open：名称有歧义时返回 ambiguous_target 并列出唯一写法；找不到返回 not_found")
@MainActor
func workspaceControlOpenRejectsAmbiguousNames() async throws {
  let fixture = WorkspaceControlFixture()
  fixture.keyWindow.cache[fixture.orb.id] = [controlTestSummary("ws-dev", "dev")]
  fixture.keyWindow.cache[fixture.pi.id] = [controlTestSummary("ws-9", "dev")]
  let dev = try #require(fixture.directory.workspaces.first { $0.name == "dev" })

  let ambiguous = await fixture.call("workspace.open", ["workspace": "dev"])
  #expect(ambiguous.error?.code == .ambiguousTarget)
  let message = ambiguous.error?.message ?? ""
  #expect(message.contains(dev.id.uuidString))
  #expect(message.contains("\(fixture.orb.id.uuidString)/ws-dev"))
  #expect(message.contains("\(fixture.pi.id.uuidString)/ws-9"))
  #expect(fixture.directory.opened.isEmpty)
  #expect(fixture.keyWindow.selected.isEmpty)

  // 用列出的写法之一就能唯一定位。
  #expect(await fixture.call("workspace.open", ["workspace": "pi/dev"]).error == nil)
  #expect(fixture.keyWindow.selected == ["\(fixture.pi.id.uuidString)/ws-9"])

  let missing = await fixture.call("workspace.open", ["workspace": "nope"])
  #expect(missing.error?.code == .notFound)
  let blank = await fixture.call("workspace.open", ["workspace": "  "])
  #expect(blank.error?.code == .invalidParams)
}

@Test("workspace.open：打开已关闭的工作区前先查打开上限，不走会弹框的开窗路径")
@MainActor
func workspaceControlOpenChecksOpenLimit() async throws {
  let open = (0..<NamedWorkspaceRegistry.maximumOpen).map { controlTestWorkspace("w\($0)", open: true) }
  let fixture = WorkspaceControlFixture(local: open + [controlTestWorkspace("closed", open: false)])
  let response = await fixture.call("workspace.open", ["workspace": "closed"])
  #expect(response.error?.code == .invalidRequest)
  #expect(fixture.directory.opened.isEmpty)
  // 已经打开的工作区只是置前，不受上限约束。
  #expect(await fixture.call("workspace.open", ["workspace": "w0"]).error == nil)
}

@Test("workspace.open：远端协调器的错误翻译成对应错误码")
@MainActor
func workspaceControlOpenMapsRemoteErrors() async throws {
  let fixture = WorkspaceControlFixture()
  fixture.keyWindow.cache[fixture.orb.id] = [controlTestSummary("ws-1", "build")]
  fixture.keyWindow.selectError = RemoteWorkspaceOperationError.workspaceNotFound("ws-1")
  #expect(await fixture.call("workspace.open", ["workspace": "orb/build"]).error?.code == .notFound)
  fixture.keyWindow.selectError = RemoteWorkspaceOperationError.machineUnavailable("已禁用")
  let unavailable = await fixture.call("workspace.open", ["workspace": "orb/build"])
  #expect(unavailable.error?.code == .invalidRequest)
  #expect(unavailable.error?.message == "已禁用")
}

@Test("workspace.new：本地名称先校验再建窗口，结果回显新条目 ID")
@MainActor
func workspaceControlNewLocal() async throws {
  let fixture = WorkspaceControlFixture()
  let created = try #require(await fixture.call("workspace.new", ["name": "  notes  "]).result)
    .decoded(as: WorkspaceActionResult.self)
  #expect(fixture.directory.created == ["notes"])
  #expect(created.kind == "local")
  #expect(created.name == "notes")
  #expect(created.workspaceID == fixture.directory.workspaces.first?.id.uuidString)

  // `--machine local` 与省略等价。
  #expect(await fixture.call("workspace.new", ["name": "n2", "machine": "local"]).error == nil)
  #expect(fixture.directory.created == ["notes", "n2"])

  let empty = await fixture.call("workspace.new", ["name": "   "])
  #expect(empty.error?.code == .invalidParams)
  let tooLong = String(repeating: "x", count: NamedWorkspaceRegistry.maximumNameLength + 1)
  #expect(await fixture.call("workspace.new", .object(["name": .string(tooLong)])).error?.code
    == .invalidParams)
  #expect(fixture.directory.created.count == 2)
}

@Test("workspace.new --machine：在那台机器上新建并选中；机器不存在或标签重复都拒绝")
@MainActor
func workspaceControlNewRemote() async throws {
  let fixture = WorkspaceControlFixture(extraMachines: ["twin", "twin"])
  let created = try #require(
    await fixture.call("workspace.new", ["name": "api", "machine": "orb"]).result
  ).decoded(as: WorkspaceActionResult.self)
  #expect(created == WorkspaceActionResult(
    kind: "remote", workspaceID: "ws-created", name: "api",
    machineID: fixture.orb.id.uuidString, machineLabel: "orb"))
  #expect(fixture.keyWindow.created == ["\(fixture.orb.id.uuidString)/api"])

  let ambiguous = await fixture.call("workspace.new", ["name": "api", "machine": "twin"])
  #expect(ambiguous.error?.code == .ambiguousTarget)
  #expect(await fixture.call("workspace.new", ["name": "api", "machine": "ghost"]).error?.code
    == .notFound)
  #expect(await fixture.call("workspace.new", ["name": "api", "machine": " "]).error?.code
    == .invalidParams)
  #expect(await fixture.call("workspace.new", ["name": "", "machine": "orb"]).error?.code
    == .invalidParams)
  #expect(fixture.keyWindow.created.count == 1)
  #expect(fixture.directory.created.isEmpty)
}
