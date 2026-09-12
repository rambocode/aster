import Foundation

/// P4.7：离线灰显、缓存时间、禁用输入/导航、重连不抢焦点、移除当前机器回 Local。
///
/// 依据 `docs/developer/remote-work.md` §4.2 末段与 §4.1 第 7 条：
/// - 断线时保留灰显结构与最后状态，显示更新时间；可以查看缓存信息，但**不能**据此
///   发送输入、操作窗格或宣称任务已完成。
/// - 重连不改变当前活动机器和焦点。
/// - 当前配置被禁用/移除时回 Local；Local 故障时保留其错误态，不自动跳到别的远端。
///
/// 纯模型，不含任何 UI；渲染由 App 侧负责。

/// 一台机器在界面上的呈现状态。
public struct MachineOfflinePresentation: Equatable, Sendable {
  public var profileID: UUID
  public var state: SessionConnectionState
  /// 结构与最后状态的更新时间。离线时界面必须显示它。
  public var lastUpdatedAt: Date
  /// 缓存是否已过时（离线即为 true）。
  public var isStale: Bool
  /// 是否灰显。
  public var isDimmed: Bool
  /// 是否允许发送输入。
  public var allowsInput: Bool
  /// 是否允许操作窗格/标签等导航与结构动作。
  public var allowsNavigation: Bool
  /// 已脱敏的原因文本（attention / 退避原因）。
  public var reason: String?

  public init(
    profileID: UUID,
    state: SessionConnectionState,
    lastUpdatedAt: Date,
    isStale: Bool,
    isDimmed: Bool,
    allowsInput: Bool,
    allowsNavigation: Bool,
    reason: String?
  ) {
    self.profileID = profileID
    self.state = state
    self.lastUpdatedAt = lastUpdatedAt
    self.isStale = isStale
    self.isDimmed = isDimmed
    self.allowsInput = allowsInput
    self.allowsNavigation = allowsNavigation
    self.reason = reason
  }

  /// 由连接状态推导呈现状态。
  ///
  /// 只有 `online` **且**已完成身份/快照校验（`inputAllowed`）才允许输入与导航。
  /// `online` 但快照未确认时仍然禁止交互：这正是「重新可见先快照后交互」的要求。
  public static func from(_ status: MachineConnectionStatus) -> MachineOfflinePresentation {
    let live = status.state == .online && status.inputAllowed
    return MachineOfflinePresentation(
      profileID: status.profileID,
      state: status.state,
      lastUpdatedAt: status.lastUpdatedAt,
      isStale: !live,
      isDimmed: !live,
      allowsInput: live,
      allowsNavigation: live,
      reason: status.reason
    )
  }
}

/// 活动机器解析的输入。
public struct ActiveMachineResolution: Equatable, Sendable {
  /// 解析后的活动机器 ID。
  public var activeProfileID: UUID
  /// 焦点是否被本次解析改变。重连场景必须为 false。
  public var focusChanged: Bool
  /// Local 自身不可用时保留的明确错误；非 nil 时**不允许**自动跳到别的远端。
  public var localFailureReason: String?

  public init(activeProfileID: UUID, focusChanged: Bool, localFailureReason: String? = nil) {
    self.activeProfileID = activeProfileID
    self.focusChanged = focusChanged
    self.localFailureReason = localFailureReason
  }
}

public enum MachineActivationPolicy {
  /// 重连不改变当前活动机器和焦点。
  ///
  /// 这是一个显式的恒等函数：把「重连之后要不要改焦点」写成可测的规则，而不是靠
  /// 各调用点自觉不去改。
  public static func afterReconnect(
    activeProfileID: UUID,
    focusedPaneID: UUID?
  ) -> (activeProfileID: UUID, focusedPaneID: UUID?) {
    (activeProfileID, focusedPaneID)
  }

  /// 当前活动机器被禁用或移除后的活动机器解析。
  ///
  /// 规则：
  /// - 被禁用/移除的不是当前活动机器 → 什么都不变。
  /// - 是当前活动机器 → **回 Local**，绝不自动挑另一台远端。
  /// - Local 本身不可用 → 仍然回 Local，并保留 Local 的明确错误态；
  ///   `localFailureReason` 非 nil 就是这个状态，调用方必须展示它而不是换一台机器。
  ///
  /// - Parameters:
  ///   - activeProfileID: 当前活动机器。
  ///   - affectedProfileID: 被禁用或移除的配置。
  ///   - localFailureReason: Local 的错误原因；Local 正常时为 nil。
  public static func afterDisableOrRemove(
    activeProfileID: UUID,
    affectedProfileID: UUID,
    localFailureReason: String? = nil
  ) -> ActiveMachineResolution {
    guard activeProfileID == affectedProfileID else {
      return ActiveMachineResolution(activeProfileID: activeProfileID, focusChanged: false)
    }
    return ActiveMachineResolution(
      activeProfileID: MachineProfile.localProfileID,
      focusChanged: true,
      localFailureReason: localFailureReason
    )
  }
}
