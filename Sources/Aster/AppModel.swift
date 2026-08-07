import AppKit
import AsterCore
import Combine
import Foundation

/// 一个分屏叶节点的运行态。持久化层只保存 `PaneDescriptor`，这里持有不可序列化的
/// PTY 与编辑缓冲区，防止会话恢复误用旧 PID 或文件描述符。
@MainActor
final class WorkspacePaneRuntime: ObservableObject, Identifiable {
  let id: UUID
  let descriptor: PaneDescriptor
  let terminalSession: TerminalSession?
  @Published var documentText = ""
  @Published private(set) var documentError: String?
  @Published private(set) var isDirty = false
  private var documentBuffer: DocumentBuffer?

  init(descriptor: PaneDescriptor) {
    id = descriptor.id
    self.descriptor = descriptor
    if descriptor.kind == .terminal {
      terminalSession = TerminalSession(workingDirectory: descriptor.workingDirectory)
    } else {
      terminalSession = nil
    }

    if descriptor.kind == .editor, let path = descriptor.resourcePath {
      do {
        let buffer = try DocumentBuffer.load(from: URL(fileURLWithPath: path))
        documentBuffer = buffer
        documentText = buffer.text
      } catch {
        documentError = error.localizedDescription
      }
    }
  }

  func updateDocument(_ text: String) {
    documentText = text
    documentBuffer?.updateText(text)
    isDirty = documentBuffer?.isDirty ?? !text.isEmpty
  }

  func saveDocument() {
    guard var buffer = documentBuffer else { return }
    buffer.updateText(documentText)
    do {
      try buffer.save()
      documentBuffer = buffer
      isDirty = false
      documentError = nil
    } catch {
      documentError = error.localizedDescription
    }
  }

  /// 在丢弃编辑器运行态前完成可取消的保存事务。
  func confirmCloseIfNeeded() -> Bool {
    guard isDirty else { return true }
    let name = URL(fileURLWithPath: descriptor.resourcePath ?? "未命名文件").lastPathComponent
    let alert = NSAlert()
    alert.messageText = "要保存对“\(name)”的更改吗？"
    alert.informativeText = "如果不保存，关闭后将无法恢复这些更改。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "不保存")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      saveDocument()
      return !isDirty
    case .alertThirdButtonReturn:
      return true
    default:
      return false
    }
  }

  func stop(immediately: Bool = false) {
    terminalSession?.stop(immediately: immediately)
  }
}

/// 一个标签页的递归分屏树及其运行态资源。
@MainActor
final class TerminalTabItem: ObservableObject, Identifiable {
  let id: UUID
  let createdAt: Date
  private(set) var updatedAt: Date
  @Published var title: String {
    didSet {
      guard title != oldValue else { return }
      markUpdated()
      onWorkspaceChanged?()
    }
  }
  private var titleState: TerminalTitleState
  @Published var layout: PaneLayout {
    didSet {
      markUpdated()
      onWorkspaceChanged?()
    }
  }
  /// 当前聚焦的面板。刻意不是 `@Published`：切换焦点只需要移动 first responder 和
  /// 焦点指示器，若走 `objectWillChange` 会让整个工作区视图树重建，正在进行的终端
  /// 拖选、TUI 重绘都会被打断。视图层订阅 `activePaneChanged` 做局部更新。
  private(set) var activePaneID: UUID
  let activePaneChanged = PassthroughSubject<UUID, Never>()
  let windowTitleChanged = PassthroughSubject<String, Never>()
  /// 目录变化由 Tab 专用回调上送给窗口级 frecency 数据库，不经 `objectWillChange`，
  /// 避免单次 `cd` 同时触发无关界面刷新。
  var onWorkingDirectoryChanged: ((String) -> Void)?
  /// 被临时放大（缩放拆分）的面板。它是纯 UI 态，不进快照——恢复会话时应当回到
  /// 完整分屏，而不是停在某次临时放大的状态。
  @Published private(set) var zoomedPaneID: UUID?
  var onWorkspaceChanged: (() -> Void)?
  private(set) var runtimes: [UUID: WorkspacePaneRuntime] = [:]
  /// 每个 Pane 保留自己的程序标题；只有活动 Pane 的状态投影到标签和窗口。
  private var paneTitleStates: [UUID: TerminalTitleState] = [:]
  private var cancellables: Set<AnyCancellable> = []

  /// 任一分屏的终端有前台命令在运行即视为「标签在运行任务」，驱动侧栏 spinner。
  var hasRunningCommand: Bool {
    runtimes.values.contains { $0.terminalSession?.hasRunningCommand == true }
  }

  /// 活动 Pane 最近一条完整命令的退出状态；侧栏只在命令停止后显示该值。
  var lastCommandExitStatus: Int? {
    runtimes[activePaneID]?.terminalSession?.lastCommandExitStatus
  }

