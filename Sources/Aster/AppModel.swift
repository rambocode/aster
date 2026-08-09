import AppKit
import AsterCore
import Combine
import Foundation

/// 外部 Recipe 的确认界面必须展示完整命令集合。格式化独立于 AppKit，便于用代码
/// 测试证明超过 20 条时不会隐藏后续命令。
enum WorkflowRecipeCommandReview {
  static func text(commands: [String]) -> String {
    let numbered = commands.enumerated().map { index, command in
      "\(index + 1). \(command)"
    }
    return (["共 \(commands.count) 条命令："] + numbered).joined(separator: "\n")
  }
}

/// 聊天目标只保存稳定的 Tab/Pane 身份和展示信息；真实 PTY 在发送时重新查找，避免
/// 弹窗停留期间 Pane 被关闭或 Agent 已退出后仍向陈旧对象写入。
struct AgentChatDestination: Identifiable, Equatable {
  var id: UUID { paneID }
  let tabID: UUID
  let paneID: UUID
  let provider: AgentProvider
  let title: String
}

/// 打开“发送到聊天”面板时冻结的来源快照。终端输出只存在内存中，绝不写入工作区
/// 快照或日志；发送前仍由 `AgentChatContextBuilder` 进行清理和脱敏。
struct AgentChatPresentation: Equatable {
  let originPaneID: UUID
  let destinations: [AgentChatDestination]
  let selection: String?
  let transcript: String
  let transcriptHasError: Bool
}

/// 文件和目录从 Files、CLI、拖放等入口进入工作区时共用的落点语义。
/// `currentPane` 不写入持久化模型；真正落盘的仍是既有 Pane 树。
enum WorkspaceResourcePlacement: Equatable {
  case currentPane
  case newTab
  case newWindow
  case split(SplitDirection)
}

/// UI 文件树按能力自动选择可编辑源码或只读预览；CLI 仍显式映射 view/edit，保持
/// 对外命令语义稳定，不让一次内部默认值调整改变脚本行为。
enum WorkspaceResourceOpenMode: Equatable {
  case automatic
  case view
  case edit
}

/// 在 Recipe 边界递归转换 Pane 描述中的目录和资源路径，保持 UUID、嵌套方向与比例。
/// 领域模型只处理模板语法，不触碰文件系统，也不把运行态对象写入 Recipe。
enum WorkflowRecipeWorkspaceMapper {
  static func makePortable(_ layout: PaneLayout, home: URL) -> PaneLayout {
    map(layout) { descriptor in
      var portable = descriptor
      portable.workingDirectory = makePortable(descriptor.workingDirectory, home: home)
      if let resourcePath = descriptor.resourcePath {
        portable.resourcePath = makePortable(resourcePath, home: home)
      }
      return portable
    }
  }

  static func resolve(
    _ layout: PaneLayout,
    context: WorkflowPortablePathContext
  ) throws -> PaneLayout {
    try map(layout) { descriptor in
      var resolved = descriptor
      resolved.workingDirectory = try WorkflowPortablePath.resolve(
        descriptor.workingDirectory, context: context)
      if let resourcePath = descriptor.resourcePath {
        resolved.resourcePath = try WorkflowPortablePath.resolve(resourcePath, context: context)
      }
      return resolved
    }
  }

  static func resolve(
    _ pane: WorkflowRecipePane,
    context: WorkflowPortablePathContext
  ) throws -> PaneDescriptor {
    PaneDescriptor(
      kind: pane.kind,
      workingDirectory: try WorkflowPortablePath.resolve(pane.workingDirectory, context: context),
      resourcePath: try pane.resourcePath.map {
        try WorkflowPortablePath.resolve($0, context: context)
      }
    )
  }

  /// Recipe 是可重复实例化的模板，不是工作区快照。每次打开都重建 Pane UUID，避免
  /// 同一文件重复打开后 Composer、CLI selector 和重放队列因键冲突互相串写。
  static func instantiate(_ layout: PaneLayout) -> PaneLayout {
    map(layout) { descriptor in
      PaneDescriptor(
        kind: descriptor.kind,
        workingDirectory: descriptor.workingDirectory,
        resourcePath: descriptor.resourcePath
      )
    }
  }

  private static func makePortable(_ path: String, home: URL) -> String {
    (try? WorkflowPortablePath.makePortable(
      path,
      replacing: home,
      with: .homeFolder
    )) ?? path
  }

  private static func map(
    _ layout: PaneLayout,
    transform: (PaneDescriptor) throws -> PaneDescriptor
  ) rethrows -> PaneLayout {
    switch layout {
    case .leaf(let descriptor):
      return .leaf(try transform(descriptor))
    case .split(let axis, let first, let second, let ratio):
      return .split(
        axis: axis,
        first: try map(first, transform: transform),
        second: try map(second, transform: transform),
        ratio: ratio
      )
    }
  }
}

/// 一个分屏叶节点的运行态。持久化层只保存 `PaneDescriptor`，这里持有不可序列化的
/// PTY 与编辑缓冲区，防止会话恢复误用旧 PID 或文件描述符。
@MainActor
final class WorkspacePaneRuntime: ObservableObject, Identifiable {
  let id: UUID
  private(set) var descriptor: PaneDescriptor
  let terminalSession: TerminalSession?
  @Published var documentText = ""
  @Published private(set) var documentError: String?
  @Published private(set) var isDirty = false
  /// Read-only 是 Pane 运行态，不写入会话快照。Preview Pane 恢复后仍默认只读；
  /// Editor Pane 恢复后默认可编辑，保持既有快照兼容性。
  @Published private(set) var isReadOnly = false
  private var documentBuffer: DocumentBuffer?

  init(descriptor: PaneDescriptor) {
    id = descriptor.id
    self.descriptor = descriptor
    if descriptor.kind == .terminal {
      terminalSession = TerminalSession(workingDirectory: descriptor.workingDirectory)
    } else {
      terminalSession = nil
    }

    isReadOnly = descriptor.kind == .preview
    if [.editor, .preview].contains(descriptor.kind), let path = descriptor.resourcePath {
      let url = URL(fileURLWithPath: path)
      let handle = try? FileHandle(forReadingFrom: url)
      let prefix = handle?.readData(ofLength: 64 * 1_024) ?? Data()
      if let handle { try? handle.close() }
      let presentation = FileDocumentClassifier.classify(
        fileName: url.lastPathComponent,
        prefix: prefix
      )
      guard presentation.usesTextContent else { return }
      do {
        let buffer = try DocumentBuffer.load(from: url)
        documentBuffer = buffer
        documentText = buffer.text
      } catch {
        documentError = error.localizedDescription
        DiagnosticsCenter.shared.record(
          "document.initial_load_failed", level: .error, category: .storage, error: error)
      }
    }
  }

  func updateDocument(_ text: String) {
    guard !isReadOnly else { return }
    documentText = text
    documentBuffer?.updateText(text)
    isDirty = documentBuffer?.isDirty ?? !text.isEmpty
  }

  func saveDocument() {
    guard !isReadOnly else { return }
    guard var buffer = documentBuffer else { return }
    buffer.updateText(documentText)
    do {
      try buffer.save()
      documentBuffer = buffer
      isDirty = false
      documentError = nil
    } catch {
      documentError = error.localizedDescription
      DiagnosticsCenter.shared.record(
        "document.save_failed", level: .error, category: .storage, error: error)
    }
  }

  func toggleReadOnly() {
    isReadOnly.toggle()
    terminalSession?.setReadOnly(isReadOnly)
  }

  func setReadOnly(_ value: Bool) {
    guard isReadOnly != value else { return }
    isReadOnly = value
    terminalSession?.setReadOnly(value)
  }

  /// 丢弃内存中的未保存内容并从磁盘重载。调用方负责在脏状态下先向用户确认，
  /// 该方法只执行可预测的文件事务并把错误暴露给 Pane。
  func reloadDocument() {
    guard let path = descriptor.resourcePath else { return }
    do {
      let buffer = try DocumentBuffer.load(from: URL(fileURLWithPath: path))
      documentBuffer = buffer
      documentText = buffer.text
      isDirty = false
      documentError = nil
    } catch {
      documentError = error.localizedDescription
      DiagnosticsCenter.shared.record(
        "document.reload_failed", level: .error, category: .storage, error: error)
    }
  }

