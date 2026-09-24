// `workspace.*` 控制协议方法：列出、打开、新建本地与远端命名工作区。
import AppKit
import AsterCore
import Foundation

/// 命名工作区的控制协议方法。
///
/// 单独成组的理由与 `MachineControlMethod` 相同：作用域是工作区注册表与远端机器上的
/// 工作区列表，不是当前工作区里的某个 Pane。
enum WorkspaceControlMethod: String, CaseIterable, Sendable {
  case workspaceList = "workspace.list"
  case workspaceOpen = "workspace.open"
  case workspaceNew = "workspace.new"

  /// 打开与新建会开窗、切换机器或在远端建进程，必须过 IPC 写门禁；列表保持只读。
  var isWrite: Bool { self != .workspaceList }
}

// MARK: - 协议载荷

/// 本地注册表里的一条工作区。
struct LocalWorkspaceControlRow: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var isOpen: Bool
  /// 主工作区（`UserDefaults.standard` 里的那一份）；它不能删除，也不受打开上限约束。
  var isMain: Bool
  var lastActiveAtUnixMs: UInt64
}

/// 一台机器上的一个远端工作区，取自缓存投影。
struct RemoteWorkspaceControlRow: Codable, Equatable, Sendable {
  var workspaceID: String
  var title: String
  var tabCount: Int
  /// 选中项属于客户端窗口；这里取的是 key window 优先的那个协调器的选中项。
  var isSelected: Bool
}

/// 一台远端机器及其工作区。
struct RemoteMachineWorkspacesRow: Codable, Equatable, Sendable {
  var machineID: String
  var machineLabel: String
  /// false 表示本进程还没有这台机器的快照：`workspaces` 为空不代表远端真的没有工作区。
  var cached: Bool
  var workspaces: [RemoteWorkspaceControlRow]
}

struct WorkspaceListResult: Codable, Equatable, Sendable {
  var local: [LocalWorkspaceControlRow]
  var remote: [RemoteMachineWorkspacesRow]
}

/// `workspace.open` / `workspace.new` 的结果：回显实际落点，便于自动化确认。
struct WorkspaceActionResult: Codable, Equatable, Sendable {
  /// `local` 或 `remote`。
  var kind: String
  /// 本地为注册表条目 UUID，远端为服务端工作区 ID。
  var workspaceID: String
  var name: String
  var machineID: String?
  var machineLabel: String?
}

/// `workspace.open` 参数：本地名称或 ID、`<机器>/<工作区>`，或远端工作区标题 / ID。
struct WorkspaceOpenParams: Codable, Equatable, Sendable {
  var workspace: String
}

/// `workspace.new` 参数；`machine` 缺省表示本地。
struct WorkspaceNewParams: Codable, Equatable, Sendable {
  var name: String
  var machine: String?
}

// MARK: - 依赖接缝

/// 控制命令需要的本地工作区目录能力；生产实现是 `NamedWorkspaceDirectory`。
@MainActor
protocol LocalWorkspaceDirectoryControlling: AnyObject {
  var workspaces: [NamedWorkspace] { get }
  @discardableResult func open(_ id: UUID) -> Bool
  @discardableResult func createLocalWorkspace(named rawName: String, errorWindow: NSWindow?) -> Bool
}

extension NamedWorkspaceDirectory: LocalWorkspaceDirectoryControlling {}

/// 控制命令需要的远端工作区能力；生产实现是每个窗口各一个的 `RemoteWorkspaceCoordinator`。
@MainActor
protocol RemoteWorkspaceControlling: AnyObject {
  func remoteWorkspaces(machineID: UUID) -> [RemoteWorkspaceSummary]
  /// 是否已有这台机器的缓存投影；用来区分「没有工作区」与「还没取过快照」。
  func hasCachedRemoteProjection(machineID: UUID) -> Bool
  func selectRemoteWorkspace(machineID: UUID, workspaceID: String) async throws
  func createRemoteWorkspace(machineID: UUID, title: String) async throws -> String
}