  /// 目录的稳定显示名：主目录显示 `~`，其余取末级目录名。选中与未选中状态都用
  /// 它作为标签主文案，切换标签时名字不再变化。
  static func displayName(forDirectory path: String) -> String {
    if path == NSHomeDirectory() { return "~" }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? "~" : name
  }

  init(
    id: UUID = UUID(),
    title: String,
    workingDirectory: String,
    layout: PaneLayout? = nil,
    titleState: TerminalTitleState? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    let initialTitleState = (titleState ?? TerminalTitleState(fallback: title)).normalized()
    self.titleState = initialTitleState
    self.title = initialTitleState.tabTitle
    let initial =
      layout
      ?? .leaf(
        PaneDescriptor(kind: .terminal, workingDirectory: workingDirectory)
      )
    self.layout = initial
    activePaneID = initial.firstPaneID ?? UUID()
    paneTitleStates[activePaneID] = initialTitleState
    rebuildRuntimes(for: initial)
  }

  convenience init(snapshot: WorkspaceTabSnapshot) {
    let directory =
      snapshot.layout.allPanes.first?.workingDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    self.init(
      id: snapshot.id,
      title: snapshot.title,
      workingDirectory: directory,
      layout: snapshot.layout,
      titleState: snapshot.titleState,
      createdAt: snapshot.createdAt ?? Date(),
      updatedAt: snapshot.updatedAt
    )
  }

