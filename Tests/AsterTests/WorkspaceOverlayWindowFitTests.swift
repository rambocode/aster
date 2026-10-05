// 窗口内浮层（Agent 历史、全局查找、命令面板）的尺寸约束：正常窗口用首选尺寸，
// 窗口比浮层小时收缩到窗口内，不能被窗口裁掉。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 构造一个带编辑器 Pane 的工作区窗口（编辑器代替终端，免起 PTY）。
@MainActor
private func makeOverlayWorkspace(size: NSSize) throws -> (
  model: AppModel, workspace: WorkspaceViewController, window: NSWindow, suite: String
) {
  let suite = "OverlayWindowFit.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let tab = WorkspaceTabSnapshot(
    id: UUID(), title: "fit",
    layout: .leaf(PaneDescriptor(kind: .editor, workingDirectory: home)))
  defaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
    forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = workspace
  window.setContentSize(size)
  window.contentView?.layoutSubtreeIfNeeded()
  return (model, workspace, window, suite)
}

/// 轮询等待浮层控制器出现并完成布局。
@MainActor
private func waitForOverlay<T: NSViewController>(
  _ type: T.Type, in workspace: WorkspaceViewController
) async -> T? {
  for _ in 0..<300 {
    if let overlay = workspace.children.compactMap({ $0 as? T }).last {
      workspace.view.layoutSubtreeIfNeeded()
      return overlay
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return nil
}

@Test("最大字号档下，矮窗口里的 Agent 历史浮层收缩到窗口内，不被裁掉底部")
@MainActor
func agentHistoryOverlayShrinksIntoShortWindow() async throws {
  InterfaceScale.install(.largest)
  defer { InterfaceScale.install(.standard) }
  // 最大档首选尺寸是 1100×800；700×620 的窗口两个方向都放不下。
  let fixture = try makeOverlayWorkspace(size: NSSize(width: 700, height: 620))
  defer {
    fixture.window.close()
    UserDefaults.standard.removePersistentDomain(forName: fixture.suite)
  }
  fixture.model.isAgentHistoryPresented = true
  let overlay = try #require(
    await waitForOverlay(AgentHistoryOverlayViewController.self, in: fixture.workspace))

  let frame = overlay.view.frame
  let bounds = fixture.workspace.view.bounds
  #expect(bounds.width == 700 && bounds.height == 620)
  #expect(frame.minX >= 28 - 0.5)
  #expect(frame.maxX <= bounds.width - 28 + 0.5)
  // 根视图不翻转：minY 是底边，必须留出边距；顶边仍在原来的 64pt 处。
  #expect(frame.minY >= 28 - 0.5)
  #expect(abs((bounds.height - frame.maxY) - 64) < 0.5)
  #expect(frame.height < 800)
}

@Test("窗口够大时，Agent 历史浮层保持首选尺寸；默认档与改动前一致")
@MainActor
func agentHistoryOverlayKeepsPreferredSizeInLargeWindow() async throws {
  let fixture = try makeOverlayWorkspace(size: NSSize(width: 1_400, height: 1_000))
  defer {
    fixture.window.close()
    UserDefaults.standard.removePersistentDomain(forName: fixture.suite)
  }
  fixture.model.isAgentHistoryPresented = true
  let overlay = try #require(
    await waitForOverlay(AgentHistoryOverlayViewController.self, in: fixture.workspace))
  #expect(abs(overlay.view.frame.width - 760) < 0.5)
  #expect(abs(overlay.view.frame.height - 560) < 0.5)
  fixture.model.isAgentHistoryPresented = false

  // 首选宽度降成低优先级后，内容较少的浮层也不能缩窄。
  fixture.model.isGlobalFindPresented = true
  let find = try #require(
    await waitForOverlay(GlobalFindOverlayViewController.self, in: fixture.workspace))
  #expect(abs(find.view.frame.width - 680) < 0.5)
  fixture.model.isGlobalFindPresented = false

  fixture.model.isPalettePresented = true
  let palette = try #require(
    await waitForOverlay(PaletteOverlayViewController.self, in: fixture.workspace))
  #expect(abs(palette.view.frame.width - 560) < 0.5)
}

@Test("最大字号档下，窄窗口里的全局查找与命令面板不超出窗口两侧")
@MainActor
func searchOverlaysStayInsideNarrowWindow() async throws {
  InterfaceScale.install(.largest)
  defer { InterfaceScale.install(.standard) }
  let fixture = try makeOverlayWorkspace(size: NSSize(width: 700, height: 620))
  defer {
    fixture.window.close()
    UserDefaults.standard.removePersistentDomain(forName: fixture.suite)
  }
  let bounds = fixture.workspace.view.bounds

  fixture.model.isGlobalFindPresented = true
  let find = try #require(
    await waitForOverlay(GlobalFindOverlayViewController.self, in: fixture.workspace))
  #expect(find.view.frame.minX >= 28 - 0.5)
  #expect(find.view.frame.maxX <= bounds.width - 28 + 0.5)
  #expect(find.view.frame.minY >= 28 - 0.5)
  fixture.model.isGlobalFindPresented = false

  fixture.model.isPalettePresented = true
  let palette = try #require(
    await waitForOverlay(PaletteOverlayViewController.self, in: fixture.workspace))
  #expect(palette.view.frame.minX >= 28 - 0.5)
  #expect(palette.view.frame.maxX <= bounds.width - 28 + 0.5)
  #expect(palette.view.frame.minY >= 28 - 0.5)
}