extension RemoteWorkspaceCoordinator: RemoteWorkspaceControlling {
  /// 只看内存里的投影，不发网络请求。
  func hasCachedRemoteProjection(machineID: UUID) -> Bool {
    workspaces[machineID]?.controller.projection != nil
  }
}

/// 一台可作为远端工作区落点的机器（不含 Local）。
struct WorkspaceControlMachine: Equatable, Sendable {
  var id: UUID
  var label: String
}

/// 一次 `workspace.*` 请求看到的全部依赖；测试注入替身。
@MainActor
struct WorkspaceControlContext {
  var directory: any LocalWorkspaceDirectoryControlling
  /// 远端机器，按侧栏顺序。
  var machines: [WorkspaceControlMachine]
  /// 已经构造出协调器的窗口，key window 在前。列表只读缓存，不为此现造协调器。
  var loadedCoordinators: [any RemoteWorkspaceControlling]
  /// 写操作的目标：key window，没有就用主窗口。可能现造协调器，因此只在写路径调用。
  var targetCoordinator: () -> (any RemoteWorkspaceControlling)?

  /// 生产依赖：共享注册表、机器侧栏模型与当前全部工作区窗口。
  static func live() -> WorkspaceControlContext {
    let directory = NamedWorkspaceDirectory.shared
    let controllers = workspaceViewControllers(directory: directory)
    return WorkspaceControlContext(
      directory: directory,
      machines: MachineFleetModel.shared.rows.filter { !$0.isLocal }.map {
        WorkspaceControlMachine(id: $0.id, label: $0.label)
      },
      loadedCoordinators: controllers.compactMap(\.loadedRemoteWorkspaces),
      targetCoordinator: { controllers.first?.remoteWorkspaces })
  }

  /// 全部工作区窗口的控制器：key window 第一，主工作区窗口第二，其余按前后顺序。
  ///
  /// 与 AppDelegate 的 `activeWorkspaceViewController` 同一回退规则（key → 主窗口）；
  /// 从 `NSApplication` 与注册表取，而不是让 AppDelegate 再暴露一份窗口表。
  private static func workspaceViewControllers(
    directory: NamedWorkspaceDirectory
  ) -> [WorkspaceViewController] {
    let application = NSApplication.shared
    let mainID = directory.workspaces.first { $0.storage == .standard }?.id
    let preferred = [application.keyWindow, mainID.flatMap(directory.window(for:))].compactMap { $0 }
    var seen: Set<ObjectIdentifier> = []
    return (preferred + application.orderedWindows + application.windows).compactMap { window in
      guard let controller = window.contentViewController as? WorkspaceViewController,
        seen.insert(ObjectIdentifier(controller)).inserted
      else { return nil }
      return controller
    }
  }
}

// MARK: - 分发

extension AsterControlDispatcher {
  /// 处理工作区方法。返回 nil 表示不是本组方法，交回原有分发。
  func handleWorkspaceMethod(_ request: AsterControlRequest) async -> AsterControlResponse? {
    guard let method = WorkspaceControlMethod(rawValue: request.method) else { return nil }
    do {
      // 门禁先于取依赖：被拒的写请求不应该顺带现造远端协调器。
      if method.isWrite, !policyProvider().allowSendKeys {
        throw AsterControlError(code: .writeNotAllowed, message: "IPC Allow Send Keys 未开启。")
      }
      let context = workspaceContextProvider?() ?? WorkspaceControlContext.live()
      let result: WorkspaceActionResult
      switch method {
      case .workspaceList:
        return AsterControlResponse(
          id: request.id, result: try JSONValue(encoding: Self.workspaceList(context)))
      case .workspaceOpen:
        let params = try request.decodeParams(WorkspaceOpenParams.self)
        result = try await openWorkspace(params.workspace, context: context)
      case .workspaceNew:
        let params = try request.decodeParams(WorkspaceNewParams.self)
        result = try await newWorkspace(params, context: context)
      }
      return AsterControlResponse(id: request.id, result: try JSONValue(encoding: result))
    } catch let error as AsterControlError {
      return AsterControlResponse(id: request.id, error: error)
    } catch {
      return AsterControlResponse(
        id: request.id, error: AsterControlError(code: .internalError, message: "\(error)"))
    }
  }