  var activeRuntime: WorkspacePaneRuntime? { runtimes[activePaneID] }
  var activeSession: TerminalSession? { activeRuntime?.terminalSession }
  var windowTitle: String { titleState.windowTitle }
  var tabTitleOverride: TerminalTitleOverride { titleState.tabOverride }
  var workingDirectory: String {
    activeSession?.resolvedCurrentWorkingDirectory()
      ?? runtimes[activePaneID]?.descriptor.workingDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  func runtime(for paneID: UUID) -> WorkspacePaneRuntime? { runtimes[paneID] }

  /// 接收终端解析后的 OSC 0/1/2 更新。固定名称保持不变；前缀模式继续跟随程序标题。
  func applyProgramTitle(code: Int, text: String) {
    applyProgramTitle(paneID: activePaneID, code: code, text: text)
  }

  func applyProgramTitle(paneID: UUID, code: Int, text: String) {
    guard runtimes[paneID] != nil else { return }
    var paneState = paneTitleStates[paneID] ?? TerminalTitleState(
      tabOverride: titleState.tabOverride,
      windowOverride: titleState.windowOverride,
      fallback: fallbackTitle(for: paneID)
    )
    paneState.tabOverride = titleState.tabOverride
    paneState.windowOverride = titleState.windowOverride
    let previousState = paneState
    paneState.applyOSC(code: code, text: text)
    guard paneState != previousState else { return }
    paneTitleStates[paneID] = paneState
    guard paneID == activePaneID else { return }
    applyActiveTitleState(paneState)
  }

  /// 固定名称、动态前缀和自动模式的统一入口；空固定名按领域规则回退为自动标题。
  func setTabTitleOverride(_ override: TerminalTitleOverride) {
    let normalized = override.normalized()
    guard titleState.tabOverride != normalized else { return }
    titleState.tabOverride = normalized
    for paneID in paneTitleStates.keys {
      paneTitleStates[paneID]?.tabOverride = normalized
    }
    applyActiveTitleState(titleState)
  }

  func updateTitleFallback(_ fallback: String) {
    updateTitleFallback(fallback, paneID: activePaneID)
  }

  private func updateTitleFallback(_ fallback: String, paneID: UUID) {
    var state = paneTitleStates[paneID] ?? TerminalTitleState(
      tabOverride: titleState.tabOverride,
      windowOverride: titleState.windowOverride,
      fallback: fallback
    )
    state.updateFallback(fallback)
    paneTitleStates[paneID] = state
    guard paneID == activePaneID else { return }
    applyActiveTitleState(state)
  }

  func split(
    direction: SplitDirection,
    kind: PaneKind = .terminal,
    resourcePath: String? = nil
  ) {
    let directory = activeSession?.resolvedCurrentWorkingDirectory() ?? workingDirectory
    let descriptor = PaneDescriptor(
      kind: kind,
      workingDirectory: directory,
      resourcePath: resourcePath
    )
    guard
      let updated = layout.splitting(
        paneID: activePaneID,
        direction: direction,
        with: descriptor
      )
    else { return }
    layout = updated
    addRuntime(for: descriptor)
    activePaneID = descriptor.id
    if let state = paneTitleStates[descriptor.id] { applyActiveTitleState(state) }
    // 新面板必须可见：在放大态下继续拆分，否则新建的 Shell 会藏在被折叠的分屏里。
    zoomedPaneID = nil
  }

  /// 切换焦点面板。`paneID` 不存在或未变化时保持原状，避免无谓的 first responder 抖动。
  func setActivePane(_ paneID: UUID) {
    guard paneID != activePaneID, runtimes[paneID] != nil else { return }
    activePaneID = paneID
    var state = paneTitleStates[paneID] ?? TerminalTitleState(
      tabOverride: titleState.tabOverride,
      windowOverride: titleState.windowOverride,
      fallback: fallbackTitle(for: paneID)
    )
    state.tabOverride = titleState.tabOverride
    state.windowOverride = titleState.windowOverride
    paneTitleStates[paneID] = state
    applyActiveTitleState(state)
    markUpdated()
    // 放大态下其它面板不可见，把焦点移出去会让 first responder 落在看不见的终端上。
    if zoomedPaneID != nil, zoomedPaneID != paneID { zoomedPaneID = nil }
    activePaneChanged.send(paneID)
  }

  /// 按方向聚焦相邻面板（对应「聚焦面板」子菜单）。返回是否真的移动了焦点。
  @discardableResult
  func focusPane(_ direction: SplitDirection) -> Bool {
    guard let target = layout.adjacentPaneID(from: activePaneID, direction: direction) else {
      return false
    }
    setActivePane(target)
    return true
  }

  /// 在分屏树的中序遍历顺序上循环切换焦点（下一个/上一个面板）。
  @discardableResult
  func focusPane(forward: Bool) -> Bool {
    let ids = layout.allPanes.map(\.id)
    guard ids.count > 1, let index = ids.firstIndex(of: activePaneID) else { return false }
    let offset = forward ? 1 : ids.count - 1
    setActivePane(ids[(index + offset) % ids.count])
    return true
  }

  /// 把当前面板临时放大到整个工作区，再次调用还原分屏（对应「缩放拆分」）。
  func toggleZoom() {
    guard layout.allPanes.count > 1 else {
      zoomedPaneID = nil
      return
    }
    zoomedPaneID = zoomedPaneID == nil ? activePaneID : nil
  }

  /// 沿指定方向移动当前面板所在的分隔条。方向语义与分隔条本身一致（右移即让
  /// 左侧变宽），与聚焦面板处在哪一侧无关；没有该方向的分隔条时返回 false。
  @discardableResult
  func moveDivider(_ direction: SplitDirection, step: Double = 0.05) -> Bool {
    let axis: SplitAxis = direction.isHorizontal ? .horizontal : .vertical
    guard let path = layout.nearestSplitPath(fromPane: activePaneID, axis: axis),
      let current = layout.splitRatio(at: path)
    else { return false }
    let delta = (direction == .right || direction == .down) ? step : -step
    let updated = layout.updatingSplitRatio(at: path, ratio: current + delta)
    guard updated != layout else { return false }
    layout = updated
    return true
  }

  /// 拖放到面板中心：交换两个面板的位置。面板 ID 不变，两端的 PTY 都不重启。
  @discardableResult
  func swapPanes(_ first: UUID, _ second: UUID) -> Bool {
    let updated = layout.swappingPanes(first, second)
    guard updated != layout else { return false }
    layout = updated
    zoomedPaneID = nil
    return true
  }

  /// 拖放到面板边缘：把面板搬到目标面板的指定一侧，并让它继续保持聚焦。
  @discardableResult
  func movePane(_ paneID: UUID, nextTo targetID: UUID, direction: SplitDirection) -> Bool {
    guard let updated = layout.movingPane(paneID, nextTo: targetID, direction: direction),
      updated != layout
    else { return false }
    layout = updated
    zoomedPaneID = nil
    activePaneID = paneID
    if let state = paneTitleStates[paneID] { applyActiveTitleState(state) }
    return true
  }

  /// 把所有层级的分屏恢复为等分（对应「等分拆分」）。
  @discardableResult
  func equalizeSplits() -> Bool {
    let updated = layout.equalizingRatios()
    guard updated != layout else { return false }
    layout = updated
    return true
  }

  func openFile(_ url: URL) {
    split(direction: .right, kind: .editor, resourcePath: url.path)
  }

  func openPreview(_ url: URL) {
    split(direction: .right, kind: .preview, resourcePath: url.path)
  }

  func openFileBrowser() {
    split(direction: .left, kind: .fileBrowser)
  }

  /// 持久化用户拖动后的分隔位置。`PaneLayout` 会校验路径并限制极端比例，避免
  /// 恢复时产生不可操作的零尺寸 Pane。
  func updateSplitRatio(at path: [Int], ratio: Double) {
    let updated = layout.updatingSplitRatio(at: path, ratio: ratio)
    guard updated != layout else { return }
    layout = updated
  }

  /// 关闭当前聚焦的面板。返回 false 表示没有可关闭的分屏（只剩最后一个面板），
  /// 由调用方决定是否升级成关闭整个标签页；用户取消保存提示同样返回 false。
  @discardableResult
  func closeActivePane() -> Bool {
    guard layout.allPanes.count > 1 else { return false }
    guard runtimes[activePaneID]?.confirmCloseIfNeeded() != false else { return false }
    guard let updated = layout.removing(paneID: activePaneID) else { return false }
    // 焦点先于删除计算：删除后原 Pane 的兄弟关系已经消失，无法再定位相邻面板。
    let successor = layout.neighborPaneID(ofPane: activePaneID) ?? updated.firstPaneID
    let removedPaneID = activePaneID
    runtimes.removeValue(forKey: removedPaneID)?.stop()
    paneTitleStates.removeValue(forKey: removedPaneID)
    if zoomedPaneID == activePaneID { zoomedPaneID = nil }
    layout = updated
    activePaneID = successor ?? activePaneID
    if let state = paneTitleStates[activePaneID] { applyActiveTitleState(state) }
    return true
  }

  func stop(immediately: Bool = false) {
    for runtime in runtimes.values {
      runtime.stop(immediately: immediately)
    }
  }

  func confirmCloseDocuments() -> Bool {
    for runtime in runtimes.values where !runtime.confirmCloseIfNeeded() {
      return false
    }
    return true
  }

  var snapshot: WorkspaceTabSnapshot {
    WorkspaceTabSnapshot(
      id: id,
      title: title,
      layout: layout,
      titleState: titleState,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  func markUpdated() { updatedAt = Date() }

  private func rebuildRuntimes(for layout: PaneLayout) {
    for pane in layout.allPanes {
      addRuntime(for: pane)
    }
  }

  private func addRuntime(for descriptor: PaneDescriptor) {
    guard runtimes[descriptor.id] == nil else { return }
    let runtime = WorkspacePaneRuntime(descriptor: descriptor)
    runtimes[descriptor.id] = runtime
    if paneTitleStates[descriptor.id] == nil {
      paneTitleStates[descriptor.id] = TerminalTitleState(
        tabOverride: titleState.tabOverride,
        windowOverride: titleState.windowOverride,
        fallback: Self.displayName(forDirectory: descriptor.workingDirectory)
      )
    }
    // 侧栏和状态栏观察的是 Tab，而终端运行状态属于子 Session。只定向转发 UI 真正
    // 消费的字段（运行态、spinner、退出码、启动错误）；不要转发 objectWillChange
    // 全量事件——OSC 标题在命令运行期间高频变化，全量转发会让侧栏整树重建、
    // spinner 每帧重启（可见闪烁）。目录变化由下方专用 sink 经 layout/title 触发刷新。
    if let session = runtime.terminalSession {
      session.onTitleUpdate = { [weak self] code, text in
        self?.applyProgramTitle(paneID: descriptor.id, code: code, text: text)
      }
      Publishers.MergeMany(
        session.$isRunning.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$hasRunningCommand.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$exitCode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$startupError.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$lastCommandExitStatus.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
      )
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    }
    runtime.terminalSession?.$currentWorkingDirectory
      .removeDuplicates()
      // `@Published` 订阅会立即发送 Session 构造时的初始目录；新建同目录分屏并不代表
      // 用户访问了一次目录，必须跳过。后续真实 OSC 7 变化仍由 removeDuplicates 去重。
      .dropFirst()
      .sink { [weak self] directory in
        guard let self else { return }
        self.layout = self.layout.updatingPane(paneID: descriptor.id) { pane in
          var updated = pane
          updated.workingDirectory = directory
          return updated
        }
        // 即使程序标题或固定名称当前遮住目录回退，也要同步每个 Pane 的 fallback；
        // 用户稍后恢复自动模式或会话重启时才能显示最新目录，而不是旧快照值。
        let folder = Self.displayName(forDirectory: directory)
        self.updateTitleFallback(folder, paneID: descriptor.id)
        self.onWorkingDirectoryChanged?(directory)
      }
      .store(in: &cancellables)
  }

  private func fallbackTitle(for paneID: UUID) -> String {
    guard let directory = runtimes[paneID]?.descriptor.workingDirectory else { return "Shell" }
    return Self.displayName(forDirectory: directory)
  }

  private func applyActiveTitleState(_ state: TerminalTitleState) {
    let previousWindowTitle = titleState.windowTitle
    titleState = state
    let resolved = state.tabTitle
    if title != resolved {
      title = resolved
    } else {
      markUpdated()
      onWorkspaceChanged?()
    }
    if previousWindowTitle != state.windowTitle {
      windowTitleChanged.send(state.windowTitle)
    }
  }
}

/// 窗口级工作区状态，集中处理标签、分屏、Recipes、详情栏与会话恢复。
@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var tabs: [TerminalTabItem] = []
  @Published var selectedTabID: UUID?
  @Published var isPalettePresented = false
  @Published var isInspectorPresented = false
  @Published var isFindPresented = false
  @Published var notice: String?
  @Published private(set) var dividerAfterTabIDs: Set<UUID> = []
  var newTabPosition = NewTabPosition.automatic
  var frecencyAutoRecord = true
  var onTabOrderBecameManual: (() -> Void)?
  private let defaults: UserDefaults
  private let snapshotKey = "aster.workspace.snapshot.v1"
  private let recentlyClosedKey = "aster.workspace.recently-closed.v1"
  private let frequentFoldersKey = "aster.frequent-folders.v1"
  private var recentlyClosedTabs: RecentlyClosedTabs
  private var frequentFolders: FrequentFolders

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: recentlyClosedKey),
      let decoded = try? JSONDecoder().decode(RecentlyClosedTabs.self, from: data)
    {
      recentlyClosedTabs = decoded
    } else {
      recentlyClosedTabs = RecentlyClosedTabs()
    }
    if let data = defaults.data(forKey: frequentFoldersKey),
      let decoded = try? FrequentFolderStore.decode(data)
    {
      frequentFolders = decoded
    } else {
      frequentFolders = FrequentFolders()
    }
  }

