import AsterCore
import Combine
import Foundation

/// 工作区对象 ↔ 控制协议的桥：为每个窗口/标签/pane 分配短 ID、投影 PaneInfo/AgentInfo、
/// 观察状态变化并向事件枢纽发布 `pane.*` 事件。AppDelegate 持有单例，每个 AppModel 都
/// 必须 `attach(model:)`（主窗口、新建窗口、恢复的附加窗口）。
@MainActor
final class AsterControlBridge {
  /// 一个已解析的 pane 及其归属；dispatcher 的所有 pane/agent 方法都以它为起点。
  struct PaneRecord {
    let model: AppModel
    let tab: TerminalTabItem
    let runtime: WorkspacePaneRuntime
    let windowID: ControlWindowID
    let tabID: ControlTabID
    let paneID: ControlPaneID

    var session: TerminalSession? { runtime.terminalSession }
  }

  let hub: AsterControlEventHub
  /// socket 路径与 CLI 二进制路径：注入到每个 Pane 环境。
  let socketPath: String
  let binaryPath: String?
  /// 用于解析 `current` 与 `focused`：返回当前 key window 的模型。
  var activeModelProvider: (() -> AppModel?)?
  /// 屏幕检测是否为该 Session 提供了状态：`screenDetectionPublished` 非 nil 即 detection == .screen。
  var screenDetectionProvider: (TerminalSession) -> Bool = { session in
    session.screenDetectionPublished != nil
  }

  private(set) var registry = ControlIdentityRegistry()
  private var models: [ObjectIdentifier: ModelRecord] = [:]
  /// pane UUID → 最近一次投影，用于去重 pane.updated / agent_status_changed。
  private var paneCache: [UUID: PaneInfo] = [:]
  private var stateChangeSequences: [UUID: UInt64] = [:]
  /// `agent.start --name` 登记的 agent 名；agent 退出或换 provider 时清除。
  private var agentNames: [UUID: String] = [:]
  private var paneSubscriptions: [UUID: Set<AnyCancellable>] = [:]
  private var tabSubscriptions: [UUID: Set<AnyCancellable>] = [:]
  /// 每个 tab 上次观察到的 pane 集合，用于 layout 变化时算出新增/关闭。
  private var tabPaneIDs: [UUID: [UUID]] = [:]

  private final class ModelRecord {
    weak var model: AppModel?
    var cancellables: Set<AnyCancellable> = []
    var tabIDs: [UUID] = []
    init(model: AppModel) { self.model = model }
  }

  init(hub: AsterControlEventHub = AsterControlEventHub(), socketPath: String, binaryPath: String?) {
    self.hub = hub
    self.socketPath = socketPath
    self.binaryPath = binaryPath
  }

  // MARK: - 接入

