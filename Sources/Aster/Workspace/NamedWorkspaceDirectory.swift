// 本地窗口注册表目录：负责注册表的加载、迁移与保存，并维护窗口与注册表条目的对应关系。
//
// 「本机工作区」现在是窗口内的一组标签（见 `AppModel+WorkspaceGroups`）；这里的注册表只管窗口：
// 恢复附加窗口、保留改过名的旧窗口，以及让切换器能重新打开已关闭的旧窗口。
import AppKit
import AsterCore

/// 真正创建工作区窗口的一方（生产环境是 `AsterAppDelegate`）。
///
/// 目录只管注册表与窗口映射；窗口、AppModel 与 PTY 的生命周期仍归 AppDelegate，
/// 避免出现第二个窗口所有者。
@MainActor
protocol NamedWorkspaceWindowHost: AnyObject {
  /// 为当前没有窗口的工作区打开窗口；成功返回 true。
  func openWindow(for workspace: NamedWorkspace) -> Bool
}

/// 目录层的操作错误。注册表自身的错误原样包在 `.registry` 里。
enum NamedWorkspaceDirectoryError: Error, Equatable {
  /// 打开着的工作区不能删除，必须先关闭它的窗口。
  case workspaceIsOpen
  case registry(NamedWorkspaceRegistryError)
}

/// 本地命名工作区的 App 侧目录，注册表的唯一读写入口。
///
/// 注册表存在 `aster.workspace.registry.v1`；每次保存都把打开着的附加窗口 suite 写回
/// 旧键 `aster.workspace.additional-window-suites.v1`，降级到旧版本后窗口照样能恢复。
/// 切换器通过 `shared` 读取 `workspaces`，并监听 `didChangeNotification` 刷新。
@MainActor
final class NamedWorkspaceDirectory {
  /// 生产实例，读写 `UserDefaults.standard`。
  static let shared = NamedWorkspaceDirectory(defaults: .standard)
  /// 注册表内容或窗口映射变化后发出，`object` 是发出变化的目录。
  static let didChangeNotification = Notification.Name("aster.named-workspaces.did-change")
  /// 改造前的附加窗口 suite 列表键，只做降级兼容的镜像。
  static let legacySuitesKey = "aster.workspace.additional-window-suites.v1"

  /// 弱引用窗口：窗口的所有者是 AppDelegate，目录不能延长它的生命周期。
  private final class WindowReference {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
  }

  /// 为 nil 时只在内存里维护注册表，供不应触碰用户数据的测试宿主使用。
  private let defaults: UserDefaults?
  private let now: () -> Date
  /// 负责开窗的宿主；由 AppDelegate 在启动时注入。
  weak var host: (any NamedWorkspaceWindowHost)?
  private var windows: [UUID: WindowReference] = [:]
  /// 首次访问时才加载：只构建菜单的测试和启动早期代码不会触发迁移。
  private lazy var registry: NamedWorkspaceRegistry = loadRegistry()

  /// `defaults` 为 nil 表示纯内存目录；`now` 可注入以便测试排序与时间戳。
  init(defaults: UserDefaults?, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
  }

  // MARK: - 查询

  /// 全部本地工作区，最近使用优先。
  var workspaces: [NamedWorkspace] { registry.recentFirst }

  /// 按 ID 查找工作区。
  func workspace(_ id: UUID) -> NamedWorkspace? { registry.workspace(id) }

  /// 窗口对应的工作区 ID；不是工作区窗口时返回 nil。
  func workspaceID(for window: NSWindow) -> UUID? {
    windows.first { $0.value.window === window }?.key
  }

  /// 工作区当前挂着的窗口（可能已关闭但尚未释放，调用方结合 `isOpen` 判断）。
  func window(for id: UUID) -> NSWindow? { windows[id]?.window }

  /// 启动恢复用：注册表里打开着的附加窗口 suite，按创建先后排列。
  var openSuiteNames: [String] { registry.openSuiteNames }

  /// 远端工作区最近使用时间（键见 `NamedWorkspaceRegistry.remoteActivityKey`），切换器排序用。
  var remoteActivity: [String: Date] { registry.remoteActivity }

  // MARK: - 启动与窗口生命周期