  func ensureInitialTab() {
    guard tabs.isEmpty else { return }
    if let data = defaults.data(forKey: snapshotKey),
      let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
      !snapshot.tabs.isEmpty
    {
      tabs = snapshot.tabs.map(TerminalTabItem.init(snapshot:))
      dividerAfterTabIDs = Set(snapshot.dividerAfterTabIDs ?? [])
      let previousHistory = recentlyClosedTabs
      recentlyClosedTabs.removeEntries(withIDs: Set(tabs.map(\.id)))
      if recentlyClosedTabs != previousHistory { persistRecentlyClosedTabs() }
      for tab in tabs { configurePersistence(for: tab) }
      selectedTabID =
        tabs.contains(where: { $0.id == snapshot.selectedTabID })
        ? snapshot.selectedTabID : tabs.first?.id
    } else {
      newTab()
    }
  }

  var selectedTab: TerminalTabItem? {
    tabs.first(where: { $0.id == selectedTabID })
  }

  /// 返回 Open Quickly / CLI 共用的 frecency 排名，不暴露可变数据库。
  func frequentFolderMatches(
    query: String = "", limit: Int? = nil, excluding excludedPath: String? = nil
  ) -> [FrequentFolderMatch] {
    frequentFolders.ranked(matching: query, limit: limit, excluding: excludedPath)
  }

