import AsterCore
import Combine
import Foundation

/// 单个工作区窗口的 Panel 布局状态仓库。
///
/// 调用方必须注入与该窗口 `AppModel` 相同的 UserDefaults suite。主窗口因此使用标准
/// 域，附加窗口使用独立域；关闭附加窗口清理 suite 时，布局状态也自然随之清除。
@MainActor
final class WorkspacePanelLayoutStore: ObservableObject {
  static let persistenceKey = "aster.workspace.panel-layout.v1"

  @Published private(set) var state: WorkspacePanelLayoutState
  private let defaults: UserDefaults

  init(defaults: UserDefaults, legacySidebarWidth: Double) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.persistenceKey),
      let decoded = try? JSONDecoder().decode(WorkspacePanelLayoutState.self, from: data) {
      state = decoded.normalized()
    } else {
      state = WorkspacePanelLayoutState(
        sidebarWidth: WorkspacePanelLayoutPolicy.clampedWidth(
          legacySidebarWidth,
          for: .sidebar
        ),
        inspectorWidth: WorkspacePanelLayoutPolicy.inspectorDefaultWidth
      )
      persist()
    }
  }

  /// 保存用户通过 divider 或设置滑杆明确选择的边缘 Panel 宽度。
  ///
  /// 中栏是弹性区域，不接受写入；非法角色不会触发发布或磁盘变更。
  func setPreferredWidth(_ width: Double, for role: WorkspacePanelRole) {
    var updated = state
    switch role {
    case .sidebar:
      updated.sidebarWidth = WorkspacePanelLayoutPolicy.clampedWidth(width, for: role)
    case .content:
      return
    case .inspector:
      updated.inspectorWidth = WorkspacePanelLayoutPolicy.clampedWidth(width, for: role)
    }
    guard updated != state else { return }
    state = updated
    persist()
  }

  func resetPreferredWidth(for role: WorkspacePanelRole) {
    guard let width = WorkspacePanelLayoutPolicy.defaultWidth(for: role) else { return }
    setPreferredWidth(width, for: role)
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(state) else { return }
    defaults.set(data, forKey: Self.persistenceKey)
  }
}

/// 设置窗口与最近活动工作区之间的窄桥接层。设置窗口本身成为 key window 后仍保留
/// 上一个工作区绑定；当另一个工作区成为 key window 时，AppDelegate 只需重新 bind，
/// 设置页即可显示并修改那个窗口的独立宽度。
@MainActor
final class WorkspacePanelSettingsBinding: ObservableObject {
  @Published private(set) var state: WorkspacePanelLayoutState?
  private var activeStore: WorkspacePanelLayoutStore?
  private var subscription: AnyCancellable?

  var isBound: Bool { activeStore != nil }

  func isBound(to store: WorkspacePanelLayoutStore) -> Bool {
    activeStore === store
  }

  func bind(_ store: WorkspacePanelLayoutStore?) {
    guard activeStore !== store else { return }
    subscription = nil
    activeStore = store
    state = store?.state
    subscription = store?.$state.sink { [weak self] state in
      self?.state = state
    }
  }

  func setPreferredWidth(_ width: Double, for role: WorkspacePanelRole) {
    activeStore?.setPreferredWidth(width, for: role)
  }

  func resetPreferredWidth(for role: WorkspacePanelRole) {
    activeStore?.resetPreferredWidth(for: role)
  }
}