  /// 启动恢复前调用：清理注册表（去重、丢弃非法 suite、淘汰超额的已关闭条目），删除被
  /// 淘汰条目的 suite 并保存，返回需要恢复的附加窗口 suite。
  ///
  /// 放在恢复之前而不是之后：去重必须先于开窗，否则两个条目指向同一 suite 时会为同一份
  /// 快照开出两个窗口。淘汰只涉及已关闭条目，不影响本次要恢复的窗口。
  func prepareForLaunchRestore() -> [String] {
    for suite in registry.prune() { Self.removeSuiteDomain(suite) }
    save()
    return registry.openSuiteNames
  }

  /// 主窗口显示时调用（首次创建与关闭后重新显示都走这里）。主窗口的模型常驻，
  /// 不受打开上限约束，所以用 `markActive` 直接标记为打开。
  func attachMainWindow(_ window: NSWindow) {
    guard let main = registry.workspace(storage: .standard) else { return }
    registry.markActive(main.id, now: now())
    bind(window, to: main.id)
  }

  /// 附加窗口创建前登记：已有条目（恢复、重新打开）标记为打开，否则新建条目。
  /// 超出打开上限或名称非法时抛错，调用方不应再创建窗口。
  func beginOpening(suiteName: String, name: String?, isPinned: Bool) throws -> UUID {
    do {
      if let existing = registry.workspace(storage: .suite(suiteName)) {
        try registry.markOpened(existing.id, now: now())
        return existing.id
      }
      return try registry.create(
        name: name ?? WorkspaceCodename.generate(), storage: .suite(suiteName),
        isPinned: isPinned, now: now()
      ).id
    } catch let error as NamedWorkspaceRegistryError {
      throw NamedWorkspaceDirectoryError.registry(error)
    }
  }

  /// `beginOpening` 之后窗口没能建出来时回滚登记。返回 true 表示调用方应删除 suite。
  @discardableResult
  func abandonOpening(_ id: UUID) -> Bool {
    let removeSuite = registry.markClosed(id)
    save()
    return removeSuite
  }

  /// 附加窗口建好后绑定到条目，并保存注册表。
  func attach(_ window: NSWindow, to id: UUID) {
    bind(window, to: id)
  }

  /// 用户单独关闭工作区窗口时调用（App 退出时不要调用，退出不改变任何打开状态）。
  ///
  /// 返回 true 表示该窗口没有需要保留的快照，调用方应删除它的 suite：不保留的条目会被
  /// 删除；固定保留的条目与主窗口只标记为关闭。未登记的窗口按改造前的行为返回 true。
  @discardableResult
  func windowWillClose(_ window: NSWindow) -> Bool {
    guard let id = workspaceID(for: window) else { return true }
    windows[id] = nil
    let removeSuite = registry.markClosed(id)
    save()
    return removeSuite
  }

  /// 窗口成为 key window 时记录一次使用，切换器据此排序。
  func windowDidBecomeKey(_ window: NSWindow) {
    guard let id = workspaceID(for: window) else { return }
    registry.markActive(id, now: now())
    save()
  }

  // MARK: - 切换器操作

  /// 打开工作区：已有窗口时置前；否则交给宿主开窗（主窗口按「主窗口重建」路径处理）。
  /// 超出打开上限时由开窗路径弹出提示。成功返回 true。
  @discardableResult
  func open(_ id: UUID) -> Bool {
    guard let workspace = registry.workspace(id) else { return false }
    if workspace.isOpen, let window = window(for: id) {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      return true
    }
    return host?.openWindow(for: workspace) ?? false
  }

  /// 重命名。重命名后的工作区自动变为固定保留。
  func rename(_ id: UUID, to name: String) throws {
    do {
      try registry.rename(id, to: name)
    } catch let error as NamedWorkspaceRegistryError {
      throw NamedWorkspaceDirectoryError.registry(error)
    }
    save()
  }

  /// 删除已关闭的工作区，同时删除它的 suite（即快照）。打开着的工作区与主工作区不能删。
  func remove(_ id: UUID) throws {
    guard let workspace = registry.workspace(id) else {
      throw NamedWorkspaceDirectoryError.registry(.unknownWorkspace(id))
    }
    guard !workspace.isOpen, window(for: id)?.isVisible != true else {
      throw NamedWorkspaceDirectoryError.workspaceIsOpen
    }
    let removed: NamedWorkspace
    do {
      removed = try registry.remove(id)
    } catch let error as NamedWorkspaceRegistryError {
      throw NamedWorkspaceDirectoryError.registry(error)
    }
    windows[id] = nil
    if case .suite(let name) = removed.storage { Self.removeSuiteDomain(name) }
    save()
  }