  /// 本地注册表 + 每台远端机器的缓存工作区。
  ///
  /// 远端协调器每个窗口一个：按机器取第一个有缓存的协调器（key window 优先），
  /// 结果天然按 machineID 去重，选中项也就是用户眼前那个窗口的选中项。
  static func workspaceList(_ context: WorkspaceControlContext) -> WorkspaceListResult {
    let local = context.directory.workspaces.map { workspace in
      LocalWorkspaceControlRow(
        id: workspace.id.uuidString,
        name: workspace.name,
        isOpen: workspace.isOpen,
        isMain: workspace.storage == .standard,
        lastActiveAtUnixMs: UInt64(max(0, workspace.lastActiveAt.timeIntervalSince1970 * 1000)))
    }
    let remote = remoteCache(context).map { entry in
      RemoteMachineWorkspacesRow(
        machineID: entry.machine.id.uuidString,
        machineLabel: entry.machine.label,
        cached: entry.cached,
        workspaces: entry.summaries.map {
          RemoteWorkspaceControlRow(
            workspaceID: $0.workspaceID, title: $0.title, tabCount: $0.tabCount,
            isSelected: $0.isSelected)
        })
    }
    return WorkspaceListResult(local: local, remote: remote)
  }

  // MARK: - 打开

  /// 按选择器找到唯一的工作区并打开；找不到或有歧义都拒绝，不猜。
  private func openWorkspace(
    _ selector: String, context: WorkspaceControlContext
  ) async throws -> WorkspaceActionResult {
    let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AsterControlError.invalidParams("workspace 不能为空。") }
    let candidates = Self.workspaceCandidates(trimmed, context: context)
    guard let candidate = candidates.first else {
      throw AsterControlError(
        code: .notFound,
        message: "找不到工作区：\(trimmed)。远端工作区只按已缓存的列表匹配；可先运行 workspace list 查看。")
    }
    guard candidates.count == 1 else {
      throw Self.ambiguity("「\(trimmed)」对应 \(candidates.count) 个工作区", candidates.map(\.choice))
    }
    switch candidate {
    case .local(let workspace):
      try Self.ensureCanOpen(workspace, in: context.directory)
      guard context.directory.open(workspace.id) else {
        throw AsterControlError(code: .internalError, message: "无法打开工作区「\(workspace.name)」。")
      }
      return WorkspaceActionResult(
        kind: "local", workspaceID: workspace.id.uuidString, name: workspace.name)
    case .remote(let machine, let summary):
      let coordinator = try Self.target(context)
      try await Self.withRemoteWorkspaceErrors {
        try await coordinator.selectRemoteWorkspace(
          machineID: machine.id, workspaceID: summary.workspaceID)
      }
      return WorkspaceActionResult(
        kind: "remote", workspaceID: summary.workspaceID, name: summary.title,
        machineID: machine.id.uuidString, machineLabel: machine.label)
    }
  }

  /// 可能的目标。`choice` 是能唯一定位它的写法，歧义时原样列给用户。
  private enum WorkspaceCandidate {
    case local(NamedWorkspace)
    case remote(WorkspaceControlMachine, RemoteWorkspaceSummary)

    var choice: String {
      switch self {
      case .local(let workspace): "\(workspace.id.uuidString)\t本地 · \(workspace.name)"
      case .remote(let machine, let summary):
        "\(machine.id.uuidString)/\(summary.workspaceID)\t\(machine.label) · \(summary.title)"
      }
    }
  }

  /// 收集全部匹配：本地按 ID 或名称；远端按 `<机器>/<工作区>`，以及裸的标题或 ID。
  ///
  /// 机器标签和工作区标题都可能含 `/`，所以在每个 `/` 处都试着切一次，而不是只切第一个。
  /// 同一个远端工作区可能被多种写法命中，按（机器，工作区 ID）去重。
  private static func workspaceCandidates(
    _ selector: String, context: WorkspaceControlContext
  ) -> [WorkspaceCandidate] {
    let uuid = UUID(uuidString: selector)
    var candidates: [WorkspaceCandidate] = context.directory.workspaces
      .filter { $0.id == uuid || $0.name == selector }
      .map { .local($0) }
    let cache = remoteCache(context)
    var seen: Set<String> = []
    func appendRemote(matching key: String, where machineMatches: (WorkspaceControlMachine) -> Bool) {
      for entry in cache where machineMatches(entry.machine) {
        for summary in entry.summaries where summary.workspaceID == key || summary.title == key {
          guard seen.insert("\(entry.machine.id)/\(summary.workspaceID)").inserted else { continue }
          candidates.append(.remote(entry.machine, summary))
        }
      }
    }
    for index in selector.indices where selector[index] == "/" {
      let prefix = String(selector[..<index])
      let prefixID = UUID(uuidString: prefix)
      appendRemote(matching: String(selector[selector.index(after: index)...])) {
        $0.id == prefixID || $0.label == prefix
      }
    }
    appendRemote(matching: selector) { _ in true }
    return candidates
  }

  /// 打开一个已关闭的附加工作区前先查打开上限。
  ///
  /// 走到开窗路径才超限的话，AppDelegate 会弹应用级模态提示；CLI 请求不能把 App 卡在
  /// 一个没人看的对话框上，所以在这里先拒绝。主工作区不受上限约束。
  private static func ensureCanOpen(
    _ workspace: NamedWorkspace, in directory: any LocalWorkspaceDirectoryControlling
  ) throws {
    guard !workspace.isOpen, workspace.storage != .standard else { return }
    try ensureOpenSlot(in: directory)
  }

  private static func ensureOpenSlot(in directory: any LocalWorkspaceDirectoryControlling) throws {
    guard directory.workspaces.filter(\.isOpen).count < NamedWorkspaceRegistry.maximumOpen else {
      throw AsterControlError(
        code: .invalidRequest,
        message: NamedWorkspaceDirectory.message(for: .registry(.tooManyOpen)))
    }
  }

  // MARK: - 新建

  /// 不带机器时新建本地工作区窗口，带机器时在那台机器上新建远端工作区并选中。
  private func newWorkspace(
    _ params: WorkspaceNewParams, context: WorkspaceControlContext
  ) async throws -> WorkspaceActionResult {
    let machineSelector = params.machine?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let machineSelector, machineSelector.isEmpty {
      throw AsterControlError.invalidParams("machine 不能为空；新建本地工作区请省略它。")
    }
    guard let machineSelector, !Self.isLocalMachine(machineSelector) else {
      return try newLocalWorkspace(named: params.name, directory: context.directory)
    }
    let machine = try Self.resolveMachine(machineSelector, in: context.machines)
    let title = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw AsterControlError.invalidParams("工作区名称不能为空。") }
    let coordinator = try Self.target(context)
    let workspaceID = try await Self.withRemoteWorkspaceErrors {
      try await coordinator.createRemoteWorkspace(machineID: machine.id, title: title)
    }
    return WorkspaceActionResult(
      kind: "remote", workspaceID: workspaceID, name: title,
      machineID: machine.id.uuidString, machineLabel: machine.label)
  }

  /// 本地新建：名称与打开上限先在这里校验。
  ///
  /// `createLocalWorkspace` 遇到非法名称会弹提示框；CLI 请求要拿到的是错误响应，
  /// 所以这里先校验，保证交给它的名称必然合法。
  private func newLocalWorkspace(
    named rawName: String, directory: any LocalWorkspaceDirectoryControlling
  ) throws -> WorkspaceActionResult {
    let name: String
    do {
      name = try NamedWorkspaceRegistry.validatedName(rawName)
    } catch let error as NamedWorkspaceRegistryError {
      throw AsterControlError.invalidParams(NamedWorkspaceDirectory.message(for: .registry(error)))
    } catch {
      throw AsterControlError(code: .internalError, message: "\(error)")
    }
    try Self.ensureOpenSlot(in: directory)
    let existing = Set(directory.workspaces.map(\.id))
    guard directory.createLocalWorkspace(named: name, errorWindow: nil) else {
      throw AsterControlError(code: .internalError, message: "无法新建工作区「\(name)」。")
    }
    // 用前后差集找新条目：同名工作区可以有多个，按名称找可能找到旧的那个。
    guard let created = directory.workspaces.first(where: { !existing.contains($0.id) }) else {
      throw AsterControlError(code: .internalError, message: "工作区窗口已创建，但注册表里没有新条目。")
    }
    return WorkspaceActionResult(kind: "local", workspaceID: created.id.uuidString, name: created.name)
  }

  /// `local` 或 Local 的固定 UUID 表示本机，与 `machine` 命令的写法一致。
  private static func isLocalMachine(_ selector: String) -> Bool {
    selector.caseInsensitiveCompare("local") == .orderedSame
      || UUID(uuidString: selector) == MachineProfile.localProfileID
  }

  /// 按 ID 或标签定位远端机器；标签重复时列出候选，不猜。
  private static func resolveMachine(
    _ selector: String, in machines: [WorkspaceControlMachine]
  ) throws -> WorkspaceControlMachine {
    let uuid = UUID(uuidString: selector)
    let matches = machines.filter { $0.id == uuid || $0.label == selector }
    guard let machine = matches.first else {
      throw AsterControlError(code: .notFound, message: "找不到机器：\(selector)")
    }
    guard matches.count == 1 else {
      throw ambiguity(
        "标签 '\(selector)' 对应 \(matches.count) 台机器", matches.map { "\($0.id.uuidString)\t\($0.label)" })
    }
    return machine
  }

  // MARK: - 远端工具

  /// 每台远端机器的缓存工作区：取第一个（key window 优先）有这台机器投影的协调器。
  private static func remoteCache(
    _ context: WorkspaceControlContext
  ) -> [(machine: WorkspaceControlMachine, cached: Bool, summaries: [RemoteWorkspaceSummary])] {
    context.machines.map { machine in
      let source = context.loadedCoordinators.first {
        $0.hasCachedRemoteProjection(machineID: machine.id)
      }
      return (machine, source != nil, source?.remoteWorkspaces(machineID: machine.id) ?? [])
    }
  }

  private static func target(
    _ context: WorkspaceControlContext
  ) throws -> any RemoteWorkspaceControlling {
    guard let coordinator = context.targetCoordinator() else {
      throw AsterControlError(code: .invalidRequest, message: "没有可用的工作区窗口。")
    }
    return coordinator
  }

  /// 歧义错误：消息里逐行列出能唯一定位的写法。
  private static func ambiguity(_ summary: String, _ choices: [String]) -> AsterControlError {
    AsterControlError(
      code: .ambiguousTarget,
      message: "\(summary)；请改用下列唯一写法之一：\n" + choices.map { "  \($0)" }.joined(separator: "\n"))
  }

  /// 把协调器的领域错误翻译成协议错误码；文案沿用界面上的同一句话。
  private static func withRemoteWorkspaceErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as AsterControlError {
      throw error
    } catch let error as RemoteWorkspaceOperationError {
      let message = error.errorDescription ?? "\(error)"
      switch error {
      case .workspaceNotFound: throw AsterControlError(code: .notFound, message: message)
      case .emptyTitle: throw AsterControlError.invalidParams(message)
      case .machineUnavailable, .notConnected:
        throw AsterControlError(code: .invalidRequest, message: message)
      }
    } catch {
      throw AsterControlError(code: .internalError, message: RemoteSetupDescription.text(for: error))
    }
  }
}
