import AsterCore
import Testing

@Test("主窗口 Panel 宽度使用稳定默认值并夹紧外部状态")
func workspacePanelLayoutNormalizesPersistedWidths() {
  let defaults = WorkspacePanelLayoutState.default
  #expect(defaults.sidebarWidth == 220)
  #expect(defaults.inspectorWidth == 278)

  let normalized = WorkspacePanelLayoutState(
    sidebarWidth: -100,
    inspectorWidth: 10_000
  ).normalized()
  #expect(normalized.sidebarWidth == 180)
  #expect(normalized.inspectorWidth == 480)
}

@Test("中栏吸收窗口宽度且左右 Panel 在窄窗口中只临时压缩")
func workspacePanelLayoutResolvesVisibleWidthsWithoutMutatingPreferences() {
  let state = WorkspacePanelLayoutState(sidebarWidth: 360, inspectorWidth: 480)

  let wide = WorkspacePanelLayoutPolicy.resolve(
    availableWidth: 1_400,
    visibleRoles: [.sidebar, .content, .inspector],
    state: state
  )
  #expect(wide[.sidebar] == 360)
  #expect(wide[.inspector] == 480)
  #expect(wide[.content] == 558)

  let narrow = WorkspacePanelLayoutPolicy.resolve(
    availableWidth: 820,
    visibleRoles: [.sidebar, .content, .inspector],
    state: state
  )
  #expect(narrow[.sidebar] == 258)
  #expect(narrow[.inspector] == 240)
  #expect(narrow[.content] == 320)

  // 实际布局压缩不能反向覆盖用户希望恢复的宽度。
  #expect(state == WorkspacePanelLayoutState(sidebarWidth: 360, inspectorWidth: 480))
}

@Test("缺少任一侧 Panel 时 divider 数量和中栏宽度按可见角色计算")
func workspacePanelLayoutHandlesOptionalSidePanels() {
  let state = WorkspacePanelLayoutState.default

  let contentOnly = WorkspacePanelLayoutPolicy.resolve(
    availableWidth: 900,
    visibleRoles: [.content],
    state: state
  )
  #expect(contentOnly == [.content: 900])

  let contentAndInspector = WorkspacePanelLayoutPolicy.resolve(
    availableWidth: 900,
    visibleRoles: [.content, .inspector],
    state: state
  )
  #expect(contentAndInspector[.inspector] == 278)
  #expect(contentAndInspector[.content] == 621)
}

@Test("Panel 角色明确区分窗口区域与中栏内部 Pane")
func workspacePanelRolesKeepStableSemanticOrder() {
  #expect(WorkspacePanelRole.allCases == [.sidebar, .content, .inspector])
  #expect(WorkspacePanelLayoutPolicy.defaultWidth(for: .sidebar) == 220)
  #expect(WorkspacePanelLayoutPolicy.defaultWidth(for: .content) == nil)
  #expect(WorkspacePanelLayoutPolicy.defaultWidth(for: .inspector) == 278)
}