  /// 显式学习目录。与自动 OSC 7 记录不同，该入口由调用者触发，忽略自动记录开关。
  @discardableResult
  func learnFolder(_ directory: String) -> Bool {
    guard isExistingDirectory(directory), frequentFolders.record(directory) else { return false }
    persistFrequentFolders()
    return true
  }

  @discardableResult
  func ignoreFolder(_ directory: String) -> Bool {
    guard frequentFolders.ignore(directory) else { return false }
    persistFrequentFolders()
    return true
  }

  @discardableResult
  func unignoreFolder(_ directory: String) -> Bool {
    guard frequentFolders.unignore(directory) else { return false }
    persistFrequentFolders()
    return true
  }

  func newTab(
    workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    position: NewTabPosition? = nil,
    hasContent: Bool = false
  ) {
    let tab = TerminalTabItem(
      title: TerminalTabItem.displayName(forDirectory: workingDirectory),
      workingDirectory: workingDirectory
    )
    insertTab(tab, position: position, hasContent: hasContent)
  }

  private func insertTab(
    _ tab: TerminalTabItem,
    position: NewTabPosition? = nil,
    hasContent: Bool
  ) {
    let selectedIndex = tabs.firstIndex { $0.id == selectedTabID }
    let sectionEndIndex = selectedIndex.flatMap { currentIndex in
      (currentIndex..<tabs.count).first { dividerAfterTabIDs.contains(tabs[$0].id) }.map { $0 + 1 }
    }
    let resolvedPosition = position ?? newTabPosition
    let insertionIndex = resolvedPosition.insertionIndex(
      selectedIndex: selectedIndex,
      tabCount: tabs.count,
      hasContent: hasContent,
      sectionEndIndex: sectionEndIndex
    )
    // 分隔线存为「位于哪个标签之后」。在当前分组末尾插入时把边界转移到新标签，
    // 这样新标签视觉上仍位于分隔线之前，而不是掉进下一个手动分组。
    if resolvedPosition != .end, insertionIndex > 0, insertionIndex <= tabs.count {
      let previousTabID = tabs[insertionIndex - 1].id
      if dividerAfterTabIDs.remove(previousTabID) != nil {
        dividerAfterTabIDs.insert(tab.id)
      }
    }
    tabs.insert(tab, at: insertionIndex)
    // 时间排序会覆盖 `new-tab-position` 的物理顺序（尤其 `.end` 会被最新时间推到
    // 顶部）。任何按位置创建的标签都切换到手动顺序，用户之后仍可显式选回时间排序。
    onTabOrderBecameManual?()
    configurePersistence(for: tab)
    selectedTabID = tab.id
    persistWorkspace()
  }