  /// 重命名后让已打开 Pane 继续跟踪同一资源。仅更新路径并重新加载，不改变 Pane ID，
  /// 因而不会破坏布局、焦点或工作区恢复引用。
  func relocateDocument(to url: URL) {
    descriptor.resourcePath = url.path
    descriptor.workingDirectory = descriptor.kind == .fileBrowser
      ? url.path : url.deletingLastPathComponent().path
    if let buffer = documentBuffer {
      documentBuffer = buffer.relocated(to: url)
      // 文本与 dirty 状态保持不变；只有保存目标随文件系统重命名移动。
      isDirty = documentBuffer?.isDirty ?? isDirty
    } else if [.editor, .preview].contains(descriptor.kind) {
      // 二进制或超大预览没有 DocumentBuffer，由 renderer 直接按新路径读取。
      documentError = nil
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
  /// 所有 Pane 焦点转换都经此属性发布局部事件，覆盖拆分、恢复、拖移、关闭与显式
  /// 聚焦。详情面板据此统一取消旧检查并切换订阅，避免某条状态转换遗漏刷新。
  private(set) var activePaneID: UUID {
    didSet {
      guard activePaneID != oldValue else { return }
      activePaneChanged.send(activePaneID)
    }
  }
  let activePaneChanged = PassthroughSubject<UUID, Never>()
  /// Shell 报告的新目录只要求刷新依赖 CWD 的局部内容。视图层订阅该事件更新详情面板，
  /// 不必等待或推断通用 `objectWillChange`，也不会在新快照返回前清空旧文件树。
  let workingDirectoryChanged = PassthroughSubject<(paneID: UUID, directory: String), Never>()
  let windowTitleChanged = PassthroughSubject<String, Never>()
  let documentLineRevealRequested = PassthroughSubject<(paneID: UUID, line: Int), Never>()
  /// 目录变化由 Tab 专用回调上送给窗口级 frecency 数据库，不经 `objectWillChange`，
  /// 避免单次 `cd` 同时触发无关界面刷新。
  var onWorkingDirectoryChanged: ((String) -> Void)?
  var onCommandFinished: ((UUID) -> Void)?
  /// Agent 生命周期状态变化的定向出口。它只服务 Prompt Queue 的自动派发，不能并入
  /// `objectWillChange`：Agent 状态在每次输入后立即变化，整树重建会打断 Agent TUI。
  var onAgentTaskStateChanged: ((UUID, AgentTaskState) -> Void)?
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

  /// 多 Pane 标签按“当前错误 > 等待输入 > 正在运行 > 已完成”聚合；旧退出码不会
  /// 覆盖已经开始的新任务，避免失败徽章在下一次构建期间仍误导用户。
  var activityBadge: TerminalBadgeState {
    let sessions = runtimes.values.compactMap(\.terminalSession)
    let explicit = sessions.compactMap(\.explicitBadge)
    if explicit.contains(.error) { return .error }
    if explicit.contains(.awaitingInput) { return .awaitingInput }
    if let running = explicit.first(where: {
      if case .running = $0 { return true }
      return false
    }) { return running }
    if explicit.contains(.completed) { return .completed }
    if explicit.contains(.finished) { return .finished }

    let agentBadges = sessions.compactMap(\.agentActivityBadge)
    if agentBadges.contains(.awaitingInput) { return .awaitingInput }
    if let running = agentBadges.first(where: {
      if case .running = $0 { return true }
      return false
    }) { return running }
    if agentBadges.contains(.completed) { return .completed }
    if agentBadges.contains(.finished) { return .finished }

    // Agent 前台进程跨越多个 turn；权威 idle 到达后不能被普通进程探针重新标成运行中。
    let ordinarySessions = sessions.filter { $0.activeAgentProvider == nil }
    if ordinarySessions.contains(where: { $0.progressState.reportsError }) { return .error }
    if ordinarySessions.contains(where: \.awaitingInput) { return .awaitingInput }
    if let active = runtimes[activePaneID]?.terminalSession, active.activeAgentProvider == nil {
      switch active.progressState {
      case let .determinate(percent): return .running(percent: percent)
      case .indeterminate: return .running(percent: nil)
      case .clear, .error, .finished: break
      }
    }
    if ordinarySessions.contains(where: { $0.progressState.isWorking || $0.hasRunningCommand }) {
      return .running(percent: nil)
    }
    if ordinarySessions.contains(where: \.showsCompletedFlash) { return .completed }
    if ordinarySessions.contains(where: {
      if case .finished = $0.progressState { return true }
      return $0.lastCommandExitStatus == 0
    }) { return .finished }
    if ordinarySessions.contains(where: {
      if case .error = $0.progressState { return true }
      return $0.lastCommandExitStatus.map { $0 != 0 } == true
    }) { return .error }
    return .none
  }

  var hasProcessingAgent: Bool {
    runtimes.values.contains { $0.terminalSession?.agentTaskState == .processing }
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
  /// 文件浏览器、编辑器和预览 Pane 需要把动作路由到同一标签中的终端。优先活动
  /// 终端，否则按布局顺序选择第一个终端；不依赖字典迭代顺序。
  var preferredTerminalRuntime: WorkspacePaneRuntime? {
    if let activeRuntime, activeRuntime.terminalSession != nil { return activeRuntime }
    return layout.allPanes.lazy.compactMap { self.runtimes[$0.id] }.first {
      $0.terminalSession != nil
    }
  }
  var windowTitle: String { titleState.windowTitle }
  var tabTitleOverride: TerminalTitleOverride { titleState.tabOverride }
  var workingDirectory: String {
    activeSession?.resolvedCurrentWorkingDirectory()
      ?? runtimes[activePaneID]?.descriptor.workingDirectory
      ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  func runtime(for paneID: UUID) -> WorkspacePaneRuntime? { runtimes[paneID] }

  func revealDocumentLine(_ line: Int, paneID: UUID) {
    guard line > 0, runtimes[paneID]?.descriptor.kind == .editor else { return }
    setActivePane(paneID)
    documentLineRevealRequested.send((paneID, line))
  }

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
    resourcePath: String? = nil,
    workingDirectory requestedWorkingDirectory: String? = nil
  ) {
    // Recipe 恢复必须在创建运行对象前给出目标目录；事后只改布局描述会让 PTY 仍从
    // 原目录启动。普通交互拆分继续继承当前 Pane 的实时 cwd。
    let directory = requestedWorkingDirectory
      ?? activeSession?.resolvedCurrentWorkingDirectory()
      ?? workingDirectory
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

  /// 恢复关闭历史中的 Pane，保留其可序列化身份、类型、目录和资源路径。运行态始终
  /// 重新创建，不复用旧 PTY/PID；恢复位置采用当前 Pane 右侧的稳定默认落点。
  func restorePane(_ descriptor: PaneDescriptor) {
    guard runtimes[descriptor.id] == nil,
      let updated = layout.splitting(
        paneID: activePaneID,
        direction: .right,
        with: descriptor
      )
    else { return }
    layout = updated
    addRuntime(for: descriptor)
    activePaneID = descriptor.id
    if let state = paneTitleStates[descriptor.id] { applyActiveTitleState(state) }
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
  }

  /// 文件面板的“在当前终端中 cd”如果存在同标签终端就复用并聚焦；若标签只有文件
  /// Pane，则创建一个继承目标目录的新终端。调用方无需猜测当前 Pane 类型。
  @discardableResult
  func openDirectoryInTerminal(_ directory: String) -> Bool {
    if let runtime = preferredTerminalRuntime,
      let session = runtime.terminalSession,
      session.sendAutomationBytes(
        Array(("cd " + WorkflowShellCommandEncoder.quote(directory) + "\n").utf8)
      )
    {
      setActivePane(runtime.id)
      return true
    }
    split(direction: .right, workingDirectory: directory)
    return activeSession != nil
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

  /// 以指定模式替换当前 Pane，保留叶节点 UUID 与树位置。正在运行命令的终端必须
  /// 显式确认；脏文档继续使用统一的保存确认，避免 Files 菜单绕过关闭保护。
  @discardableResult
  func replaceActivePane(with descriptorKind: PaneKind, resourceURL: URL) -> Bool {
    if let session = runtimes[activePaneID]?.terminalSession, session.hasRunningCommand {
      let alert = NSAlert()
      alert.messageText = "Replace the active terminal?"
      alert.informativeText = "A command is still running. Replacing this Pane will stop it."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Replace")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
    }
    guard runtimes[activePaneID]?.confirmCloseIfNeeded() != false else { return false }
    let replacement = PaneDescriptor(
      id: activePaneID,
      kind: descriptorKind,
      workingDirectory: descriptorKind == .fileBrowser
        ? resourceURL.path : resourceURL.deletingLastPathComponent().path,
      resourcePath: resourceURL.path
    )
    runtimes.removeValue(forKey: activePaneID)?.stop()
    layout = layout.updatingPane(paneID: activePaneID) { _ in replacement }
    addRuntime(for: replacement)
    updateTitleFallback(resourceURL.lastPathComponent, paneID: activePaneID)
    zoomedPaneID = nil
    markUpdated()
    return true
  }

  func openPreview(_ url: URL) {
    split(direction: .right, kind: .preview, resourcePath: url.path)
  }

  /// 在指定方向拆出编辑器 Pane；Files「在 Aster 中打开」四向分屏入口。
  func openFile(_ url: URL, splitDirection: SplitDirection) {
    split(direction: splitDirection, kind: .editor, resourcePath: url.path)
  }

  /// 用编辑器替换当前聚焦 Pane（保留 Pane UUID 与树位置）。脏编辑器先走关闭确认。
  @discardableResult
  func openFileReplacingActivePane(_ url: URL) -> Bool {
    replaceActivePane(with: .editor, resourceURL: url)
  }

  /// 文件重命名后同步所有打开该路径的 Pane。目录重命名会同步其后代资源，路径比较
  /// 按标准化 pathComponents 完成，避免 `/a/b` 错误匹配 `/a/b2`。
  func relocateOpenResources(from oldURL: URL, to newURL: URL) {
    let oldComponents = oldURL.standardizedFileURL.pathComponents
    for pane in layout.allPanes {
      guard let path = pane.resourcePath else { continue }
      let current = URL(fileURLWithPath: path).standardizedFileURL
      let components = current.pathComponents
      guard components.count >= oldComponents.count,
        components.prefix(oldComponents.count).elementsEqual(oldComponents)
      else { continue }
      let suffix = components.dropFirst(oldComponents.count)
      let relocated = suffix.reduce(newURL) { $0.appendingPathComponent($1) }
      guard let runtime = runtimes[pane.id] else { continue }
      runtime.relocateDocument(to: relocated)
      layout = layout.updatingPane(paneID: pane.id) { _ in runtime.descriptor }
    }
    markUpdated()
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
    // spinner 每帧重启（可见闪烁）。Agent task state 与未读完成状态同样不能走这里：
    // 它们在输入后立即变化，若重建会让 Files 回退到 Pane 初始目录并打断 Agent TUI。
    // 目录变化由下方专用 sink 经 layout/title 触发刷新。
    if let session = runtime.terminalSession {
      session.onTitleUpdate = { [weak self] code, text in
        self?.applyProgramTitle(paneID: descriptor.id, code: code, text: text)
      }
      session.onCommandFinished = { [weak self] in self?.onCommandFinished?(descriptor.id) }
      Publishers.MergeMany(
        session.$isRunning.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$hasRunningCommand.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$exitCode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$startupError.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$lastCommandExitStatus.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$progressState.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$awaitingInput.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$showsCompletedFlash.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$explicitBadge.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        session.$activeAgentProvider.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
      )
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

      // `@Published` 在 `willSet` 阶段发布，此刻回读 `session.agentTaskState` 仍是旧值，
      // 因此新状态必须随事件一起上送。
      session.$agentTaskState
        .removeDuplicates()
        .dropFirst()
        .sink { [weak self] state in self?.onAgentTaskStateChanged?(descriptor.id, state) }
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
        self.workingDirectoryChanged.send((paneID: descriptor.id, directory: directory))
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
  private struct ClosedWorkspaceItem: Codable {
    let event: WorkflowClosedItem
    let tabID: UUID?
    let tab: WorkspaceTabSnapshot?
    let pane: PaneDescriptor?
  }
  private enum PendingWorkflowCLIKind {
    case run(format: WorkflowCLIOutputFormat)
    case exec(
      format: WorkflowCLIOutputFormat,
      temporaryDirectory: URL,
      standardOutputURL: URL,
      standardErrorURL: URL
    )
  }

  private struct PendingWorkflowCLICommand {
    let command: String
    let startedAt: Date
    let kind: PendingWorkflowCLIKind
    let completion: (WorkflowCLIExecutionResponse) -> Void
  }

  @Published private(set) var tabs: [TerminalTabItem] = []
  @Published var selectedTabID: UUID?
  @Published var isPalettePresented = false
  /// Open Quickly 是工作区上的临时浮层，显隐不应触发 `ObservableObject` 的整窗口
  /// 重绘。独立事件让 AppKit 控制器只挂载或移除浮层，并保留终端与侧栏实例。
  let openQuicklyPresentationChanged = PassthroughSubject<Bool, Never>()
  var isOpenQuicklyPresented = false {
    didSet {
      guard isOpenQuicklyPresented != oldValue else { return }
      openQuicklyPresentationChanged.send(isOpenQuicklyPresented)
    }
  }
  @Published var isGlobalFindPresented = false
  @Published var isComposerPresented = false
  @Published var isAgentHistoryPresented = false
  /// Prompt Queue 仅局部挂载到活动 Pane，不能通过 `objectWillChange` 触发整棵终端
  /// 视图重建，否则正在输入的 TUI 会短暂失焦。
  let promptQueuePresentationChanged = PassthroughSubject<UUID?, Never>()
  private(set) var presentedPromptQueuePaneID: UUID?
  /// 发送弹窗同样由专用事件展示；领域模型只提供安全的冻结来源和目标清单。
  let agentChatPresentationRequested = PassthroughSubject<AgentChatPresentation, Never>()
  /// 历史扫描可能在启动后任意时刻完成；独立事件只更新消费历史的局部面板，避免一次
  /// 后台 I/O 完成把整个终端工作区重建。
  let agentHistoriesChanged = PassthroughSubject<[AgentSessionHistory], Never>()
  private(set) var agentHistories: [AgentSessionHistory] = [] {
    didSet { agentHistoriesChanged.send(agentHistories) }
  }
  /// 详情面板与 Open Quickly 一样属于局部展示状态。显隐只改变内容区约束，不得通过
  /// `objectWillChange` 触发整个工作区重建，否则终端、侧栏和 Pane 树都会被拆下再挂回。
  let inspectorPresentationChanged = PassthroughSubject<Bool, Never>()
  var isInspectorPresented = false {
    didSet {
      guard isInspectorPresented != oldValue else { return }
      inspectorPresentationChanged.send(isInspectorPresented)
    }
  }
  @Published var isFindPresented = false
  @Published var notice: String?
  @Published private(set) var dividerAfterTabIDs: Set<UUID> = []
  var newTabPosition = NewTabPosition.automatic
  var frecencyAutoRecord = true
  var recipeReplayMode = RecipeReplayMode.confirmOnce
  var openQuicklyInitialFilter = OpenQuicklyFilter.all
  var enabledAgentProviders: [AgentProvider] = []
  var agentLaunchCommands: [String: [String]] = [:]
  var workflowRecipeReplaySettings: WorkflowRecipeReplaySettings {
    WorkflowRecipeReplaySettings(savedRecipes: .automatic, recipeFiles: recipeReplayMode)
  }
  var onTabOrderBecameManual: (() -> Void)?
  /// 窗口创建、置顶和 PiP 由 AppDelegate 持有真实 NSWindow；AppModel 只发布意图，
  /// 保持 CLI、命令面板与工作区领域逻辑可在无窗口测试中独立验证。
  var onRequestNewWindow: ((PaneDescriptor?) -> Bool)?
  var onRequestToggleWindowPin: (() -> Void)?
  var onRequestPictureInPicture: ((Bool) -> Void)?
  private let defaults: UserDefaults
  private let snapshotKey = "aster.workspace.snapshot.v1"
  private let recentlyClosedKey = "aster.workspace.recently-closed.v1"
  private let frequentFoldersKey = "aster.frequent-folders.v1"
  private let workflowRecipeTrustKey = "aster.workflow-recipe-trust.v1"
  private let closedWorkspaceItemsKey = "aster.workspace.closed-items.v1"
  private let applicationSessionRunningKey = "aster.session.running.v1"
  private let applicationSessionCrashCountKey = "aster.session.crash-count.v1"
  private let applicationSessionEndReasonKey = "aster.session.end-reason.v1"
  private let windowID = UUID()
  private var recentlyClosedTabs: RecentlyClosedTabs
  private var frequentFolders: FrequentFolders
  private var workflowRecipeTrust: WorkflowRecipeTrustStore
  private var closedWorkspaceItems: [ClosedWorkspaceItem]
  private var shouldRestoreInitialWorkspace = true
  private var agentComposers: [UUID: AgentComposerState] = [:]
  private var agentPromptQueues: [UUID: AgentPromptQueue] = [:]
  private var promptQueueDrafts: [UUID: String] = [:]
  private var didRequestAgentHistory = false
  private var pendingRecipeCommands: [UUID: [String]] = [:]
  /// `.oneByOne` 模式按 Pane 记录逐条确认要求；命令发送完成、跳过或停止时同步清理，
  /// 绝不能因一次外部文件信任确认而退化为批量执行授权。
  private var recipeCommandConfirmationPaneIDs: Set<UUID> = []
  /// 标记已经开始回放的 Pane，避免视图重建时重复发送下一条命令。只有收到当前命令的
  /// Shell Integration 完成事件后，才允许继续消费该 Pane 的队列。
  private var activeRecipeReplayPaneIDs: Set<UUID> = []
  /// 每个 Pane 同时最多一个需要等待 OSC 133 完成事件的 CLI 请求。请求不进入工作区
  /// 快照；应用退出时 shell wrapper 仍可结束，但调用方会按本机传输超时失败。
  private var pendingWorkflowCLICommands: [UUID: PendingWorkflowCLICommand] = [:]

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
    if let data = defaults.data(forKey: workflowRecipeTrustKey),
      let decoded = try? JSONDecoder().decode(WorkflowRecipeTrustStore.self, from: data)
    {
      workflowRecipeTrust = decoded
    } else {
      workflowRecipeTrust = WorkflowRecipeTrustStore()
    }
    if let data = defaults.data(forKey: closedWorkspaceItemsKey),
      let decoded = try? JSONDecoder().decode([ClosedWorkspaceItem].self, from: data)
    {
      closedWorkspaceItems = Array(decoded.suffix(WorkflowRecoveryHistory.maximumEntries))
    } else {
      closedWorkspaceItems = []
    }
  }

  /// 在创建工作区控制器前调用。未清掉 running 标记表示上次异常退出；异常退出与
  /// 原地更新都优先恢复快照，普通退出才遵循“恢复 / 新窗口”偏好。连续三次异常恢复
  /// 会启动空工作区，避免损坏快照形成启动循环。
  func beginApplicationSession(launchBehavior: LaunchBehavior) {
    let previousWasRunning = defaults.bool(forKey: applicationSessionRunningKey)
    let previousReason = WorkflowSessionEndReason(
      rawValue: defaults.string(forKey: applicationSessionEndReasonKey) ?? "") ?? .cleanQuit
    let reason: WorkflowSessionEndReason = previousWasRunning ? .crash : previousReason
    let crashCount: Int
    if reason == .crash || reason == .forceQuit {
      crashCount = defaults.integer(forKey: applicationSessionCrashCountKey) + 1
    } else {
      crashCount = 0
    }
    defaults.set(crashCount, forKey: applicationSessionCrashCountKey)
    defaults.set(true, forKey: applicationSessionRunningKey)
    defaults.set(WorkflowSessionEndReason.forceQuit.rawValue, forKey: applicationSessionEndReasonKey)

    let onLaunch: WorkflowOnLaunchBehavior = launchBehavior == .restoreLastSession
      ? .restoreSession : .newWindow
    let decision = WorkflowSessionRecoveryPlanner.plan(
      after: reason,
      onLaunch: onLaunch,
      snapshotAvailable: defaults.data(forKey: snapshotKey) != nil,
      crashLoopDetected: crashCount >= 3
    )
    switch decision {
    case .restoreSnapshot:
      shouldRestoreInitialWorkspace = true
    case .openNewWindow, .startFreshAfterCrashLoop:
      shouldRestoreInitialWorkspace = false
    }
    // 复用既有恢复真值记录异常退出与 crash-loop 决策；不新增并行状态文件，避免多窗口
    // 或强制退出时两套标记彼此矛盾。
    DiagnosticsCenter.shared.record(
      "workspace.session_recovery_planned",
      level: reason == .crash || reason == .forceQuit ? .warning : .info,
      category: .workspace,
      attributes: [
        "reason": reason.rawValue,
        "decision": String(describing: decision),
        "crash_count": "\(crashCount)",
      ]
    )
  }

  func ensureInitialTab() {
    if !didRequestAgentHistory {
      didRequestAgentHistory = true
      reloadAgentHistory()
    }
    guard tabs.isEmpty else { return }
    if shouldRestoreInitialWorkspace, let data = defaults.data(forKey: snapshotKey),
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

  /// 给窗口路由层预置一个文件 Pane。Descriptor 由调用者创建，因此 CLI 的
  /// `--new-window` 不会先在旧窗口落一个标签，也不会丢失目标 Pane 身份。
  func openResourceInNewTab(_ descriptor: PaneDescriptor) {
    let resourceURL = descriptor.resourcePath.map(URL.init(fileURLWithPath:))
    let tab = TerminalTabItem(
      title: resourceURL?.lastPathComponent ?? descriptor.kind.rawValue,
      workingDirectory: descriptor.workingDirectory,
      layout: .leaf(descriptor)
    )
    insertTab(tab, hasContent: true)
  }

  /// Files、Open 面板与 CLI 共用的资源路由。普通文件默认由调用方选择 view/edit；
  /// 目录固定进入 File Browser。这里重新检查类型与符号链接，防止菜单展示后目标被
  /// 替换成特殊文件或跳出原来的安全边界。
  @discardableResult
  func openResource(
    _ url: URL,
    mode: WorkspaceResourceOpenMode = .view,
    placement: WorkspaceResourcePlacement = .split(.right)
  ) -> Bool {
    guard url.isFileURL,
      let values = try? url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]), values.isSymbolicLink != true,
      values.isDirectory == true || values.isRegularFile == true
    else {
      notice = "The selected item is not a safe local file or folder."
      return false
    }
    let kind: PaneKind
    if values.isDirectory == true {
      kind = .fileBrowser
    } else {
      switch mode {
      case .view:
        kind = .preview
      case .edit:
        kind = .editor
      case .automatic:
        let handle = try? FileHandle(forReadingFrom: url)
        let prefix = handle?.readData(ofLength: 64 * 1_024) ?? Data()
        if let handle { try? handle.close() }
        let trustedProvider = agentHistories.first(where: {
          $0.metadata.transcriptFileURL.standardizedFileURL == url.standardizedFileURL
        })?.metadata.configuration.provider
        let presentation = FileDocumentClassifier.classify(
          fileName: url.lastPathComponent,
          prefix: prefix,
          trustedAgentProvider: trustedProvider
        )
        kind = presentation.supportsEditing ? .editor : .preview
      }
    }
    let workingDirectory = values.isDirectory == true
      ? url.path : url.deletingLastPathComponent().path
    let descriptor = PaneDescriptor(
      kind: kind,
      workingDirectory: workingDirectory,
      resourcePath: url.path
    )
    switch placement {
    case .currentPane:
      guard selectedTab?.replaceActivePane(with: kind, resourceURL: url) == true else {
        return false
      }
    case .newTab:
      openResourceInNewTab(descriptor)
    case .newWindow:
      guard onRequestNewWindow?(descriptor) == true else {
        notice = "Unable to create a new window."
        return false
      }
    case .split(let direction):
      guard let tab = selectedTab else {
        notice = "There is no active workspace."
        return false
      }
      tab.split(
        direction: direction,
        kind: kind,
        resourcePath: url.path,
        workingDirectory: workingDirectory
      )
    }
    persistWorkspace()
    return true
  }
  /// 文件系统重命名完成后更新窗口内所有引用旧路径的 Pane，再一次性持久化布局。
  func relocateOpenResources(from oldURL: URL, to newURL: URL) {
    for tab in tabs { tab.relocateOpenResources(from: oldURL, to: newURL) }
    persistWorkspace()
  }

  var selectedTab: TerminalTabItem? {
    tabs.first(where: { $0.id == selectedTabID })
  }

  var recentlyClosedSnapshots: [WorkspaceTabSnapshot] { recentlyClosedTabs.entries.reversed() }

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

  /// 跨窗口拖动标签时转移现有 TerminalTabItem，而不是从 snapshot 重建。PTY、编辑
  /// 草稿、滚动历史和 Agent 状态因此保持原对象；源窗口若被取走最后一项会补一个新
  /// Shell，继续满足工作区永不为空的不变量。
  func detachTabForTransfer(id: UUID) -> TerminalTabItem? {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
    let tab = tabs.remove(at: index)
    dividerAfterTabIDs.remove(tab.id)
    if tabs.isEmpty {
      newTab()
    } else {
      selectedTabID = tabs[min(index, tabs.count - 1)].id
      persistWorkspace()
    }
    return tab
  }

  func receiveTransferredTab(_ tab: TerminalTabItem) {
    guard !tabs.contains(where: { $0.id == tab.id }) else { return }
    insertTab(tab, position: .end, hasContent: true)
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
    if closePaneAndRecord(in: tab) {
      persistWorkspace()
      return
    }
    closeSelectedTab()
  }

  func closeSelectedTab() {
    guard let selectedTabID else { return }
    closeTab(id: selectedTabID)
  }

  /// 关闭指定标签，用于侧栏行内关闭等不应先改变当前选中项的入口。
  /// 若目标就是当前标签，选中相邻标签；关闭后台标签时保持当前选中项。
  /// 未保存文档拒绝关闭时不改变任何模型状态。
  func closeTab(id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    guard tabs[index].confirmCloseDocuments() else { return }
    let wasSelected = selectedTabID == id
    let snapshot = tabs[index].snapshot
    recentlyClosedTabs.record(snapshot)
    recordClosedWorkspaceItem(.init(
      event: WorkflowClosedItem(
        id: UUID(), kind: .tab, originWindowID: windowID, closedAt: Date()),
      tabID: snapshot.id,
      tab: snapshot,
      pane: nil
    ))
    persistRecentlyClosedTabs()
    tabs[index].stop()
    dividerAfterTabIDs.remove(tabs[index].id)
    tabs.remove(at: index)
    if tabs.isEmpty {
      newTab()
    } else if wasSelected {
      self.selectedTabID = tabs[min(index, tabs.count - 1)].id
      persistWorkspace()
    } else {
      persistWorkspace()
    }
  }

  /// 恢复最近关闭的标签。历史只保存可重建快照，因此会创建新的运行态 Shell，
  /// 不会尝试重新使用已终止的 PID 或 PTY 文件描述符。
  @discardableResult
  func reopenLastClosedTab() -> Bool {
    if let item = closedWorkspaceItems.popLast() {
      persistClosedWorkspaceItems()
      switch item.event.kind {
      case .pane:
        guard let descriptor = item.pane,
          let tabID = item.tabID,
          let tab = tabs.first(where: { $0.id == tabID }) ?? selectedTab
        else { return false }
        tab.restorePane(descriptor)
        selectedTabID = tab.id
        persistWorkspace()
        return true
      case .tab:
        guard let snapshot = item.tab else { return false }
        recentlyClosedTabs.removeEntries(withIDs: [snapshot.id])
        let tab = TerminalTabItem(snapshot: snapshot)
        tabs.append(tab)
        configurePersistence(for: tab)
        selectedTabID = tab.id
        persistRecentlyClosedTabs()
        persistWorkspace()
        return true
      case .window:
        guard let snapshot = item.tab else { return false }
        let tab = TerminalTabItem(snapshot: snapshot)
        tabs.append(tab)
        configurePersistence(for: tab)
        selectedTabID = tab.id
        persistWorkspace()
        return true
      }
    }
    guard let snapshot = recentlyClosedTabs.reopenLast() else { return false }
    let tab = TerminalTabItem(snapshot: snapshot)
    tabs.append(tab)
    configurePersistence(for: tab)
    selectedTabID = tab.id
    persistRecentlyClosedTabs()
    persistWorkspace()
    return true
  }

  @discardableResult
  func reopenClosedTab(id: UUID) -> Bool {
    guard let snapshot = recentlyClosedTabs.reopen(id: id) else { return false }
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
    guard let tab = selectedTab, closePaneAndRecord(in: tab) else { return }
    persistWorkspace()
  }

  private func closePaneAndRecord(in tab: TerminalTabItem) -> Bool {
    guard tab.layout.allPanes.count > 1,
      let descriptor = tab.layout.allPanes.first(where: { $0.id == tab.activePaneID }),
      tab.closeActivePane()
    else { return false }
    recordClosedWorkspaceItem(.init(
      event: WorkflowClosedItem(
        id: UUID(), kind: .pane, originWindowID: windowID, closedAt: Date()),
      tabID: tab.id,
      tab: nil,
      pane: descriptor
    ))
    return true
  }

  private func recordClosedWorkspaceItem(_ item: ClosedWorkspaceItem) {
    closedWorkspaceItems.append(item)
    if closedWorkspaceItems.count > WorkflowRecoveryHistory.maximumEntries {
      closedWorkspaceItems.removeFirst(
        closedWorkspaceItems.count - WorkflowRecoveryHistory.maximumEntries)
    }
    persistClosedWorkspaceItems()
  }

  private func persistClosedWorkspaceItems() {
    guard let data = try? JSONEncoder().encode(closedWorkspaceItems) else { return }
    defaults.set(data, forKey: closedWorkspaceItemsKey)
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

  var activePaneIsReadOnly: Bool {
    selectedTab?.activeRuntime?.isReadOnly == true
  }

  func toggleActivePaneReadOnly() {
    selectedTab?.activeRuntime?.toggleReadOnly()
  }

  func togglePalette() {
    let presents = !isPalettePresented
    dismissWorkspaceOverlays()
    isPalettePresented = presents
  }

  func toggleOpenQuickly(filter: OpenQuicklyFilter = .all) {
    let presents = !isOpenQuicklyPresented
    dismissWorkspaceOverlays()
    openQuicklyInitialFilter = filter
    isOpenQuicklyPresented = presents
  }

  func toggleGlobalFind() {
    let presents = !isGlobalFindPresented
    dismissWorkspaceOverlays()
    isGlobalFindPresented = presents
  }

  func dismissWorkspaceOverlays() {
    // `@Published` 即使写入相同值也会发送 objectWillChange；只修改真实打开的浮层，
    // 避免单纯打开 Open Quickly 时先制造多次无意义的整窗口刷新。
    if isPalettePresented { isPalettePresented = false }
    if isOpenQuicklyPresented { isOpenQuicklyPresented = false }
    if isGlobalFindPresented { isGlobalFindPresented = false }
    if isAgentHistoryPresented { isAgentHistoryPresented = false }
  }

  func toggleInspector() { isInspectorPresented.toggle() }
  func toggleFind() { isFindPresented.toggle() }
  func toggleComposer() { isComposerPresented.toggle() }

  /// Prompt 队列是当前终端 Pane 的手动输入工作流，不依赖 Claude/Codex 的识别结果。
  /// 识别状态会随 Agent 生命周期变化，不能用它禁用菜单或让已入队的命令失去发送入口。
  var canPresentPromptQueue: Bool {
    selectedTab?.activeSession != nil
  }

  func togglePromptQueue() {
    guard let paneID = selectedTab?.activePaneID, canPresentPromptQueue else {
      notice = "请先选择一个终端 Pane。"
      return
    }
    presentedPromptQueuePaneID = presentedPromptQueuePaneID == paneID ? nil : paneID
    promptQueuePresentationChanged.send(presentedPromptQueuePaneID)
  }

  func hidePromptQueue(paneID: UUID) {
    guard presentedPromptQueuePaneID == paneID else { return }
    presentedPromptQueuePaneID = nil
    promptQueuePresentationChanged.send(nil)
  }

  func promptQueueDraft(for paneID: UUID) -> String { promptQueueDrafts[paneID] ?? "" }

  /// 草稿沿用队列的单条 64 KiB 上限，关闭输入条后仍只保留在本次运行内，不会进入
  /// 会话快照。返回 false 时 UI 保持用户原有文本并展示错误反馈。
  @discardableResult
  func updatePromptQueueDraft(_ value: String, paneID: UUID) -> Bool {
    guard value.utf8.count <= AgentPromptQueue().maximumPromptBytes else {
      notice = "队列提示词超过 64 KiB 上限。"
      return false
    }
    promptQueueDrafts[paneID] = value
    return true
  }

  @discardableResult
  func enqueuePromptQueueDraft(paneID: UUID) -> Bool {
    var queue = promptQueue(for: paneID)
    do {
      try queue.enqueue(.init(text: promptQueueDraft(for: paneID)))
      promptQueueDrafts[paneID] = ""
      agentPromptQueues[paneID] = queue
      // 只重建底部条以显示新增列表项；不能用 objectWillChange 打断整个终端 Pane 树。
      promptQueuePresentationChanged.send(presentedPromptQueuePaneID == paneID ? paneID : nil)
      // Agent 已经在等输入时不会再有状态变化事件，入队本身就是可派发时机。
      advancePromptQueue(paneID: paneID)
      return true
    } catch {
      notice = "加入队列失败：\(error.localizedDescription)"
      DiagnosticsCenter.shared.record(
        "agent.prompt_queue_enqueue_failed", level: .warning, category: .workspace, error: error)
      return false
    }
  }

  /// 当前 Pane 中尚未发送的 FIFO 项。队列项只是本次进程内的临时工作清单，不会进入
  /// 工作区快照；用户可通过列表行左侧的发送按钮选择准确的一项立即提交。
  func promptQueueItems(for paneID: UUID) -> [AgentQueuedPrompt] {
    promptQueue(for: paneID).pending
  }

  /// 把指定的待发送项模拟为当前 Pane 的键入并提交 Return。只有 PTY 接受完整文本后
  /// 才从队列移除，写入失败时保留原项，避免用户丢失命令。
  @discardableResult
  func sendPromptQueueItem(id: UUID, paneID: UUID) -> Bool {
    guard let session = tabs.lazy.compactMap({ $0.runtime(for: paneID)?.terminalSession }).first
    else {
      notice = "当前终端 Pane 已关闭。"
      return false
    }

    var queue = promptQueue(for: paneID)
    guard let item = queue.pending.first(where: { $0.id == id }) else {
      notice = "该队列项已不存在。"
      return false
    }
    guard session.submitPromptQueueText(item.text) else {
      notice = "无法写入当前 CLI 输入框（\(session.promptWriteBlocker ?? "输入被前台程序拒绝")），队列项已保留。"
      return false
    }
    _ = queue.remove(id: id)
    agentPromptQueues[paneID] = queue
    promptQueuePresentationChanged.send(presentedPromptQueuePaneID == paneID ? paneID : nil)
    return true
  }

  /// Agent lifecycle hook 驱动的自动派发，是队列的常规发送路径：hook 报告 idle 才
  /// 代表当前轮次已结束、Agent 正在等下一条指令。严格单 in-flight —— 只有观察到
  /// 上一条从 processing/awaiting-input 回到 idle 才发下一条，否则多条 prompt 会挤进
  /// 同一轮对话。
  ///
  /// awaiting-input 刻意不派发：它来自 PermissionRequest hook，屏幕上是权限确认选择
  /// 器，此时写入文本加 Return 等于替用户批准了一次工具调用。
  private func advancePromptQueue(paneID: UUID, reportedState: AgentTaskState? = nil) {
    guard var queue = agentPromptQueues[paneID],
      queue.inFlight != nil || !queue.pending.isEmpty,
      let session = tabs.lazy.compactMap({ $0.runtime(for: paneID)?.terminalSession }).first
    else { return }

    // 状态变化事件带着新值进来；入队等主动调用没有事件，回读当前值即可。
    let state = reportedState ?? session.agentTaskState
    let completed = queue.observeAgentState(state)
    var dispatched = false
    if session.hasAuthoritativeAgentLifecycle, session.activeAgentProvider != nil,
      let next = queue.dispatchNext(when: .agent(state))
    {
      if session.submitPromptQueueText(next.text) {
        dispatched = true
      } else {
        // 写入失败（只读 Pane、输入模式限制、PTY 已退出）时把 prompt 放回队首，
        // 用户仍能改用列表行的立即发送按钮。
        queue.restoreInFlight()
        notice = "无法自动写入当前 CLI 输入框（\(session.promptWriteBlocker ?? "输入被前台程序拒绝")），队列项已保留。"
      }
    }
    // 无论本次是否派发都要写回：`observeAgentState` 记下的「in-flight 已真正开始」
    // 是隐式状态，丢掉它会让后续 idle 永远无法释放锁，队列卡在第一条上。
    agentPromptQueues[paneID] = queue
    guard completed != nil || dispatched else { return }
    promptQueuePresentationChanged.send(presentedPromptQueuePaneID == paneID ? paneID : nil)
  }

  /// 仅删除还未发送的指定项。已经由用户发出的内容不会留在队列中，因此不会出现撤销
  /// 已送入 Agent 的假象。
  func removePromptQueueItem(id: UUID, paneID: UUID) {
    var queue = promptQueue(for: paneID)
    guard queue.remove(id: id) != nil else { return }
    agentPromptQueues[paneID] = queue
    promptQueuePresentationChanged.send(presentedPromptQueuePaneID == paneID ? paneID : nil)
  }

  /// 捕获当前 Pane 的选区与最近滚动缓冲区，随后由面板让用户决定是否各自附加。目标
  /// 覆盖当前工作区的全部标签，但只接受仍运行中的 Claude Code/Codex 会话。
  func presentAgentChat() {
    guard let tab = selectedTab,
      let runtime = tab.activeRuntime,
      let session = runtime.terminalSession
    else {
      notice = "请先选择一个终端 Pane。"
      return
    }
    let destinations = agentChatDestinations()
    guard !destinations.isEmpty else {
      notice = "当前工作区没有可接收聊天内容的 Claude Code 或 Codex。"
      return
    }
    let transcript = session.textSnapshot().lines.suffix(2_000).joined(separator: "\n")
    agentChatPresentationRequested.send(
      AgentChatPresentation(
        originPaneID: runtime.id,
        destinations: destinations,
        selection: session.selectedTextForAgentContext,
        transcript: transcript,
        transcriptHasError: session.lastCommandExitStatus.map { $0 != 0 } ?? false
      )
    )
  }

  /// 将已确认的上下文按普通键入预填到目标 Agent 的原生输入框。该动作不发送 Return，
  /// 也不强制 bracketed paste；目标 Pane 可在弹窗停留期间变化，故这里按 UUID 重查
  /// provider 和运行态。
  @discardableResult
  func prefillAgentChat(
    destination: AgentChatDestination,
    comment: String,
    selection: String?,
    transcript: String?
  ) -> Bool {
    let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedComment.utf8.count <= AgentChatContextBudget().reservedPromptBytes else {
      notice = "Comment 超过 8 KiB 上限。"
      return false
    }
    guard let target = tabs.first(where: { $0.id == destination.tabID })?.runtime(for: destination.paneID),
      let session = target.terminalSession,
      session.activeAgentProvider == destination.provider,
      destination.provider == .claudeCode || destination.provider == .codex
    else {
      notice = "目标 Agent 已退出或 Pane 已关闭。"
      return false
    }

    do {
      var builder = AgentChatContextBuilder()
      if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try builder.add(source: .terminalSelection, content: selection)
      }
      if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try builder.add(source: .lastCommandOutput, content: transcript)
      }
      let context = builder.renderedForPrompt
      guard !trimmedComment.isEmpty || !context.isEmpty else {
        notice = "请填写 Comment 或至少选择一项上下文。"
        return false
      }
      let text = [trimmedComment, context].filter { !$0.isEmpty }.joined(separator: "\n\n")
      guard session.typePromptText(text) else {
        notice = "目标 Agent 当前无法接收聊天内容。"
        return false
      }
      notice = "已预填到 \(destination.title) 的输入框，等待你确认发送。"
      return true
    } catch {
      notice = "无法构造聊天上下文：\(error.localizedDescription)"
      return false
    }
  }

  func toggleAgentHistory() {
    let presents = !isAgentHistoryPresented
    dismissWorkspaceOverlays()
    isAgentHistoryPresented = presents
    if presents { reloadAgentHistory() }
  }

  /// 终端右键入口复用“发送到聊天”确认面板，并默认携带当前选区；发送前仍可改选
  /// transcript、目标 Agent 与 Comment，最终只预填输入框而不会自动回车。
  func sendTerminalSelectionToChat() {
    presentAgentChat()
  }

  /// 文件浏览器的 Send to Chat 只读取普通、非符号链接、UTF-8 小文件，并复用
  /// AgentChatContextBuilder 的控制字符清理、secret 遮盖和字节预算。路径作为来源说明
  /// 一并进入不可信区块，不会被当成系统指令。
  func sendFileToChat(_ url: URL) {
    guard let tab = selectedTab, let target = tab.preferredTerminalRuntime else {
      notice = "当前标签没有可接收聊天上下文的终端。"
      return
    }
    do {
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= AgentChatContextBudget().maximumItemBytes
      else {
        notice = "只能发送不超过 64 KiB 的普通文件。"
        return
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count == size, let text = String(data: data, encoding: .utf8) else {
        notice = "文件不是有效 UTF-8 文本，未添加到 Chat。"
        return
      }
      var builder = AgentChatContextBuilder()
      try builder.add(source: .fileSelection, content: "Path: \(url.path)\n\n\(text)")
      tab.setActivePane(target.id)
      appendToComposer(builder.renderedForPrompt, paneID: target.id)
    } catch {
      notice = "无法添加文件上下文：\(error.localizedDescription)"
    }
  }

  func reloadAgentHistory() {
    Task { @MainActor [weak self] in
      let histories = await AgentHistoryDiscoveryService.discover()
      guard let self else { return }
      self.agentHistories = histories
    }
  }

  func continueAgentSession(_ metadata: AgentSessionMetadata, kind: AgentContinuationKind) {
    do {
      let components = launchComponents(for: metadata.configuration.provider)
      let prefix = try AgentLaunchPrefix(
        executable: components[0], arguments: Array(components.dropFirst()))
      let plan = try AgentSessionCommandPlanner.plan(
        kind, session: metadata, launchPrefix: prefix)
      newTab(workingDirectory: metadata.projectDirectory, hasContent: true)
      let session = selectedTab?.activeSession
      let command = AgentShellCommandEncoder.encode(plan)
      Task { @MainActor [weak session] in
        try? await Task.sleep(for: .milliseconds(800))
        session?.send(command)
      }
      isAgentHistoryPresented = false
    } catch {
      notice = "无法继续 Agent 会话：\(error.localizedDescription)"
    }
  }

  /// 从命令面板或 Open Quickly 启动新的 Agent。自定义前缀按 argv 保存并由统一 Shell
  /// 编码器转义；这里只预填并执行用户明确选择的 Agent，不执行历史文件内容。
  func launchAgent(_ provider: AgentProvider) {
    let directory = selectedTab?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
    let components = launchComponents(for: provider)
    guard !components.isEmpty else { return }
    let command = WorkflowShellCommandEncoder.encode(components)
    newTab(workingDirectory: directory, hasContent: true)
    let session = selectedTab?.activeSession
    Task { @MainActor [weak session] in
      try? await Task.sleep(for: .milliseconds(800))
      session?.send(command)
    }
  }

  private func launchComponents(for provider: AgentProvider) -> [String] {
    guard let components = agentLaunchCommands[provider.rawValue],
      let executable = components.first,
      (try? AgentLaunchPrefix(
        executable: executable,
        arguments: Array(components.dropFirst())
      )) != nil
    else { return [provider.commandName] }
    return components
  }

  func composerState(for paneID: UUID) -> AgentComposerState {
    agentComposers[paneID] ?? AgentComposerState()
  }

  func promptQueue(for paneID: UUID) -> AgentPromptQueue {
    agentPromptQueues[paneID] ?? AgentPromptQueue()
  }

  @discardableResult
  func updateComposerDraft(_ value: String, paneID: UUID) -> Bool {
    var state = composerState(for: paneID)
    guard state.updateDraft(value) else {
      notice = "Composer 草稿超过大小上限。"
      return false
    }
    agentComposers[paneID] = state
    return true
  }

  func appendToComposer(_ value: String, paneID: UUID) {
    var state = composerState(for: paneID)
    let separator = state.draft.isEmpty ? "" : "\n"
    guard state.updateDraft(state.draft + separator + value) else {
      notice = "Composer 草稿超过大小上限。"
      return
    }
    agentComposers[paneID] = state
    isComposerPresented = true
  }

  func addComposerAttachment(_ url: URL, paneID: UUID) {
    do {
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      var state = composerState(for: paneID)
      try state.addAttachment(.init(
        fileURL: url,
        displayName: url.lastPathComponent,
        byteCount: values.fileSize ?? -1,
        isRegularFile: values.isRegularFile == true && values.isSymbolicLink != true
      ))
      agentComposers[paneID] = state
      objectWillChange.send()
    } catch {
      notice = "无法添加附件：\(error.localizedDescription)"
    }
  }

  func removeComposerAttachment(_ id: UUID, paneID: UUID) {
    var state = composerState(for: paneID)
    guard state.removeAttachment(id: id) != nil else { return }
    agentComposers[paneID] = state
    objectWillChange.send()
  }

  func setComposerPinned(_ value: Bool, paneID: UUID) {
    var state = composerState(for: paneID)
    state.setPinned(value)
    agentComposers[paneID] = state
    objectWillChange.send()
  }

  func floatComposer(paneID: UUID) {
    var state = composerState(for: paneID)
    state.float()
    agentComposers[paneID] = state
    objectWillChange.send()
  }

  func dockComposer(paneID: UUID) {
    var state = composerState(for: paneID)
    state.cancel()
    agentComposers[paneID] = state
    objectWillChange.send()
  }

  func closeComposer(paneID: UUID) {
    var state = composerState(for: paneID)
    state.cancel()
    agentComposers[paneID] = state
    isComposerPresented = false
  }

  func submitComposer(paneID: UUID) {
    guard let session = selectedTab?.runtime(for: paneID)?.terminalSession else { return }
    var state = composerState(for: paneID)
    do {
      let submission = try state.send()
      let rendered = try renderedComposerSubmission(submission)
      guard session.submitComposerText(rendered) else {
        agentComposers[paneID] = AgentComposerState(
          draft: submission.text,
          attachments: submission.attachments,
          isPinned: state.isPinned
        )
        notice = "当前终端无法接收 Composer 内容。"
        return
      }
      agentComposers[paneID] = state
      if !state.isPinned { isComposerPresented = false }
    } catch {
      notice = "Composer 发送失败：\(error.localizedDescription)"
    }
  }

  func queueComposer(paneID: UUID) {
    var composer = composerState(for: paneID)
    var queue = promptQueue(for: paneID)
    do {
      for prompt in try composer.takeQueuePrompts() {
        try queue.enqueue(.init(text: prompt))
      }
      agentComposers[paneID] = composer
      agentPromptQueues[paneID] = queue
      promptQueuePresentationChanged.send(presentedPromptQueuePaneID == paneID ? paneID : nil)
      objectWillChange.send()
      advancePromptQueue(paneID: paneID)
    } catch {
      notice = "加入队列失败：\(error.localizedDescription)"
    }
  }

  private func renderedComposerSubmission(_ submission: AgentComposerSubmission) throws -> String {
    var result = submission.text
    if !submission.attachments.isEmpty {
      result += result.isEmpty ? "" : "\n\n"
      result += "Attached files:\n"
    }
    for attachment in submission.attachments {
      let values = try attachment.fileURL.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.fileSize == attachment.byteCount
      else { throw AgentComposerError.attachmentNotRegularFile }
      result += "- \(attachment.fileURL.path)\n"
    }
    return result
  }

  private func agentChatDestinations() -> [AgentChatDestination] {
    tabs.flatMap { tab in
      tab.layout.allPanes.compactMap { descriptor in
        guard let session = tab.runtime(for: descriptor.id)?.terminalSession,
          session.statusIsRunning,
          let provider = session.activeAgentProvider,
          provider == .claudeCode || provider == .codex
        else { return nil }
        return AgentChatDestination(
          tabID: tab.id,
          paneID: descriptor.id,
          provider: provider,
          title: "\(tab.windowTitle) · \(provider.commandName)"
        )
      }
    }
  }

  /// 全局跳转必须同时恢复标签与 Pane 焦点；终端行号仅在目标仍位于 scrollback 时
  /// 滚动，已裁剪时仍可安全聚焦会话而不会跳到错误文本。
  func revealWorkspaceLocation(tabID: UUID, paneID: UUID, absoluteRow: Int? = nil) {
    guard let tab = tabs.first(where: { $0.id == tabID }), tab.runtime(for: paneID) != nil else {
      return
    }
    select(tab)
    dismissWorkspaceOverlays()
    // 标签切换会在下一轮主队列重建 Pane 视图；延后行跳转，确保编辑器 NSTextView
    // 已注册。终端 Session 长期存活，同一路径同样安全。
    DispatchQueue.main.async { [weak tab] in
      guard let tab, let runtime = tab.runtime(for: paneID) else { return }
      tab.setActivePane(paneID)
      guard let absoluteRow else { return }
      if let session = runtime.terminalSession {
        _ = session.revealAbsoluteRow(absoluteRow)
      } else if runtime.descriptor.kind == .editor {
        tab.revealDocumentLine(absoluteRow + 1, paneID: paneID)
      }
    }
  }

  /// 聚焦指定 Pane 并把提示词粘贴进其终端输入行（不自动回车），供 Open Quickly
  /// 「当前」页的提示词条目复用历史 prompt；多行文本经 bracketed paste 防注入。
  func insertPromptIntoPane(tabID: UUID, paneID: UUID, text: String) {
    guard let tab = tabs.first(where: { $0.id == tabID }),
      let session = tab.runtime(for: paneID)?.terminalSession
    else { return }
    revealWorkspaceLocation(tabID: tabID, paneID: paneID)
    // 视图重建在下一轮主队列完成，延后粘贴确保终端已是 first responder。
    DispatchQueue.main.async {
      session.pastePromptText(text)
    }
  }

  /// 生成全局搜索快照。终端读取有界 scrollback，编辑器只读取已加载内存缓冲；不会
  /// 为搜索隐式打开磁盘文件，也不会把用户内容写入持久化索引。
  func workspaceSearchDocuments() -> [WorkspaceSearchDocument] {
    tabs.flatMap { tab in
      tab.layout.allPanes.compactMap { pane in
        guard let runtime = tab.runtime(for: pane.id) else { return nil }
        let lines: [String]
        let firstAbsoluteRow: Int
        switch pane.kind {
        case .terminal:
          let snapshot = runtime.terminalSession?.textSnapshot()
          lines = snapshot?.lines ?? []
          firstAbsoluteRow = snapshot?.firstAbsoluteRow ?? 0
        case .editor:
          lines = runtime.documentText.split(
            separator: "\n", omittingEmptySubsequences: false
          ).map(String.init)
          firstAbsoluteRow = 0
        case .preview, .fileBrowser:
          return nil
        }
        return WorkspaceSearchDocument(
          tabID: tab.id,
          paneID: pane.id,
          title: "\(tab.title) · \(pane.kind.rawValue)",
          firstAbsoluteRow: firstAbsoluteRow,
          lines: lines
        )
      }
    }
  }

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
    _ = openResource(url, mode: .view, placement: .split(.right))
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
    panel.nameFieldStringValue = "\(tab.title).ottyrecipe"
    let scope = NSPopUpButton()
    scope.addItems(withTitles: ["当前标签", "当前窗口", "仅命令"])
    let content = NSPopUpButton()
    content.addItems(withTitles: ["布局", "布局与命令", "布局、命令与 Scrollback"])
    content.selectItem(at: 1)
    let accessory = NSStackView(views: [
      makeRecipeAccessoryRow(title: "范围", control: scope),
      makeRecipeAccessoryRow(title: "内容", control: content),
    ])
    accessory.orientation = .vertical
    accessory.spacing = 8
    accessory.translatesAutoresizingMaskIntoConstraints = false
    accessory.widthAnchor.constraint(equalToConstant: 320).isActive = true
    panel.accessoryView = accessory
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension.lowercased() != "ottyrecipe" {
      url.appendPathExtension("ottyrecipe")
    }
    do {
      let selectedScope: WorkflowRecipeScope = switch scope.indexOfSelectedItem {
      case 1: .window
      case 2: .commands
      default: .tab
      }
      let selectedContent: WorkflowRecipeContent = switch content.indexOfSelectedItem {
      case 0: .layoutOnly
      case 2: .includeScrollback
      default: .includeCommands
      }
      let recipe = try makeWorkflowRecipe(
        name: tab.title,
        scope: selectedScope,
        content: selectedContent
      )
      try WorkflowRecipeTOML.save(recipe, to: url)
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

  /// 统一的外部打开入口：ssh、聚焦深链、目录与两代 Recipe 文件。
  func handleOpenURL(_ url: URL) {
    if url.scheme?.lowercased() == "ssh" {
      openSSHURL(url)
      return
    }
    if url.scheme?.lowercased() == "otty" {
      handleWorkflowDeepLink(url)
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
    guard ["asterrecipe", "ottyrecipe"].contains(url.pathExtension.lowercased()) else {
      notice = "Aster 暂不支持打开该类型文件。"
      return
    }
    openRecipe(from: url)
  }

  private func handleWorkflowDeepLink(_ url: URL) {
    do {
      switch try WorkflowDeepLink.parse(url.absoluteString) {
      case .focusWindow:
        // 当前版本由 AppDelegate 管理一个工作区窗口；Window selector 仍只移动焦点。
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
      case .focusTab(let selector):
        let tab: TerminalTabItem?
        switch selector {
        case .index(let oneBased):
          tab = tabs.indices.contains(oneBased - 1) ? tabs[oneBased - 1] : nil
        case .identifier(let identifier):
          let raw = identifier.hasPrefix("t_") ? String(identifier.dropFirst(2)) : identifier
          tab = UUID(uuidString: raw).flatMap { id in tabs.first { $0.id == id } }
        }
        if let tab { select(tab) } else { notice = "深链指定的标签不存在。" }
      case .focusPane(let selector):
        let match: (TerminalTabItem, UUID)? = tabs.lazy.compactMap { tab in
          switch selector {
          case .identifier(let identifier):
            let raw = identifier.hasPrefix("p_") ? String(identifier.dropFirst(2)) : identifier
            guard let id = UUID(uuidString: raw), tab.runtime(for: id) != nil else { return nil }
            return (tab, id)
          case .sessionIdentifier(let identifier):
            guard let pane = tab.runtimes.first(where: {
              $0.value.terminalSession?.id.uuidString == identifier
            }) else { return nil }
            return (tab, pane.key)
          }
        }.first
        if let (tab, paneID) = match {
          revealWorkspaceLocation(tabID: tab.id, paneID: paneID)
        } else {
          notice = "深链指定的 Pane 不存在。"
        }
      }
    } catch {
      notice = "无效或不受支持的 Aster 深链。"
    }
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

  /// Open Quickly 的 SSH 条目与 `ssh://` 使用同一安全语义：只预填命令，不自动执行。
  func openSSHHost(_ host: SSHHost) {
    guard Self.isSafeSSHComponent(host.alias, allowColon: false) else {
      notice = "SSH 配置包含不安全的主机字段。"
      return
    }
    // 使用 Host alias，才能保留 ProxyJump、IdentityFile 等完整 SSH 配置；显式展开
    // HostName/User/Port 反而会绕过这些配置。命令仍不附带回车。
    let command = "ssh \(host.alias)"
    newTab(hasContent: true)
    let tab = selectedTab
    Task { @MainActor [weak tab] in
      try? await Task.sleep(for: .milliseconds(800))
      tab?.activeSession?.typeText(command)
    }
  }

  func openRecipe(from url: URL) {
    if url.pathExtension.lowercased() == "ottyrecipe" {
      openWorkflowRecipe(from: url)
      return
    }
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

  private func makeRecipeAccessoryRow(title: String, control: NSView) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.alignment = .right
    label.translatesAutoresizingMaskIntoConstraints = false
    label.widthAnchor.constraint(equalToConstant: 72).isActive = true
    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.spacing = 8
    return row
  }

  private func makeWorkflowRecipe(
    name: String,
    scope: WorkflowRecipeScope,
    content: WorkflowRecipeContent
  ) throws -> WorkflowRecipe {
    let sourceTabs = scope == .window ? tabs : selectedTab.map { [$0] } ?? []
    if scope == .commands {
      let candidates = sourceTabs.flatMap { tab in
        tab.layout.allPanes.flatMap { pane in
          tab.runtime(for: pane.id)?.terminalSession?.recipeCommandCandidates ?? []
        }
      }
      return WorkflowRecipe(
        name: name,
        scope: .commands,
        content: content == .layoutOnly ? .includeCommands : content,
        commands: try WorkflowRecipeCommandCapture.commands(from: candidates)
      )
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let recipeTabs = try sourceTabs.map { tab in
      let portableLayout = WorkflowRecipeWorkspaceMapper.makePortable(tab.layout, home: home)
      let panes = try portableLayout.allPanes.enumerated().map { index, pane in
        let session = tab.runtime(for: pane.id)?.terminalSession
        let commands = content == .layoutOnly
          ? [] : try WorkflowRecipeCommandCapture.commands(
            from: session?.recipeCommandCandidates ?? [])
        let scrollback = content == .includeScrollback
          ? session?.textSnapshot().lines.joined(separator: "\n") : nil
        return WorkflowRecipePane(
          workingDirectory: pane.workingDirectory,
          kind: pane.kind,
          resourcePath: pane.resourcePath,
          split: index == 0 ? nil : .right,
          size: nil,
          commands: commands,
          scrollback: scrollback
        )
      }
      return WorkflowRecipeTab(title: tab.title, panes: panes, layout: portableLayout)
    }
    return WorkflowRecipe(
      name: name,
      scope: scope,
      content: content,
      tabs: recipeTabs
    )
  }

  private func openWorkflowRecipe(from url: URL) {
    do {
      let envelope = try WorkflowRecipeTOML.load(from: url)
      let settings = workflowRecipeReplaySettings
      let initial = try WorkflowRecipeOpenPlanner.plan(
        envelope,
        settings: settings,
        trustStore: &workflowRecipeTrust
      )
      let choice: WorkflowRecipeTrustChoice?
      if case .reviewRequired(let digest, let commands) = initial {
        choice = reviewExternalRecipe(digest: digest, commands: commands)
        guard choice != .cancel else { return }
      } else {
        choice = nil
      }
      let decision = try WorkflowRecipeOpenPlanner.plan(
        envelope,
        settings: settings,
        trustStore: &workflowRecipeTrust,
        trustChoice: choice
      )
      persistWorkflowRecipeTrust()
      guard case .replay(let replayPlan) = decision else { return }
      let permitsReplay = confirmRecipeReplayIfNeeded(replayPlan, recipe: envelope.recipe)
      let confirmsEveryCommand = WorkflowRecipeReplayExecutionPolicy.confirmsEveryCommand(replayPlan)
      let context = WorkflowPortablePathContext(
        currentFolder: URL(fileURLWithPath: selectedTab?.workingDirectory ?? NSHomeDirectory()),
        homeFolder: FileManager.default.homeDirectoryForCurrentUser,
        recipeLocation: url.deletingLastPathComponent()
      )
      let recipeTabs: [WorkflowRecipeTab]
      if envelope.recipe.scope == .commands {
        recipeTabs = [WorkflowRecipeTab(
          title: envelope.recipe.name,
          panes: [WorkflowRecipePane(
            workingDirectory: WorkflowPortablePathVariable.currentFolder.rawValue,
            commands: envelope.recipe.commands
          )]
        )]
      } else {
        recipeTabs = envelope.recipe.tabs
      }
      for recipeTab in recipeTabs {
        guard let first = recipeTab.panes.first else { continue }
        let tab: TerminalTabItem
        if let portableLayout = recipeTab.layout {
          let resolvedLayout = try WorkflowRecipeWorkspaceMapper.resolve(
            portableLayout, context: context)
          let layout = WorkflowRecipeWorkspaceMapper.instantiate(resolvedLayout)
          guard let directory = layout.allPanes.first?.workingDirectory else { continue }
          tab = TerminalTabItem(title: recipeTab.title, workingDirectory: directory, layout: layout)
        } else {
          let firstDescriptor = try WorkflowRecipeWorkspaceMapper.resolve(first, context: context)
          tab = TerminalTabItem(
            title: recipeTab.title,
            workingDirectory: firstDescriptor.workingDirectory,
            layout: .leaf(firstDescriptor)
          )
          for pane in recipeTab.panes.dropFirst() {
            let descriptor = try WorkflowRecipeWorkspaceMapper.resolve(pane, context: context)
            tab.split(
              direction: pane.split ?? .right,
              kind: descriptor.kind,
              resourcePath: descriptor.resourcePath,
              workingDirectory: descriptor.workingDirectory
            )
          }
        }
        insertTab(tab, hasContent: true)
        if permitsReplay {
          for (pane, descriptor) in zip(recipeTab.panes, tab.layout.allPanes) where !pane.commands.isEmpty {
            pendingRecipeCommands[descriptor.id] = pane.commands
            if confirmsEveryCommand { recipeCommandConfirmationPaneIDs.insert(descriptor.id) }
          }
        }
      }
      persistWorkspace()
      notice = "已打开 \(envelope.recipe.name)"
    } catch {
      notice = "Recipe 打开失败：\(error.localizedDescription)"
    }
  }

  private func reviewExternalRecipe(
    digest: String,
    commands: [String]
  ) -> WorkflowRecipeTrustChoice {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "外部 Recipe 包含将要运行的命令"
    alert.informativeText = "SHA-256: \(digest)\n请在下方逐条检查全部命令。"
    alert.accessoryView = workflowRecipeCommandReviewView(commands: commands)
    alert.addButton(withTitle: "仅运行一次")
    alert.addButton(withTitle: "始终信任此内容")
    alert.addButton(withTitle: "取消")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .runOnce
    case .alertSecondButtonReturn: return .alwaysTrust
    default: return .cancel
    }
  }

  private func confirmRecipeReplayIfNeeded(
    _ plan: WorkflowRecipeReplayPlan,
    recipe: WorkflowRecipe
  ) -> Bool {
    switch plan {
    case .skip:
      return false
    case .automatic:
      return true
    case .oneByOne:
      // 每条命令在真正写入 PTY 前单独确认，不能在这里一次性授权全部命令。
      return true
    case .confirmOnce:
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "运行 Recipe 命令？"
      alert.informativeText = "请在下方逐条检查全部命令。"
      alert.accessoryView = workflowRecipeCommandReviewView(commands: recipe.allCommands)
      alert.addButton(withTitle: "运行")
      alert.addButton(withTitle: "仅打开布局")
      return alert.runModal() == .alertFirstButtonReturn
    }
  }

  /// 固定尺寸滚动区既完整呈现最多 128 条合法命令，又不会让 NSAlert 高度超出屏幕。
  /// 文本只读且可选择，用户可在授权前复制到其它审查工具。
  private func workflowRecipeCommandReviewView(commands: [String]) -> NSView {
    let textView = NSTextView(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.string = WorkflowRecipeCommandReview.text(commands: commands)
    textView.textContainerInset = NSSize(width: 8, height: 8)

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    return scrollView
  }

  private func persistWorkflowRecipeTrust() {
    guard let data = try? JSONEncoder().encode(workflowRecipeTrust) else { return }
    defaults.set(data, forKey: workflowRecipeTrustKey)
  }

  func startPendingRecipeCommands(paneID: UUID) {
    guard pendingRecipeCommands[paneID]?.isEmpty == false,
      activeRecipeReplayPaneIDs.insert(paneID).inserted
    else { return }
    dispatchNextRecipeCommand(paneID: paneID)
  }

  private func dispatchNextRecipeCommand(paneID: UUID) {
    guard activeRecipeReplayPaneIDs.contains(paneID) else { return }
    guard var commands = pendingRecipeCommands[paneID], !commands.isEmpty else {
      pendingRecipeCommands[paneID] = nil
      activeRecipeReplayPaneIDs.remove(paneID)
      recipeCommandConfirmationPaneIDs.remove(paneID)
      return
    }
    guard
      let session = tabs.lazy.compactMap({ $0.runtime(for: paneID)?.terminalSession }).first,
      session.statusIsRunning
    else { return }
    let command = commands.removeFirst()
    if recipeCommandConfirmationPaneIDs.contains(paneID) {
      switch confirmSingleRecipeCommand(command) {
      case .run:
        break
      case .skip:
        pendingRecipeCommands[paneID] = commands
        // 下一轮主队列再询问后续命令，避免连续模态对话框形成递归调用栈。
        DispatchQueue.main.async { [weak self] in
          self?.dispatchNextRecipeCommand(paneID: paneID)
        }
        return
      case .stop:
        pendingRecipeCommands[paneID] = nil
        activeRecipeReplayPaneIDs.remove(paneID)
        recipeCommandConfirmationPaneIDs.remove(paneID)
        return
      }
    }
    guard session.sendRecipeCommand(command) else { return }
    pendingRecipeCommands[paneID] = commands
  }

  private enum SingleRecipeCommandDecision {
    case run
    case skip
    case stop
  }

  /// `.oneByOne` 的最后授权点。对话框完整显示当前命令，并提供跳过与停止整组重放，
  /// 因而用户永远不会因确认前一条而隐式授权后一条。
  private func confirmSingleRecipeCommand(_ command: String) -> SingleRecipeCommandDecision {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "运行下一条 Recipe 命令？"
    alert.informativeText = command
    alert.addButton(withTitle: "运行此命令")
    alert.addButton(withTitle: "跳过")
    alert.addButton(withTitle: "停止重放")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .run
    case .alertSecondButtonReturn: return .skip
    default: return .stop
    }
  }

  /// 执行已经由 `WorkflowCLIParser` 验证的动作。所有写 Pane 的动作再次检查用户权限和
  /// 敏感会话；`run/exec` 通过 completion 延迟返回，其它动作在本次调用内完成。
  func executeWorkflowCLI(
    _ action: WorkflowCLIAction,
    standardInput: Data? = nil,
    allowSendKeys: Bool,
    allowSensitiveSessions: Bool,
    completion: @escaping (WorkflowCLIExecutionResponse) -> Void
  ) {
    switch action {
    case .open(let request):
      guard isExistingDirectory(request.path) else {
        completion(.failure("目录不存在或不是普通目录：\(request.path)\n", exitCode: 66))
        return
      }
      newTab(workingDirectory: request.path, hasContent: true)
      if let title = request.title { selectedTab?.setTabTitleOverride(.name(title)) }
      if let command = request.command, let session = selectedTab?.activeSession {
        Task { @MainActor [weak session] in
          try? await Task.sleep(for: .milliseconds(350))
          session?.send(command)
        }
      }
      completion(.success())

    case .openTarget(let request):
      completion(openWorkflowCLITarget(request))

    case .watch:
      // `aster watch` 由当前 TTY 中的 shell wrapper 直接执行，应用端没有目标 PTY。
      completion(.failure("watch 必须由已安装的 aster CLI wrapper 执行。\n", exitCode: 64))

    case .jump(let request):
      let current = selectedTab?.workingDirectory
      let target: String?
      if let query = request.query {
        target = frequentFolderMatches(query: query, limit: 1, excluding: current).first?.path
      } else if current == NSHomeDirectory() {
        target = frequentFolderMatches(limit: 1, excluding: current).first?.path
      } else {
        target = NSHomeDirectory()
      }
      guard let target else {
        completion(.failure("没有匹配的常用目录。\n", exitCode: 1))
        return
      }
      if request.noCD {
        completion(.success(target + "\n"))
      } else if let session = selectedTab?.activeSession,
        session.sendAutomationBytes(Array(("cd " + WorkflowShellCommandEncoder.quote(target) + "\n").utf8))
      {
        completion(.success(target + "\n"))
      } else {
        completion(.failure("当前没有可写入的活动终端。\n", exitCode: 69))
      }

    case .learn(let request):
      let target = request.target ?? selectedTab?.workingDirectory ?? NSHomeDirectory()
      let expanded = resolveCLIPath(target, relativeTo: selectedTab?.workingDirectory)
      if isExistingDirectory(expanded) {
        completion(learnFolder(expanded) ? .success(expanded + "\n") : .failure("无法学习该目录。\n"))
      } else if AutocompleteService.shared?.pin(
        command: target,
        directory: selectedTab?.workingDirectory ?? NSHomeDirectory()
      ) == true {
        completion(.success(target + "\n"))
      } else {
        completion(.failure("无法学习该目录或命令。\n"))
      }

    case .ignore(let request):
      let expanded = resolveCLIPath(request.target, relativeTo: selectedTab?.workingDirectory)
      guard isExistingDirectory(expanded) || frequentFolderMatches().contains(where: { $0.path == expanded })
      else {
        completion(.failure("当前只支持忽略 Frequent Folders 中的目录。\n", exitCode: 64))
        return
      }
      completion(ignoreFolder(expanded) ? .success() : .failure("该目录已经被忽略。\n"))

    case .capture(let request):
      guard let (_, runtime) = workflowCLIRuntime(selector: request.selector),
        let session = runtime.terminalSession
      else {
        completion(.failure("找不到目标 Pane。\n", exitCode: 69))
        return
      }
      let snapshot = session.textSnapshot()
      let lines = request.lines.map { Array(snapshot.lines.suffix($0)) } ?? snapshot.lines
      completion(.success(formatCapture(lines: lines, format: request.format)))

    case .send(let request):
      guard let (_, runtime) = workflowCLIRuntime(selector: request.selector),
        let session = runtime.terminalSession
      else {
        completion(.failure("找不到目标 Pane。\n", exitCode: 69))
        return
      }
      guard permitsWorkflowCLIWrite(
        session: session,
        allowSendKeys: allowSendKeys,
        allowSensitiveSessions: allowSensitiveSessions,
        completion: completion
      ) else { return }
      do {
        let bytes = try workflowCLIInputBytes(request.input, standardInput: standardInput)
        completion(session.sendAutomationBytes(bytes)
          ? .success() : .failure("无法写入目标 Pane。\n", exitCode: 69))
      } catch {
        completion(.failure("输入无效或超过大小上限。\n", exitCode: 65))
      }

    case .run(let request):
      beginWorkflowCLICommand(
        selector: request.selector,
        arguments: request.command,
        kind: .run(format: request.format),
        allowSendKeys: allowSendKeys,
        allowSensitiveSessions: allowSensitiveSessions,
        completion: completion
      )

    case .exec(let request):
      beginWorkflowCLIExec(
        request,
        allowSendKeys: allowSendKeys,
        allowSensitiveSessions: allowSensitiveSessions,
        completion: completion
      )
    }
  }

  private func openWorkflowCLITarget(
    _ request: WorkflowCLIOpenTargetAction
  ) -> WorkflowCLIExecutionResponse {
    switch request.target {
    case .webURL(let value):
      guard let url = URL(string: value), NSWorkspace.shared.open(url) else {
        return .failure("无法打开网页目标。\n", exitCode: 69)
      }
      return .success()
    case .remotePath:
      return .failure("远程文件 Pane 仍属于上游开发中能力。\n", exitCode: 69)
    case .localPath(let path):
      let url = URL(fileURLWithPath: path)
      let placement: WorkspaceResourcePlacement = switch request.placement {
      case .split(let direction): .split(direction)
      case .newTab: .newTab
      case .newWindow: .newWindow
      }
      let mode: WorkspaceResourceOpenMode = request.mode == .edit ? .edit : .view
      guard openResource(url, mode: mode, placement: placement) else {
        return .failure("目标不是可安全打开的本地文件或目录。\n", exitCode: 66)
      }
      return .success()
    }
  }

  private func workflowCLIRuntime(
    selector: String?
  ) -> (TerminalTabItem, WorkspacePaneRuntime)? {
    guard let selector else {
      guard let tab = selectedTab, let runtime = tab.activeRuntime else { return nil }
      return (tab, runtime)
    }
    let rawIdentifier = selector.hasPrefix("p_") ? String(selector.dropFirst(2)) : selector
    if let paneID = UUID(uuidString: rawIdentifier) {
      for tab in tabs {
        if let runtime = tab.runtime(for: paneID) { return (tab, runtime) }
      }
    }
    for tab in tabs {
      if let runtime = tab.runtimes.values.first(where: {
        $0.terminalSession?.id.uuidString == selector
      }) { return (tab, runtime) }
    }
    return nil
  }

  private func permitsWorkflowCLIWrite(
    session: TerminalSession,
    allowSendKeys: Bool,
    allowSensitiveSessions: Bool,
    completion: (WorkflowCLIExecutionResponse) -> Void
  ) -> Bool {
    guard allowSendKeys else {
      completion(.failure("IPC Allow Send Keys 未开启。\n", exitCode: 77))
      return false
    }
    guard !session.isSensitiveAutomationSession || allowSensitiveSessions else {
      completion(.failure("敏感会话还需要开启 IPC Allow Sensitive Sessions。\n", exitCode: 77))
      return false
    }
    return true
  }

  private func workflowCLIInputBytes(
    _ input: WorkflowCLISendInput,
    standardInput: Data?
  ) throws -> [UInt8] {
    switch input {
    case .text(let value):
      return try WorkflowCLIInputDecoder.decode(value)
    case .keys(let names):
      return try names.flatMap { name -> [UInt8] in
        switch name.lowercased() {
        case "enter", "return": [13]
        case "tab": [9]
        case "escape", "esc": [27]
        case "backspace": [127]
        case "ctrl-c", "control-c": [3]
        case "up": Array("\u{1B}[A".utf8)
        case "down": Array("\u{1B}[B".utf8)
        case "right": Array("\u{1B}[C".utf8)
        case "left": Array("\u{1B}[D".utf8)
        default: throw WorkflowCLIInputDecodeError.invalidEscape
        }
      }
    case .file(let path):
      let url = URL(fileURLWithPath: path)
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= WorkflowCLIInputDecoder.maximumBytes
      else { throw WorkflowCLIInputDecodeError.outputTooLarge }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count == size else { throw WorkflowCLIInputDecodeError.outputTooLarge }
      return Array(data)
    case .standardInput:
      guard let standardInput, standardInput.count <= WorkflowCLIInputDecoder.maximumBytes else {
        throw WorkflowCLIInputDecodeError.outputTooLarge
      }
      return Array(standardInput)
    }
  }

  private func beginWorkflowCLICommand(
    selector: String?,
    arguments: [String],
    kind: PendingWorkflowCLIKind,
    allowSendKeys: Bool,
    allowSensitiveSessions: Bool,
    completion: @escaping (WorkflowCLIExecutionResponse) -> Void
  ) {
    guard let (_, runtime) = workflowCLIRuntime(selector: selector),
      let session = runtime.terminalSession
    else {
      completion(.failure("找不到目标 Pane。\n", exitCode: 69))
      return
    }
    guard permitsWorkflowCLIWrite(
      session: session,
      allowSendKeys: allowSendKeys,
      allowSensitiveSessions: allowSensitiveSessions,
      completion: completion
    ) else { return }
    guard session.shellIntegrationDetected, !session.hasRunningCommand,
      pendingWorkflowCLICommands[runtime.id] == nil
    else {
      completion(.failure("目标 Pane 必须启用 Shell Integration 并停在空闲 Prompt。\n", exitCode: 75))
      return
    }
    let command = WorkflowShellCommandEncoder.encode(arguments)
    pendingWorkflowCLICommands[runtime.id] = PendingWorkflowCLICommand(
      command: command,
      startedAt: Date(),
      kind: kind,
      completion: completion
    )
    guard session.sendAutomationBytes(Array((command + "\n").utf8)) else {
      pendingWorkflowCLICommands[runtime.id] = nil
      completion(.failure("无法写入目标 Pane。\n", exitCode: 69))
      return
    }
  }

  private func beginWorkflowCLIExec(
    _ request: WorkflowCLIExecAction,
    allowSendKeys: Bool,
    allowSensitiveSessions: Bool,
    completion: @escaping (WorkflowCLIExecutionResponse) -> Void
  ) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aster-pane-exec-\(UUID().uuidString)", isDirectory: true)
    let output = directory.appendingPathComponent("stdout")
    let error = directory.appendingPathComponent("stderr")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      guard FileManager.default.createFile(atPath: output.path, contents: nil),
        FileManager.default.createFile(atPath: error.path, contents: nil)
      else { throw CocoaError(.fileWriteUnknown) }
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: error.path)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      completion(.failure("无法创建受保护的输出缓冲。\n", exitCode: 73))
      return
    }
    let command = WorkflowShellCommandEncoder.encode(request.command)
    let script = "\(command) >\(WorkflowShellCommandEncoder.quote(output.path)) 2>\(WorkflowShellCommandEncoder.quote(error.path)); __aster_status=$?; /bin/cat \(WorkflowShellCommandEncoder.quote(output.path)); /bin/cat \(WorkflowShellCommandEncoder.quote(error.path)) >&2; exit \"$__aster_status\""
    beginWorkflowCLICommand(
      selector: request.selector,
      arguments: ["/bin/sh", "-c", script],
      kind: .exec(
        format: request.format,
        temporaryDirectory: directory,
        standardOutputURL: output,
        standardErrorURL: error
      ),
      allowSendKeys: allowSendKeys,
      allowSensitiveSessions: allowSensitiveSessions
    ) { response in
      if response.exitCode == 75 || response.exitCode == 77 || response.exitCode == 69 {
        try? FileManager.default.removeItem(at: directory)
      }
      completion(response)
    }
  }

  private func completeWorkflowCLICommand(paneID: UUID) {
    // Shell Integration 的完成标记与前台进程状态可能在相邻回调到达。只有退出状态
    // 已经可见时才消费 pending；否则保留请求等待下一次完成通知，避免 CLI 永久挂起。
    guard let pending = pendingWorkflowCLICommands[paneID],
      let (_, runtime) = workflowCLIRuntime(selector: "p_\(paneID.uuidString)"),
      let status = runtime.terminalSession?.lastCommandExitStatus
    else { return }
    pendingWorkflowCLICommands[paneID] = nil
    let duration = Int(Date().timeIntervalSince(pending.startedAt) * 1_000)
    switch pending.kind {
    case .run(let format):
      if format == .json {
        let state = status == 0 ? "succeed" : "error"
        pending.completion(.init(
          exitCode: Int32(status),
          output: "{\"state\":\"\(state)\",\"exit_code\":\(status),\"command\":\(jsonString(pending.command)),\"duration_ms\":\(duration)}\n"
        ))
      } else {
        pending.completion(.init(
          exitCode: Int32(status), output: status == 0 ? "succeed\n" : "error\n"))
      }
    case .exec(let format, let directory, let outputURL, let errorURL):
      defer { try? FileManager.default.removeItem(at: directory) }
      let stdout: String
      let stderr: String
      do {
        stdout = try WorkflowCLIOutputReader.read(
          outputURL, maximumBytes: AsterCLIRequestService.maximumResponseStreamBytes)
        stderr = try WorkflowCLIOutputReader.read(
          errorURL, maximumBytes: AsterCLIRequestService.maximumResponseStreamBytes)
      } catch {
        pending.completion(.failure(
          "aster: \(error.localizedDescription)\n",
          exitCode: 74
        ))
        return
      }
      if format == .json {
        pending.completion(.init(
          exitCode: Int32(status),
          output: "{\"exit_code\":\(status),\"stdout\":\(jsonString(stdout)),\"stderr\":\(jsonString(stderr)),\"stderr_is_tty\":false,\"duration_ms\":\(duration)}\n"
        ))
      } else {
        pending.completion(.init(
          exitCode: Int32(status),
          standardOutput: stdout,
          standardError: stderr
        ))
      }
    }
  }

  private func formatCapture(lines: [String], format: WorkflowCLIOutputFormat) -> String {
    if format == .json {
      return "{\"lines\":[\(lines.map(jsonString).joined(separator: ","))]}\n"
    }
    return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
  }

  private func jsonString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
    return String(decoding: data, as: UTF8.self)
  }

  private func resolveCLIPath(_ path: String, relativeTo directory: String?) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
    return URL(
      fileURLWithPath: expanded,
      relativeTo: URL(fileURLWithPath: directory ?? NSHomeDirectory(), isDirectory: true)
    ).standardizedFileURL.path
  }

  var paletteCommands: [PaletteCommand] {
    var commands: [PaletteCommand] = [
      .init(id: "new-window", title: "新建窗口", keywords: ["new", "window"], scope: .application),
      .init(id: "new-tab", title: "新建标签页", keywords: ["new", "tab"], scope: .window),
      .init(id: "reopen-tab", title: "重新打开最近关闭的标签页", keywords: ["reopen", "closed", "tab"], scope: .window),
      .init(id: "rename-tab", title: "重命名标签页", keywords: ["rename", "prefix", "title"], scope: .window),
      .init(id: "open-file", title: "打开文件", keywords: ["edit", "file"], scope: .window),
      .init(id: "open-folder", title: "打开文件夹", keywords: ["browser", "folder"], scope: .window),
      .init(id: "split-right", title: "向右拆分", keywords: ["pane", "split"]),
      .init(id: "split-left", title: "向左拆分", keywords: ["pane", "split"]),
      .init(id: "split-down", title: "向下拆分", keywords: ["pane", "split"]),
      .init(id: "split-up", title: "向上拆分", keywords: ["pane", "split"]),
      .init(id: "zoom-pane", title: "缩放拆分", keywords: ["zoom", "pane", "maximize"]),
      .init(id: "equalize-splits", title: "等分拆分", keywords: ["pane", "split", "equal"]),
      .init(id: "focus-next-pane", title: "聚焦下一个面板", keywords: ["pane", "focus"]),
      .init(id: "files", title: "新建文件浏览器", keywords: ["tree", "files"]),
      .init(id: "find", title: "在当前 Pane 中查找", keywords: ["search", "buffer"]),
      .init(id: "global-find", title: "在全部 Pane 中查找", keywords: ["search", "workspace"], scope: .window),
      .init(id: "open-quickly", title: "Open Quickly", keywords: ["jump", "recent", "ssh"], scope: .window),
      .init(id: "inspector", title: "切换详情面板", keywords: ["git", "info", "outline"], scope: .window),
      .init(id: "pin-window", title: "切换窗口置顶", keywords: ["pin", "floating"], scope: .window),
      .init(id: "picture-in-picture", title: "当前 Pane 画中画", keywords: ["pip", "float"], scope: .window),
      .init(id: "picture-in-picture-follow", title: "画中画跟随活动 Pane", keywords: ["pip", "follow"], scope: .window),
      .init(id: "save-recipe", title: "保存为 Recipe", keywords: ["workspace"], scope: .window),
      .init(id: "open-recipe", title: "打开 Recipe", keywords: ["workspace"], scope: .window),
      .init(id: "interrupt", title: "中断当前命令", keywords: ["control c", "stop"]),
      .init(id: "vi-mode", title: "进入 Vi Mode", keywords: ["terminal", "keyboard", "navigate"]),
      .init(id: "mark-mode", title: "进入 Mark Mode", keywords: ["terminal", "select", "copy"]),
      .init(id: "hint-mode", title: "打开链接（Hint Mode）", keywords: ["terminal", "url", "path"]),
      .init(id: "read-only", title: "切换只读模式", keywords: ["terminal", "lock", "input"]),
      .init(id: "composer", title: "切换 Composer", keywords: ["agent", "prompt", "queue"]),
      .init(id: "prompt-queue", title: "切换 Prompt 队列", keywords: ["agent", "prompt", "queue"]),
      .init(id: "send-to-chat", title: "发送到聊天", keywords: ["agent", "selection", "transcript", "context"]),
      .init(id: "agent-history", title: "Agent 历史", keywords: ["resume", "fork", "transcript"], scope: .window),
      .init(id: "close-pane", title: "关闭当前面板", keywords: ["pane", "close"]),
      .init(id: "close-tab", title: "关闭标签页", keywords: ["tab", "close"], scope: .window),
      .init(id: "settings", title: "打开设置", keywords: ["preferences"], scope: .application),
    ]
    commands.insert(
      contentsOf: enabledAgentProviders.map { provider in
        PaletteCommand(
          id: "launch-agent:\(provider.rawValue)",
          title: "启动 \(provider.commandName)",
          keywords: ["agent", "new", provider.rawValue],
          scope: .window
        )
      },
      at: max(commands.count - 1, 0)
    )
    return commands
  }

  func performPaletteCommand(_ command: PaletteCommand, dismissesPalette: Bool = true) {
    switch command.id {
    case "new-window": _ = onRequestNewWindow?(nil)
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
    case "find": isFindPresented = true
    case "global-find": toggleGlobalFind()
    case "open-quickly": toggleOpenQuickly()
    case "inspector": toggleInspector()
    case "pin-window": onRequestToggleWindowPin?()
    case "picture-in-picture": onRequestPictureInPicture?(false)
    case "picture-in-picture-follow": onRequestPictureInPicture?(true)
    case "save-recipe": saveRecipe()
    case "open-recipe": openRecipe()
    case "interrupt": selectedTab?.activeSession?.interrupt()
    case "vi-mode": selectedTab?.activeSession?.enterViMode()
    case "mark-mode": selectedTab?.activeSession?.enterMarkMode()
    case "hint-mode": selectedTab?.activeSession?.openHintMode()
    case "read-only": toggleActivePaneReadOnly()
    case "composer": toggleComposer()
    case "prompt-queue": togglePromptQueue()
    case "send-to-chat": presentAgentChat()
    case "agent-history": toggleAgentHistory()
    case "close-pane": closeActivePane()
    case "close-tab": closeSelectedTab()
    case "settings": (NSApp.delegate as? AsterAppDelegate)?.showSettings(nil)
    default:
      if command.id.hasPrefix("launch-agent:"),
        let provider = AgentProvider(rawValue: String(command.id.dropFirst("launch-agent:".count)))
      {
        launchAgent(provider)
      }
    }
    if dismissesPalette { isPalettePresented = false }
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
    tab.onCommandFinished = { [weak self] paneID in
      self?.completeWorkflowCLICommand(paneID: paneID)
      self?.dispatchNextRecipeCommand(paneID: paneID)
    }
    tab.onAgentTaskStateChanged = { [weak self] paneID, state in
      self?.advancePromptQueue(paneID: paneID, reportedState: state)
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

  /// 退出事务的可取消阶段。这里只处理未保存文档，不写退出标记、不终止进程；多窗口
  /// 中任一用户取消时，其它窗口因此仍保持完全可用。
  func confirmTermination() -> Bool {
    for tab in tabs where !tab.confirmCloseDocuments() {
      return false
    }
    return true
  }

  /// 退出事务的不可逆提交阶段。调用方必须先确认所有参与窗口均允许退出。
  func commitTermination() {
    persistWorkspace()
    defaults.set(false, forKey: applicationSessionRunningKey)
    defaults.set(0, forKey: applicationSessionCrashCountKey)
    defaults.set(WorkflowSessionEndReason.cleanQuit.rawValue, forKey: applicationSessionEndReasonKey)
    DiagnosticsCenter.shared.record(
      "workspace.session_marked_clean", level: .notice, category: .workspace)
    // `terminateNow` 返回后 AppKit 不保证延迟任务继续运行，因此退出路径直接终止
    // 各 Shell 进程组；普通 Pane/标签关闭仍保留温和退出与 750ms 升级窗口。
    for tab in tabs { tab.stop(immediately: true) }
  }

  /// 保留单模型调用入口；多窗口退出必须使用 `WorkspaceTerminationTransaction`，避免
  /// `allSatisfy` 在中途取消前已提交前序窗口。
  func prepareForTermination() -> Bool {
    guard confirmTermination() else { return false }
    commitTermination()
    return true
  }
}
