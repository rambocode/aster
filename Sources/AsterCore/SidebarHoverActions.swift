import CoreGraphics
import Foundation

/// 侧栏顶部两个悬停动作按钮（「+ 新建标签页」与「折叠/展开标签栏」）的可见性规则。
///
/// 两个按钮虽然并排显示，但触发区域不同：「+」属于整个左栏，「折叠」只属于红绿灯
/// 那一行。规则写成纯函数是为了能脱离 AppKit 断言完整真值表——视图层只负责把指针
/// 和两个区域换算到同一坐标系。
public struct SidebarHoverActionVisibility: Equatable, Sendable {
  public var showsNewTab: Bool
  public var showsCollapseToggle: Bool

  public init(showsNewTab: Bool, showsCollapseToggle: Bool) {
    self.showsNewTab = showsNewTab
    self.showsCollapseToggle = showsCollapseToggle
  }

  /// 两个按钮都不显示。
  public static let hidden = SidebarHoverActionVisibility(
    showsNewTab: false, showsCollapseToggle: false)

  /// 按指针位置解析可见性。所有参数使用同一坐标系（宿主层统一换算到窗口坐标）。
  ///
  /// - Parameters:
  ///   - pointer: 指针位置；窗口不是键盘焦点窗口时传 `nil`，后台窗口不露出动作按钮。
  ///   - sidebar: 左栏区域；标签栏折叠时宿主层传顶部悬停带，用户仍能拿到「+」。
  ///   - titleBarRow: 红绿灯所在那一行的区域。
  public static func resolve(
    pointer: CGPoint?,
    sidebar: CGRect?,
    titleBarRow: CGRect?
  ) -> SidebarHoverActionVisibility {
    guard let pointer else { return .hidden }
    let inSidebar = sidebar?.contains(pointer) ?? false
    let inTitleBarRow = titleBarRow?.contains(pointer) ?? false
    // 红绿灯行在展开态嵌在左栏内部，指针停在那里时「+」同样保持可见，光标从标签
    // 列表移到按钮上的整个过程中「+」不会闪断。
    return SidebarHoverActionVisibility(
      showsNewTab: inSidebar || inTitleBarRow,
      showsCollapseToggle: inTitleBarRow
    )
  }
}