  /// ⌘W 的上下文语义：标签内还有分屏时只关闭当前聚焦的面板，只剩最后一个面板时
  /// 才关闭整个标签页。与 Otty/iTerm 一致——多分屏工作区里误关整个标签代价太大。
  func closeSelectedPaneOrTab() {
    guard let tab = selectedTab else { return }
    if tab.closeActivePane() {
      persistWorkspace()
      return
    }
    closeSelectedTab()
  }

  func closeSelectedTab() {
    guard let selectedTabID,
      let index = tabs.firstIndex(where: { $0.id == selectedTabID })
    else { return }
    guard tabs[index].confirmCloseDocuments() else { return }
    recentlyClosedTabs.record(tabs[index].snapshot)
    persistRecentlyClosedTabs()
    tabs[index].stop()
    dividerAfterTabIDs.remove(tabs[index].id)
    tabs.remove(at: index)
    if tabs.isEmpty {
      newTab()
    } else {
      self.selectedTabID = tabs[min(index, tabs.count - 1)].id
      persistWorkspace()
    }
  }

  /// 恢复最近关闭的标签。历史只保存可重建快照，因此会创建新的运行态 Shell，
  /// 不会尝试重新使用已终止的 PID 或 PTY 文件描述符。
  @discardableResult
  func reopenLastClosedTab() -> Bool {
    guard let snapshot = recentlyClosedTabs.reopenLast() else { return false }
    let tab = TerminalTabItem(snapshot: snapshot)
    tabs.append(tab)
    configurePersistence(for: tab)
    selectedTabID = tab.id
    persistRecentlyClosedTabs()
    persistWorkspace()
    return true
  }

  func select(_ tab: TerminalTabItem) {
    tab.markUpdated()
    selectedTabID = tab.id
    persistWorkspace()
  }

  func splitSelectedTab(_ direction: SplitDirection = .right) {
    selectedTab?.split(direction: direction)
    persistWorkspace()
  }

  func closeActivePane() {
    guard selectedTab?.closeActivePane() == true else { return }
    persistWorkspace()
  }

  /// 「聚焦面板」子菜单入口。焦点没有可去处时保持原状，不发出任何变更。
  func focusPane(_ direction: SplitDirection) {
    selectedTab?.focusPane(direction)
  }

  func focusPane(forward: Bool) {
    selectedTab?.focusPane(forward: forward)
  }

  func toggleZoomActivePane() {
    selectedTab?.toggleZoom()
  }

  /// 「调整拆分大小」子菜单入口；比例变化要落进快照，因此成功后立即持久化。
  func moveDivider(_ direction: SplitDirection) {
    guard selectedTab?.moveDivider(direction) == true else { return }
    persistWorkspace()
  }

  func equalizeSplits() {
    guard selectedTab?.equalizeSplits() == true else { return }
    persistWorkspace()
  }

  /// 面板拖放的统一入口；布局变化要落进快照，因此成功后立即持久化。
  func swapPanes(_ first: UUID, _ second: UUID) {
    guard selectedTab?.swapPanes(first, second) == true else { return }
    persistWorkspace()
  }

  func movePane(_ paneID: UUID, nextTo targetID: UUID, direction: SplitDirection) {
    guard selectedTab?.movePane(paneID, nextTo: targetID, direction: direction) == true else {
      return
    }
    persistWorkspace()
  }

  /// 当前标签是否处于可分屏操作的状态，供菜单项启用状态判断。
  var selectedTabHasSplits: Bool {
    (selectedTab?.layout.allPanes.count ?? 0) > 1
  }

  func togglePalette() { isPalettePresented.toggle() }
  func toggleInspector() { isInspectorPresented.toggle() }
  func toggleFind() { isFindPresented.toggle() }