  /// 记录一次远端工作区使用并保存；切换器选中、新建远端工作区时调用。
  func markRemoteActive(machineID: UUID, workspaceID: String) {
    registry.markRemoteActive(machineID: machineID, workspaceID: workspaceID, now: now())
    save()
  }

  /// 立即保存注册表并镜像旧键；App 退出时调用，打开状态保持原样。
  func save() {
    if let defaults {
      do {
        defaults.set(try JSONEncoder().encode(registry), forKey: NamedWorkspaceRegistry.defaultsKey)
      } catch {
        DiagnosticsCenter.shared.record(
          "workspace.registry_encode_failed", level: .error, category: .workspace, error: error)
      }
      defaults.set(registry.openSuiteNames, forKey: Self.legacySuitesKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  // MARK: - 交互入口

  /// 「新建工作区…」（⌘⇧N）：弹出带主机下拉的新建表单。本机工作区建在当前窗口里，
  /// 远端工作区建在所选机器上；两者都从这里建。
  func presentNewWorkspace(in window: NSWindow?) {
    NewWorkspaceSheet.present(in: window, directory: self)
  }

  /// 把错误翻译成用户看得懂的一句话。
  static func message(for error: NamedWorkspaceDirectoryError) -> String {
    switch error {
    case .workspaceIsOpen:
      return L("这个工作区还开着。请先关闭它的窗口，再删除。")
    case .registry(.emptyName):
      return L("工作区名称不能为空。")
    case .registry(.nameTooLong):
      return L("工作区名称不能超过 \(NamedWorkspaceRegistry.maximumNameLength) 个字符。")
    case .registry(.tooManyOpen):
      return L("最多同时打开 \(NamedWorkspaceRegistry.maximumOpen) 个工作区。请先关闭一个窗口，再打开新的工作区。")
    case .registry(.unknownWorkspace):
      return L("找不到这个工作区，它可能已被删除。")
    case .registry(.cannotRemoveStandard):
      return L("主工作区不能删除。")
    }
  }

  /// 弹出错误提示；有宿主窗口时用 sheet，否则用应用级模态框。
  static func presentError(_ error: NamedWorkspaceDirectoryError, in window: NSWindow?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("无法完成工作区操作")
    alert.informativeText = message(for: error)
    alert.addButton(withTitle: L("好"))
    run(alert, in: window) { _ in }
  }

  // MARK: - 私有实现

  /// 首次访问时加载注册表：不存在或无法解码时从旧键迁移，存在时与旧键对账。
  private func loadRegistry() -> NamedWorkspaceRegistry {
    let legacy = defaults?.stringArray(forKey: Self.legacySuitesKey)
    if let data = defaults?.data(forKey: NamedWorkspaceRegistry.defaultsKey) {
      do {
        var registry = try JSONDecoder().decode(NamedWorkspaceRegistry.self, from: data)
        registry.reconcile(legacyOpenSuites: legacy, mainName: L("主工作区"), now: now())
        return registry
      } catch {
        // 注册表损坏时退回旧键迁移：旧键始终镜像打开着的窗口，至少这些窗口不会丢。
        DiagnosticsCenter.shared.record(
          "workspace.registry_decode_failed", level: .warning, category: .workspace, error: error)
      }
    }
    return NamedWorkspaceRegistry.migrated(
      mainName: L("主工作区"), legacySuites: legacy ?? [], now: now())
  }

  /// 记录窗口映射并保存。
  ///
  /// 注册表条目名（如「主工作区」）不再写进窗口副标题：工作区已改为窗口内的标签分组，
  /// 窗口级名字对用户没有意义，写进副标题会让 Dock 菜单显示成「标题 (主工作区)」。
  private func bind(_ window: NSWindow, to id: UUID) {
    windows = windows.filter { $0.value.window != nil && $0.value.window !== window }
    windows[id] = WindowReference(window)
    save()
  }

  /// 删除 suite 域前再校验一次名称，绝不删除 Aster 以外的 UserDefaults 域。
  private static func removeSuiteDomain(_ name: String) {
    guard NamedWorkspaceRegistry.isValidSuiteName(name) else { return }
    UserDefaults.standard.removePersistentDomain(forName: name)
  }

  /// 有窗口时以 sheet 展示，否则应用级模态；两条路径共用同一个结果处理。
  private static func run(
    _ alert: NSAlert, in window: NSWindow?,
    completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
  ) {
    if let window, window.isVisible {
      alert.beginSheetModal(for: window) { response in
        MainActor.assumeIsolated { completion(response) }
      }
    } else {
      completion(alert.runModal())
    }
  }
}
