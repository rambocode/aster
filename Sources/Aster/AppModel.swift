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
    didSet { markUpdated() }
  }
  @Published var layout: PaneLayout {
    didSet {
      markUpdated()
      onWorkspaceChanged?()
    }
  }
  @Published var activePaneID: UUID {
    didSet {
      if oldValue != activePaneID {
        markUpdated()
        onWorkspaceChanged?()
      }
    }
  }
  var onWorkspaceChanged: (() -> Void)?
  private(set) var runtimes: [UUID: WorkspacePaneRuntime] = [:]
  private var cancellables: Set<AnyCancellable> = []

  /// 任一分屏的终端有前台命令在运行即视为「标签在运行任务」，驱动侧栏 spinner。
  var hasRunningCommand: Bool {
    runtimes.values.contains { $0.terminalSession?.hasRunningCommand == true }
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
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.title = title
    let initial =
      layout
      ?? .leaf(
        PaneDescriptor(kind: .terminal, workingDirectory: workingDirectory)
      )
    self.layout = initial
    activePaneID = initial.firstPaneID ?? UUID()
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
      createdAt: snapshot.createdAt ?? Date(),
      updatedAt: snapshot.updatedAt
    )
  }

  var activeRuntime: WorkspacePaneRuntime? { runtimes[activePaneID] }
  var activeSession: TerminalSession? { activeRuntime?.terminalSession }
  var workingDirectory: String {
    activeSession?.resolvedCurrentWorkingDirectory()
      ?? runtimes[activePaneID]?.descriptor.workingDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  func runtime(for paneID: UUID) -> WorkspacePaneRuntime? { runtimes[paneID] }

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

  func closeActivePane() {
    guard runtimes[activePaneID]?.confirmCloseIfNeeded() != false else { return }
    guard layout.allPanes.count > 1, let updated = layout.removing(paneID: activePaneID) else {
      return
    }
    runtimes.removeValue(forKey: activePaneID)?.stop()
    layout = updated
    activePaneID = updated.firstPaneID ?? activePaneID
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
    // 侧栏和状态栏观察的是 Tab，而终端运行状态属于子 Session。只定向转发 UI 真正
    // 消费的字段（运行态、spinner、退出码、启动错误）；不要转发 objectWillChange
    // 全量事件——OSC 标题在命令运行期间高频变化，全量转发会让侧栏整树重建、
    // spinner 每帧重启（可见闪烁）。目录变化由下方专用 sink 经 layout/title 触发刷新。
    if let session = runtime.terminalSession {
      Publishers.MergeMany(
        session.$isRunning.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$hasRunningCommand.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$exitCode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$startupError.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
      )
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    }
    runtime.terminalSession?.$currentWorkingDirectory
      .removeDuplicates()
      .sink { [weak self] directory in
        guard let self else { return }
        self.layout = self.layout.updatingPane(paneID: descriptor.id) { pane in
          var updated = pane
          updated.workingDirectory = directory
          return updated
        }
        if self.activePaneID == descriptor.id {
          // 只在名字真正变化时写回：title 的 didSet 会 markUpdated 并触发持久化，
          // 高频写同值会造成无意义的重建与快照写入。
          let folder = Self.displayName(forDirectory: directory)
          if self.title != folder { self.title = folder }
        }
      }
      .store(in: &cancellables)
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
  private let defaults: UserDefaults
  private let snapshotKey = "aster.workspace.snapshot.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func ensureInitialTab() {
    guard tabs.isEmpty else { return }
    if let data = defaults.data(forKey: snapshotKey),
      let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
      !snapshot.tabs.isEmpty
    {
      tabs = snapshot.tabs.map(TerminalTabItem.init(snapshot:))
      dividerAfterTabIDs = Set(snapshot.dividerAfterTabIDs ?? [])
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

  func newTab(workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
    let tab = TerminalTabItem(
      title: TerminalTabItem.displayName(forDirectory: workingDirectory),
      workingDirectory: workingDirectory
    )
    tabs.append(tab)
    configurePersistence(for: tab)
    selectedTabID = tab.id
    persistWorkspace()
  }

  func closeSelectedTab() {
    guard let selectedTabID,
      let index = tabs.firstIndex(where: { $0.id == selectedTabID })
    else { return }
    guard tabs[index].confirmCloseDocuments() else { return }
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
    selectedTab?.closeActivePane()
    persistWorkspace()
  }

  func togglePalette() { isPalettePresented.toggle() }
  func toggleInspector() { isInspectorPresented.toggle() }
  func toggleFind() { isFindPresented.toggle() }

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
      newTab(workingDirectory: url.path)
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
    newTab()
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
        tabs.append(tab)
        configurePersistence(for: tab)
        selectedTabID = tab.id
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
      .init(id: "open-file", title: "打开文件", keywords: ["edit", "file"]),
      .init(id: "open-folder", title: "打开文件夹", keywords: ["browser", "folder"]),
      .init(id: "split-right", title: "向右分屏", keywords: ["pane", "split"]),
      .init(id: "split-down", title: "向下分屏", keywords: ["pane", "split"]),
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
    case "open-file": openFile()
    case "open-folder": openFolder()
    case "split-right": splitSelectedTab(.right)
    case "split-down": splitSelectedTab(.down)
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