  /// 原生重命名对话框同时支持固定名称与动态前缀。第三个按钮直接恢复程序标题，
  /// 与留空固定名称的领域语义一致。
  func promptRenameSelectedTab() {
    guard let tab = selectedTab else { return }
    let mode = NSPopUpButton()
    mode.addItems(withTitles: ["固定名称", "动态前缀"])
    let field = NSTextField()
    field.placeholderString = "输入名称或前缀"
    switch tab.tabTitleOverride {
    case .automatic:
      field.stringValue = ""
    case .name(let value):
      mode.selectItem(at: 0)
      field.stringValue = value
    case .prefix(let value):
      mode.selectItem(at: 1)
      field.stringValue = value
    }
    mode.translatesAutoresizingMaskIntoConstraints = false
    field.translatesAutoresizingMaskIntoConstraints = false
    let accessory = NSStackView(views: [mode, field])
    accessory.orientation = .vertical
    accessory.spacing = 8
    accessory.translatesAutoresizingMaskIntoConstraints = false
    accessory.widthAnchor.constraint(equalToConstant: 300).isActive = true

    let alert = NSAlert()
    alert.messageText = "重命名标签页"
    alert.informativeText = "固定名称忽略程序标题更新；动态前缀会继续跟随 OSC 标题。"
    alert.accessoryView = accessory
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "恢复自动标题")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      let override: TerminalTitleOverride = mode.indexOfSelectedItem == 0
        ? .name(field.stringValue) : .prefix(field.stringValue)
      tab.setTabTitleOverride(override)
    case .alertThirdButtonReturn:
      tab.setTabTitleOverride(.automatic)
    default:
      return
    }
    persistWorkspace()
  }

  /// 在当前标签之后插入一个视觉分隔线。重复调用保持幂等，避免菜单误操作堆叠线条。
  func insertDividerAfterSelectedTab() {
    guard let selectedTabID else { return }
    dividerAfterTabIDs.insert(selectedTabID)
    persistWorkspace()
  }

  func removeAllTabDividers() {
    guard !dividerAfterTabIDs.isEmpty else { return }
    dividerAfterTabIDs.removeAll()
    persistWorkspace()
  }

  func saveActiveDocument() {
    selectedTab?.activeRuntime?.saveDocument()
  }

  func openFile() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    selectedTab?.openFile(url)
    persistWorkspace()
  }

  func openFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    selectedTab?.split(direction: .left, kind: .fileBrowser, resourcePath: url.path)
    persistWorkspace()
  }

  func saveRecipe() {
    guard let tab = selectedTab else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(tab.title).asterrecipe"
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension.lowercased() != "asterrecipe" {
      url.appendPathExtension("asterrecipe")
    }
    let recipe = WorkspaceRecipe(
      name: tab.title,
      tabs: [RecipeTab(title: tab.title, layout: tab.layout)],
      replayMode: .confirmOnce
    )
    do {
      try RecipeStore.save(recipe, to: url)
      notice = "Recipe 已保存"
    } catch {
      notice = "Recipe 保存失败：\(error.localizedDescription)"
    }
  }

  func openRecipe() {
    let panel = NSOpenPanel()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openRecipe(from: url)
  }

  /// 统一的外部打开入口：ssh 链接、目录（CLI / Finder 服务）与 .asterrecipe。
  func handleOpenURL(_ url: URL) {
    if url.scheme?.lowercased() == "ssh" {
      openSSHURL(url)
      return
    }
    guard url.isFileURL else {
      notice = "Aster 暂不支持该链接。"
      return
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      // `newTab` 的默认参数用于空标签；目录属于带内容入口，应紧跟当前标签。
      newTab(workingDirectory: url.path, hasContent: true)
      return
    }
    guard url.pathExtension.lowercased() == "asterrecipe" else {
      notice = "Aster 暂不支持打开该类型文件。"
      return
    }
    openRecipe(from: url)
  }

  /// ssh:// 链接可写入 PTY 的保守字符集。控制字符（尤其换行）会把「预填不执行」
  /// 变成自动执行注入命令，因此 host 只允许主机名/IP（含 IPv6 冒号），user 更严格。
  private static func isSafeSSHComponent(_ value: String, allowColon: Bool) -> Bool {
    let pattern = allowColon ? "^[A-Za-z0-9._:-]+$" : "^[A-Za-z0-9._-]+$"
    return value.range(of: pattern, options: .regularExpression) != nil
  }

  /// ssh:// 链接：新建标签并把 ssh 命令预填到提示符（不自动回车）。链接可能来自
  /// 网页等外部来源，是否执行必须由用户确认，与「不执行外部命令」的安全边界一致。
  private func openSSHURL(_ url: URL) {
    guard let host = url.host, !host.isEmpty, Self.isSafeSSHComponent(host, allowColon: true) else {
      notice = "无效的 ssh 链接。"
      return
    }
    var command = "ssh "
    if let port = url.port { command += "-p \(port) " }
    if let user = url.user, !user.isEmpty {
      guard Self.isSafeSSHComponent(user, allowColon: false) else {
        notice = "无效的 ssh 链接。"
        return
      }
      command += "\(user)@"
    }
    command += host
    newTab(hasContent: true)
    let tab = selectedTab
    // PTY 在标签视图挂载后才启动，延迟片刻再写入提示符。
    Task { @MainActor [weak tab] in
      try? await Task.sleep(for: .milliseconds(800))
      tab?.activeSession?.typeText(command)
    }
  }

  private func openRecipe(from url: URL) {
    do {
      let recipe = try RecipeStore.load(from: url)
      for recipeTab in recipe.tabs {
        let directory =
          recipeTab.layout.allPanes.first?.workingDirectory
          ?? FileManager.default.homeDirectoryForCurrentUser.path
        let tab = TerminalTabItem(
          title: recipeTab.title,
          workingDirectory: directory,
          layout: recipeTab.layout
        )
        insertTab(tab, hasContent: true)
      }
      persistWorkspace()
      notice = "已打开 \(recipe.name)"
    } catch {
      notice = "Recipe 打开失败：\(error.localizedDescription)"
    }
  }

  var paletteCommands: [PaletteCommand] {
    [
      .init(id: "new-tab", title: "新建标签页", keywords: ["new", "tab"]),
      .init(id: "reopen-tab", title: "重新打开最近关闭的标签页", keywords: ["reopen", "closed", "tab"]),
      .init(id: "rename-tab", title: "重命名标签页", keywords: ["rename", "prefix", "title"]),
      .init(id: "open-file", title: "打开文件", keywords: ["edit", "file"]),
      .init(id: "open-folder", title: "打开文件夹", keywords: ["browser", "folder"]),
      .init(id: "split-right", title: "向右拆分", keywords: ["pane", "split"]),
      .init(id: "split-left", title: "向左拆分", keywords: ["pane", "split"]),
      .init(id: "split-down", title: "向下拆分", keywords: ["pane", "split"]),
      .init(id: "split-up", title: "向上拆分", keywords: ["pane", "split"]),
      .init(id: "zoom-pane", title: "缩放拆分", keywords: ["zoom", "pane", "maximize"]),
      .init(id: "equalize-splits", title: "等分拆分", keywords: ["pane", "split", "equal"]),
      .init(id: "focus-next-pane", title: "聚焦下一个面板", keywords: ["pane", "focus"]),
      .init(id: "files", title: "新建文件浏览器", keywords: ["tree", "files"]),
      .init(id: "inspector", title: "切换详情面板", keywords: ["git", "info", "outline"]),
      .init(id: "save-recipe", title: "保存为 Recipe", keywords: ["workspace"]),
      .init(id: "open-recipe", title: "打开 Recipe", keywords: ["workspace"]),
      .init(id: "interrupt", title: "中断当前命令", keywords: ["control c", "stop"]),
      .init(id: "close-pane", title: "关闭当前面板", keywords: ["pane", "close"]),
    ]
  }

  func performPaletteCommand(_ command: PaletteCommand) {
    switch command.id {
    case "new-tab": newTab()
    case "reopen-tab": _ = reopenLastClosedTab()
    case "rename-tab": promptRenameSelectedTab()
    case "open-file": openFile()
    case "open-folder": openFolder()
    case "split-right": splitSelectedTab(.right)
    case "split-left": splitSelectedTab(.left)
    case "split-down": splitSelectedTab(.down)
    case "split-up": splitSelectedTab(.up)
    case "zoom-pane": toggleZoomActivePane()
    case "equalize-splits": equalizeSplits()
    case "focus-next-pane": focusPane(forward: true)
    case "files":
      selectedTab?.openFileBrowser()
      persistWorkspace()
    case "inspector": toggleInspector()
    case "save-recipe": saveRecipe()
    case "open-recipe": openRecipe()
    case "interrupt": selectedTab?.activeSession?.interrupt()
    case "close-pane": closeActivePane()
    default: break
    }
    isPalettePresented = false
  }

  func persistWorkspace() {
    guard let selectedTabID, !tabs.isEmpty else { return }
    let snapshot = WorkspaceSnapshot(
      selectedTabID: selectedTabID,
      tabs: tabs.map(\.snapshot),
      dividerAfterTabIDs: Array(dividerAfterTabIDs)
    )
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: snapshotKey)
  }

  private func configurePersistence(for tab: TerminalTabItem) {
    tab.onWorkspaceChanged = { [weak self] in self?.persistWorkspace() }
    tab.onWorkingDirectoryChanged = { [weak self] directory in
      self?.recordVisitedFolderIfEnabled(directory)
    }
  }

  private func persistRecentlyClosedTabs() {
    guard let data = try? JSONEncoder().encode(recentlyClosedTabs) else { return }
    defaults.set(data, forKey: recentlyClosedKey)
  }

  private func recordVisitedFolderIfEnabled(_ directory: String) {
    guard frecencyAutoRecord, isExistingDirectory(directory), frequentFolders.record(directory)
    else { return }
    persistFrequentFolders()
  }

  private func isExistingDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func persistFrequentFolders() {
    guard let data = try? FrequentFolderStore.encode(frequentFolders) else { return }
    defaults.set(data, forKey: frequentFoldersKey)
  }

  /// 应用退出前统一处理未保存文档并写入最后快照；取消任一提示会取消退出。
  func prepareForTermination() -> Bool {
    for tab in tabs where !tab.confirmCloseDocuments() {
      return false
    }
    persistWorkspace()
    // `terminateNow` 返回后 AppKit 不保证延迟任务继续运行，因此退出路径直接终止
    // 各 Shell 进程组；普通 Pane/标签关闭仍保留温和退出与 750ms 升级窗口。
    for tab in tabs { tab.stop(immediately: true) }
    return true
  }
}