  /// 接入一个窗口模型：分配窗口号、登记现有标签与 pane、订阅后续增删与状态变化。
  func attach(model: AppModel) {
    let key = ObjectIdentifier(model)
    guard models[key] == nil else { return }
    let record = ModelRecord(model: model)
    models[key] = record
    _ = registry.windowID(for: model.windowID)
    model.controlContextResolver = { [weak self, weak model] tabID, paneID in
      guard let self, let model else { return nil }
      return self.controlContext(model: model, tabID: tabID, paneID: paneID)
    }
    // 旧 CLI（workflow.execute）也能用短 ID / current：ASTER_PANE_ID 现在是 `w1:p1`。
    model.workflowCLISelectorResolver = { [weak self] selector in
      self?.paneUUID(forLegacySelector: selector)
    }
    syncTabs(model: model, record: record, emit: false)
    model.$tabs
      .dropFirst()
      .sink { [weak self, weak model, weak record] _ in
        // `@Published` 在 willSet 发布；延后一轮读到新数组。
        DispatchQueue.main.async {
          guard let self, let model, let record else { return }
          self.syncTabs(model: model, record: record, emit: true)
        }
      }
      .store(in: &record.cancellables)
    model.$selectedTabID
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self, weak model] _ in
        DispatchQueue.main.async {
          guard let self, let model, let tab = model.selectedTab else { return }
          self.emitFocused(paneUUID: tab.activePaneID)
        }
      }
      .store(in: &record.cancellables)
  }

  /// 已接入的模型（弱引用已释放的会被清理）。
  var attachedModels: [AppModel] {
    models.values.compactMap(\.model)
  }

  private func syncTabs(model: AppModel, record: ModelRecord, emit: Bool) {
    let current = model.tabs
    let currentIDs = current.map(\.id)
    for tab in current where !record.tabIDs.contains(tab.id) {
      _ = registry.tabID(for: tab.id, inWindow: model.windowID)
      observeTab(tab, model: model, emit: emit)
    }
    for removed in record.tabIDs where !currentIDs.contains(removed) {
      // 标签可能被转移到另一窗口：若别的模型仍持有它，由目标窗口的 syncTabs 重新登记，
      // 旧短 ID 作为别名保留；否则视为关闭。
      let stillOwned = attachedModels.contains { $0 !== model && $0.tabs.contains { $0.id == removed } }
      if !stillOwned {
        for paneUUID in tabPaneIDs[removed] ?? [] { closePane(paneUUID, emit: emit) }
        registry.retire(tab: removed)
      }
      tabSubscriptions[removed] = nil
      tabPaneIDs[removed] = nil
    }
    record.tabIDs = currentIDs
  }

  private func observeTab(_ tab: TerminalTabItem, model: AppModel, emit: Bool) {
    var cancellables: Set<AnyCancellable> = []
    syncPanes(tab: tab, model: model, emit: emit)
    tab.$layout
      .dropFirst()
      .sink { [weak self, weak tab, weak model] _ in
        DispatchQueue.main.async {
          guard let self, let tab, let model else { return }
          self.syncPanes(tab: tab, model: model, emit: true)
        }
      }
      .store(in: &cancellables)
    tab.activePaneChanged
      .sink { [weak self] paneUUID in
        DispatchQueue.main.async { self?.emitFocused(paneUUID: paneUUID) }
      }
      .store(in: &cancellables)
    tab.titleChanged
      .sink { [weak self, weak tab] _ in
        DispatchQueue.main.async {
          guard let self, let tab else { return }
          self.refreshPane(tab.activePaneID)
        }
      }
      .store(in: &cancellables)
    tabSubscriptions[tab.id] = cancellables
  }

  private func syncPanes(tab: TerminalTabItem, model: AppModel, emit: Bool) {
    let panes = tab.layout.allPanes.map(\.id)
    let previous = tabPaneIDs[tab.id] ?? []
    // runtime（含 terminalSession，随 runtime 同步创建）尚未就绪的 pane 不记入已登记集合，
    // 下一次 layout 事件会重试登记，不会永久漏订阅。
    var registered: [UUID] = []
    for paneUUID in panes where !previous.contains(paneUUID) {
      guard let runtime = tab.runtime(for: paneUUID) else { continue }
      registered.append(paneUUID)
      _ = registry.paneID(for: paneUUID, inWindow: model.windowID)
      observePane(runtime, tab: tab, model: model)
      if let info = projectPane(paneUUID) {
        paneCache[paneUUID] = info
        if emit { hub.publish(.paneCreated, encoding: info) }
      }
    }
    for paneUUID in previous where !panes.contains(paneUUID) {
      closePane(paneUUID, emit: emit)
    }
    tabPaneIDs[tab.id] = previous.filter { panes.contains($0) } + registered
  }

  private func closePane(_ paneUUID: UUID, emit: Bool) {
    paneSubscriptions[paneUUID] = nil
    if emit, let info = paneCache[paneUUID] {
      hub.publish(.paneClosed, encoding: info)
    }
    paneCache[paneUUID] = nil
    stateChangeSequences[paneUUID] = nil
    agentNames[paneUUID] = nil
    registry.retire(pane: paneUUID)
  }

  private func observePane(_ runtime: WorkspacePaneRuntime, tab: TerminalTabItem, model: AppModel) {
    guard let session = runtime.terminalSession else { return }
    let paneUUID = runtime.id
    var cancellables: Set<AnyCancellable> = []
    // `@Published` 在 willSet 发出，统一延后一轮再读值（与 AppModel 的既有模式一致）。
    Publishers.MergeMany(
      session.$agentTaskState.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$agentTaskCompletionUnread.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$activeAgentProvider.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$activeAgentSessionID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$lifecycleState.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$terminalTitle.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$currentWorkingDirectory.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      session.$hasRunningCommand.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    )
    .sink { [weak self] _ in
      DispatchQueue.main.async { self?.refreshPane(paneUUID) }
    }
    .store(in: &cancellables)
    paneSubscriptions[paneUUID] = cancellables
  }

  /// 重新投影某个 pane；与缓存比较后发 `pane.exited` / `pane.agent_status_changed` / `pane.updated`。
  /// `state_change_seq` 只在这里、且只在 agent 状态/provider/sessionID 真正变化时递增一次；
  /// 读取路径（agentInfo）永远不改它。
  func refreshPane(_ paneUUID: UUID) {
    guard let previous = paneCache[paneUUID], var current = projectPane(paneUUID) else { return }
    let previousStatus = previous.agent?.agentStatus
    let previousAgent = previous.agent?.agent
    if let agent = current.agent {
      let changed = previous.agent == nil || agent.agentStatus != previousStatus
        || agent.agent != previousAgent || agent.sessionID != previous.agent?.sessionID
      if changed {
        current.agent?.stateChangeSeq = bumpStateChangeSequence(paneUUID)
      }
      // provider 换人：旧名字作废。
      if let previousAgent, previousAgent != agent.agent, agentNames[paneUUID] != nil {
        agentNames[paneUUID] = nil
        current.agent?.name = nil
      }
    } else if previous.agent != nil {
      agentNames[paneUUID] = nil
    }
    guard previous != current else { return }
    paneCache[paneUUID] = current
    if previous.running, !current.running {
      hub.publish(.paneExited, encoding: current)
    }
    if let agent = current.agent, agent.agentStatus != previousStatus || agent.agent != previousAgent {
      hub.publish(
        .paneAgentStatusChanged,
        encoding: AsterControlEvent.AgentStatusChange(
          paneID: agent.paneID, previous: previousStatus, status: agent.agentStatus,
          detection: agent.detection, stateChangeSeq: agent.stateChangeSeq, agent: agent))
    } else if current.agent == nil, previous.agent != nil, let previousAgent = previous.agent {
      // agent 退出：也算一次状态变化，等待者据此得到 agent_not_running。
      hub.publish(
        .paneAgentStatusChanged,
        encoding: AsterControlEvent.AgentStatusChange(
          paneID: previousAgent.paneID, previous: previousStatus, status: .unknown,
          detection: previousAgent.detection, stateChangeSeq: bumpStateChangeSequence(paneUUID),
          agent: nil))
    }
    hub.publish(.paneUpdated, encoding: current)
  }

  private func emitFocused(paneUUID: UUID) {
    guard let info = projectPane(paneUUID) else { return }
    paneCache[paneUUID] = info
    hub.publish(.paneFocused, encoding: info)
  }

  private func bumpStateChangeSequence(_ paneUUID: UUID) -> UInt64 {
    let next = (stateChangeSequences[paneUUID] ?? 0) + 1
    stateChangeSequences[paneUUID] = next
    return next
  }

  // MARK: - 上下文与解析

  func controlContext(model: AppModel, tabID: UUID, paneID: UUID) -> TerminalControlContext? {
    let windowID = registry.windowID(for: model.windowID)
    let tab = registry.tabID(for: tabID, inWindow: model.windowID)
    let pane = registry.paneID(for: paneID, inWindow: model.windowID)
    return TerminalControlContext(
      windowID: windowID.description, tabID: tab.description, paneID: pane.description,
      socketPath: socketPath, binaryPath: binaryPath)
  }

  /// 全部已登记的 pane（按窗口号、标签号、布局顺序）。
  func allPanes() -> [PaneRecord] {
    var records: [PaneRecord] = []
    let sortedModels = attachedModels.sorted { registry.windowNumber(for: $0.windowID) < registry.windowNumber(for: $1.windowID) }
    for model in sortedModels {
      for tab in model.tabs {
        for descriptor in tab.layout.allPanes {
          if let record = record(model: model, tab: tab, paneUUID: descriptor.id) { records.append(record) }
        }
      }
    }
    return records
  }

  private func record(model: AppModel, tab: TerminalTabItem, paneUUID: UUID) -> PaneRecord? {
    guard let runtime = tab.runtime(for: paneUUID) else { return nil }
    return PaneRecord(
      model: model, tab: tab, runtime: runtime,
      windowID: registry.windowID(for: model.windowID),
      tabID: registry.tabID(for: tab.id, inWindow: model.windowID),
      paneID: registry.paneID(for: paneUUID, inWindow: model.windowID))
  }

  func record(paneUUID: UUID) -> PaneRecord? {
    for model in attachedModels {
      for tab in model.tabs where tab.runtime(for: paneUUID) != nil {
        return record(model: model, tab: tab, paneUUID: paneUUID)
      }
    }
    return nil
  }

  /// 当前焦点 pane：key window 模型的选中标签的活动 pane。
  func currentPane() -> PaneRecord? {
    let model = activeModelProvider?() ?? attachedModels.first
    guard let model, let tab = model.selectedTab else { return nil }
    return record(model: model, tab: tab, paneUUID: tab.activePaneID)
  }

  /// 旧 CLI selector 的短 ID / current 解析；非短 ID 形态返回 nil 让 AppModel 走旧规则。
  func paneUUID(forLegacySelector selector: String) -> UUID? {
    guard let parsed = ControlTargetSelector(parsing: selector) else { return nil }
    switch parsed {
    case .pane, .tab, .window, .current:
      return (try? resolve(selector: selector))?.runtime.id
    case .legacyPaneUUID, .agentName:
      return nil
    }
  }

  /// selector → pane。找不到抛 `not_found`（agent name 抛 `agent_not_found`）。
  func resolve(selector text: String) throws -> PaneRecord {
    guard let selector = ControlTargetSelector(parsing: text) else {
      throw AsterControlError.invalidParams("非法 selector: \(text)")
    }
    switch selector {
    case .current:
      guard let record = currentPane() else {
        throw AsterControlError(code: .notFound, message: "当前没有焦点 pane")
      }
      return record
    case .pane(let id):
      guard let uuid = registry.paneUUID(for: id), let record = record(paneUUID: uuid) else {
        throw AsterControlError(code: .notFound, message: "pane 不存在: \(id)")
      }
      return record
    case .tab(let id):
      guard let tabUUID = registry.tabUUID(for: id) else {
        throw AsterControlError(code: .notFound, message: "标签不存在: \(id)")
      }
      for model in attachedModels {
        if let tab = model.tabs.first(where: { $0.id == tabUUID }),
          let record = record(model: model, tab: tab, paneUUID: tab.activePaneID)
        {
          return record
        }
      }
      throw AsterControlError(code: .notFound, message: "标签不存在: \(id)")
    case .window(let id):
      guard let model = attachedModels.first(where: { registry.windowID(registeredFor: $0.windowID) == id }),
        let tab = model.selectedTab, let record = record(model: model, tab: tab, paneUUID: tab.activePaneID)
      else {
        throw AsterControlError(code: .notFound, message: "窗口不存在: \(id)")
      }
      return record
    case .legacyPaneUUID(let uuid):
      // 旧 selector 既可能是 pane 描述符 ID，也可能是 TerminalSession.id（ASTER_SESSION_ID）。
      if let record = record(paneUUID: uuid) { return record }
      for model in attachedModels {
        for tab in model.tabs {
          if let runtime = tab.runtimes.values.first(where: { $0.terminalSession?.id == uuid }),
            let record = record(model: model, tab: tab, paneUUID: runtime.id)
          {
            return record
          }
        }
      }
      throw AsterControlError(code: .notFound, message: "pane 不存在: \(uuid.uuidString)")
    case .agentName(let name):
      // 先查 `agent.start --name` 登记的名字，再回退 provider rawValue / commandName。
      if let owner = paneOwningAgentName(name), let record = record(paneUUID: owner),
        record.session?.activeAgentProvider != nil
      {
        return record
      }
      let matches = allPanes().filter { record in
        guard let provider = record.session?.activeAgentProvider else { return false }
        return provider.rawValue.lowercased() == name || provider.commandName.lowercased() == name
      }
      guard !matches.isEmpty else {
        throw AsterControlError(code: .agentNotFound, message: "没有名为 \(name) 的 agent")
      }
      if matches.count > 1, let focused = matches.first(where: { isFocused($0) }) { return focused }
      return matches[0]
    }
  }

  // MARK: - agent 名字

  /// 登记名字并刷新投影（事件里的 AgentInfo.name 随之更新）。
  func setAgentName(_ name: String, paneUUID: UUID) {
    agentNames[paneUUID] = name
    refreshPane(paneUUID)
  }

  func agentName(for paneUUID: UUID) -> String? { agentNames[paneUUID] }

  /// 持有该名字的 pane（大小写不敏感）。
  func paneOwningAgentName(_ name: String) -> UUID? {
    agentNames.first { $0.value.lowercased() == name.lowercased() }?.key
  }

  // MARK: - 投影

  func isFocused(_ record: PaneRecord) -> Bool {
    let activeModel = activeModelProvider?() ?? attachedModels.first
    return record.model === activeModel && record.model.selectedTabID == record.tab.id
      && record.tab.activePaneID == record.runtime.id
  }

  func projectPane(_ paneUUID: UUID) -> PaneInfo? {
    record(paneUUID: paneUUID).map(paneInfo)
  }

  func paneInfo(_ record: PaneRecord) -> PaneInfo {
    let descriptor = record.runtime.descriptor
    if let session = record.session {
      return PaneInfo(
        paneID: record.paneID.description, tabID: record.tabID.description,
        windowID: record.windowID.description, kind: .terminal,
        title: AsterControlTitleNormalizer.stripped(session.terminalTitle),
        cwd: session.resolvedCurrentWorkingDirectory(),
        command: session.foregroundCommandName, focused: isFocused(record),
        running: session.statusIsRunning, agent: agentInfo(record))
    }
    return PaneInfo(
      paneID: record.paneID.description, tabID: record.tabID.description,
      windowID: record.windowID.description, kind: descriptor.kind,
      title: descriptor.resourcePath.map { ($0 as NSString).lastPathComponent },
      cwd: descriptor.workingDirectory, command: nil, focused: isFocused(record), running: false,
      agent: nil)
  }

  /// pane 正在跑 agent 时的 AgentInfo；`state_change_seq` 在状态变化时递增。
  func agentInfo(_ record: PaneRecord) -> AgentInfo? {
    guard let session = record.session, let provider = session.activeAgentProvider else { return nil }
    let mapping = AgentControlStatusMapper.map(
      taskState: session.agentTaskState,
      completionUnread: session.agentTaskCompletionUnread,
      authoritative: session.hasAuthoritativeAgentLifecycle,
      screenDetected: screenDetectionProvider(session))
    let paneUUID = record.runtime.id
    // 只读：序列号来自 refreshPane 维护的表，读多少次都不变。
    let sequence = stateChangeSequences[paneUUID] ?? 0
    return AgentInfo(
      paneID: record.paneID.description, tabID: record.tabID.description,
      windowID: record.windowID.description, name: agentNames[paneUUID], agent: provider.rawValue,
      command: session.foregroundCommandName, agentStatus: mapping.status, detection: mapping.source,
      sessionID: session.activeAgentSessionID,
      title: AsterControlTitleNormalizer.stripped(session.terminalTitle),
      cwd: session.resolvedCurrentWorkingDirectory(), focused: isFocused(record),
      stateChangeSeq: sequence)
  }

  func snapshot() -> SessionSnapshot {
    let activeModel = activeModelProvider?() ?? attachedModels.first
    let sortedModels = attachedModels.sorted { registry.windowNumber(for: $0.windowID) < registry.windowNumber(for: $1.windowID) }
    let windows = sortedModels.map { model -> SessionSnapshot.Window in
      let tabs = model.tabs.map { tab -> SessionSnapshot.Tab in
        let panes = tab.layout.allPanes.compactMap { descriptor in
          record(model: model, tab: tab, paneUUID: descriptor.id).map(paneInfo)
        }
        return SessionSnapshot.Tab(
          tabID: registry.tabID(for: tab.id, inWindow: model.windowID).description,
          title: tab.displayTitle, focused: model.selectedTabID == tab.id, panes: panes)
      }
      return SessionSnapshot.Window(
        windowID: registry.windowID(for: model.windowID).description,
        focused: model === activeModel, tabs: tabs)
    }
    return SessionSnapshot(windows: windows, sequence: hub.sequence)
  }
}
